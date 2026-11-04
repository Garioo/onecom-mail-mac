// Smart mail: Remind Me (snooze), Send Later, follow-up reminders, standing Clean Up rules,
// trusted image senders, the People / Newsletters / Receipts filter, one-tap codes, the attachment
// browser and Quick Look. One.com has no server-side scheduling, so the timed parts run from this
// Mac while the app is open, checked with every new-mail poll (once a minute).

import SwiftUI
import AppKit
import Quartz

// MARK: - Scheduled work

struct ScheduledItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case snooze, sendLater, followUp }

    var id = UUID()
    var kind: Kind
    var messageID: String
    var due: Date
    var subject = ""
    var who = ""
    /// Send Later only: also remind if nobody replies.
    var followUp = false

    private static let key = "scheduledItems"

    static func load() -> [ScheduledItem] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ScheduledItem].self, from: data)) ?? []
    }

    static func save(_ items: [ScheduledItem]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key)
    }
}

/// "Remind Me" times. The dates fall on whole hours, in the Mac's own calendar.
enum SnoozeChoice: Int, CaseIterable, Identifiable {
    case laterToday, tomorrow, weekend, nextWeek

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .laterToday: return "Later Today"
        case .tomorrow: return "Tomorrow Morning"
        case .weekend: return "This Weekend"
        case .nextWeek: return "Next Week"
        }
    }

    func date(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        switch self {
        case .laterToday:
            let inThree = now.addingTimeInterval(3 * 3600)
            return cal.nextDate(after: inThree, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? inThree
        case .tomorrow:
            let start = cal.startOfDay(for: now.addingTimeInterval(86400))
            return cal.date(bySettingHour: 8, minute: 0, second: 0, of: start) ?? start
        case .weekend:
            return cal.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 7), matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(3 * 86400)
        case .nextWeek:
            return cal.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0, weekday: 2), matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(7 * 86400)
        }
    }
}

/// The "Choose Date…" sheet for Remind Me.
struct SnoozeRequest: Identifiable {
    let id = UUID()
    let ids: Set<String>
}

/// Send Later times offered in the compose toolbar.
enum SendLaterChoice: Int, CaseIterable {
    case inAnHour, tomorrow, monday

    var title: String {
        switch self {
        case .inAnHour: return "In an Hour"
        case .tomorrow: return "Tomorrow at 8:00"
        case .monday: return "Monday at 8:00"
        }
    }

    func date(from now: Date = Date()) -> Date {
        switch self {
        case .inAnHour: return now.addingTimeInterval(3600)
        case .tomorrow: return SnoozeChoice.tomorrow.date(from: now)
        case .monday: return SnoozeChoice.nextWeek.date(from: now)
        }
    }
}

enum Relative {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    /// "Tomorrow at 08:00", "Saturday 9 Nov at 09:00"
    static func string(_ d: Date) -> String { formatter.string(from: d) }
}

// MARK: - Clean Up rules

struct CleanupRule: Codable, Identifiable, Hashable {
    /// Lowercased address.
    var sender: String
    var name: String
    /// True: keep only their newest email. False: trash their mail once it's `days` old.
    var keepNewest: Bool
    var days = 30

    var id: String { sender }

    var summary: String {
        keepNewest ? "Keep only the newest" : days == 7 ? "Trash after a week" : "Trash after \(days) days"
    }

    private static let key = "cleanupRules"

    static func load() -> [CleanupRule] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CleanupRule].self, from: data)) ?? []
    }

    static func save(_ rules: [CleanupRule]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: key)
    }

    /// UIDs a rule removes from one sender's mail.
    func uidsToRemove(_ items: [CleanupItem], now: Date = Date()) -> [UInt32] {
        if keepNewest {
            return items.sorted { $0.date > $1.date }.dropFirst().map { $0.uid }
        }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return items.filter { $0.date < cutoff }.map { $0.uid }
    }
}

// MARK: - Inbox filter

enum InboxFilter: String, CaseIterable, Identifiable {
    case all = "All", people = "People", newsletters = "Newsletters", receipts = "Receipts"

    var id: String { rawValue }

    func matches(_ m: MessageSummary) -> Bool {
        let receipt = SmartMail.isReceipt(m)
        let robot = m.isAutomated || {
            let local = (m.from?.email.lowercased() ?? "").split(separator: "@").first ?? ""
            return ["noreply", "no-reply", "donotreply", "do-not-reply", "notification", "info", "newsletter", "kundeservice"]
                .contains { local.contains($0) }
        }()
        switch self {
        case .all: return true
        case .receipts: return receipt
        case .newsletters: return !receipt && robot
        case .people: return !receipt && !robot
        }
    }
}

// MARK: - Store

extension MailStore {
    // MARK: Remind Me (snooze)

    /// Moves mail to a "Snoozed" folder and brings it back to the Inbox, unread, at `date`.
    func snooze(_ ids: Set<String>, until date: Date) {
        let targets = expand(ids).filter { $0.messageID != nil }
        guard !targets.isEmpty else {
            errorMessage = "That message can't be snoozed: it has no Message-ID for the app to find it by again."
            return
        }
        Task {
            guard let folder = await ensureFolder(named: "Snoozed") else { return }
            for m in targets {
                scheduled.removeAll { $0.kind == .snooze && $0.messageID == m.messageID }
                scheduled.append(ScheduledItem(kind: .snooze, messageID: m.messageID ?? "", due: date,
                                               subject: m.subject, who: m.from?.display ?? ""))
            }
            relocate(targets, to: folder)
        }
    }

    var snoozedFolder: MailFolder? {
        folders.first { $0.role == .other && $0.name.caseInsensitiveCompare("Snoozed") == .orderedSame }
    }

    /// Finds or makes a top-level folder (inside the personal namespace).
    func ensureFolder(named name: String) async -> MailFolder? {
        if let f = folders.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return f }
        guard let client = client else { return nil }
        let ns = (try? await client.personalNamespace()) ?? (prefix: "", delimiter: ".")
        let path = ns.prefix + MIME.encodeModifiedUTF7(name)
        do {
            try await client.createFolder(path)
        } catch {
            errorMessage = "Couldn't make the \(name) folder: " + error.localizedDescription
            return nil
        }
        await reloadFolders()
        return folder(path: path) ?? folders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Brings a snoozed message back now.
    func wakeNow(_ m: MessageSummary) {
        guard let id = m.messageID else { return }
        for i in scheduled.indices where scheduled[i].kind == .snooze && scheduled[i].messageID == id {
            scheduled[i].due = Date()
        }
        Task { await runScheduled() }
    }

    /// The time shown in place of the date for snoozed mail and mail waiting to be sent.
    func scheduleNote(for m: MessageSummary) -> String? {
        guard let id = m.messageID else { return nil }
        let role = folder(path: m.folder)?.role
        if role == .drafts, let item = scheduled.first(where: { $0.kind == .sendLater && $0.messageID == id }) {
            return "Sends " + Relative.string(item.due)
        }
        if m.folder == snoozedFolder?.path, let item = scheduled.first(where: { $0.kind == .snooze && $0.messageID == id }) {
            return Relative.string(item.due)
        }
        return nil
    }

    func isScheduledToSend(_ m: MessageSummary) -> Bool {
        scheduled.contains { $0.kind == .sendLater && $0.messageID == m.messageID }
    }

    func cancelSendLater(_ m: MessageSummary) {
        scheduled.removeAll { $0.kind == .sendLater && $0.messageID == m.messageID }
    }

    // MARK: Send Later and follow-ups

    func scheduleSend(messageID: String, at date: Date, subject: String, who: String, followUp: Bool) {
        scheduled.removeAll { $0.kind == .sendLater && $0.messageID == messageID }
        scheduled.append(ScheduledItem(kind: .sendLater, messageID: messageID, due: date,
                                       subject: subject, who: who, followUp: followUp))
    }

    /// Reminds you in three days if nothing in the Inbox or Archive answers this message.
    func scheduleFollowUp(messageID: String, subject: String, who: String) {
        scheduled.append(ScheduledItem(kind: .followUp, messageID: messageID,
                                       due: Date().addingTimeInterval(3 * 86400), subject: subject, who: who))
    }

    // MARK: Running what's due

    /// Wakes snoozed mail, sends scheduled mail, checks follow-ups, and every few hours applies the Clean Up rules.
    func runScheduled() async {
        guard let client = client else { return }
        let now = Date()
        for item in scheduled where item.due <= now {
            switch item.kind {
            case .snooze:
                if let snoozed = snoozedFolder, let inbox = inboxFolder,
                   let uids = try? await client.findUIDs(folder: snoozed.path, messageID: item.messageID), !uids.isEmpty {
                    try? await client.setFlag(folder: snoozed.path, uids: uids, flag: "\\Seen", on: false)
                    try? await client.move(folder: snoozed.path, uids: uids, to: inbox.path)
                    if currentFolder?.path == snoozed.path { await loadTop(token: folderToken, showSpinner: false) }
                }
                scheduled.removeAll { $0.id == item.id }
            case .sendLater:
                if await sendScheduled(item) { scheduled.removeAll { $0.id == item.id } }
            case .followUp:
                var replied = false
                for folder in [inboxFolder, archiveFolder].compactMap({ $0 }) where !replied {
                    replied = (try? await client.hasReply(folder: folder.path, to: item.messageID)) ?? true
                }
                if !replied {
                    onReminder?("No reply from \(item.who.isEmpty ? "them" : item.who) yet",
                                "“\(item.subject.isEmpty ? "(No subject)" : item.subject)” was sent 3 days ago.")
                }
                scheduled.removeAll { $0.id == item.id }
            }
        }
        if now.timeIntervalSince(lastRulesRun) > 6 * 3600, !cleanupRules.isEmpty {
            lastRulesRun = now
            await applyRules()
        }
    }

    /// Sends a draft saved for later. Returns true when it's done with (sent, or the draft is gone).
    private func sendScheduled(_ item: ScheduledItem) async -> Bool {
        guard let client = client, let account = account, let drafts = draftsFolder else { return false }
        guard let uids = try? await client.findUIDs(folder: drafts.path, messageID: item.messageID) else { return false }
        guard let uid = uids.max() else { return true }   // sent or deleted by hand meanwhile
        do {
            let bytes = try await client.fetchMessage(folder: drafts.path, uid: uid)
            let ready = SmartMail.prepareScheduled(bytes)
            guard !ready.recipients.isEmpty else { return true }
            try await SMTPSender.send(account: account, password: password, recipients: ready.recipients, message: ready.message)
            if let sent = sentFolder { try? await client.append(folder: sent.path, message: ready.message, flags: "\\Seen") }
            try? await client.deletePermanently(folder: drafts.path, uids: uids)
            if currentFolder?.path == drafts.path || currentFolder?.path == sentFolder?.path {
                await loadTop(token: folderToken, showSpinner: false)
            }
            if item.followUp { scheduleFollowUp(messageID: item.messageID, subject: item.subject, who: item.who) }
            onReminder?("Sent", "“\(item.subject.isEmpty ? "(No subject)" : item.subject)” went to \(item.who).")
            return true
        } catch {
            // ponytail: retries every minute while failing; give up after N tries if that ever nags.
            errorMessage = "Couldn't send “\(item.subject)” yet: \(error.localizedDescription) It'll try again in a minute."
            return false
        }
    }

    // MARK: Clean Up rules

    func rule(for sender: String) -> CleanupRule? { cleanupRules.first { $0.sender == sender } }

    func setRule(_ rule: CleanupRule?, for sender: String) {
        cleanupRules.removeAll { $0.sender == sender }
        if let rule = rule { cleanupRules.append(rule) }
    }

    /// Applies every rule to the Inbox: their mail goes to Trash. Returns how many emails went.
    @discardableResult
    func applyRules() async -> Int {
        guard let client = client, let inbox = inboxFolder, let trash = trashFolder, !cleanupRules.isEmpty,
              let items = try? await client.fetchCleanupItems(folder: inbox.path) else { return 0 }
        var uids: [UInt32] = []
        let bySender = Dictionary(grouping: items) { $0.from?.email.lowercased() ?? "" }
        for rule in cleanupRules { uids += rule.uidsToRemove(bySender[rule.sender] ?? []) }
        guard !uids.isEmpty else { return 0 }
        do {
            try await client.move(folder: inbox.path, uids: uids, to: trash.path)
        } catch {
            errorMessage = "Clean Up rules couldn't run: " + error.localizedDescription
            return 0
        }
        if currentFolder?.path == inbox.path { await loadTop(token: folderToken, showSpinner: false) }
        await refreshUnread()
        return uids.count
    }

    // MARK: Images

    func trustsImages(from sender: MailAddress?) -> Bool {
        sender.map { trustedImageSenders.contains($0.email.lowercased()) } ?? false
    }

    /// Loads remote images in this sender's mail from now on, and in the open message now.
    func trustImages(from sender: MailAddress?) {
        guard let key = sender?.email.lowercased(), !key.isEmpty else { return }
        trustedImageSenders.insert(key)
        allowRemoteContent = true
    }

    // MARK: Attachments

    func openAttachmentBrowser() {
        guard let folder = currentFolder ?? inboxFolder else { return }
        let model = AttachmentBrowserModel(store: self, folder: folder)
        attachmentBrowser = model
        Task { await model.load() }
    }
}

// MARK: - One-tap codes

enum Clipboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// "482 913  Copy": a sign-in code lifted out of the message.
struct CodeChip: View {
    let code: String
    var textSize = 0
    @State private var copied = false

    /// Groups of three, the way codes are read aloud.
    private var spaced: String {
        code.count == 6 ? code.prefix(3) + " " + code.suffix(3) : code
    }

    var body: some View {
        Button {
            Clipboard.copy(code)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            HStack(spacing: 5) {
                Text(spaced)
                    .font(.system(size: MailType.size(12, textSize), weight: .semibold))
                    .monospacedDigit()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: MailType.size(10, textSize)))
                    .foregroundColor(copied ? .accentColor : .secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy the code \(code)")
        .accessibilityLabel(copied ? "Copied" : "Copy code \(code)")
    }
}

// MARK: - Quick Look

/// Shows files in the system Quick Look panel.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Writes the data to a private temporary folder and previews it.
    func show(_ data: Data, filename: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("one.com Mail Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        show([url])
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

// MARK: - Attachment browser

@MainActor
final class AttachmentBrowserModel: ObservableObject, Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", photos = "Photos", pdfs = "PDFs", other = "Other"
        var id: String { rawValue }
    }

    let id = UUID()
    let store: MailStore
    @Published private(set) var folder: MailFolder
    @Published private(set) var items: [AttachmentInfo] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var kind: Kind = .all
    @Published var biggestFirst = false
    @Published var filterText = ""
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var opening: String?
    private var requested = Set<String>()

    init(store: MailStore, folder: MailFolder) {
        self.store = store
        self.folder = folder
    }

    func load() async {
        guard let client = store.client else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            items = try await client.fetchAttachments(folder: folder.path)
        } catch {
            items = []
            self.error = error.localizedDescription
        }
    }

    func changeFolder(_ f: MailFolder) {
        guard f.path != folder.path else { return }
        folder = f
        items = []
        thumbnails = [:]
        requested = []
        Task { await load() }
    }

    var shown: [AttachmentInfo] {
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let list = items.filter { a in
            switch kind {
            case .all: break
            case .photos: if !a.isImage { return false }
            case .pdfs: if !a.isPDF { return false }
            case .other: if a.isImage || a.isPDF { return false }
            }
            return q.isEmpty || a.filename.lowercased().contains(q) || a.subject.lowercased().contains(q)
                || (a.from?.display.lowercased().contains(q) ?? false) || (a.from?.email.lowercased().contains(q) ?? false)
        }
        return list.sorted { biggestFirst ? $0.size > $1.size : $0.date > $1.date }
    }

    private func data(for a: AttachmentInfo) async throws -> Data {
        guard let client = store.client else { throw MailError.server("You're not signed in.") }
        return try await client.fetchPart(folder: a.folder, uid: a.uid, part: a.part, encoding: a.encoding)
    }

    /// Loads a picture's thumbnail when its tile first appears. Big photos are skipped (an icon shows instead).
    func thumbnail(for a: AttachmentInfo) {
        guard a.isImage, a.fileSize < 8_000_000, !requested.contains(a.id) else { return }
        requested.insert(a.id)
        Task {
            guard let data = try? await data(for: a), let image = NSImage(data: data) else { return }
            thumbnails[a.id] = image
        }
    }

    func preview(_ a: AttachmentInfo) {
        opening = a.id
        Task {
            defer { opening = nil }
            do {
                QuickLook.shared.show(try await data(for: a), filename: a.filename)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func save(_ a: AttachmentInfo) {
        Task {
            do {
                let data = try await data(for: a)
                AttachmentSaver.save(MailAttachment(filename: a.filename, mimeType: a.mimeType, data: data), reveal: true)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct AttachmentBrowserView: View {
    @ObservedObject var model: AttachmentBrowserModel
    @ObservedObject var store: MailStore
    let close: () -> Void

    private var folderChoice: Binding<String> {
        Binding(get: { model.folder.path },
                set: { path in if let f = store.folder(path: path) { model.changeFolder(f) } })
    }

    var body: some View {
        let shown = model.shown
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attachments in \(model.folder.name)")
                        .font(.system(size: 22, weight: .semibold))
                    Text(model.isLoading ? "Looking through every email…"
                         : "\(shown.count.formatted()) \(shown.count == 1 ? "file" : "files") · \(ByteCountFormatter.string(fromByteCount: Int64(shown.reduce(0) { $0 + $1.fileSize }), countStyle: .file)). Click one to preview it.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Picker("Mailbox:", selection: folderChoice) {
                    ForEach(store.folders) { f in Text(f.name).tag(f.path) }
                }
                .fixedSize()
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            HStack(spacing: 16) {
                Picker("Show", selection: $model.kind) {
                    ForEach(AttachmentBrowserModel.Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("Biggest first", isOn: $model.biggestFirst)
                    .toggleStyle(.checkbox)
                Spacer()
                SearchField(text: $model.filterText, placeholder: "File, sender or subject")
                    .frame(width: 220)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Divider()

            ZStack {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)], spacing: 16) {
                        ForEach(shown) { a in
                            AttachmentTile(attachment: a, thumbnail: model.thumbnails[a.id], opening: model.opening == a.id)
                                .onAppear { model.thumbnail(for: a) }
                                .onTapGesture { model.preview(a) }
                                .contextMenu {
                                    Button("Quick Look") { model.preview(a) }
                                    Button("Save to Downloads") { model.save(a) }
                                }
                        }
                    }
                    .padding(20)
                }
                if model.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading \(model.folder.name)…").foregroundColor(.secondary)
                    }
                } else if shown.isEmpty {
                    EmptyState(symbol: "paperclip", title: model.items.isEmpty ? "No Attachments" : "No Matches",
                               detail: model.items.isEmpty ? "Nothing in \(model.folder.name) has files attached."
                                                           : "Nothing matches this filter.")
                }
            }

            Divider()

            HStack {
                if let error = model.error {
                    Text(error).font(.system(size: 13)).foregroundColor(.red).lineLimit(2)
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 860, height: 640)
    }
}

struct AttachmentTile: View {
    let attachment: AttachmentInfo
    let thumbnail: NSImage?
    var opening = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045))
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(nsImage: AttachmentSaver.icon(for: attachment.filename))
                        .resizable()
                        .frame(width: 56, height: 56)
                }
                if opening {
                    ProgressView().controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(hovering ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: hovering ? 2 : 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(attachment.from?.display ?? "Unknown") · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.fileSize), countStyle: .file))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(MailDate.listString(attachment.date))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(attachment.subject.isEmpty ? "(No subject)" : attachment.subject)\nClick to preview")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Remind Me date picker

struct SnoozePickerView: View {
    let request: SnoozeRequest
    @ObservedObject var store: MailStore
    @State private var date = SnoozeChoice.tomorrow.date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remind Me")
                .font(.system(size: 17, weight: .semibold))
            Text(request.ids.count == 1
                 ? "The email moves to Snoozed and comes back to your Inbox, unread, at this time."
                 : "The emails move to Snoozed and come back to your Inbox, unread, at this time.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .labelsHidden()
            Text("Snoozed mail comes back while one.com Mail is open.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { store.snoozePicker = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Remind Me") {
                    store.snooze(request.ids, until: date)
                    store.snoozePicker = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

// MARK: - Settings: rules and trusted senders

struct RulesSettings: View {
    @ObservedObject var store: MailStore
    @State private var picked: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Standing Clean Up rules for your Inbox, checked every few hours while the app is open. Add one from a sender's row in Clean Up.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(store.cleanupRules.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                 selection: $picked) { rule in
                HStack {
                    Text(rule.name.isEmpty ? rule.sender : rule.name)
                    Spacer()
                    Text(rule.summary).foregroundColor(.secondary)
                }
                .tag(rule.sender)
            }
            .overlay {
                if store.cleanupRules.isEmpty {
                    Text("No rules yet.")
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Remove Rule") {
                    if let p = picked { store.setRule(nil, for: p) }
                    picked = nil
                }
                .disabled(picked == nil)
            }
            if !store.trustedImageSenders.isEmpty {
                Divider().padding(.vertical, 4)
                HStack {
                    Text(store.trustedImageSenders.count == 1
                         ? "Images load automatically from 1 sender."
                         : "Images load automatically from \(store.trustedImageSenders.count) senders.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Ask Again for All") { store.trustedImageSenders = [] }
                }
            }
        }
        .padding(10)
    }
}
