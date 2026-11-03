// State for the native mail client: account, folders, message list, the open message,
// actions (read/flag/delete/archive), server search, drafts, sending, and checking for new mail.

import AppKit
import Security
import UniformTypeIdentifiers

struct MailAccount: Codable, Equatable {
    var email: String
    var name: String
    var imapHost: String
    var imapPort: Int
    var smtpHost: String
    var smtpPort: Int
}

struct OpenedMessage {
    var summary: MessageSummary
    var parsed: ParsedMessage
}

struct ReplyReference {
    var folder: String
    var uid: UInt32
}

struct ComposeDraft {
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = NSAttributedString()
    var attachments: [OutgoingAttachment] = []
    var inReplyTo: String?
    var references: [String] = []
    var replyingTo: ReplyReference?
    /// Set when editing a saved draft: its Message-ID and where it is, so saving or sending replaces it.
    var messageID: String?
    var existingDraft: ReplyReference?
}

// MARK: - Keychain

enum Keychain {
    // The Dev build keeps its own entry: macOS won't let one app replace an entry another app made.
    static let service = isDevBuild ? "one.com Mail Dev" : "one.com Mail"

    static func save(_ password: String, account: String) throws {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
        ]
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // An entry we couldn't delete (e.g. made by an older build): change its password instead.
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: Data(password.utf8)] as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw MailError.server("Couldn't save your password to the Keychain (error \(status)).")
        }
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Store

@MainActor
final class MailStore: ObservableObject {
    enum SearchScope: Hashable {
        case allMail, currentFolder
    }

    @Published private(set) var account: MailAccount?
    @Published private(set) var folders: [MailFolder] = []
    @Published private(set) var currentFolder: MailFolder?
    @Published private(set) var messages: [MessageSummary] = []
    /// The selected messages (⌘-click / ⇧-click selects several).
    @Published var selection: Set<String> = [] {
        didSet { if selection != oldValue { openSelected() } }
    }

    /// The single selected message, if exactly one is selected.
    var selectedID: String? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }

    /// Clean Up sheet, when open.
    @Published var cleanup: CleanupModel?
    @Published private(set) var opened: OpenedMessage?
    @Published private(set) var isLoadingList = false
    @Published private(set) var isLoadingMessage = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var inboxUnread: Int?
    @Published var errorMessage: String?
    @Published var allowRemoteContent = false

    // Search: typing filters the loaded list instantly; then the server is searched.
    @Published var searchText = "" {
        didSet { if searchText != oldValue { searchTextChanged() } }
    }
    @Published var searchScope: SearchScope = .allMail {
        didSet { if searchScope != oldValue { scheduleSearch(delay: 0) } }
    }
    @Published private(set) var searchResults: [MessageSummary]?
    @Published private(set) var isSearching = false

    var onUnreadChanged: ((Int?) -> Void)?
    var onNewMail: (([MessageSummary]) -> Void)?
    var onCompose: ((ComposeDraft) -> Void)?
    var onFolderChanged: (() -> Void)?

    private let pageSize = 50
    private var client: IMAPClient?
    private var password = ""
    private var lowestSeq = 1
    private var folderToken = UUID()
    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var inboxUIDNext: Int?
    private var cache: [String: ParsedMessage] = [:]

    private static let accountKey = "mailAccount"
    private static let blockedKey = "blockedSenders"

    /// Senders whose new mail goes straight to Trash: lowercased addresses, or "@domain" for a whole domain.
    @Published private(set) var blockedSenders = Set(UserDefaults.standard.stringArray(forKey: blockedKey) ?? []) {
        didSet { UserDefaults.standard.set(blockedSenders.sorted(), forKey: Self.blockedKey) }
    }

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.accountKey),
              let saved = try? JSONDecoder().decode(MailAccount.self, from: data),
              let pw = Keychain.load(account: saved.email) else { return }
        account = saved
        password = pw
        begin(with: IMAPClient(account: saved, password: pw))
    }

    var inboxFolder: MailFolder? { folders.first { $0.role == .inbox } }
    var archiveFolder: MailFolder? { folders.first { $0.role == .archive } }
    var trashFolder: MailFolder? { folders.first { $0.role == .trash } }
    var sentFolder: MailFolder? { folders.first { $0.role == .sent } }
    var draftsFolder: MailFolder? { folders.first { $0.role == .drafts } }

    func folder(path: String) -> MailFolder? { folders.first { $0.path == path } }

    var isServerSearchActive: Bool { searchResults != nil }

    var visibleMessages: [MessageSummary] {
        if let results = searchResults { return results }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return messages }
        return messages.filter { m in
            m.subject.lowercased().contains(q)
                || m.snippet.lowercased().contains(q)
                || (m.from?.display.lowercased().contains(q) ?? false)
                || (m.from?.email.lowercased().contains(q) ?? false)
                || m.to.contains { $0.display.lowercased().contains(q) || $0.email.lowercased().contains(q) }
        }
    }

    func message(id: String) -> MessageSummary? {
        searchResults?.first { $0.id == id } ?? messages.first { $0.id == id }
    }

    var openedIsDraft: Bool {
        guard let o = opened else { return false }
        return folder(path: o.summary.folder)?.role == .drafts
    }

    // MARK: Account

    /// Returns an error message, or nil on success.
    func signIn(_ newAccount: MailAccount, password newPassword: String) async -> String? {
        let candidate = IMAPClient(account: newAccount, password: newPassword)
        do {
            let found = try await candidate.listFolders()
            try Keychain.save(newPassword, account: newAccount.email)
            if let data = try? JSONEncoder().encode(newAccount) {
                UserDefaults.standard.set(data, forKey: Self.accountKey)
            }
            account = newAccount
            password = newPassword
            folders = Self.sorted(found)
            begin(with: candidate)
            return nil
        } catch {
            await candidate.close()
            return error.localizedDescription
        }
    }

    func signOut() {
        pollTask?.cancel()
        pollTask = nil
        searchTask?.cancel()
        let old = client
        Task { await old?.close() }
        if let email = account?.email { Keychain.delete(account: email) }
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        client = nil
        account = nil
        password = ""
        folders = []
        currentFolder = nil
        messages = []
        searchResults = nil
        searchText = ""
        selectedID = nil
        opened = nil
        cache = [:]
        inboxUIDNext = nil
        setUnread(nil)
        onFolderChanged?()
    }

    private func begin(with newClient: IMAPClient) {
        client = newClient
        Task {
            if folders.isEmpty { await reloadFolders() }
            if let start = inboxFolder ?? folders.first { open(folder: start) }
            await poll(notify: false)
        }
        startPolling()
    }

    /// What's wrong with a new folder name, or nil if it's fine.
    private func folderNameProblem(_ name: String, renaming: MailFolder? = nil) -> String? {
        if name.isEmpty { return "Type a name for the folder." }
        if name.contains(".") || name.contains("/") { return "Folder names can't contain “.” or “/”." }
        if name.uppercased() == "INBOX" { return "“Inbox” is already taken." }
        if folders.contains(where: { $0.path != renaming?.path && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "There's already a folder called “\(name)”."
        }
        return nil
    }

    /// Makes a new top-level folder on the server and opens it. Returns an error to show, or nil.
    func createFolder(named raw: String) async -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = client else { return "You're not signed in." }
        if let problem = folderNameProblem(name) { return problem }
        let ns = (try? await client.personalNamespace()) ?? (prefix: "", delimiter: ".")
        let path = ns.prefix + MIME.encodeModifiedUTF7(name)
        do {
            try await client.createFolderStrict(path)
        } catch {
            return "one.com didn't make the folder: " + error.localizedDescription
        }
        await reloadFolders()
        guard let made = folder(path: path) ?? folders.first(where: { $0.name == name }) else {
            return "one.com said the folder was made, but it isn't in the folder list. Try Get New Mail (⇧⌘N)."
        }
        open(folder: made)
        return nil
    }

    /// Renames one of your own folders. Returns an error to show, or nil.
    func renameFolder(_ folder: MailFolder, to raw: String) async -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = client else { return "You're not signed in." }
        if name == folder.name { return nil }
        if let problem = folderNameProblem(name, renaming: folder) { return problem }
        // Keep it where it is: "INBOX.Job" renamed to "Work" becomes "INBOX.Work".
        let ns = (try? await client.personalNamespace()) ?? (prefix: "", delimiter: ".")
        let parent = folder.path.range(of: ns.delimiter, options: .backwards).map { String(folder.path[..<$0.upperBound]) } ?? ""
        let path = parent + MIME.encodeModifiedUTF7(name)
        do {
            try await client.renameFolder(folder.path, to: path)
        } catch {
            return "one.com didn't rename the folder: " + error.localizedDescription
        }
        let wasOpen = currentFolder?.path == folder.path
        await reloadFolders()
        if wasOpen, let renamed = self.folder(path: path) { open(folder: renamed) }
        return nil
    }

    func messageCount(in folder: MailFolder) async -> Int? {
        try? await client?.messageCount(folder: folder.path)
    }

    /// Deletes one of your own folders and everything in it. Returns an error to show, or nil.
    func deleteFolder(_ folder: MailFolder) async -> String? {
        guard let client = client else { return "You're not signed in." }
        do {
            try await client.deleteFolder(folder.path)
        } catch {
            return error.localizedDescription
        }
        let wasOpen = currentFolder?.path == folder.path
        await reloadFolders()
        if wasOpen, let inbox = inboxFolder { open(folder: inbox) }
        return nil
    }

    private func reloadFolders() async {
        guard let client = client else { return }
        do {
            folders = Self.sorted(try await client.listFolders())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func sorted(_ list: [MailFolder]) -> [MailFolder] {
        let ordered = list.sorted { a, b in
            if a.role != b.role { return a.role < b.role }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        // Two folders can both look like "Sent" (e.g. "Sent" and "INBOX.Sent"): the first keeps the
        // role, the others show their full name so the sidebar never lists the same name twice.
        var seen = Set<FolderRole>()
        return ordered.map { folder in
            guard folder.role != .other, !seen.insert(folder.role).inserted else { return folder }
            var f = folder
            f.role = .other
            let name = MIME.decodeModifiedUTF7(folder.path)
            f.name = name.hasPrefix("INBOX.") ? "Inbox › " + name.dropFirst(6) : name
            return f
        }
    }

    // MARK: Folders and lists

    func open(folder: MailFolder) {
        currentFolder = folder
        messages = []
        selectedID = nil
        opened = nil
        canLoadMore = false
        searchText = ""
        lowestSeq = 1
        folderToken = UUID()
        let token = folderToken
        onFolderChanged?()
        Task { await loadTop(token: token, showSpinner: true) }
    }

    func refresh() {
        guard client != nil else { return }
        let token = folderToken
        Task {
            await reloadFolders()
            await loadTop(token: token, showSpinner: true)
            await poll(notify: true)
        }
    }

    func loadMore() {
        guard canLoadMore, !isLoadingList, let client = client, let folder = currentFolder else { return }
        let token = folderToken
        let end = lowestSeq - 1
        isLoadingList = true
        Task {
            defer { if token == folderToken { isLoadingList = false } }
            do {
                let page = try await client.fetchPage(folder: folder.path, upTo: end, count: pageSize)
                guard token == folderToken else { return }
                let existing = Set(messages.map { $0.uid })
                messages += page.messages.filter { !existing.contains($0.uid) }
                messages.sort { $0.uid > $1.uid }
                lowestSeq = page.lowestSeq
                canLoadMore = lowestSeq > 1
            } catch {
                if token == folderToken { errorMessage = error.localizedDescription }
            }
        }
    }

    private func loadTop(token: UUID, showSpinner: Bool) async {
        guard let client = client, let folder = currentFolder else { return }
        if showSpinner { isLoadingList = true }
        defer { if token == folderToken { isLoadingList = false } }
        do {
            let page = try await client.fetchPage(folder: folder.path, upTo: nil, count: pageSize)
            guard token == folderToken else { return }
            let newest = folder.role == .inbox ? await dropBlocked(page.messages) : page.messages
            guard token == folderToken else { return }
            let cutoff = newest.map { $0.uid }.min() ?? 0
            let older = messages.filter { $0.uid < cutoff }
            messages = (newest + older).sorted { $0.uid > $1.uid }
            if older.isEmpty { lowestSeq = page.lowestSeq }
            canLoadMore = lowestSeq > 1
            if searchResults == nil, let sel = selectedID {
                if let fresh = messages.first(where: { $0.id == sel }) {
                    if var o = opened, o.summary.id == sel {
                        o.summary = fresh
                        opened = o
                    }
                } else {
                    selectedID = nil
                }
            }
        } catch {
            if token == folderToken { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Server search

    private func searchTextChanged() {
        searchTask?.cancel()
        searchResults = nil
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isSearching = false
            return
        }
        scheduleSearch(delay: 0.7)
    }

    /// Runs the server search now (e.g. when you press Return in the search field).
    func submitSearch() {
        scheduleSearch(delay: 0)
    }

    private func scheduleSearch(delay: Double) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let client = client else {
            searchResults = nil
            isSearching = false
            return
        }
        let targets: [MailFolder]
        if searchScope == .allMail {
            targets = folders.filter { $0.role != .trash && $0.role != .junk }
        } else {
            targets = currentFolder.map { [$0] } ?? []
        }
        isSearching = true
        searchTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if Task.isCancelled { return }
            var found: [MessageSummary] = []
            var failure: Error?
            for folder in targets {
                if Task.isCancelled { return }
                do {
                    found += try await client.search(folder: folder.path, query: query, limit: 60)
                } catch {
                    failure = error
                }
            }
            if Task.isCancelled { return }
            found.sort { $0.date > $1.date }
            searchResults = Array(found.prefix(250))
            isSearching = false
            if found.isEmpty, let failure = failure {
                errorMessage = "Search failed: \(failure.localizedDescription)"
            }
        }
    }

    // MARK: Reading

    private func openSelected() {
        allowRemoteContent = false
        guard let id = selectedID, let summary = message(id: id) else {
            opened = nil
            isLoadingMessage = false
            return
        }
        if let parsed = cache[id] {
            opened = OpenedMessage(summary: summary, parsed: parsed)
            markSeen(summary)
            return
        }
        opened = nil
        isLoadingMessage = true
        guard let client = client else { return }
        Task {
            defer { if selectedID == id { isLoadingMessage = false } }
            do {
                let bytes = try await client.fetchMessage(folder: summary.folder, uid: summary.uid)
                let parsed = await Task.detached(priority: .userInitiated) { ParsedMessage.parse(bytes) }.value
                if cache.count > 60 { cache.removeAll() }
                cache[id] = parsed
                guard selectedID == id else { return }
                let latest = message(id: id) ?? summary
                opened = OpenedMessage(summary: latest, parsed: parsed)
                markSeen(latest)
            } catch {
                if selectedID == id { errorMessage = error.localizedDescription }
            }
        }
    }

    private func markSeen(_ message: MessageSummary) {
        guard !message.seen, let client = client else { return }
        update(message.id) { $0.seen = true }
        let isInbox = message.folder == inboxFolder?.path
        Task {
            try? await client.setFlag(folder: message.folder, uids: [message.uid], flag: "\\Seen", on: true)
            if isInbox { await refreshUnread() }
        }
    }

    private func update(_ id: String, _ change: (inout MessageSummary) -> Void) {
        if let i = messages.firstIndex(where: { $0.id == id }) { change(&messages[i]) }
        if var results = searchResults, let i = results.firstIndex(where: { $0.id == id }) {
            change(&results[i])
            searchResults = results
        }
        if var o = opened, o.summary.id == id {
            change(&o.summary)
            opened = o
        }
    }

    private func removeLocally(_ id: String) {
        let visible = visibleMessages
        let index = visible.firstIndex(where: { $0.id == id })
        messages.removeAll { $0.id == id }
        if var results = searchResults {
            results.removeAll { $0.id == id }
            searchResults = results
        }
        cache[id] = nil
        if selectedID == id {
            let remaining = visibleMessages
            if let i = index, !remaining.isEmpty {
                selectedID = remaining[min(i, remaining.count - 1)].id
            } else {
                selectedID = nil
            }
        }
    }

    // MARK: Actions

    func toggleRead(_ id: String) {
        guard let client = client, let m = message(id: id) else { return }
        let newValue = !m.seen
        update(id) { $0.seen = newValue }
        let isInbox = m.folder == inboxFolder?.path
        Task {
            do {
                try await client.setFlag(folder: m.folder, uids: [m.uid], flag: "\\Seen", on: newValue)
            } catch {
                errorMessage = error.localizedDescription
            }
            if isInbox { await refreshUnread() }
        }
    }

    func toggleFlag(_ id: String) {
        guard let client = client, let m = message(id: id) else { return }
        let newValue = !m.flagged
        update(id) { $0.flagged = newValue }
        Task {
            do {
                try await client.setFlag(folder: m.folder, uids: [m.uid], flag: "\\Flagged", on: newValue)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func delete(_ id: String) {
        guard let client = client, let m = message(id: id) else { return }
        let trash = trashFolder
        let token = folderToken
        let isInbox = m.folder == inboxFolder?.path
        removeLocally(id)
        Task {
            do {
                if let trash = trash, trash.path != m.folder {
                    try await client.move(folder: m.folder, uids: [m.uid], to: trash.path)
                } else {
                    try await client.deletePermanently(folder: m.folder, uids: [m.uid])
                }
                if isInbox { await refreshUnread() }
            } catch {
                errorMessage = error.localizedDescription
                await loadTop(token: token, showSpinner: false)
            }
        }
    }

    func canArchive(_ id: String) -> Bool {
        guard let archive = archiveFolder, let m = message(id: id) else { return false }
        return archive.path != m.folder
    }

    func archive(_ id: String) {
        guard let client = client, let archive = archiveFolder, let m = message(id: id),
              archive.path != m.folder else { return }
        let token = folderToken
        let isInbox = m.folder == inboxFolder?.path
        removeLocally(id)
        Task {
            do {
                try await client.move(folder: m.folder, uids: [m.uid], to: archive.path)
                if isInbox { await refreshUnread() }
            } catch {
                errorMessage = error.localizedDescription
                await loadTop(token: token, showSpinner: false)
            }
        }
    }

    // MARK: Bulk actions on the selection

    var selectedMessages: [MessageSummary] { selection.compactMap { message(id: $0) } }
    var selectionAllRead: Bool { selectedMessages.allSatisfy { $0.seen } }
    var selectionAllFlagged: Bool { selectedMessages.allSatisfy { $0.flagged } }
    var selectionCanArchive: Bool {
        guard let archive = archiveFolder else { return false }
        return selectedMessages.contains { $0.folder != archive.path }
    }

    private func byFolder(_ list: [MessageSummary]) -> [String: [UInt32]] {
        var groups: [String: [UInt32]] = [:]
        for m in list { groups[m.folder, default: []].append(m.uid) }
        return groups
    }

    private func removeMany(_ ids: Set<String>) {
        let firstIndex = visibleMessages.firstIndex { ids.contains($0.id) }
        messages.removeAll { ids.contains($0.id) }
        if var results = searchResults {
            results.removeAll { ids.contains($0.id) }
            searchResults = results
        }
        for id in ids { cache[id] = nil }
        let remaining = visibleMessages
        if let i = firstIndex, !remaining.isEmpty {
            selection = [remaining[min(i, remaining.count - 1)].id]
        } else {
            selection = []
        }
    }

    func deleteSelection() {
        let targets = selectedMessages
        guard !targets.isEmpty, let client = client else { return }
        let trash = trashFolder
        let token = folderToken
        let groups = byFolder(targets)
        removeMany(Set(targets.map { $0.id }))
        Task {
            do {
                for (folder, uids) in groups {
                    if let trash = trash, trash.path != folder {
                        try await client.move(folder: folder, uids: uids, to: trash.path)
                    } else {
                        try await client.deletePermanently(folder: folder, uids: uids)
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                await loadTop(token: token, showSpinner: false)
            }
            await refreshUnread()
        }
    }

    /// Moves messages to another folder (drag and drop onto the sidebar, or Move To in the menu).
    func move(_ ids: Set<String>, to destination: MailFolder) {
        guard let client = client else { return }
        let targets = ids.compactMap { message(id: $0) }.filter { $0.folder != destination.path }
        guard !targets.isEmpty else { return }
        let token = folderToken
        let groups = byFolder(targets)
        removeMany(Set(targets.map { $0.id }))
        Task {
            do {
                for (folder, uids) in groups {
                    try await client.move(folder: folder, uids: uids, to: destination.path)
                }
            } catch {
                errorMessage = "Couldn't move to \(destination.name): " + error.localizedDescription
                await loadTop(token: token, showSpinner: false)
            }
            await refreshUnread()
        }
    }

    /// Folders a message can be moved into: everything except Drafts.
    var moveTargets: [MailFolder] { folders.filter { $0.role != .drafts } }

    func archiveSelection() {
        guard let archive = archiveFolder, let client = client else { return }
        let targets = selectedMessages.filter { $0.folder != archive.path }
        guard !targets.isEmpty else { return }
        let token = folderToken
        let groups = byFolder(targets)
        removeMany(Set(targets.map { $0.id }))
        Task {
            do {
                for (folder, uids) in groups {
                    try await client.move(folder: folder, uids: uids, to: archive.path)
                }
            } catch {
                errorMessage = error.localizedDescription
                await loadTop(token: token, showSpinner: false)
            }
            await refreshUnread()
        }
    }

    func setSelectionRead(_ read: Bool) {
        let targets = selectedMessages.filter { $0.seen != read }
        guard !targets.isEmpty, let client = client else { return }
        for m in targets { update(m.id) { $0.seen = read } }
        let groups = byFolder(targets)
        Task {
            do {
                for (folder, uids) in groups {
                    try await client.setFlag(folder: folder, uids: uids, flag: "\\Seen", on: read)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            await refreshUnread()
        }
    }

    func setSelectionFlagged(_ flagged: Bool) {
        let targets = selectedMessages.filter { $0.flagged != flagged }
        guard !targets.isEmpty, let client = client else { return }
        for m in targets { update(m.id) { $0.flagged = flagged } }
        let groups = byFolder(targets)
        Task {
            do {
                for (folder, uids) in groups {
                    try await client.setFlag(folder: folder, uids: uids, flag: "\\Flagged", on: flagged)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Blocked senders

    /// The block-list entry that catches this sender: their address, or "@their-domain".
    func blockEntry(for sender: MailAddress?) -> String? {
        guard let email = sender?.email.lowercased() else { return nil }
        if blockedSenders.contains(email) { return email }
        let domain = email.split(separator: "@").last.map { "@" + $0 }
        return domain.flatMap { blockedSenders.contains($0) ? $0 : nil }
    }

    func isBlocked(_ sender: MailAddress?) -> Bool { blockEntry(for: sender) != nil }

    /// Turns what someone typed ("name@example.com", "@example.com" or "example.com") into a block-list entry.
    static func blockEntry(typed raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.contains(" "), s.contains(".") else { return nil }
        if s.contains("@") { return s.hasSuffix("@") ? nil : s }
        return "@" + s
    }

    /// Blocks an address or "@domain" and moves loaded mail it catches to Trash; new mail is trashed on arrival.
    func block(_ entry: String) {
        blockedSenders.insert(entry)
        let caught = messages.filter { $0.folder != trashFolder?.path && isBlocked($0.from) }
        guard !caught.isEmpty else { return }
        removeMany(Set(caught.map { $0.id }))
        Task { _ = await dropBlocked(caught) }
    }

    func unblock(_ entry: String) {
        blockedSenders.remove(entry)
    }

    /// Moves mail from blocked senders to Trash on the server and returns the rest.
    private func dropBlocked(_ list: [MessageSummary]) async -> [MessageSummary] {
        guard let client = client, let trash = trashFolder else { return list }
        let blocked = list.filter { $0.folder != trash.path && isBlocked($0.from) }
        guard !blocked.isEmpty else { return list }
        for (folder, uids) in byFolder(blocked) {
            try? await client.move(folder: folder, uids: uids, to: trash.path)
        }
        await refreshUnread()
        let ids = Set(blocked.map { $0.id })
        return list.filter { !ids.contains($0.id) }
    }

    // MARK: Clean Up

    /// Opens Clean Up for the current folder, optionally with one sender already ticked.
    func openCleanup(sender: MailAddress? = nil) {
        guard let folder = currentFolder ?? inboxFolder else { return }
        let model = CleanupModel(store: self, folder: folder)
        if let sender = sender {
            let key = sender.email.lowercased()
            model.selectedSenders = [key]
            model.filterText = sender.email
        }
        cleanup = model
        Task { await model.load() }
    }

    func cleanupItems(folder: MailFolder) async throws -> [CleanupItem] {
        guard let client = client else { throw MailError.server("You're not signed in.") }
        return try await client.fetchCleanupItems(folder: folder.path)
    }

    /// Moves the messages to Trash (or deletes them for good when they're already in Trash).
    func cleanupRemove(folder: MailFolder, uids: [UInt32]) async throws {
        guard let client = client else { throw MailError.server("You're not signed in.") }
        if let trash = trashFolder, trash.path != folder.path {
            try await client.move(folder: folder.path, uids: uids, to: trash.path)
        } else {
            try await client.deletePermanently(folder: folder.path, uids: uids)
        }
        let removed = Set(uids.map { folder.path + "\u{1}" + String($0) })
        messages.removeAll { removed.contains($0.id) }
        if var results = searchResults {
            results.removeAll { removed.contains($0.id) }
            searchResults = results
        }
        if !selection.isDisjoint(with: removed) { selection = [] }
        for id in removed { cache[id] = nil }
        if currentFolder?.path == folder.path { await loadTop(token: folderToken, showSpinner: false) }
        await refreshUnread()
    }

    // MARK: Composing

    func newMessage() {
        guard account != nil else { return }
        var draft = ComposeDraft()
        draft.body = RichText.plain(signatureBlock)
        onCompose?(draft)
    }

    /// The signature from Settings, set off by the standard "-- " line; empty when there's none.
    private var signatureBlock: String {
        let sig = (UserDefaults.standard.string(forKey: "signature") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return sig.isEmpty ? "" : "\n\n-- \n" + sig
    }

    func reply(all: Bool) {
        guard let o = opened, let me = account?.email.lowercased() else { return }
        let s = o.summary
        var to: [MailAddress]
        if s.from?.email.lowercased() == me {
            to = s.to   // replying to something you sent
        } else if !s.replyTo.isEmpty {
            to = s.replyTo
        } else {
            to = s.from.map { [$0] } ?? []
        }
        var cc: [MailAddress] = []
        if all {
            let toEmails = Set(to.map { $0.email.lowercased() })
            cc = (s.to + s.cc).filter { $0.email.lowercased() != me && !toEmails.contains($0.email.lowercased()) }
        }

        var draft = ComposeDraft()
        draft.to = to.map { $0.editable }.joined(separator: ", ")
        draft.cc = cc.map { $0.editable }.joined(separator: ", ")
        draft.subject = s.subject.lowercased().hasPrefix("re:") ? s.subject : "Re: " + s.subject
        let who = s.from?.display ?? "someone"
        let body = NSMutableAttributedString(attributedString: RichText.plain(signatureBlock + "\n\nOn \(MailDate.longString(s.date)), \(who) wrote:\n"))
        body.append(RichText.quoted(o.parsed.plainText))
        draft.body = body
        draft.inReplyTo = s.messageID
        draft.references = s.references + (s.messageID.map { [$0] } ?? [])
        draft.replyingTo = ReplyReference(folder: s.folder, uid: s.uid)
        onCompose?(draft)
    }

    func forward() {
        guard let o = opened else { return }
        let s = o.summary
        var draft = ComposeDraft()
        draft.subject = s.subject.lowercased().hasPrefix("fwd:") ? s.subject : "Fwd: " + s.subject
        var header = signatureBlock + "\n\n---------- Forwarded message ----------\n"
        if let from = s.from { header += "From: \(from.editable)\n" }
        header += "Date: \(MailDate.longString(s.date))\n"
        header += "Subject: \(s.subject)\n"
        if !s.to.isEmpty { header += "To: \(s.to.map { $0.editable }.joined(separator: ", "))\n" }
        let body = NSMutableAttributedString(attributedString: RichText.plain(header + "\n"))
        if let html = o.parsed.html {
            body.append(RichText.fromHTML(html))
        } else {
            body.append(RichText.plain(o.parsed.plainText))
        }
        draft.body = body
        draft.attachments = o.parsed.attachments.map {
            OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
        onCompose?(draft)
    }

    /// Opens the selected saved draft for editing.
    func editDraft() {
        guard let o = opened, openedIsDraft else { return }
        let s = o.summary
        var draft = ComposeDraft()
        draft.to = s.to.map { $0.editable }.joined(separator: ", ")
        draft.cc = s.cc.map { $0.editable }.joined(separator: ", ")
        draft.bcc = MailAddress.parseList(o.parsed.headers["bcc"]).map { $0.editable }.joined(separator: ", ")
        draft.subject = s.subject
        if let html = o.parsed.html {
            draft.body = RichText.fromHTML(html)
        } else {
            draft.body = RichText.plain(o.parsed.text ?? "")
        }
        draft.attachments = o.parsed.attachments.map {
            OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
        draft.inReplyTo = o.parsed.headers["in-reply-to"]
        draft.references = s.references
        draft.messageID = s.messageID
        draft.existingDraft = ReplyReference(folder: s.folder, uid: s.uid)
        onCompose?(draft)
    }

    private func buildMessage(_ draft: ComposeDraft, account: MailAccount, messageID: String, forDraft: Bool) -> [UInt8] {
        let body = RichText.html(draft.body)
        return MessageBuilder.build(
            from: MailAddress(name: account.name, email: account.email),
            to: MailAddress.parseList(draft.to),
            cc: MailAddress.parseList(draft.cc),
            bcc: forDraft ? MailAddress.parseList(draft.bcc) : [],
            subject: draft.subject,
            text: RichText.plainText(draft.body),
            html: body.html,
            inlineImages: body.images,
            attachments: draft.attachments,
            inReplyTo: draft.inReplyTo,
            references: draft.references,
            messageID: messageID)
    }

    func send(_ draft: ComposeDraft, messageID: String) async throws {
        guard let account = account else { throw MailError.server("You're not signed in.") }
        let everyone = MailAddress.parseList(draft.to) + MailAddress.parseList(draft.cc) + MailAddress.parseList(draft.bcc)
        guard !everyone.isEmpty else { throw MailError.server("Add at least one recipient.") }
        if let bad = everyone.first(where: { !$0.email.contains("@") || $0.email.contains(" ") }) {
            throw MailError.server("“\(bad.email)” isn't a valid email address.")
        }

        let message = buildMessage(draft, account: account, messageID: messageID, forDraft: false)
        try await SMTPSender.send(account: account, password: password,
                                  recipients: everyone.map { $0.email }, message: message)

        // Keep a copy in Sent, and mark the original as answered.
        if let client = client {
            if let sent = sentFolder {
                try? await client.append(folder: sent.path, message: message, flags: "\\Seen")
                if currentFolder?.path == sent.path { await loadTop(token: folderToken, showSpinner: false) }
            }
            if let ref = draft.replyingTo {
                try? await client.setFlag(folder: ref.folder, uids: [ref.uid], flag: "\\Answered", on: true)
            }
        }
    }

    // MARK: Drafts

    /// Saves to the Drafts folder, replacing any earlier copy of the same draft.
    func saveDraft(_ draft: ComposeDraft, messageID: String, replacing: ReplyReference?) async throws {
        guard let account = account, let client = client else { throw MailError.server("You're not signed in.") }
        let drafts = try await ensureDraftsFolder()
        let message = buildMessage(draft, account: account, messageID: messageID, forDraft: true)
        let previous = (try? await client.findUIDs(folder: drafts.path, messageID: messageID)) ?? []
        try await client.append(folder: drafts.path, message: message, flags: "\\Draft \\Seen")
        var stale = previous
        if let r = replacing, r.folder == drafts.path, !stale.contains(r.uid) { stale.append(r.uid) }
        if !stale.isEmpty {
            try? await client.deletePermanently(folder: drafts.path, uids: stale)
            for uid in stale { cache[drafts.path + "\u{1}" + String(uid)] = nil }
        }
        if currentFolder?.path == drafts.path { await loadTop(token: folderToken, showSpinner: false) }
    }

    /// Removes saved copies of a draft (after sending it, or when you choose Don't Save).
    func discardDraft(messageID: String, replacing: ReplyReference?) async {
        guard let client = client, let drafts = draftsFolder else { return }
        var uids = (try? await client.findUIDs(folder: drafts.path, messageID: messageID)) ?? []
        if let r = replacing, r.folder == drafts.path, !uids.contains(r.uid) { uids.append(r.uid) }
        guard !uids.isEmpty else { return }
        try? await client.deletePermanently(folder: drafts.path, uids: uids)
        if currentFolder?.path == drafts.path { await loadTop(token: folderToken, showSpinner: false) }
    }

    private func ensureDraftsFolder() async throws -> MailFolder {
        if let drafts = draftsFolder { return drafts }
        guard let client = client else { throw MailError.server("You're not signed in.") }
        try await client.createFolder("Drafts")
        await reloadFolders()
        if let drafts = draftsFolder { return drafts }
        throw MailError.server("Couldn't find or create a Drafts folder.")
    }

    // MARK: New mail

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled, let self = self else { return }
                await self.poll(notify: true)
            }
        }
    }

    private func poll(notify: Bool) async {
        guard let client = client, let inbox = inboxFolder else { return }
        do {
            let status = try await client.status(folder: inbox.path)
            setUnread(status.unseen)
            if let previous = inboxUIDNext, status.uidNext > previous {
                let fresh = await dropBlocked(try await client.fetchNewMessages(folder: inbox.path, fromUID: previous))
                if notify && !fresh.isEmpty { onNewMail?(fresh) }
                await autoReply(to: fresh)
                if currentFolder?.path == inbox.path { await loadTop(token: folderToken, showSpinner: false) }
            }
            inboxUIDNext = status.uidNext
        } catch {
            // Stay quiet; the next check will try again.
        }
    }

    // MARK: Auto-reply

    /// When each sender last got an auto-reply, so nobody gets more than one a week.
    private var autoReplied: [String: Date] {
        get { UserDefaults.standard.dictionary(forKey: "autoReplied") as? [String: Date] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "autoReplied") }
    }

    /// Answers new mail with the auto-reply from Settings while it's on. Runs from this Mac, so only
    /// while the app is open. Skips newsletters, mailing lists, no-reply addresses and yourself.
    private func autoReply(to fresh: [MessageSummary]) async {
        let d = UserDefaults.standard
        let text = (d.string(forKey: "autoReplyText") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard d.bool(forKey: "autoReplyOn"), !text.isEmpty, let account = account else { return }
        let until = d.double(forKey: "autoReplyUntil")   // 0 = no end date
        if until > 0, Calendar.current.startOfDay(for: Date()) > Date(timeIntervalSince1970: until) {
            d.set(false, forKey: "autoReplyOn")
            return
        }
        let me = account.email.lowercased()
        let robots = ["noreply", "no-reply", "donotreply", "do-not-reply", "mailer-daemon", "postmaster", "bounce"]
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        var replied = autoReplied.filter { $0.value > weekAgo }
        for m in fresh where !m.isAutomated {
            guard let to = m.replyTo.first ?? m.from else { continue }
            let key = to.email.lowercased()
            let local = String(key.split(separator: "@").first ?? "")
            guard key != me, replied[key] == nil, !robots.contains(where: local.contains) else { continue }

            var draft = ComposeDraft()
            draft.to = to.editable
            draft.subject = m.subject.lowercased().hasPrefix("re:") ? m.subject : "Re: " + m.subject
            draft.body = RichText.plain(text)
            draft.inReplyTo = m.messageID
            draft.references = m.references + (m.messageID.map { [$0] } ?? [])
            let id = MessageBuilder.newMessageID(for: account.email)
            // Marks it as automatic (RFC 3834) so the other side's auto-reply doesn't answer back.
            let message = Array("Auto-Submitted: auto-replied\r\n".utf8)
                + buildMessage(draft, account: account, messageID: id, forDraft: false)
            do {
                try await SMTPSender.send(account: account, password: password, recipients: [to.email], message: message)
                replied[key] = Date()
                if let client = client, let sent = sentFolder {
                    try? await client.append(folder: sent.path, message: message, flags: "\\Seen")
                }
            } catch {
                // Try again with the next new mail from them.
            }
        }
        autoReplied = replied
    }

    private func refreshUnread() async {
        guard let client = client, let inbox = inboxFolder else { return }
        if let status = try? await client.status(folder: inbox.path) { setUnread(status.unseen) }
    }

    private func setUnread(_ count: Int?) {
        inboxUnread = count
        onUnreadChanged?(count)
    }
}
