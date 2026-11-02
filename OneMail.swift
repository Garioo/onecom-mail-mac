// one.com Mail — a personal, unofficial Mac app for one.com email.
// Native mail (IMAP/SMTP) plus one.com Webmail and the Control Panel in web views.
// Build with ./build.sh (needs Xcode Command Line Tools).

import Cocoa
import Combine
import SwiftUI
import WebKit
import UserNotifications
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers

let webmailURL = URL(string: "https://mail.one.com/")!
let controlPanelURL = URL(string: "https://login.one.com/")!
let appName = "one.com Mail"

/// Pages on one.com (and its subdomains) stay inside the app; everything else opens in your browser.
func isOneCom(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return true }
    return host == "one.com" || host.hasSuffix(".one.com")
}

func isExternalWeb(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased() ?? ""
    return (scheme == "http" || scheme == "https") && !isOneCom(url)
}

func symbol(_ name: String, _ label: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: label)
}

/// The places in the sidebar.
enum AppSection: Int, CaseIterable {
    case mail, webmail, controlPanel

    var title: String {
        switch self {
        case .mail: return "Mail"
        case .webmail: return "Webmail"
        case .controlPanel: return "Control Panel"
        }
    }

    var symbolName: String {
        switch self {
        case .mail: return "envelope"
        case .webmail: return "globe"
        case .controlPanel: return "slider.horizontal.3"
        }
    }

    var startURL: URL { self == .controlPanel ? controlPanelURL : webmailURL }
}

@main
struct OneMailApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

// MARK: - Notification clicks

/// Handles clicks on macOS notifications (kept separate from the main-actor app delegate).
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            (NSApp.delegate as? AppDelegate)?.showMail(nil)
        }
        completionHandler()
    }
}

// MARK: - Sidebar

/// Window-level state the sidebar and toolbar share with the app delegate.
@MainActor
final class ShellModel: ObservableObject {
    @Published var section: AppSection = .mail
    @Published var updateAvailable = false
    @Published var updateBuilding = false
}

enum SidebarItem: Hashable {
    case folder(String)
    case section(AppSection)
}

/// The source list: your mailboxes, your own folders, then one.com's web pages.
struct SidebarView: View {
    @ObservedObject var store: MailStore
    @ObservedObject var shell: ShellModel
    let select: (SidebarItem) -> Void
    let installUpdate: () -> Void
    @State private var dropTarget: String?
    let newFolder: () -> Void
    let renameFolder: (MailFolder) -> Void
    let deleteFolder: (MailFolder) -> Void

    private var mailboxes: [MailFolder] { store.folders.filter { $0.role != .other } }
    private var custom: [MailFolder] { store.folders.filter { $0.role == .other } }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if shell.section != .mail { return .section(shell.section) }
                if store.account == nil { return .section(.mail) }
                return store.currentFolder.map { .folder($0.path) }
            },
            set: { item in if let item = item { select(item) } })
    }

    @ViewBuilder
    private func row(_ folder: MailFolder) -> some View {
        let unread = folder.role == .inbox ? (store.inboxUnread ?? 0) : 0
        Label(folder.name, systemImage: folder.role.symbol)
            .badge(unread)
            .help(folder.name)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(.horizontal, -6)
                .opacity(dropTarget == folder.path ? 1 : 0))
            .onDrop(of: [UTType.plainText], isTargeted: Binding(
                get: { dropTarget == folder.path },
                set: { on in
                    if on { dropTarget = folder.path } else if dropTarget == folder.path { dropTarget = nil }
                })) { providers in
                guard folder.role != .drafts, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let ids = (text as? String).flatMap(MessageDrag.ids(from:)) else { return }
                    Task { @MainActor in store.move(ids, to: folder) }
                }
                return true
            }
            .tag(SidebarItem.folder(folder.path))
            .contextMenu {
                // Inbox, Sent, Trash and the other mailboxes belong to the server; only your own folders change.
                if folder.role == .other {
                    Button("Rename “\(folder.name)”…") { renameFolder(folder) }
                    Button("Delete “\(folder.name)”…") { deleteFolder(folder) }
                    Divider()
                }
                Button("New Folder…", action: newFolder)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                if store.account == nil {
                    Section("Mail") {
                        Label("Sign In", systemImage: "envelope").tag(SidebarItem.section(.mail))
                    }
                } else {
                    Section("Mailboxes") {
                        ForEach(mailboxes) { row($0) }
                    }
                    if !custom.isEmpty {
                        Section("Folders") {
                            ForEach(custom) { row($0) }
                        }
                    }
                }
                Section("one.com") {
                    Label("Webmail", systemImage: AppSection.webmail.symbolName)
                        .tag(SidebarItem.section(.webmail))
                    Label("Control Panel", systemImage: AppSection.controlPanel.symbolName)
                        .tag(SidebarItem.section(.controlPanel))
                }
            }
            .listStyle(.sidebar)
            .contextMenu {
                if store.account != nil { Button("New Folder…", action: newFolder) }
            }

            VStack(alignment: .leading, spacing: 8) {
                if shell.updateAvailable || shell.updateBuilding {
                    Button(action: installUpdate) {
                        Label(shell.updateBuilding ? "Updating…" : "Install Update",
                              systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(shell.updateBuilding)
                    .help("A new version is ready. Drafts are saved first, then the app restarts.")
                }
                if store.account != nil {
                    Button(action: newFolder) {
                        Label("New Folder", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .help("Make a new folder on the server")
                }
                Text(store.account?.email ?? "Unofficial app for one.com")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.account == nil ? "" : "Signed in as \(store.account?.email ?? "")")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Content area

final class ProgressLine: NSView {
    private let fill = CALayer()
    var progress: Double = 0 { didSet { needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height)
    }
}

/// Shows either the native mail view or one of the web views, with a loading line for web pages.
@MainActor
final class ContentViewController: NSViewController {
    private let progressLine = ProgressLine()
    private(set) var current: NSView?
    private var observations: [NSKeyValueObservation] = []

    override func loadView() {
        let v = NSView()
        progressLine.translatesAutoresizingMaskIntoConstraints = false
        progressLine.isHidden = true
        v.addSubview(progressLine)
        NSLayoutConstraint.activate([
            progressLine.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor),
            progressLine.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            progressLine.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            progressLine.heightAnchor.constraint(equalToConstant: 2),
        ])
        view = v
    }

    func show(_ content: NSView) {
        guard content !== current else { return }
        current?.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content, positioned: .below, relativeTo: progressLine)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = content

        observations = []
        if let webView = content as? WKWebView {
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.updateProgress() }
                },
                webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor in self?.updateProgress() }
                },
            ]
        }
        updateProgress()
    }

    private func updateProgress() {
        guard let webView = current as? WKWebView else {
            progressLine.isHidden = true
            return
        }
        progressLine.isHidden = !webView.isLoading
        progressLine.progress = webView.estimatedProgress
    }
}

// MARK: - Toolbar identifiers

extension NSToolbarItem.Identifier {
    static let back = NSToolbarItem.Identifier("back")
    static let forward = NSToolbarItem.Identifier("forward")
    static let reload = NSToolbarItem.Identifier("reload")
    static let home = NSToolbarItem.Identifier("home")
    static let browser = NSToolbarItem.Identifier("browser")
    static let cleanUp = NSToolbarItem.Identifier("cleanUp")
    static let compose = NSToolbarItem.Identifier("compose")
    static let getMail = NSToolbarItem.Identifier("getMail")
    static let reply = NSToolbarItem.Identifier("reply")
    static let replyAll = NSToolbarItem.Identifier("replyAll")
    static let forwardMessage = NSToolbarItem.Identifier("forwardMessage")
    static let archive = NSToolbarItem.Identifier("archive")
    static let trash = NSToolbarItem.Identifier("trash")
    static let flag = NSToolbarItem.Identifier("flag")
    static let readUnread = NSToolbarItem.Identifier("readUnread")
    static let search = NSToolbarItem.Identifier("search")
    static let send = NSToolbarItem.Identifier("send")
    static let attach = NSToolbarItem.Identifier("attach")
    static let saveDraft = NSToolbarItem.Identifier("saveDraft")
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation,
                         NSToolbarDelegate, NSToolbarItemValidation, NSSearchFieldDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    var window: NSWindow!
    let shell = ShellModel()
    var content: ContentViewController!
    var currentAppSection: AppSection = .mail
    var mailToolbar: NSToolbar!
    var webToolbar: NSToolbar!
    weak var searchField: NSSearchField?
    var cancellables: [AnyCancellable] = []
    var composeCancellables: [ObjectIdentifier: [AnyCancellable]] = [:]

    /// Reading size for the message list and reader: 0 is standard, each step about 8% bigger.
    var mailTextSize: Int {
        get { UserDefaults.standard.integer(forKey: "mailTextSize") }
        set { UserDefaults.standard.set(min(max(newValue, -1), 4), forKey: "mailTextSize") }
    }

    var darkenEmails: Bool {
        get { UserDefaults.standard.object(forKey: "darkenEmails") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "darkenEmails") }
    }

    var mailStore: MailStore!
    var mailView: NSView!
    var webmailWebView: WKWebView?
    var controlWebView: WKWebView?
    var popups: [NSWindow] = []
    var composeWindows: [NSWindow] = []
    var composeModels: [ObjectIdentifier: ComposeModel] = [:]
    var updater: Updater!
    /// Release builds (downloaded from GitHub) update through Sparkle; builds from this folder use `updater`.
    var sparkle: SPUStandardUpdaterController?
    private var updateNotified = false
    var downloadDestinations: [ObjectIdentifier: URL] = [:]
    var observations: [NSKeyValueObservation] = []

    var statusItem: NSStatusItem!
    let notificationHandler = NotificationHandler()

    var notificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "notifyNewMail") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyNewMail") }
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        updater = Updater()
        if updater.sourceFolder == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            sparkle = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
        buildMenu()
        buildStatusItem()

        let center = UNUserNotificationCenter.current()
        center.delegate = notificationHandler
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        mailStore = MailStore()
        mailStore.onUnreadChanged = { [weak self] count in self?.unreadChanged(count) }
        mailStore.onNewMail = { [weak self] messages in self?.notifyNewMail(messages) }
        mailStore.onCompose = { [weak self] draft in self?.openCompose(draft) }
        mailStore.onFolderChanged = { [weak self] in self?.titlesChanged() }
        mailView = NSHostingView(rootView: MailRootView(store: mailStore))

        buildMainWindow()
        select(.mail)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Keep the window title, toolbar buttons and search field in step with the mail state.
        mailStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.titlesChanged()
                self?.window.toolbar?.validateVisibleItems()
                if let field = self?.searchField, field.currentEditor() == nil,
                   field.stringValue != self?.mailStore.searchText {
                    field.stringValue = self?.mailStore.searchText ?? ""
                }
            }
            .store(in: &cancellables)

        updater.onChange = { [weak self] in self?.updaterChanged() }
        updater.onUpdateFound = { [weak self] in self?.notifyUpdateReady() }
        updater.onFailure = { [weak self] log in self?.showUpdateFailure(log) }
        updater.start()
    }

    // MARK: Updates

    func updaterChanged() {
        shell.updateAvailable = updater.updateAvailable
        shell.updateBuilding = updater.isBuilding
    }

    func notifyUpdateReady() {
        guard !updateNotified else { return }
        updateNotified = true
        let note = UNMutableNotificationContent()
        note.title = "Update ready"
        note.body = "A new version of one.com Mail is ready. Click Install Update at the bottom of the sidebar."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "update-ready", content: note, trigger: nil))
    }

    @objc func installUpdate(_ sender: Any?) {
        guard updater.updateAvailable, !updater.isBuilding else { return }
        // Save any drafts being written first, so nothing is lost when the app restarts.
        let models = Array(composeModels.values).filter { $0.hasContent && $0.dirty }
        Task {
            for model in models { await model.saveDraft() }
            updater.install()
        }
    }

    @objc func checkForUpdates(_ sender: Any?) { sparkle?.checkForUpdates(sender) }

    func showUpdateFailure(_ log: String) {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        let errorLines = lines.filter { $0.contains("error:") }
        let summary = (errorLines.isEmpty ? Array(lines.suffix(12)) : Array(errorLines.prefix(8)))
            .joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "The update couldn't be built"
        alert.informativeText = "Your current version keeps working. Copy the error log and send it to Claude to get it fixed.\n\n" + summary
        alert.addButton(withTitle: "Copy Error Log")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(log, forType: .string)
        }
    }

    func buildMainWindow() {
        let sidebar = NSHostingController(rootView: SidebarView(
            store: mailStore, shell: shell,
            select: { [weak self] item in self?.select(item) },
            installUpdate: { [weak self] in self?.installUpdate(nil) },
            newFolder: { [weak self] in self?.newFolder(nil) },
            renameFolder: { [weak self] folder in self?.askToRename(folder) },
            deleteFolder: { [weak self] folder in self?.askToDelete(folder) }))
        content = ContentViewController()

        let split = NSSplitViewController()
        split.splitView.autosaveName = "MailSplit"   // new name: the redesign starts with the sidebar showing
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 190
        sideItem.maximumThickness = 280
        sideItem.canCollapse = true
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1340, height: 860))
        window.minSize = NSSize(width: 900, height: 560)
        window.center()
        window.setFrameAutosaveName("MainWindow")   // remembers size and position

        func makeToolbar(_ id: String) -> NSToolbar {
            let toolbar = NSToolbar(identifier: id)
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = true
            toolbar.autosavesConfiguration = true
            return toolbar
        }
        mailToolbar = makeToolbar("MailToolbar")
        webToolbar = makeToolbar("MainToolbar")
        window.toolbar = mailToolbar
        window.toolbarStyle = .unified
    }

    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()           // keeps you logged in between launches
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        return makeWebView(config)
    }

    func makeWebView(_ config: WKWebViewConfiguration) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        return wv
    }

    func view(for section: AppSection) -> NSView {
        switch section {
        case .mail:
            return mailView
        case .webmail:
            if let webmailWebView = webmailWebView { return webmailWebView }
            let wv = makeWebView()
            watch(wv)
            webmailWebView = wv
            wv.load(URLRequest(url: webmailURL))
            return wv
        case .controlPanel:
            if let controlWebView = controlWebView { return controlWebView }
            let wv = makeWebView()
            watch(wv)
            controlWebView = wv
            wv.load(URLRequest(url: controlPanelURL))
            return wv
        }
    }

    func watch(_ webView: WKWebView) {
        observations.append(webView.observe(\.title, options: [.new]) { _, _ in
            Task { @MainActor in (NSApp.delegate as? AppDelegate)?.titlesChanged() }
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { _, _ in
            Task { @MainActor in (NSApp.delegate as? AppDelegate)?.window?.toolbar?.validateVisibleItems() }
        })
    }

    /// Switches the main window between Mail, Webmail and Control Panel.
    func select(_ section: AppSection) {
        currentAppSection = section
        shell.section = section
        content.show(view(for: section))
        let toolbar: NSToolbar = section == .mail ? mailToolbar : webToolbar
        if window.toolbar !== toolbar { window.toolbar = toolbar }
        titlesChanged()
        window.toolbar?.validateVisibleItems()
    }

    /// A sidebar click: a mailbox opens in Mail, the one.com rows switch to their web page.
    func select(_ item: SidebarItem) {
        switch item {
        case .section(let section):
            if section != currentAppSection { select(section) }
        case .folder(let path):
            if currentAppSection != .mail { select(.mail) }
            if let folder = mailStore.folder(path: path), mailStore.currentFolder?.path != path {
                mailStore.open(folder: folder)
            }
        }
    }

    func titlesChanged() {
        guard let window = window else { return }
        window.title = currentAppSection.title
        if currentAppSection == .mail {
            guard mailStore.account != nil, let folder = mailStore.currentFolder else {
                window.subtitle = ""
                return
            }
            window.title = folder.name
            if folder.role == .inbox, let n = mailStore.inboxUnread, n > 0 {
                window.subtitle = "\(n.formatted()) unread"
            } else {
                window.subtitle = ""
            }
        } else {
            window.subtitle = (view(for: currentAppSection) as? WKWebView)?.title ?? ""
        }
    }

    // Closing the window keeps the app running; clicking the Dock or menu bar icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: Unread count and notifications

    func unreadChanged(_ count: Int?) {
        let shown = (count ?? 0) > 0 ? count : nil
        NSApp.dockTile.badgeLabel = shown.map { String($0) }
        statusItem.button?.title = shown.map { " \($0)" } ?? ""
    }

    func notifyNewMail(_ messages: [MessageSummary]) {
        guard notificationsEnabled, !messages.isEmpty else { return }
        // Skip if you're already looking at your mail.
        if NSApp.isActive && window.isKeyWindow && currentAppSection == .mail
            && mailStore.currentFolder?.role == .inbox { return }
        let note = UNMutableNotificationContent()
        if messages.count == 1, let m = messages.first {
            note.title = m.from?.display ?? "New email"
            note.subtitle = m.subject.isEmpty ? "(No subject)" : m.subject
            note.body = m.snippet
        } else {
            note.title = "\(messages.count) new emails"
            let senders = messages.prefix(4).compactMap { $0.from?.display }
            note.body = senders.joined(separator: ", ")
        }
        note.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: note, trigger: nil))
    }

    // MARK: Compose windows

    func openCompose(_ draft: ComposeDraft) {
        let model = ComposeModel(draft: draft, store: mailStore)
        let host = NSHostingController(rootView: ComposeView(model: model))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.setContentSize(NSSize(width: 720, height: 600))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        let toolbar = NSToolbar(identifier: "ComposeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        w.toolbar = toolbar
        w.toolbarStyle = .unified
        model.close = { [weak w] in w?.close() }
        composeWindows.append(w)
        composeModels[ObjectIdentifier(w)] = model

        // Title follows the subject; the subtitle says whether the draft is saved.
        composeCancellables[ObjectIdentifier(w)] = [
            model.$draft.map(\.subject).removeDuplicates().sink { [weak w] subject in
                let s = subject.trimmingCharacters(in: .whitespaces)
                w?.title = s.isEmpty ? "New Message" : s
            },
            Publishers.CombineLatest3(model.$isSending, model.$isSavingDraft, model.$lastSaved)
                .sink { [weak w] sending, saving, saved in
                    w?.subtitle = sending ? "Sending…"
                        : saving ? "Saving draft…"
                        : saved.map { "Draft saved \(MailDate.listString($0))" } ?? ""
                    w?.toolbar?.validateVisibleItems()
                },
        ]
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Menu bar icon

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = symbol("envelope", appName)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.toolTip = appName
        }

        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            i.target = self
        }
        item("Open Mail", #selector(showMail(_:)))
        item("New Message", #selector(newMessage(_:)))
        item("Open Control Panel", #selector(showControlPanel(_:)))
        menu.addItem(.separator())
        item("Notify on New Mail", #selector(toggleNotifications(_:)))
        item("Launch at Login", #selector(toggleLaunchAtLogin(_:)))
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        statusItem.menu = menu
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        switch toolbar.identifier {
        case "MailToolbar":
            return [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .cleanUp, .compose, .space,
                    .reply, .replyAll, .forwardMessage, .space, .archive, .trash, .flag, .search]
        case "ComposeToolbar":
            return [.send, .flexibleSpace, .attach, .saveDraft]
        default:
            return [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .flexibleSpace, .home, .reload, .browser]
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        switch toolbar.identifier {
        case "MailToolbar":
            return [.toggleSidebar, .sidebarTrackingSeparator, .cleanUp, .compose, .getMail, .reply, .replyAll,
                    .forwardMessage, .archive, .trash, .flag, .readUnread, .search, .flexibleSpace, .space]
        case "ComposeToolbar":
            return [.send, .attach, .saveDraft, .flexibleSpace, .space]
        default:
            return [.toggleSidebar, .sidebarTrackingSeparator, .back, .forward, .home, .reload, .browser, .flexibleSpace, .space]
        }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func make(_ label: String, _ symbolName: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = symbol(symbolName, label)
            item.isBordered = true
            item.target = self
            item.action = action
            return item
        }
        switch id {
        case .back: return make("Back", "chevron.left", #selector(goBackPage(_:)))
        case .forward: return make("Forward", "chevron.right", #selector(goForwardPage(_:)))
        case .reload: return make("Reload", "arrow.clockwise", #selector(reloadPage(_:)))
        case .home: return make("Start Page", "house", #selector(goHome(_:)))
        case .browser: return make("Open in Browser", "safari", #selector(openInBrowser(_:)))

        case .cleanUp:
            // Clean Up is the app's signature: it keeps its words so nobody has to guess the icon.
            let item = NSToolbarItem(itemIdentifier: id)
            let button = NSButton(title: "Clean Up", image: symbol("wand.and.stars", "Clean Up") ?? NSImage(),
                                  target: self, action: #selector(openCleanup(_:)))
            button.imagePosition = .imageLeading
            button.bezelStyle = .texturedRounded
            button.toolTip = "Clear out lots of mail at once, sender by sender (⇧⌘K)"
            item.view = button
            item.label = "Clean Up"
            item.paletteLabel = "Clean Up"
            item.target = self
            item.action = #selector(openCleanup(_:))
            return item
        case .compose: return make("New Message", "square.and.pencil", #selector(newMessage(_:)))
        case .getMail: return make("Get Mail", "arrow.clockwise", #selector(getNewMail(_:)))
        case .reply: return make("Reply", "arrowshape.turn.up.left", #selector(replyMessage(_:)))
        case .replyAll: return make("Reply All", "arrowshape.turn.up.left.2", #selector(replyAllMessage(_:)))
        case .forwardMessage: return make("Forward", "arrowshape.turn.up.right", #selector(forwardMessage(_:)))
        case .archive: return make("Archive", "archivebox", #selector(archiveMessage(_:)))
        case .trash: return make("Delete", "trash", #selector(deleteMessage(_:)))
        case .flag: return make("Flag", "flag", #selector(toggleFlagMessage(_:)))
        case .readUnread: return make("Read/Unread", "envelope.badge", #selector(toggleReadMessage(_:)))
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "Search"
            item.paletteLabel = "Search"
            item.preferredWidthForSearchField = 220
            let field = item.searchField
            field.placeholderString = "Search"
            field.target = self
            field.action = #selector(searchChanged(_:))
            field.delegate = self
            field.stringValue = mailStore?.searchText ?? ""
            searchField = field
            return item

        case .send:
            let item = make("Send", "paperplane", #selector(sendCompose(_:)))
            item.toolTip = "Send (⌘↩)"
            return item
        case .attach: return make("Attach", "paperclip", #selector(attachInCompose(_:)))
        case .saveDraft: return make("Save Draft", "square.and.arrow.down", #selector(saveDraftInCompose(_:)))
        default: return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let signedIn = mailStore?.account != nil
        let hasSelection = !(mailStore?.selection.isEmpty ?? true)
        let mailShown = currentAppSection == .mail && signedIn
        switch item.itemIdentifier {
        case .back: return activeWebView?.canGoBack ?? false
        case .forward: return activeWebView?.canGoForward ?? false
        case .cleanUp, .compose, .getMail, .search: return signedIn
        case .reply, .replyAll, .forwardMessage:
            return mailShown && mailStore.opened != nil && mailStore.selection.count <= 1 && !mailStore.openedIsDraft
        case .trash, .readUnread: return mailShown && hasSelection
        case .flag:
            if mailShown && hasSelection {
                item.image = symbol(mailStore.selectionAllFlagged ? "flag.fill" : "flag", "Flag")
                item.label = mailStore.selectionAllFlagged ? "Unflag" : "Flag"
            }
            return mailShown && hasSelection
        case .archive: return mailShown && hasSelection && mailStore.selectionCanArchive
        case .send, .attach, .saveDraft:
            guard let model = composeModel(for: item) else { return false }
            return !model.isSending && (item.itemIdentifier != .saveDraft || !model.isSavingDraft)
        default: return true
        }
    }

    private func composeModel(for item: NSToolbarItem) -> ComposeModel? {
        guard let w = composeWindows.first(where: { $0.toolbar === item.toolbar }) else { return nil }
        return composeModels[ObjectIdentifier(w)]
    }

    // MARK: Search field

    @objc func searchChanged(_ sender: NSSearchField) {
        if mailStore.searchText != sender.stringValue { mailStore.searchText = sender.stringValue }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            mailStore.searchText = searchField?.stringValue ?? ""
            mailStore.submitSearch()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            searchField?.stringValue = ""
            mailStore.searchText = ""
            window.makeFirstResponder(nil)
            return true
        }
        return false
    }

    // MARK: Showing sections

    @objc func showMail(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        select(.mail)
    }

    @objc func showWebmail(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        select(.webmail)
    }

    @objc func showControlPanel(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        select(.controlPanel)
    }

    // MARK: Message actions

    /// True when the main window is in front showing Mail, and you're not typing in a text field.
    private var mailIsFocused: Bool {
        guard NSApp.keyWindow === window, currentAppSection == .mail, mailStore.account != nil else { return false }
        return !(window.firstResponder is NSText)
    }

    @objc func newMessage(_ sender: Any?) {
        mailStore.newMessage()
    }

    @objc func getNewMail(_ sender: Any?) { mailStore.refresh() }

    /// Asks for a name, makes the folder on the server and opens it. On a problem it asks again.
    @objc func newFolder(_ sender: Any?) {
        askForFolderName(title: "New Folder", button: "Create", prefill: "",
                         note: "The folder is made on one.com, so it also shows up in Webmail and on your phone.") {
            await self.mailStore.createFolder(named: $0)
        }
    }

    /// The open folder, when it's one of your own (the File menu's Rename and Delete act on it).
    private var openCustomFolder: MailFolder? {
        guard currentAppSection == .mail, let f = mailStore?.currentFolder, f.role == .other else { return nil }
        return f
    }

    @objc func renameOpenFolder(_ sender: Any?) { if let f = openCustomFolder { askToRename(f) } }
    @objc func deleteOpenFolder(_ sender: Any?) { if let f = openCustomFolder { askToDelete(f) } }

    func askToRename(_ folder: MailFolder) {
        askForFolderName(title: "Rename “\(folder.name)”", button: "Rename", prefill: folder.name,
                         note: "The new name shows up everywhere you read this mail.") {
            await self.mailStore.renameFolder(folder, to: $0)
        }
    }

    /// Asks for a name and runs `commit`; if it reports a problem, asks again with the name kept.
    private func askForFolderName(title: String, button: String, prefill: String, note: String,
                                  problem: String? = nil, commit: @escaping (String) async -> String?) {
        if currentAppSection != .mail { select(.mail) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = problem ?? note
        if problem != nil { alert.alertStyle = .warning }
        let field = NSTextField(string: prefill)
        field.placeholderString = "Folder name"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            let name = field.stringValue
            Task { @MainActor in
                if let error = await commit(name) {
                    self.askForFolderName(title: title, button: button, prefill: name, note: note,
                                          problem: error, commit: commit)
                }
            }
        }
    }

    /// Deleting a folder deletes its mail for good, so it says how much and Cancel is the default.
    func askToDelete(_ folder: MailFolder) {
        if currentAppSection != .mail { select(.mail) }
        Task { @MainActor in
            let count = await mailStore.messageCount(in: folder)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Delete “\(folder.name)”?"
            switch count {
            case 0?: alert.informativeText = "The folder is empty."
            case 1?: alert.informativeText = "The email in it will be deleted permanently from one.com. This can't be undone."
            case let n?: alert.informativeText = "The \(n.formatted()) emails in it will be deleted permanently from one.com. This can't be undone. To keep any, move them to another folder first."
            case nil: alert.informativeText = "Everything in it will be deleted permanently from one.com. This can't be undone."
            }
            let delete = alert.addButton(withTitle: "Delete Folder")
            delete.hasDestructiveAction = true
            delete.keyEquivalent = ""
            let cancel = alert.addButton(withTitle: "Cancel")
            cancel.keyEquivalent = "\r"
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self = self else { return }
                Task { @MainActor in
                    if let error = await self.mailStore.deleteFolder(folder) {
                        self.showAlert("Couldn't delete “\(folder.name)”.", info: error)
                    }
                }
            }
        }
    }
    @objc func replyMessage(_ sender: Any?) { mailStore.reply(all: false) }
    @objc func replyAllMessage(_ sender: Any?) { mailStore.reply(all: true) }
    @objc func forwardMessage(_ sender: Any?) { mailStore.forward() }

    @objc func deleteMessage(_ sender: Any?) { mailStore.deleteSelection() }
    @objc func archiveMessage(_ sender: Any?) { mailStore.archiveSelection() }
    @objc func toggleReadMessage(_ sender: Any?) { mailStore.setSelectionRead(!mailStore.selectionAllRead) }
    @objc func toggleFlagMessage(_ sender: Any?) { mailStore.setSelectionFlagged(!mailStore.selectionAllFlagged) }

    @objc func openCleanup(_ sender: Any?) {
        showMail(nil)
        mailStore.openCleanup()
    }

    @objc func editDraftMessage(_ sender: Any?) { mailStore.editDraft() }

    private var keyComposeModel: ComposeModel? {
        guard let key = NSApp.keyWindow else { return nil }
        return composeModels[ObjectIdentifier(key)]
    }

    /// The compose window a toolbar button sits in, or the one in front for menu commands.
    private func composeTarget(_ sender: Any?) -> ComposeModel? {
        if let item = sender as? NSToolbarItem { return composeModel(for: item) }
        return keyComposeModel
    }

    @objc func sendCompose(_ sender: Any?) { composeTarget(sender)?.send() }
    @objc func saveDraftInCompose(_ sender: Any?) { composeTarget(sender)?.saveDraftNow() }

    @objc func attachInCompose(_ sender: Any?) {
        guard let model = composeTarget(sender),
              let w = composeWindows.first(where: { composeModels[ObjectIdentifier($0)] === model }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.beginSheetModal(for: w) { result in
            if result == .OK { model.addAttachments(panel.urls) }
        }
    }

    @objc func insertLinkInCompose(_ sender: Any?) { keyComposeModel?.editor.insertLink() }
    @objc func toggleBulletsInCompose(_ sender: Any?) { keyComposeModel?.editor.toggleBullets() }
    @objc func biggerInCompose(_ sender: Any?) { keyComposeModel?.editor.bigger() }
    @objc func smallerInCompose(_ sender: Any?) { keyComposeModel?.editor.smaller() }

    @objc func signOutOfMail(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Sign out of \(mailStore.account?.email ?? "your mailbox")?"
        alert.informativeText = "Your password will be removed from this Mac's Keychain. Your mail stays on one.com."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { mailStore.signOut() }
    }

    // MARK: Settings toggles

    @objc func toggleNotifications(_ sender: Any?) {
        notificationsEnabled.toggle()
    }

    @objc func toggleLaunchAtLogin(_ sender: Any?) {
        guard #available(macOS 13.0, *) else {
            showAlert("Launch at Login needs macOS 13 Ventura or later.",
                      info: "On older macOS, add the app in System Settings → Users & Groups → Login Items.")
            return
        }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            showAlert("Couldn't change Launch at Login.",
                      info: "\(error.localizedDescription)\n\nTip: move the app into your Applications folder first.")
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func showAlert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasSelection = !(mailStore?.selection.isEmpty ?? true)
        let hasOpen = mailStore?.opened != nil
        switch menuItem.action {
        case #selector(toggleNotifications(_:)):
            menuItem.state = notificationsEnabled ? .on : .off
        case #selector(toggleLaunchAtLogin(_:)):
            if #available(macOS 13.0, *) {
                switch SMAppService.mainApp.status {
                case .enabled: menuItem.state = .on
                case .requiresApproval: menuItem.state = .mixed
                default: menuItem.state = .off
                }
            } else {
                menuItem.state = .off
            }
        case #selector(showMail(_:)):
            menuItem.state = (currentAppSection == .mail && menuItem.menu !== statusItem.menu) ? .on : .off
        case #selector(showWebmail(_:)):
            menuItem.state = currentAppSection == .webmail ? .on : .off
        case #selector(showControlPanel(_:)):
            menuItem.state = (currentAppSection == .controlPanel && menuItem.menu !== statusItem.menu) ? .on : .off
        case #selector(newMessage(_:)), #selector(getNewMail(_:)), #selector(signOutOfMail(_:)), #selector(newFolder(_:)):
            return mailStore?.account != nil
        case #selector(replyMessage(_:)), #selector(replyAllMessage(_:)), #selector(forwardMessage(_:)):
            return mailIsFocused && hasOpen && !mailStore.openedIsDraft
        case #selector(deleteMessage(_:)), #selector(toggleReadMessage(_:)), #selector(toggleFlagMessage(_:)):
            return mailIsFocused && hasSelection
        case #selector(archiveMessage(_:)):
            return mailIsFocused && hasSelection && mailStore.selectionCanArchive
        case #selector(openCleanup(_:)):
            return mailStore?.account != nil
        case #selector(editDraftMessage(_:)):
            return mailIsFocused && mailStore.openedIsDraft
        case #selector(insertLinkInCompose(_:)), #selector(toggleBulletsInCompose(_:)),
             #selector(biggerInCompose(_:)), #selector(smallerInCompose(_:)):
            return keyComposeModel != nil
        case #selector(checkForUpdates(_:)):
            menuItem.isHidden = sparkle == nil
            return sparkle?.updater.canCheckForUpdates ?? false
        case #selector(installUpdate(_:)):
            menuItem.isHidden = updater.sourceFolder == nil
            menuItem.title = updater.isBuilding ? "Updating…" : "Install Update…"
            return updater.updateAvailable && !updater.isBuilding
        case #selector(goBackPage(_:)):
            return activeWebView?.canGoBack ?? false
        case #selector(goForwardPage(_:)):
            return activeWebView?.canGoForward ?? false
        case #selector(zoomInPage(_:)), #selector(zoomOutPage(_:)), #selector(actualSizePage(_:)):
            return zoomsMail ? mailStore.account != nil : activeWebView != nil
        case #selector(renameOpenFolder(_:)), #selector(deleteOpenFolder(_:)):
            return openCustomFolder != nil
        case #selector(toggleDarkenEmails(_:)):
            menuItem.state = darkenEmails ? .on : .off
        case #selector(sendCompose(_:)), #selector(attachInCompose(_:)):
            return !(keyComposeModel?.isSending ?? true)
        case #selector(saveDraftInCompose(_:)):
            guard let model = keyComposeModel else { return false }
            return !model.isSending && !model.isSavingDraft
        default:
            break
        }
        return true
    }

    // MARK: Web navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""

        if action.shouldPerformDownload { decisionHandler(.download); return }

        // mailto: links open a compose window here; tel:, facetime: etc. go to the system.
        if scheme == "mailto", mailStore.account != nil {
            var draft = ComposeDraft()
            let parts = url.absoluteString.dropFirst("mailto:".count).split(separator: "?", maxSplits: 1)
            draft.to = parts.first.map { String($0).removingPercentEncoding ?? String($0) } ?? ""
            if parts.count > 1, let query = URLComponents(string: "x:?" + parts[1])?.queryItems {
                for q in query {
                    switch q.name.lowercased() {
                    case "subject": draft.subject = q.value ?? ""
                    case "body": draft.body = RichText.plain(q.value ?? "")
                    case "cc": draft.cc = q.value ?? ""
                    default: break
                    }
                }
            }
            openCompose(draft)
            decisionHandler(.cancel)
            return
        }
        if !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // Links leaving one.com open in your default browser.
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        let isPopup = popups.contains { $0.contentView === webView }
        if isMainFrame && isExternalWeb(url) && (action.navigationType == .linkActivated || isPopup) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            if isPopup && (webView.url == nil || webView.url?.absoluteString == "about:blank") {
                Task { @MainActor in webView.window?.close() }
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window.toolbar?.validateVisibleItems()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" { return }   // e.g. a navigation turned into a download
        let retryURL: URL
        if webView === webmailWebView { retryURL = webmailURL }
        else if webView === controlWebView { retryURL = controlPanelURL }
        else { return }
        webView.loadHTMLString(offlinePage(e.localizedDescription, retry: retryURL), baseURL: nil)
    }

    func offlinePage(_ message: String, retry: URL) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{font:15px -apple-system,sans-serif;display:flex;align-items:center;justify-content:center;
             height:100vh;margin:0;color:#333;background:#f5f5f7}
        @media (prefers-color-scheme:dark){body{color:#ddd;background:#1e1e1e}}
        .box{text-align:center;max-width:420px}
        a{display:inline-block;margin-top:16px;padding:8px 18px;border-radius:8px;background:#4f5fe8;
          color:#fff;text-decoration:none}
        </style></head><body><div class="box">
        <h2>Can't reach one.com</h2><p>\(message)</p>
        <a href="\(retry.absoluteString)">Try again</a></div></body></html>
        """
    }

    // MARK: Pop-up windows (e.g. attachment previews, print views)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, isExternalWeb(url) {
            NSWorkspace.shared.open(url)
            return nil
        }
        let popupView = makeWebView(configuration)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                             width: windowFeatures.width?.doubleValue ?? 960,
                                             height: windowFeatures.height?.doubleValue ?? 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = appName
        w.contentView = popupView
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        popups.append(w)
        return popupView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView !== webmailWebView && webView !== controlWebView { webView.window?.close() }
    }

    /// Closing a compose window with unsaved changes asks whether to keep it as a draft.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model = composeModels[ObjectIdentifier(sender)], model.needsSavePrompt else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save this message as a draft?"
        alert.informativeText = "It will be saved to your Drafts folder so you can finish it later."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { response in
            switch response {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    if await model.saveDraft() { model.finish() }
                }
            case .alertSecondButtonReturn:
                Task { @MainActor in
                    await model.discardAutosavedDraft()
                    model.finish()
                }
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        popups.removeAll { $0 === closing }
        composeWindows.removeAll { $0 === closing }
        composeModels.removeValue(forKey: ObjectIdentifier(closing))?.stop()
        composeCancellables.removeValue(forKey: ObjectIdentifier(closing))
    }

    // MARK: File uploads and JavaScript dialogs (web views)

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: webView.window ?? window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: webView.window ?? window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: webView.window ?? window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    // MARK: Downloads from web views (saved to ~/Downloads)

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var dest = dir.appendingPathComponent(name)
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        downloadDestinations[ObjectIdentifier(download)] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let dest = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            // Bounces the Downloads stack in the Dock, like Safari does.
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"), object: dest.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window) { _ in }
    }

    // MARK: View menu actions

    /// The web view you're looking at: a pop-up window in front, or the selected web section.
    var activeWebView: WKWebView? {
        if let key = NSApp.keyWindow, key !== window, let wv = key.contentView as? WKWebView { return wv }
        return content?.current as? WKWebView
    }

    @objc func goHome(_ sender: Any?) {
        switch currentAppSection {
        case .mail:
            if let inbox = mailStore.inboxFolder { mailStore.open(folder: inbox) }
        case .webmail:
            webmailWebView?.load(URLRequest(url: webmailURL))
        case .controlPanel:
            controlWebView?.load(URLRequest(url: controlPanelURL))
        }
    }

    @objc func reloadPage(_ sender: Any?) {
        if let wv = activeWebView { wv.reload() } else { mailStore.refresh() }
    }

    @objc func goBackPage(_ sender: Any?) { activeWebView?.goBack() }
    @objc func goForwardPage(_ sender: Any?) { activeWebView?.goForward() }

    // In Mail these change the reading size of the list and reader; on web pages they zoom the page.
    private var zoomsMail: Bool {
        NSApp.keyWindow === window && currentAppSection == .mail
    }

    @objc func zoomInPage(_ sender: Any?) {
        if zoomsMail { mailTextSize += 1 } else { setZoom((activeWebView?.pageZoom ?? 1) + 0.1) }
    }
    @objc func zoomOutPage(_ sender: Any?) {
        if zoomsMail { mailTextSize -= 1 } else { setZoom((activeWebView?.pageZoom ?? 1) - 0.1) }
    }
    @objc func actualSizePage(_ sender: Any?) {
        if zoomsMail { mailTextSize = 0 } else { setZoom(1.0) }
    }

    @objc func toggleDarkenEmails(_ sender: Any?) { darkenEmails.toggle() }

    func setZoom(_ value: CGFloat) {
        activeWebView?.pageZoom = min(max(value, 0.5), 3.0)
    }

    @objc func openInBrowser(_ sender: Any?) {
        NSWorkspace.shared.open(activeWebView?.url ?? currentAppSection.startURL)
    }

    // MARK: App menus

    func buildMenu() {
        let mainMenu = NSMenu()

        func submenu(_ title: String, _ fill: (NSMenu) -> Void) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            fill(menu)
            item.submenu = menu
            mainMenu.addItem(item)
            return menu
        }

        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                 _ mods: NSEvent.ModifierFlags = [.command]) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
        }

        _ = submenu(appName) { m in
            add(m, "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
            m.addItem(.separator())
            add(m, "Notify on New Mail", #selector(AppDelegate.toggleNotifications(_:)), "")
            add(m, "Launch at Login", #selector(AppDelegate.toggleLaunchAtLogin(_:)), "")
            m.addItem(.separator())
            add(m, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)), "")
            add(m, "Install Update…", #selector(AppDelegate.installUpdate(_:)), "")
            m.addItem(.separator())
            add(m, "Sign Out of Mail…", #selector(AppDelegate.signOutOfMail(_:)), "")
            m.addItem(.separator())
            add(m, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
            m.addItem(.separator())
            add(m, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        }

        _ = submenu("File") { m in
            add(m, "New Message", #selector(AppDelegate.newMessage(_:)), "n")
            add(m, "New Folder…", #selector(AppDelegate.newFolder(_:)), "n", [.command, .option])
            add(m, "Rename Folder…", #selector(AppDelegate.renameOpenFolder(_:)), "")
            add(m, "Delete Folder…", #selector(AppDelegate.deleteOpenFolder(_:)), "")
            m.addItem(.separator())
            add(m, "Send Message", #selector(AppDelegate.sendCompose(_:)), "\r")
            add(m, "Save Draft", #selector(AppDelegate.saveDraftInCompose(_:)), "s")
            add(m, "Attach Files…", #selector(AppDelegate.attachInCompose(_:)), "a", [.command, .shift])
            m.addItem(.separator())
            add(m, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        }

        _ = submenu("Edit") { m in
            add(m, "Undo", Selector(("undo:")), "z")
            add(m, "Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            add(m, "Cut", #selector(NSText.cut(_:)), "x")
            add(m, "Copy", #selector(NSText.copy(_:)), "c")
            add(m, "Paste", #selector(NSText.paste(_:)), "v")
            add(m, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
            add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
        }

        _ = submenu("View") { m in
            add(m, "Mail", #selector(AppDelegate.showMail(_:)), "1")
            add(m, "Webmail", #selector(AppDelegate.showWebmail(_:)), "2")
            add(m, "Control Panel", #selector(AppDelegate.showControlPanel(_:)), "3")
            m.addItem(.separator())
            add(m, "Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
            m.addItem(.separator())
            add(m, "Start Page", #selector(AppDelegate.goHome(_:)), "h", [.command, .shift])
            add(m, "Reload", #selector(AppDelegate.reloadPage(_:)), "r", [.command, .option])
            m.addItem(.separator())
            add(m, "Actual Size", #selector(AppDelegate.actualSizePage(_:)), "0")
            add(m, "Zoom In", #selector(AppDelegate.zoomInPage(_:)), "+")
            add(m, "Zoom Out", #selector(AppDelegate.zoomOutPage(_:)), "-")
            add(m, "Darken Emails in Dark Mode", #selector(AppDelegate.toggleDarkenEmails(_:)), "")
            m.addItem(.separator())
            add(m, "Open Page in Browser", #selector(AppDelegate.openInBrowser(_:)), "o", [.command, .shift])
            add(m, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        }

        _ = submenu("Message") { m in
            add(m, "Get New Mail", #selector(AppDelegate.getNewMail(_:)), "n", [.command, .shift])
            m.addItem(.separator())
            add(m, "Reply", #selector(AppDelegate.replyMessage(_:)), "r")
            add(m, "Reply All", #selector(AppDelegate.replyAllMessage(_:)), "r", [.command, .shift])
            add(m, "Forward", #selector(AppDelegate.forwardMessage(_:)), "f", [.command, .shift])
            m.addItem(.separator())
            add(m, "Mark as Read/Unread", #selector(AppDelegate.toggleReadMessage(_:)), "u", [.command, .shift])
            add(m, "Flag/Unflag", #selector(AppDelegate.toggleFlagMessage(_:)), "l", [.command, .shift])
            add(m, "Archive", #selector(AppDelegate.archiveMessage(_:)), "a", [.command, .control])
            add(m, "Edit Draft", #selector(AppDelegate.editDraftMessage(_:)), "e")
            m.addItem(.separator())
            add(m, "Clean Up Mail…", #selector(AppDelegate.openCleanup(_:)), "k", [.command, .shift])
            add(m, "Delete", #selector(AppDelegate.deleteMessage(_:)), "\u{8}")
        }

        _ = submenu("Format") { m in
            let fonts = NSFontManager.shared
            let bold = m.addItem(withTitle: "Bold", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "b")
            bold.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
            bold.target = fonts
            let italic = m.addItem(withTitle: "Italic", action: #selector(NSFontManager.addFontTrait(_:)), keyEquivalent: "i")
            italic.tag = Int(NSFontTraitMask.italicFontMask.rawValue)
            italic.target = fonts
            add(m, "Underline", #selector(NSText.underline(_:)), "u")
            m.addItem(.separator())
            add(m, "Bigger", #selector(AppDelegate.biggerInCompose(_:)), "")
            add(m, "Smaller", #selector(AppDelegate.smallerInCompose(_:)), "")
            add(m, "Bulleted List", #selector(AppDelegate.toggleBulletsInCompose(_:)), "7", [.command, .shift])
            add(m, "Add Link…", #selector(AppDelegate.insertLinkInCompose(_:)), "k")
            m.addItem(.separator())
            let showFonts = m.addItem(withTitle: "Show Fonts", action: #selector(NSFontManager.orderFrontFontPanel(_:)), keyEquivalent: "t")
            showFonts.target = fonts
            add(m, "Show Colors", #selector(NSApplication.orderFrontColorPanel(_:)), "c", [.command, .shift])
        }

        _ = submenu("History") { m in
            add(m, "Back", #selector(AppDelegate.goBackPage(_:)), "[")
            add(m, "Forward", #selector(AppDelegate.goForwardPage(_:)), "]")
        }

        let windowMenu = submenu("Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(m, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        }

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
