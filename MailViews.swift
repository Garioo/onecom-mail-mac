// SwiftUI screens for the native mail client: sign-in, the two-pane mailbox, the reader and compose.

import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

// MARK: - Settings

/// The Settings window (⌘,).
struct SettingsView: View {
    @ObservedObject var store: MailStore
    /// Settings that live in the app delegate (notifications, Launch at Login).
    let notify: Binding<Bool>
    let launchAtLogin: Binding<Bool>

    var body: some View {
        TabView {
            GeneralSettings(notify: notify, launchAtLogin: launchAtLogin)
                .tabItem { Label("General", systemImage: "gearshape") }
            SignatureSettings()
                .tabItem { Label("Signature", systemImage: "signature") }
            AutoReplySettings()
                .tabItem { Label("Auto-Reply", systemImage: "arrowshape.turn.up.left") }
            BlockedSendersSettings(store: store)
                .tabItem { Label("Blocked", systemImage: "hand.raised") }
            RulesSettings(store: store)
                .tabItem { Label("Rules", systemImage: "wand.and.stars") }
        }
        .padding(20)
        .frame(width: 480, height: 400)
    }
}

struct GeneralSettings: View {
    let notify: Binding<Bool>
    let launchAtLogin: Binding<Bool>
    @AppStorage("undoSendSeconds") private var undoSeconds = 5
    /// Bumped after a change so the toggles re-read the real state (Launch at Login can fail).
    @State private var tick = 0

    private func refreshing(_ b: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = $0; tick += 1 })
    }

    var body: some View {
        Form {
            Toggle("Notify on new mail", isOn: refreshing(notify))
            Toggle("Launch at login", isOn: refreshing(launchAtLogin))
            Picker("Undo send:", selection: $undoSeconds) {
                Text("Off").tag(0)
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
                Text("20 seconds").tag(20)
            }
            .fixedSize()
        }
        .id(tick)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
    }
}

/// The app's own auto-reply (MailStore.autoReply), e.g. for holidays.
struct AutoReplySettings: View {
    @AppStorage("autoReplyOn") private var isOn = false
    @AppStorage("autoReplyText") private var text = ""
    @AppStorage("autoReplyUntil") private var until: Double = 0   // 0 = no end date

    private var hasEnd: Binding<Bool> {
        Binding(get: { until > 0 },
                set: { until = $0 ? Date().addingTimeInterval(7 * 86400).timeIntervalSince1970 : 0 })
    }
    private var endDate: Binding<Date> {
        Binding(get: { Date(timeIntervalSince1970: until) }, set: { until = $0.timeIntervalSince1970 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Send an auto-reply to new mail", isOn: $isOn)
            HStack {
                Toggle("Turn off after", isOn: hasEnd)
                if until > 0 {
                    DatePicker("", selection: endDate, displayedComponents: .date).labelsHidden().fixedSize()
                }
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .border(Color.secondary.opacity(0.3))
            Text("Sent from this Mac, so only while the app is open and the Mac is awake. Each sender gets at most one a week; newsletters and no-reply addresses are skipped.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
    }
}

struct SignatureSettings: View {
    @AppStorage("signature") private var signature = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Added at the end of new messages, replies and forwards.")
                .font(.callout)
                .foregroundColor(.secondary)
            TextEditor(text: $signature)
                .font(.system(size: 13))
                .border(Color.secondary.opacity(0.3))
        }
        .padding(10)
    }
}

/// Senders whose mail goes straight to Trash.
struct BlockedSendersSettings: View {
    @ObservedObject var store: MailStore
    @State private var typed = ""
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mail from these addresses or domains is moved to Trash when it arrives. The list is kept on this Mac.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(store.blockedSenders.sorted(), id: \.self, selection: $picked) { Text($0) }
                .overlay {
                    if store.blockedSenders.isEmpty {
                        Text("No blocked senders. Right-click a message to block its sender.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            HStack {
                TextField("name@example.com or example.com", text: $typed).onSubmit(add)
                Button("Block", action: add).disabled(MailStore.blockEntry(typed: typed) == nil)
                Spacer()
                Button("Unblock") {
                    if let p = picked { store.unblock(p) }
                    picked = nil
                }
                .disabled(picked == nil)
            }
        }
        .padding(10)
    }

    private func add() {
        guard let entry = MailStore.blockEntry(typed: typed) else { return }
        store.block(entry)
        typed = ""
    }
}

// MARK: - Root

struct MailRootView: View {
    @ObservedObject var store: MailStore

    var body: some View {
        if store.account == nil {
            LoginView(store: store)
        } else {
            MailMainView(store: store)
        }
    }
}

struct MailMainView: View {
    @ObservedObject var store: MailStore
    @AppStorage("messageListWidth") private var listWidth = 390.0
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchStatusBar(store: store)
                Divider()
            }
            if let message = store.errorMessage {
                ErrorBanner(text: message) { store.errorMessage = nil }
                Divider()
            }
            HStack(spacing: 0) {
                MessageListView(store: store)
                    .frame(width: CGFloat(listWidth))
                ColumnDivider(width: $listWidth, range: 300...560)
                ReaderView(store: store)
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
        }
        .sheet(item: $store.cleanup) { model in
            CleanupView(model: model, store: store) { store.cleanup = nil }
        }
        .sheet(item: $store.attachmentBrowser) { model in
            AttachmentBrowserView(model: model, store: store) { store.attachmentBrowser = nil }
        }
        .sheet(item: $store.snoozePicker) { request in
            SnoozePickerView(request: request, store: store)
        }
        .onAppear { store.undoManager = undoManager }
    }
}

/// The draggable line between the message list and the reader. It keeps its place when
/// the reader's content changes (HSplitView would hand the list extra width).
struct ColumnDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 9).contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        if start == nil { start = width }
                        width = min(max((start ?? width) + g.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }))
            .accessibilityHidden(true)
    }
}

/// Mail's scope bar: where the search looks, and how it's going.
struct SearchStatusBar: View {
    @ObservedObject var store: MailStore
    @AppStorage("mailTextSize") private var textSize = 0

    var body: some View {
        HStack(spacing: 10) {
            Text("Search:")
                .foregroundColor(.secondary)
            Picker("Search in", selection: $store.searchScope) {
                Text("All Mailboxes").tag(MailStore.SearchScope.allMail)
                Text(store.currentFolder?.name ?? "This Mailbox").tag(MailStore.SearchScope.currentFolder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if store.isSearching {
                ProgressView().controlSize(.small)
                Text("Searching the server…")
                    .foregroundColor(.secondary)
            } else if let results = store.searchResults {
                Text(results.count == 1 ? "1 result" : "\(results.count.formatted()) results")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            } else {
                Text("Press Return to search the server")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: MailType.size(12, textSize)))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(text).font(.system(size: 12)).lineLimit(2)
            Spacer()
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.1))
    }
}

/// Dragged messages travel as text: a marker line, then one message id per line.
enum MessageDrag {
    static let marker = "one.com-mail-messages"

    static func provider(_ ids: Set<String>) -> NSItemProvider {
        NSItemProvider(object: ([marker] + ids.sorted()).joined(separator: "\n") as NSString)
    }

    static func ids(from text: String) -> Set<String>? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == marker else { return nil }
        return Set(lines.dropFirst().filter { !$0.isEmpty })
    }
}

/// Reading size chosen with View → Zoom In / Zoom Out (⌘+ / ⌘−) while Mail is shown.
enum MailType {
    static func scale(_ step: Int) -> CGFloat { 1 + CGFloat(step) * 0.08 }
    static func size(_ base: CGFloat, _ step: Int) -> CGFloat { (base * scale(step)).rounded() }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search"
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Message list

/// Groups messages under calm date headings: Today, Yesterday, Previous 7 Days, …, then by month.
enum DateSections {
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f
    }()

    static func title(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if days >= 0 && days < 7 { return "Previous 7 Days" }
        if days >= 0 && days < 30 { return "Previous 30 Days" }
        return monthFormatter.string(from: date)
    }

    static func group(_ items: [MessageSummary]) -> [(title: String, items: [MessageSummary])] {
        var sections: [(title: String, items: [MessageSummary])] = []
        for m in items {
            let t = title(for: m.date)
            if let last = sections.last, last.title == t {
                sections[sections.count - 1].items.append(m)
            } else {
                sections.append((title: t, items: [m]))
            }
        }
        return sections
    }
}

struct MessageListView: View {
    @ObservedObject var store: MailStore
    @AppStorage("mailTextSize") private var textSize = 0

    private func moveMenu(_ ids: Set<String>, from folder: String?) -> some View {
        Menu("Move To") {
            ForEach(store.moveTargets.filter { $0.path != folder }) { target in
                Button { store.move(ids, to: target) } label: {
                    Label(target.name, systemImage: target.role.symbol)
                }
            }
        }
    }

    private func remindMenu(_ ids: Set<String>) -> some View {
        Menu("Remind Me") {
            ForEach(SnoozeChoice.allCases) { choice in
                Button("\(choice.title) (\(Relative.string(choice.date())))") { store.snooze(ids, until: choice.date()) }
            }
            Divider()
            Button("Choose Date…") { store.snoozePicker = SnoozeRequest(ids: ids) }
        }
    }

    @ViewBuilder
    private func menu(for message: MessageSummary) -> some View {
        let many = store.selection.count > 1 && store.selection.contains(message.id)
        if many {
            let n = store.selection.count
            Button(store.selectionAllRead ? "Mark \(n) as Unread" : "Mark \(n) as Read") {
                store.setSelectionRead(!store.selectionAllRead)
            }
            Button(store.selectionAllFlagged ? "Unflag \(n)" : "Flag \(n)") {
                store.setSelectionFlagged(!store.selectionAllFlagged)
            }
            if store.selectionCanArchive {
                Button("Archive \(n) Messages") { store.archiveSelection() }
            }
            moveMenu(store.selection, from: nil)
            remindMenu(store.selection)
            Divider()
            Button("Delete \(n) Messages") { store.deleteSelection() }
        } else {
            Button("Reply") { store.selection = [message.id]; store.reply(all: false) }
            Button("Forward") { store.selection = [message.id]; store.forward() }
            Divider()
            Button(message.seen ? "Mark as Unread" : "Mark as Read") { store.toggleRead(message.id) }
            Button(message.flagged ? "Unflag" : "Flag") { store.toggleFlag(message.id) }
            if store.canArchive(message.id) {
                Button("Archive") { store.archive(message.id) }
            }
            moveMenu([message.id], from: message.folder)
            remindMenu([message.id])
            if message.folder == store.snoozedFolder?.path, store.scheduleNote(for: message) != nil {
                Button("Bring Back Now") { store.wakeNow(message) }
            }
            if store.isScheduledToSend(message) {
                Button("Don't Send Later") { store.cancelSendLater(message) }
            }
            if let sender = message.from {
                Divider()
                Button("Select All Loaded from \(sender.display)") {
                    let key = sender.email.lowercased()
                    store.selection = Set(store.visibleMessages
                        .filter { $0.from?.email.lowercased() == key }
                        .map { $0.id })
                }
                Button("Clean Up Mail from \(sender.display)…") { store.openCleanup(sender: sender) }
                if let entry = store.blockEntry(for: sender) {
                    Button("Unblock \(entry)") { store.unblock(entry) }
                } else {
                    let email = sender.email.lowercased()
                    let domain = email.split(separator: "@").last.map { "@" + $0 } ?? ""
                    Button("Block \(email)") { store.block(email) }
                    // Not your own domain: that would trash mail from yourself and your colleagues.
                    if !domain.isEmpty, store.account?.email.lowercased().hasSuffix(domain) == false {
                        Button("Block Everyone \(domain)") { store.block(domain) }
                    }
                }
            }
            Divider()
            Button("Delete") { store.delete(message.id) }
        }
    }

    var body: some View {
        let threads = store.visibleThreads
        let items = threads.map(MessageRow.summary(of:))
        let sizes = Dictionary(uniqueKeysWithValues: threads.map { ($0[0].id, $0.count) })
        let searching = store.isServerSearchActive
        let sections = DateSections.group(items)
        VStack(spacing: 0) {
            if store.currentFolder?.role == .inbox && store.searchText.isEmpty {
                Picker("Show", selection: $store.inboxFilter) {
                    ForEach(InboxFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                Divider()
            }
            ZStack(alignment: .top) {
                List(selection: $store.selection) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { pair in
                        Section(header: SectionHeader(title: pair.element.title, textSize: textSize)) {
                            ForEach(pair.element.items) { message in
                                let folder = store.folder(path: message.folder)
                                let showRecipient = folder?.role == .sent || folder?.role == .drafts
                                MessageRow(message: message, showRecipient: showRecipient,
                                           folderName: searching ? folder?.name : nil,
                                           threadSize: sizes[message.id] ?? 1,
                                           note: store.scheduleNote(for: message), textSize: textSize)
                                    .tag(message.id)
                                    .contextMenu { menu(for: message) }
                                    .onDrag {
                                        // Dragging a selected row takes the whole selection along.
                                        MessageDrag.provider(store.selection.contains(message.id)
                                                             ? store.selection : [message.id])
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button { store.toggleRead(message.id) } label: {
                                            Label(message.seen ? "Unread" : "Read",
                                                  systemImage: message.seen ? "envelope.badge" : "envelope.open")
                                        }
                                        .tint(.accentColor)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { store.delete(message.id) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        if store.canArchive(message.id) {
                                            Button { store.archive(message.id) } label: {
                                                Label("Archive", systemImage: "archivebox")
                                            }
                                        }
                                    }
                            }
                        }
                    }
                    if store.canLoadMore && store.searchText.isEmpty && !items.isEmpty {
                        HStack {
                            Spacer()
                            Button(store.isLoadingList ? "Loading…" : "Load Older Messages") { store.loadMore() }
                                .buttonStyle(.borderless)
                                .disabled(store.isLoadingList)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand {
                    store.deleteSelection()
                }

                if items.isEmpty {
                    Group {
                        if store.isLoadingList || store.isSearching {
                            ProgressView()
                        } else if store.searchText.isEmpty && store.currentFolder?.role == .inbox && store.inboxFilter != .all {
                            EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "No \(store.inboxFilter.rawValue)",
                                       detail: "Nothing in the loaded mail fits. Choose All to see everything.")
                        } else if store.searchText.isEmpty && store.currentFolder?.role == .inbox {
                            EmptyState(symbol: "checkmark.circle", title: "All Caught Up",
                                       detail: "There's nothing in your Inbox.")
                        } else if store.searchText.isEmpty {
                            EmptyState(symbol: "tray", title: "No Messages",
                                       detail: "\(store.currentFolder?.name ?? "This mailbox") is empty.")
                        } else {
                            EmptyState(symbol: "magnifyingglass", title: "No Results",
                                       detail: store.isServerSearchActive
                                           ? "Nothing on the server matches “\(store.searchText)”."
                                           : "Press Return to search the whole server.")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.isLoadingList {
                    // Quiet "checking for mail" pill over the top of the list.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking for mail…")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottom) {
                if let undo = store.undoable {
                    UndoNotice(text: undo.summary) { store.undoLatest() }
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.isLoadingList)
            .animation(.easeOut(duration: 0.22), value: store.undoable?.id)
        }
    }
}

/// "Moved 3 messages to Trash · Undo", floating over the bottom of the list for a few seconds.
struct UndoNotice: View {
    let text: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .monospacedDigit()
            Button("Undo", action: undo)
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .help("Put them back (⌘Z)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .combine)
    }
}

/// Centered, quiet placeholder for empty lists and panes.
struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.secondary)
                .padding(.bottom, 6)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.secondary)
            if let detail = detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .padding(24)
    }
}

struct MessageRow: View {
    let message: MessageSummary
    let showRecipient: Bool
    var folderName: String? = nil
    /// How many messages the row's conversation holds.
    var threadSize = 1
    /// Shown instead of the date: when snoozed mail comes back, or when a draft is sent.
    var note: String? = nil
    var textSize = 0

    /// A sign-in code, offered on recent mail only.
    private var code: String? {
        Date().timeIntervalSince(message.date) < 86400 ? SmartMail.code(for: message) : nil
    }

    /// A conversation as one row: its newest message, unread if any message is, flagged if any is.
    static func summary(of thread: [MessageSummary]) -> MessageSummary {
        var head = thread[0]
        head.seen = thread.allSatisfy { $0.seen }
        head.flagged = thread.contains { $0.flagged }
        head.hasAttachments = thread.contains { $0.hasAttachments }
        return head
    }

    private var person: MailAddress? { showRecipient ? message.to.first : message.from }

    private var personText: String {
        if showRecipient {
            let names = message.to.map { $0.display }
            return names.isEmpty ? "(No recipient)" : "To: " + names.joined(separator: ", ")
        }
        return message.from?.display ?? "(Unknown sender)"
    }

    private func size(_ base: CGFloat) -> CGFloat { MailType.size(base, textSize) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.seen ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, size(14) * 0.5)
                .accessibilityLabel(message.seen ? "" : "Unread")
            AvatarView(address: person, size: (34 * MailType.scale(textSize)).rounded())
                .padding(.trailing, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(personText)
                        .font(.system(size: size(14), weight: message.seen ? .medium : .semibold))
                        .lineLimit(1)
                    if threadSize > 1 {
                        Text("\(threadSize)")
                            .font(.system(size: size(11), weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .accessibilityLabel("\(threadSize) messages")
                    }
                    Spacer(minLength: 6)
                    if let folderName = folderName {
                        Text(folderName)
                            .font(.system(size: size(10), weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .foregroundColor(.secondary)
                    }
                    if message.answered {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: size(9)))
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Replied")
                    }
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: size(11)))
                            .foregroundColor(.secondary)
                            .accessibilityLabel("Has attachments")
                    }
                    if message.flagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: size(10)))
                            .foregroundColor(.orange)
                            .accessibilityLabel("Flagged")
                    }
                    if let note = note {
                        Label(note, systemImage: "clock")
                            .font(.system(size: size(12)))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(MailDate.listString(message.date))
                            .font(.system(size: size(12)))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 6) {
                    Text(message.subject.isEmpty ? "(No subject)" : message.subject)
                        .font(.system(size: size(13), weight: message.seen ? .regular : .medium))
                        .foregroundColor(.primary.opacity(message.seen ? 0.8 : 1))
                        .lineLimit(1)
                    if let code = code {
                        Spacer(minLength: 4)
                        CodeChip(code: code, textSize: textSize)
                    }
                }
                if !message.snippet.isEmpty {
                    Text(message.snippet)
                        .font(.system(size: size(13)))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .lineSpacing(1)
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.trailing, 2)
    }
}

struct SectionHeader: View {
    let title: String
    var textSize = 0

    var body: some View {
        Text(title)
            .font(.system(size: MailType.size(12, textSize), weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// Contacts-style monogram: grey disc, white initials.
struct AvatarView: View {
    let address: MailAddress?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: [Color(white: 0.68), Color(white: 0.55)],
                startPoint: .top, endPoint: .bottom))
            Text(address?.initials ?? "?")
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundColor(.white)
                .minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Reader

struct ReaderView: View {
    @ObservedObject var store: MailStore

    var body: some View {
        Group {
            if store.selection.count > 1 {
                BulkSelectionView(store: store)
            } else if let opened = store.opened {
                MessageDetailView(store: store, opened: opened)
            } else if store.isLoadingMessage {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    EmptyState(symbol: "envelope", title: "No Message Selected",
                               detail: "⌘-click or ⇧-click to select several messages at once.")
                    HStack(spacing: 10) {
                        Button { store.openCleanup() } label: {
                            Label("Clean Up Mail…", systemImage: "wand.and.stars")
                        }
                        Button { store.openAttachmentBrowser() } label: {
                            Label("Browse Attachments…", systemImage: "paperclip")
                        }
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Shown when several messages are selected: big, clear bulk actions.
struct BulkSelectionView: View {
    @ObservedObject var store: MailStore
    @AppStorage("mailTextSize") private var textSize = 0

    var body: some View {
        let n = store.selection.count
        VStack(spacing: 18) {
            Image(systemName: "tray.full")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.secondary)
            VStack(spacing: 4) {
                Text("\(n.formatted()) Messages Selected")
                    .font(.system(size: MailType.size(22, textSize), weight: .semibold))
                Text("Act on all of them at once.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button { store.setSelectionRead(!store.selectionAllRead) } label: {
                    Label(store.selectionAllRead ? "Mark as Unread" : "Mark as Read",
                          systemImage: store.selectionAllRead ? "envelope.badge" : "envelope.open")
                }
                Button { store.setSelectionFlagged(!store.selectionAllFlagged) } label: {
                    Label(store.selectionAllFlagged ? "Unflag" : "Flag", systemImage: "flag")
                }
                if store.selectionCanArchive {
                    Button { store.archiveSelection() } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
            }
            .controlSize(.large)

            Button(role: .destructive) { store.deleteSelection() } label: {
                Label("Delete \(n.formatted()) Messages", systemImage: "trash")
                    .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            Button("Deselect All") { store.selection = [] }
                .buttonStyle(.borderless)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MessageDetailView: View {
    @ObservedObject var store: MailStore
    let opened: OpenedMessage
    @AppStorage("mailTextSize") private var textSize = 0
    @AppStorage("darkenEmails") private var darkenEmails = true
    @Environment(\.colorScheme) private var colorScheme

    private var s: MessageSummary { opened.summary }
    private var asDesigned: Bool { store.showsAsDesigned(s.from) }
    /// "Show as Designed" only means something for HTML mail that's being darkened.
    private var canShowAsDesigned: Bool {
        darkenEmails && colorScheme == .dark && opened.parsed.html != nil
    }
    private var unsubscribe: Unsubscribe? {
        Unsubscribe(header: opened.parsed.headers["list-unsubscribe"], post: opened.parsed.headers["list-unsubscribe-post"])
    }
    private var conversation: [MessageSummary] {
        store.selectedID.map { store.thread(of: $0) } ?? []
    }
    private func size(_ base: CGFloat) -> CGFloat { MailType.size(base, textSize) }

    private func recipients(_ label: String, _ list: [MailAddress]) -> some View {
        Text("\(label) ").foregroundColor(.secondary.opacity(0.8))
            + Text(list.map { $0.display }.joined(separator: ", ")).foregroundColor(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(s.subject.isEmpty ? "(No subject)" : s.subject)
                        .font(.system(size: size(22), weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if store.openedIsDraft {
                        Button { store.editDraft() } label: {
                            Label("Edit Draft", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Carry on writing this message (⌘E)")
                    } else if s.flagged {
                        Image(systemName: "flag.fill")
                            .foregroundColor(.orange)
                            .accessibilityLabel("Flagged")
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    AvatarView(address: s.from, size: (40 * MailType.scale(textSize)).rounded())
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(s.from?.display ?? "Unknown sender")
                                .font(.system(size: size(14), weight: .semibold))
                            if let from = s.from, !from.name.isEmpty {
                                Text(from.email)
                                    .font(.system(size: size(12)))
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(MailDate.longString(s.date))
                                .font(.system(size: size(12)))
                                .foregroundColor(.secondary)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                if !s.to.isEmpty { recipients("To:", s.to) }
                                if !s.cc.isEmpty { recipients("Cc:", s.cc) }
                            }
                            .font(.system(size: size(12)))
                            .lineLimit(2)
                            Spacer(minLength: 8)
                            if canShowAsDesigned {
                                Button(asDesigned ? "Darken Email" : "Show as Designed") {
                                    store.setShowsAsDesigned(s.from, !asDesigned)
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: size(12)))
                                .help(asDesigned
                                      ? "Darken mail from \(s.from?.display ?? "this sender") to match dark mode"
                                      : "Show mail from \(s.from?.display ?? "this sender") on white, the way it was designed")
                            }
                        }
                    }
                    .textSelection(.enabled)
                }

                if let code = SmartMail.code(for: s) {
                    HStack(spacing: 10) {
                        Image(systemName: "key").foregroundColor(.secondary)
                        Text("Sign-in code")
                            .font(.system(size: size(12)))
                            .foregroundColor(.secondary)
                        CodeChip(code: code, textSize: textSize)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
                }

                if !opened.parsed.attachments.isEmpty {
                    AttachmentStrip(attachments: opened.parsed.attachments)
                }

                if let unsubscribe = unsubscribe, s.from?.email.lowercased() != store.account?.email.lowercased() {
                    UnsubscribeNotice(store: store, unsubscribe: unsubscribe, sender: s.from, textSize: textSize)
                        .id(s.id)
                }

                if conversation.count > 1 {
                    ConversationStrip(store: store, messages: conversation, showing: s.id, textSize: textSize)
                }

                if opened.parsed.hasRemoteContent && !store.allowRemoteContent {
                    HStack(spacing: 10) {
                        Image(systemName: "eye.slash")
                            .foregroundColor(.secondary)
                        Text("Images from the web are hidden to protect your privacy.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 8)
                        Button("Load Images") { store.allowRemoteContent = true }
                            .controlSize(.small)
                        if let sender = s.from {
                            Button("Always for This Sender") { store.trustImages(from: sender) }
                                .controlSize(.small)
                                .help("Load images in mail from \(sender.email) without asking. You can undo this in Settings → Rules.")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider().padding(.horizontal, 28)

            let paper = canShowAsDesigned && asDesigned
            MessageBodyView(html: opened.parsed.displayHTML,
                            key: "\(s.id)#\(store.allowRemoteContent)#\(darkenEmails)#\(paper)",
                            allowRemote: store.allowRemoteContent,
                            darken: darkenEmails && !paper,
                            paper: paper,
                            zoom: MailType.scale(textSize))
        }
    }
}

/// A newsletter's "leave this list" link, offered quietly under the header.
struct UnsubscribeNotice: View {
    @ObservedObject var store: MailStore
    let unsubscribe: Unsubscribe
    let sender: MailAddress?
    var textSize = 0

    private enum Phase { case idle, working, done, openedPage, failed(String) }
    @State private var phase = Phase.idle
    @State private var confirming = false

    private var who: String { sender?.display ?? "this sender" }

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .done, .openedPage:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
            default:
                Image(systemName: "newspaper").foregroundColor(.secondary)
            }
            Group {
                switch phase {
                case .idle, .working: Text("This is a newsletter from \(who).")
                case .done: Text("Unsubscribed. It can take a few days for their mail to stop.")
                case .openedPage: Text("Finish unsubscribing on the page that opened in your browser.")
                case .failed(let why): Text(why).foregroundColor(.red)
                }
            }
            .font(.system(size: MailType.size(12, textSize)))
            .foregroundColor(.secondary)
            .lineLimit(2)
            Spacer(minLength: 8)
            switch phase {
            case .idle, .failed:
                Button("Unsubscribe…") { confirming = true }
                    .controlSize(.small)
            case .working:
                ProgressView().controlSize(.small)
            case .done, .openedPage:
                if let sender = sender {
                    Button("Clean Up Their Mail…") { store.openCleanup(sender: sender) }
                        .controlSize(.small)
                        .help("Move the mail you already have from \(who) to Trash")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
        .confirmationDialog("Unsubscribe from \(who)?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Unsubscribe") { run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(unsubscribe.isAutomatic
                 ? "one.com Mail asks \(who) to stop sending you these emails."
                 : "\(who) needs you to confirm on their website, which opens in your browser.")
        }
    }

    private func run() {
        phase = .working
        Task {
            do {
                phase = try await store.unsubscribe(unsubscribe) == .done ? .done : .openedPage
            } catch {
                phase = .failed("Couldn't unsubscribe: " + error.localizedDescription)
            }
        }
    }
}

/// The other messages of the selected conversation, oldest first; click one to read it.
struct ConversationStrip: View {
    @ObservedObject var store: MailStore
    let messages: [MessageSummary]
    let showing: String
    var textSize = 0

    private func size(_ base: CGFloat) -> CGFloat { MailType.size(base, textSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(messages.count) messages in this conversation")
                .font(.system(size: size(12), weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(messages.reversed()) { m in
                        Button { store.show(m.id) } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(m.id == showing ? Color.accentColor : Color.clear)
                                    .frame(width: 6, height: 6)
                                Text(m.from?.display ?? "(Unknown sender)")
                                    .font(.system(size: size(12), weight: m.id == showing ? .semibold : .regular))
                                    .lineLimit(1)
                                    .frame(width: 150 * MailType.scale(textSize), alignment: .leading)
                                Text(m.snippet.isEmpty ? m.subject : m.snippet)
                                    .font(.system(size: size(12)))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(MailDate.listString(m.date))
                                    .font(.system(size: size(11)))
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .background(m.id == showing ? Color.primary.opacity(0.05) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(m.from?.display ?? "Unknown sender"), \(MailDate.longString(m.date))")
                        .accessibilityAddTraits(m.id == showing ? .isSelected : [])
                    }
                }
            }
            .frame(maxHeight: messages.count > 5 ? 150 * MailType.scale(textSize) : nil)
            .fixedSize(horizontal: false, vertical: messages.count <= 5)
            .padding(.bottom, 4)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AttachmentStrip: View {
    let attachments: [MailAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Button { QuickLook.shared.show(attachment.data, filename: attachment.filename) } label: {
                        HStack(spacing: 6) {
                            Image(nsImage: AttachmentSaver.icon(for: attachment.filename))
                                .resizable()
                                .frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(attachment.filename)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Preview \(attachment.filename)")
                    .contextMenu {
                        Button("Quick Look") { QuickLook.shared.show(attachment.data, filename: attachment.filename) }
                        Button("Open") { AttachmentSaver.open(attachment) }
                        Button("Save to Downloads") { AttachmentSaver.save(attachment, reveal: true) }
                    }
                }
            }
        }
    }
}

enum AttachmentSaver {
    static func icon(for filename: String) -> NSImage {
        let ext = (filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    @discardableResult
    static func save(_ attachment: MailAttachment, reveal: Bool) -> URL? {
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safeName = attachment.filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        var dest = dir.appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        do {
            try attachment.data.write(to: dest)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
        if reveal { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
        return dest
    }

    static func open(_ attachment: MailAttachment) {
        if let url = save(attachment, reveal: false) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Message body (HTML)

struct MessageBodyView: NSViewRepresentable {
    let html: String
    let key: String
    let allowRemote: Bool
    var darken = true
    var paper = false
    var zoom: CGFloat = 1

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")   // the reader's own background shows through
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.pageZoom != zoom { webView.pageZoom = zoom }
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        // Hidden until drawn, so a message never flashes white (or half-styled) before it's ready.
        webView.alphaValue = 0
        webView.loadHTMLString(MailHTML.wrap(html, allowRemote: allowRemote, darken: darken, paper: paper), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey: String?

        private func reveal(_ webView: WKWebView) {
            guard webView.alphaValue < 1 else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                webView.alphaValue = 1
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                webView.animator().alphaValue = 1
            }
        }

        // Shown once the email's own HTML is in (styles included), not after every web image has loaded.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.reveal(webView) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { reveal(webView) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { reveal(webView) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reveal(webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "about"
            if isMainFrame && scheme != "about" && scheme != "data" {
                decisionHandler(.cancel)   // e.g. meta refresh: don't navigate away from the email
                return
            }
            decisionHandler(.allow)
        }
    }
}

enum MailHTML {
    /// In dark mode, HTML mail (which is nearly always designed on white) is inverted to the reader's
    /// dark grey, with photos and pictures flipped back so they keep their real colours.
    /// Plain-text mail already follows the appearance, so it's left alone.
    private static let darkenCSS = """
    @media (prefers-color-scheme:dark){\
    html{background:#fff;filter:invert(.88) hue-rotate(180deg)}\
    img,video,picture,svg,canvas,iframe,[background],[style*="background-image"]{filter:invert(1) hue-rotate(180deg)}}
    """

    /// Mail that ships its own dark styles (a prefers-color-scheme rule or a color-scheme declaration)
    /// looks right as designed; inverting it would flip those already-dark colours back to light.
    private static func darkCSS(for html: String) -> String {
        html.range(of: #"prefers-color-scheme\s*:\s*dark|color-scheme"[^>]*dark|color-scheme\s*:[^;}"]*dark"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
            ? ":root{color-scheme:light dark}" : darkenCSS
    }

    /// "Show as Designed": the mail on white, as its sender drew it, even in dark mode.
    private static let paperCSS = ":root{color-scheme:light}html{background:#fff;color:#000}"

    static func wrap(_ html: String, allowRemote: Bool, darken: Bool = false, paper: Bool = false) -> String {
        let policy = allowRemote
            ? "default-src 'none'; img-src data: https: http:; media-src https: http:; style-src 'unsafe-inline' https: http:; font-src data: https: http:"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"
        let head = """
        <meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(policy)">\
        <style>body{margin:22px 28px;font:14px -apple-system,BlinkMacSystemFont,sans-serif;\
        overflow-wrap:break-word;word-wrap:break-word}img{max-width:100%;height:auto}\
        pre{white-space:pre-wrap}\(paper ? paperCSS : darken && !html.contains("<div class=\"plain\">") ? darkCSS(for: html) : "")</style>
        """
        if let r = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var s = html
            s.insert(contentsOf: head, at: r.upperBound)
            return s
        }
        if let r = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var s = html
            s.insert(contentsOf: "<head>" + head + "</head>", at: r.upperBound)
            return s
        }
        return "<!doctype html><html><head>" + head + "</head><body>" + html + "</body></html>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Plain-text mail as HTML: system font, follows light/dark mode, links clickable, quotes styled.
    static func plainToHTML(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let rendered = lines.map { line -> String in
            let html = linkify(line)
            return line.trimmingCharacters(in: .whitespaces).hasPrefix(">") ? "<span class=\"q\">\(html)</span>" : html
        }.joined(separator: "\n")
        return """
        <!doctype html><html><head><style>
        :root{color-scheme:light dark}
        body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.6;max-width:720px;
             margin:24px auto;padding:0 28px;color:rgba(0,0,0,.82)}
        @media (prefers-color-scheme:dark){body{color:rgba(255,255,255,.86)}}
        .plain{white-space:pre-wrap}
        .q{color:#8e8e93}
        a{color:-apple-system-control-accent}
        </style></head><body><div class="plain">\(rendered)</div></body></html>
        """
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func linkify(_ line: String) -> String {
        guard let detector = linkDetector else { return escape(line) }
        let ns = line as NSString
        var out = ""
        var last = 0
        for m in detector.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out += escape(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            let shown = ns.substring(with: m.range)
            let href = m.url?.absoluteString ?? shown
            out += "<a href=\"\(escape(href))\">\(escape(shown))</a>"
            last = m.range.location + m.range.length
        }
        out += escape(ns.substring(from: last))
        return out
    }
}

// MARK: - Sign in

struct LoginView: View {
    @ObservedObject var store: MailStore
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var imapHost = "imap.one.com"
    @State private var imapPort = "993"
    @State private var smtpHost = "send.one.com"
    @State private var smtpPort = "465"
    @State private var showServers = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
            Text("Sign in to your one.com mailbox")
                .font(.system(size: 20, weight: .semibold))
            Text("Your password is kept in your Mac's Keychain and only sent to one.com's mail servers.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 360)

            VStack(spacing: 10) {
                TextField("Email address", text: $email)
                SecureField("Password", text: $password)
                TextField("Your name (shown to people you email)", text: $name)
                DisclosureGroup("Server settings", isExpanded: $showServers) {
                    VStack(spacing: 8) {
                        HStack {
                            TextField("Incoming (IMAP) server", text: $imapHost)
                            TextField("Port", text: $imapPort).frame(width: 64)
                        }
                        HStack {
                            TextField("Outgoing (SMTP) server", text: $smtpHost)
                            TextField("Port", text: $smtpPort).frame(width: 64)
                        }
                        Text("Both use SSL/TLS. one.com's defaults are already filled in.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 340)

            if let error = error {
                Text(error)
                    .font(.callout)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 360)
            }

            Button(action: signIn) {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "Signing In…" : "Sign In")
                }
                .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() {
        let account = MailAccount(
            email: email.trimmingCharacters(in: .whitespaces),
            name: name.trimmingCharacters(in: .whitespaces),
            imapHost: imapHost.trimmingCharacters(in: .whitespaces),
            imapPort: Int(imapPort) ?? 993,
            smtpHost: smtpHost.trimmingCharacters(in: .whitespaces),
            smtpPort: Int(smtpPort) ?? 465)
        busy = true
        error = nil
        let pw = password
        Task {
            let failure = await store.signIn(account, password: pw)
            busy = false
            error = failure
        }
    }
}

// MARK: - Compose

@MainActor
final class ComposeModel: ObservableObject {
    @Published var draft: ComposeDraft {
        didSet { dirty = true }
    }
    @Published var isSending = false
    /// Seconds left before a sent message really goes out, while it can still be undone.
    @Published private(set) var undoCountdown: Int?
    @Published var isSavingDraft = false
    @Published var error: String?
    @Published var showBcc: Bool
    @Published private(set) var lastSaved: Date?
    @Published private(set) var dirty = false
    /// Remind me in three days if nobody answers.
    @Published var followUp = false

    let store: MailStore
    let editor: RichTextController
    let messageID: String
    /// Set once the window may close without asking (after sending, saving or discarding).
    private(set) var allowClose = false
    var close: () -> Void = {}

    private var replacingDraft: ReplyReference?
    private let openedFromDraft: Bool
    private var savedThisSession = false
    private var autosaveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    init(draft: ComposeDraft, store: MailStore) {
        self.draft = draft
        self.store = store
        self.editor = RichTextController(initial: draft.body)
        self.messageID = draft.messageID ?? MessageBuilder.newMessageID(for: store.account?.email ?? "localhost")
        self.replacingDraft = draft.existingDraft
        self.openedFromDraft = draft.existingDraft != nil
        self.showBcc = !draft.bcc.isEmpty
        editor.onChange = { [weak self] in self?.dirty = true }
        editor.onFiles = { [weak self] urls in self?.addAttachments(urls) }
        startAutosave()
    }

    /// Anything worth keeping as a draft?
    var hasContent: Bool {
        let d = draft
        return !d.to.trimmingCharacters(in: .whitespaces).isEmpty
            || !d.subject.trimmingCharacters(in: .whitespaces).isEmpty
            || !d.attachments.isEmpty
            || !editor.attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var needsSavePrompt: Bool { !allowClose && dirty && hasContent }

    private func currentDraft() -> ComposeDraft {
        var d = draft
        d.body = editor.attributedText
        return d
    }

    func send() {
        guard !isSending else { return }
        isSending = true
        error = nil
        let current = currentDraft()
        let id = messageID
        let replacing = replacingDraft
        let hadDraft = savedThisSession || openedFromDraft
        let delay = UserDefaults.standard.object(forKey: "undoSendSeconds") as? Int ?? 5
        sendTask = Task {
            for left in stride(from: delay, to: 0, by: -1) {
                undoCountdown = left
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
            }
            undoCountdown = nil
            do {
                try await store.send(current, messageID: id)
                if followUp { store.scheduleFollowUp(messageID: id, subject: current.subject, who: Self.who(current)) }
                if hadDraft { await store.discardDraft(messageID: id, replacing: replacing) }
                isSending = false
                finish()
            } catch let failure {
                error = failure.localizedDescription
                isSending = false
            }
        }
    }

    /// "Anna" or "Anna and 2 others", for reminders.
    private static func who(_ d: ComposeDraft) -> String {
        let people = MailAddress.parseList(d.to) + MailAddress.parseList(d.cc)
        guard let first = people.first?.display else { return "" }
        return people.count == 1 ? first : "\(first) and \(people.count - 1) other\(people.count == 2 ? "" : "s")"
    }

    /// Saves the message to Drafts and sends it from there at `date` (while the app is open).
    func sendLater(at date: Date) {
        let current = currentDraft()
        if (MailAddress.parseList(current.to) + MailAddress.parseList(current.cc) + MailAddress.parseList(current.bcc)).isEmpty {
            error = "Add at least one recipient."
            return
        }
        Task {
            guard await saveDraft() else { return }
            store.scheduleSend(messageID: messageID, at: date, subject: current.subject,
                               who: Self.who(current), followUp: followUp)
            finish()
        }
    }

    func undoSend() {
        sendTask?.cancel()
        sendTask = nil
        undoCountdown = nil
        isSending = false
    }

    @discardableResult
    func saveDraft() async -> Bool {
        guard !isSavingDraft, !isSending else { return false }
        isSavingDraft = true
        defer { isSavingDraft = false }
        let current = currentDraft()
        dirty = false   // edits made while saving mark it dirty again
        do {
            try await store.saveDraft(current, messageID: messageID, replacing: replacingDraft)
            replacingDraft = nil
            savedThisSession = true
            lastSaved = Date()
            error = nil
            return true
        } catch let failure {
            dirty = true
            error = "Couldn't save the draft: " + failure.localizedDescription
            return false
        }
    }

    func saveDraftNow() {
        Task { await saveDraft() }
    }

    /// "Don't Save": removes a draft that only exists because of autosave in this window.
    func discardAutosavedDraft() async {
        if savedThisSession && !openedFromDraft {
            await store.discardDraft(messageID: messageID, replacing: nil)
        }
    }

    func finish() {
        autosaveTask?.cancel()
        allowClose = true
        close()
    }

    func stop() {
        autosaveTask?.cancel()
    }

    private func startAutosave() {
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard !Task.isCancelled, let self = self else { return }
                if self.dirty && self.hasContent && !self.isSending {
                    await self.saveDraft()
                }
            }
        }
    }

    func addAttachments(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                error = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            draft.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: mime, data: data))
        }
    }
}

struct ComposeField: View {
    let label: String
    @Binding var text: String
    var trailing: AnyView? = nil
    /// For address fields: people matching the name being typed.
    var suggest: ((String) -> [MailAddress])? = nil

    @FocusState private var focused: Bool

    /// The address being typed: whatever follows the last comma.
    private var typing: String {
        String(text.split(separator: ",", omittingEmptySubsequences: false).last ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    private var suggestions: [MailAddress] {
        guard focused, let suggest = suggest, !typing.isEmpty else { return [] }
        let list = suggest(typing)
        // Already typed out in full: nothing left to suggest.
        return list.contains { $0.editable.caseInsensitiveCompare(typing) == .orderedSame
            || $0.email.caseInsensitiveCompare(typing) == .orderedSame } ? [] : list
    }

    private func pick(_ address: MailAddress) {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        parts.removeLast()
        text = (parts.map { $0.trimmingCharacters(in: .whitespaces) } + [address.editable])
            .filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }

    var body: some View {
        let matches = suggestions
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(label)
                    .foregroundColor(.secondary)
                    .frame(width: 62, alignment: .leading)
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .accessibilityLabel(label)
                    .onSubmit { if let first = matches.first { pick(first) } }
                if let trailing = trailing { trailing }
            }
            .font(.system(size: 14))
            .padding(.horizontal, 20)
            .frame(minHeight: 36)
            // Suggestions sit in the flow (not floating), so nothing can draw over them.
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.offset) { i, address in
                        Button { pick(address) } label: {
                            HStack(spacing: 8) {
                                AvatarView(address: address, size: 22)
                                Text(address.name.isEmpty ? address.email : address.name)
                                    .font(.system(size: 13, weight: .medium))
                                if !address.name.isEmpty {
                                    Text(address.email)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer(minLength: 12)
                                if i == 0 {
                                    Text("Return to add")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(i == 0 ? Color.accentColor.opacity(0.12) : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 80)
                .padding(.trailing, 20)
                .padding(.bottom, 6)
            }
            Divider().padding(.leading, 20)
        }
    }
}

struct ComposeView: View {
    @ObservedObject var model: ComposeModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                ErrorBanner(text: error) { model.error = nil }
            }
            if model.isSending {
                HStack(spacing: 8) {
                    if let left = model.undoCountdown {
                        Image(systemName: "paperplane.fill").foregroundColor(.accentColor)
                        Text(left == 1 ? "Sending in 1 second…" : "Sending in \(left) seconds…")
                            .font(.system(size: 12))
                            .monospacedDigit()
                        Spacer()
                        Button("Undo") { model.undoSend() }
                            .controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Sending…").font(.system(size: 12))
                        Spacer()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.1))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            let suggest = model.store.addressSuggestions(for:)
            ComposeField(label: "To:", text: $model.draft.to, suggest: suggest)
            ComposeField(label: "Cc:", text: $model.draft.cc, trailing: model.showBcc ? nil : AnyView(
                Button("Bcc") { model.showBcc = true }
                    .buttonStyle(.borderless)
                    .help("Add a Bcc field: those people get the email without others seeing it")),
                suggest: suggest)
            if model.showBcc {
                ComposeField(label: "Bcc:", text: $model.draft.bcc, suggest: suggest)
            }
            ComposeField(label: "Subject:", text: $model.draft.subject)
            FormatBar(editor: model.editor)
            Divider()

            RichTextEditor(controller: model.editor)

            if !model.draft.attachments.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.draft.attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(nsImage: AttachmentSaver.icon(for: attachment.filename))
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                Text(attachment.filename).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                    .foregroundColor(.secondary)
                                Button {
                                    model.draft.attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.secondary)
                                .help("Remove \(attachment.filename)")
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .animation(.easeOut(duration: 0.2), value: model.isSending)
        .frame(minWidth: 560, minHeight: 420)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { Task { @MainActor in model.addAttachments([url]) } }
                }
            }
            return true
        }
    }
}
