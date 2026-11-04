// Network layer for the native mail client: a TLS socket, an IMAP client (reading mail) and an
// SMTP sender (sending mail). Talks directly to one.com's servers; nothing goes anywhere else.

import Foundation
import Network

enum MailError: LocalizedError {
    case connection(String)
    case server(String)
    case auth(String)

    var errorDescription: String? {
        switch self {
        case .connection(let m), .server(let m), .auth(let m): return m
        }
    }

    var isConnection: Bool {
        if case .connection = self { return true }
        return false
    }
}

/// Thread-safe "only the first caller wins" flag.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

// MARK: - TLS socket

final class TLSSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "onecom-mail.socket")
    private var buffer: [UInt8] = []
    private var position = 0
    var readTimeout: TimeInterval = 90

    init(host: String, port: Int) {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = 20
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 993
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
    }

    func open() async throws {
        let once = OnceFlag()
        let conn = connection
        let q = queue
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume() }
                case .failed(let error), .waiting(let error):
                    if once.fire() {
                        conn.cancel()
                        cont.resume(throwing: MailError.connection("Couldn't connect to the mail server: \(error.localizedDescription)"))
                    }
                case .cancelled:
                    if once.fire() { cont.resume(throwing: MailError.connection("The connection was cancelled.")) }
                default:
                    break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + 25) {
                if once.fire() {
                    conn.cancel()
                    cont.resume(throwing: MailError.connection("Timed out connecting to the mail server."))
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }

    func send(_ bytes: [UInt8]) async throws {
        let conn = connection
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: MailError.connection(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receiveChunk() async throws -> [UInt8] {
        let conn = connection
        let q = queue
        let done = OnceFlag()
        let timeout = readTimeout
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                _ = done.fire()
                if let data = data, !data.isEmpty {
                    cont.resume(returning: [UInt8](data))
                } else if let error = error {
                    cont.resume(throwing: MailError.connection(error.localizedDescription))
                } else if isComplete {
                    cont.resume(throwing: MailError.connection("The mail server closed the connection."))
                } else {
                    cont.resume(returning: [])
                }
            }
            // A stalled connection gets cancelled, which makes the receive above fail.
            q.asyncAfter(deadline: .now() + timeout) {
                if done.fire() { conn.cancel() }
            }
        }
    }

    private func compact() {
        if position >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            position = 0
        } else if position > 1_000_000 {
            buffer.removeFirst(position)
            position = 0
        }
    }

    /// Reads one line, without its line break.
    func readLine() async throws -> [UInt8] {
        var searchFrom = position
        while true {
            var i = searchFrom
            while i + 1 < buffer.count {
                if buffer[i] == 13 && buffer[i + 1] == 10 {
                    let line = Array(buffer[position..<i])
                    position = i + 2
                    compact()
                    return line
                }
                i += 1
            }
            searchFrom = max(position, buffer.count - 1)
            buffer += try await receiveChunk()
        }
    }

    func readBytes(_ count: Int) async throws -> [UInt8] {
        while buffer.count - position < count {
            buffer += try await receiveChunk()
        }
        let out = Array(buffer[position..<(position + count)])
        position += count
        compact()
        return out
    }
}

// MARK: - IMAP values

enum IMAPValue {
    case atom(String)
    case string([UInt8])
    case list([IMAPValue])
    case null

    var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let b): return String(decoding: b, as: UTF8.self)
        default: return nil
        }
    }

    var bytes: [UInt8]? {
        switch self {
        case .string(let b): return b
        case .atom(let s): return Array(s.utf8)
        default: return nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let l) = self { return l }
        return nil
    }

    var int: Int? { text.flatMap { Int($0) } }
}

/// Parses one IMAP response line (with any {n} literals already inlined after their markers).
struct IMAPParser {
    let b: [UInt8]
    var i = 0

    init(bytes: [UInt8]) { b = bytes }

    mutating func parseAll() -> [IMAPValue] {
        var out: [IMAPValue] = []
        while true {
            skipSpaces()
            if i >= b.count { break }
            guard let v = parseValue() else { break }
            out.append(v)
        }
        return out
    }

    private mutating func skipSpaces() {
        while i < b.count && b[i] == 32 { i += 1 }
    }

    private mutating func parseValue() -> IMAPValue? {
        skipSpaces()
        guard i < b.count else { return nil }
        switch b[i] {
        case 40: // (
            i += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                if i >= b.count { break }
                if b[i] == 41 { i += 1; break }
                guard let v = parseValue() else { break }
                items.append(v)
            }
            return .list(items)
        case 41: // stray )
            i += 1
            return .atom(")")
        case 34: // "quoted"
            i += 1
            var s: [UInt8] = []
            while i < b.count {
                let c = b[i]
                if c == 92 && i + 1 < b.count {
                    s.append(b[i + 1])
                    i += 2
                    continue
                }
                if c == 34 { i += 1; break }
                s.append(c)
                i += 1
            }
            return .string(s)
        case 123: // {n} literal
            var j = i + 1
            var n = 0
            while j < b.count, b[j] >= 48, b[j] <= 57 {
                n = n * 10 + Int(b[j] - 48)
                j += 1
            }
            if j < b.count && b[j] == 43 { j += 1 }
            if j < b.count && b[j] == 125 { j += 1 }
            if j + 1 < b.count && b[j] == 13 && b[j + 1] == 10 { j += 2 }
            let end = min(j + n, b.count)
            let literal = j < end ? Array(b[j..<end]) : []
            i = end
            return .string(literal)
        default: // atom, which may contain [...] sections and a <...> origin
            var s: [UInt8] = []
            var depth = 0
            while i < b.count {
                let c = b[i]
                if depth == 0 && (c == 32 || c == 40 || c == 41 || c == 13 || c == 10) { break }
                if c == 91 { depth += 1 } else if c == 93 { depth = max(0, depth - 1) }
                s.append(c)
                i += 1
            }
            if s.isEmpty {
                i += 1
                return .atom("")
            }
            let str = String(decoding: s, as: UTF8.self)
            return str.uppercased() == "NIL" ? .null : .atom(str)
        }
    }
}

// MARK: - IMAP client

actor IMAPClient {
    struct Response {
        var untagged: [[IMAPValue]]
        var status: String
        var text: String

        func check() throws {
            guard status == "OK" else {
                throw MailError.server(text.isEmpty ? "The mail server refused the request." : text)
            }
        }
    }

    enum Part {
        case text(String)
        case literal([UInt8])
    }

    static let summaryItems = "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID REFERENCES IN-REPLY-TO CONTENT-TYPE CONTENT-TRANSFER-ENCODING LIST-ID LIST-UNSUBSCRIBE PRECEDENCE AUTO-SUBMITTED)] BODY.PEEK[TEXT]<0.3000>)"

    let account: MailAccount
    private let password: String
    private var socket: TLSSocket?
    private var tagCounter = 0
    private var selected: String?
    private var exists = 0
    private var capabilities: Set<String> = []

    // One command at a time on the connection.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(account: MailAccount, password: String) {
        self.account = account
        self.password = password
    }

    private func lock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    // MARK: Public operations

    func close() async {
        await lock()
        defer { unlock() }
        if let s = socket {
            _ = try? await run([.text("LOGOUT")])
            s.close()
        }
        socket = nil
        selected = nil
    }

    func listFolders() async throws -> [MailFolder] {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> [MailFolder] in
            let r = try await self.run([.text("LIST \"\" \"*\"")])
            try r.check()
            var folders: [MailFolder] = []
            for vals in r.untagged where vals.count >= 4 && vals[0].text?.uppercased() == "LIST" {
                let flags = Set((vals[1].list ?? []).compactMap { $0.text?.lowercased() })
                if flags.contains("\\noselect") || flags.contains("\\nonexistent") { continue }
                let delimiter = vals[2].text ?? "/"
                guard let path = vals[3].text, !path.isEmpty else { continue }
                folders.append(Self.makeFolder(path: path, delimiter: delimiter, flags: flags))
            }
            return folders
        }
    }

    /// The newest `count` messages at or below sequence number `end` (nil = the newest).
    func fetchPage(folder: String, upTo end: Int?, count: Int) async throws -> (messages: [MessageSummary], lowestSeq: Int) {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> (messages: [MessageSummary], lowestSeq: Int) in
            let total = try await self.selectIfNeeded(folder)
            let top = min(end ?? total, total)
            guard top >= 1 else { return (messages: [], lowestSeq: 1) }
            let low = max(1, top - count + 1)
            let r = try await self.run([.text("FETCH \(low):\(top) \(Self.summaryItems)")])
            try r.check()
            return (messages: Self.summaries(from: r.untagged, folder: folder), lowestSeq: low)
        }
    }

    func fetchMessage(folder: String, uid: UInt32) async throws -> [UInt8] {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> [UInt8] in
            _ = try await self.selectIfNeeded(folder)
            let r = try await self.run([.text("UID FETCH \(uid) (UID BODY.PEEK[])")])
            try r.check()
            for vals in r.untagged {
                let items = Self.fetchItems(vals)
                if items["UID"]?.int == Int(uid), let body = items["BODY[]"]?.bytes { return body }
            }
            throw MailError.server("That message is no longer on the server.")
        }
    }

    func fetchNewMessages(folder: String, fromUID: Int) async throws -> [MessageSummary] {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> [MessageSummary] in
            _ = try await self.selectIfNeeded(folder)
            let r = try await self.run([.text("UID FETCH \(fromUID):* \(Self.summaryItems)")])
            try r.check()
            return Self.summaries(from: r.untagged, folder: folder).filter { Int($0.uid) >= fromUID && !$0.seen }
        }
    }

    /// Full-text search on the server (headers and body); returns the newest `limit` matches.
    func search(folder: String, query: String, limit: Int) async throws -> [MessageSummary] {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> [MessageSummary] in
            _ = try await self.selectIfNeeded(folder)
            var parts: [Part] = [.text("UID SEARCH CHARSET UTF-8 TEXT ")]
            parts += Self.astring(query)
            var r = try await self.run(parts)
            if r.status != "OK" && query.allSatisfy({ $0.isASCII }) {
                // Some servers don't accept CHARSET; plain ASCII queries work without it.
                r = try await self.run([.text("UID SEARCH TEXT " + Self.quoted(query))])
            }
            try r.check()
            let newest = Array(Self.searchUIDs(r.untagged).sorted(by: >).prefix(limit))
            guard !newest.isEmpty else { return [] }
            let set = newest.map { String($0) }.joined(separator: ",")
            let f = try await self.run([.text("UID FETCH \(set) \(Self.summaryItems)")])
            try f.check()
            return Self.summaries(from: f.untagged, folder: folder)
        }
    }

    /// UIDs of messages in `folder` with this Message-ID header (used to replace saved drafts).
    func findUIDs(folder: String, messageID: String) async throws -> [UInt32] {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> [UInt32] in
            _ = try await self.selectIfNeeded(folder)
            let r = try await self.run([.text("UID SEARCH HEADER Message-ID " + Self.quoted(messageID))])
            try r.check()
            return Self.searchUIDs(r.untagged)
        }
    }

    /// Whether anything in `folder` answers the message with this Message-ID (for follow-up reminders).
    func hasReply(folder: String, to messageID: String) async throws -> Bool {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> Bool in
            _ = try await self.selectIfNeeded(folder)
            let id = Self.quoted(messageID)
            let r = try await self.run([.text("UID SEARCH OR HEADER In-Reply-To \(id) HEADER References \(id)")])
            try r.check()
            return !Self.searchUIDs(r.untagged).isEmpty
        }
    }

    /// Every attachment in a folder, from the messages' structure; nothing is downloaded yet.
    func fetchAttachments(folder: String) async throws -> [AttachmentInfo] {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> [AttachmentInfo] in
            let total = try await self.selectIfNeeded(folder)
            guard total > 0 else { return [] }
            var found: [AttachmentInfo] = []
            var start = 1
            while start <= total {
                let end = min(start + 999, total)
                let r = try await self.run([.text("FETCH \(start):\(end) (UID INTERNALDATE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])")])
                try r.check()
                for vals in r.untagged {
                    let items = Self.fetchItems(vals)
                    guard let uidValue = items["UID"]?.int, let uid = UInt32(exactly: uidValue),
                          let structure = items["BODYSTRUCTURE"]?.list else { continue }
                    var headerBytes: [UInt8] = []
                    for (key, value) in items where key.hasPrefix("BODY[HEADER") { headerBytes = value.bytes ?? [] }
                    let h = MIMEHeaders.parse(headerBytes)
                    let from = MailAddress.parseList(h["from"]).first
                    let subject = MIME.decodeHeader(h["subject"] ?? "")
                    let date = MailDate.parseInternal(items["INTERNALDATE"]?.text) ?? Date()
                    for p in AttachmentInfo.parts(of: structure) {
                        found.append(AttachmentInfo(folder: folder, uid: uid, part: p.part, filename: p.filename,
                                                    mimeType: p.mimeType, encoding: p.encoding, size: p.size,
                                                    from: from, subject: subject, date: date))
                    }
                }
                start = end + 1
            }
            return found
        }
    }

    /// One part of a message (e.g. "2" or "1.3"), decoded.
    func fetchPart(folder: String, uid: UInt32, part: String, encoding: String) async throws -> Data {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> Data in
            _ = try await self.selectIfNeeded(folder)
            let r = try await self.run([.text("UID FETCH \(uid) (UID BODY.PEEK[\(part)])")])
            try r.check()
            for vals in r.untagged {
                let items = Self.fetchItems(vals)
                guard items["UID"]?.int == Int(uid), let raw = items["BODY[\(part)]"]?.bytes else { continue }
                switch encoding {
                case "base64": return Data(MIME.decodeBase64(raw))
                case "quoted-printable": return Data(MIME.decodeQuotedPrintable(raw))
                default: return Data(raw)
                }
            }
            throw MailError.server("That attachment is no longer on the server.")
        }
    }

    func createFolder(_ name: String) async throws {
        await lock()
        defer { unlock() }
        try await withRetry { () async throws -> Void in
            let r = try await self.run([.text("CREATE " + Self.quoted(name))])
            if r.status != "OK" && !r.text.lowercased().contains("exist") { try r.check() }
        }
    }

    /// Compact UID sets ("12:40,52,60:61"), split so no single command gets too long.
    static func uidSets(_ uids: [UInt32], maxRanges: Int = 200) -> [String] {
        let sorted = Array(Set(uids)).sorted()
        var ranges: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] &+ 1 { j += 1 }
            ranges.append(i == j ? String(sorted[i]) : "\(sorted[i]):\(sorted[j])")
            i = j + 1
        }
        var sets: [String] = []
        var start = 0
        while start < ranges.count {
            let end = min(start + maxRanges, ranges.count)
            sets.append(ranges[start..<end].joined(separator: ","))
            start = end
        }
        return sets
    }

    func setFlag(folder: String, uids: [UInt32], flag: String, on: Bool) async throws {
        guard !uids.isEmpty else { return }
        await lock()
        defer { unlock() }
        try await withRetry { () async throws -> Void in
            _ = try await self.selectIfNeeded(folder)
            let sign = on ? "+" : "-"
            for set in Self.uidSets(uids) {
                try await self.run([.text("UID STORE \(set) \(sign)FLAGS.SILENT (\(flag))")]).check()
            }
        }
    }

    func move(folder: String, uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        await lock()
        defer { unlock() }
        try await withRetry { () async throws -> Void in
            _ = try await self.selectIfNeeded(folder)
            let dest = Self.quoted(destination)
            for set in Self.uidSets(uids) {
                if self.capabilities.contains("MOVE") {
                    try await self.run([.text("UID MOVE \(set) \(dest)")]).check()
                } else {
                    try await self.run([.text("UID COPY \(set) \(dest)")]).check()
                    try await self.run([.text("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")]).check()
                    try await self.expunge(set)
                }
            }
        }
    }

    func deletePermanently(folder: String, uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        await lock()
        defer { unlock() }
        try await withRetry { () async throws -> Void in
            _ = try await self.selectIfNeeded(folder)
            for set in Self.uidSets(uids) {
                try await self.run([.text("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")]).check()
                try await self.expunge(set)
            }
        }
    }

    /// Lightweight info about every message in a folder, for Clean Up (sender, date, size, flags, newsletter).
    func fetchCleanupItems(folder: String) async throws -> [CleanupItem] {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> [CleanupItem] in
            let total = try await self.selectIfNeeded(folder)
            guard total > 0 else { return [] }
            var items: [CleanupItem] = []
            var start = 1
            while start <= total {
                let end = min(start + 1999, total)
                let r = try await self.run([.text("FETCH \(start):\(end) (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM DATE LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID PRECEDENCE)])")])
                try r.check()
                for vals in r.untagged {
                    let fetched = Self.fetchItems(vals)
                    guard let uidValue = fetched["UID"]?.int, let uid = UInt32(exactly: uidValue) else { continue }
                    var headerBytes: [UInt8] = []
                    for (key, value) in fetched where key.hasPrefix("BODY[HEADER") { headerBytes = value.bytes ?? [] }
                    let h = MIMEHeaders.parse(headerBytes)
                    let flags = Set((fetched["FLAGS"]?.list ?? []).compactMap { $0.text?.lowercased() })
                    let precedence = (h["precedence"] ?? "").lowercased()
                    let newsletter = h["list-unsubscribe"] != nil || h["list-id"] != nil
                        || precedence == "bulk" || precedence == "list"
                    items.append(CleanupItem(
                        uid: uid,
                        from: MailAddress.parseList(h["from"]).first,
                        date: MailDate.parseInternal(fetched["INTERNALDATE"]?.text) ?? MailDate.parse(h["date"]) ?? Date(),
                        size: fetched["RFC822.SIZE"]?.int ?? 0,
                        seen: flags.contains("\\seen"),
                        isNewsletter: newsletter,
                        unsubscribe: Unsubscribe(header: h["list-unsubscribe"], post: h["list-unsubscribe-post"])))
                }
                start = end + 1
            }
            return items
        }
    }

    func append(folder: String, message: [UInt8], flags: String) async throws {
        await lock()
        defer { unlock() }
        try await withRetry { () async throws -> Void in
            try await self.run([.text("APPEND \(Self.quoted(folder)) (\(flags)) "), .literal(message)]).check()
        }
    }

    /// Where your own folders live and what separates folder levels, from the server's NAMESPACE.
    /// one.com accounts often keep them under "INBOX." rather than at the top.
    func personalNamespace() async throws -> (prefix: String, delimiter: String) {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> (prefix: String, delimiter: String) in
            let r = try await self.run([.text("NAMESPACE")])
            guard r.status == "OK" else { return (prefix: "", delimiter: ".") }
            for vals in r.untagged where vals.count >= 2 && vals[0].text?.uppercased() == "NAMESPACE" {
                if let first = vals[1].list?.first?.list, first.count >= 2 {
                    return (prefix: first[0].text ?? "", delimiter: first[1].text ?? ".")
                }
            }
            return (prefix: "", delimiter: ".")
        }
    }

    /// CREATE that reports every refusal (createFolder tolerates "already exists" for Drafts).
    func createFolderStrict(_ path: String) async throws {
        await lock()
        defer { unlock() }
        try await withRetry { () async throws -> Void in
            try await self.run([.text("CREATE " + Self.quoted(path))]).check()
        }
    }

    /// How many messages a folder holds (asked before deleting it).
    func messageCount(folder: String) async throws -> Int {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> Int in
            let r = try await self.run([.text("STATUS \(Self.quoted(folder)) (MESSAGES)")])
            try r.check()
            for vals in r.untagged where vals.count >= 3 && vals[0].text?.uppercased() == "STATUS" {
                let list = vals.last?.list ?? []
                if list.count >= 2, list[0].text?.uppercased() == "MESSAGES" { return list[1].int ?? 0 }
            }
            return 0
        }
    }

    func renameFolder(_ path: String, to newPath: String) async throws {
        await lock()
        defer { unlock() }
        try await withRetry { () async throws -> Void in
            // Some servers refuse to rename or delete the folder that's open, so step out of it first.
            if self.selected == path { _ = try await self.selectIfNeeded("INBOX") }
            try await self.run([.text("RENAME \(Self.quoted(path)) \(Self.quoted(newPath))")]).check()
        }
    }

    /// Removes the folder and everything in it from the server, for good.
    func deleteFolder(_ path: String) async throws {
        await lock()
        defer { unlock() }
        try await withRetry { () async throws -> Void in
            if self.selected == path { _ = try await self.selectIfNeeded("INBOX") }
            try await self.run([.text("DELETE \(Self.quoted(path))")]).check()
        }
    }

    func status(folder: String) async throws -> (unseen: Int, uidNext: Int) {
        await lock()
        defer { unlock() }
        return try await withRetry { () async throws -> (unseen: Int, uidNext: Int) in
            let r = try await self.run([.text("STATUS \(Self.quoted(folder)) (UNSEEN UIDNEXT)")])
            try r.check()
            var unseen = 0
            var uidNext = 0
            for vals in r.untagged where vals.count >= 3 && vals[0].text?.uppercased() == "STATUS" {
                let list = vals.last?.list ?? []
                var i = 0
                while i + 1 < list.count {
                    let key = list[i].text?.uppercased()
                    let value = list[i + 1].int ?? 0
                    if key == "UNSEEN" { unseen = value } else if key == "UIDNEXT" { uidNext = value }
                    i += 2
                }
            }
            return (unseen: unseen, uidNext: uidNext)
        }
    }

    // MARK: Connection

    private func withRetry<T>(_ body: () async throws -> T) async throws -> T {
        do {
            try await connectIfNeeded()
            return try await body()
        } catch let error as MailError where error.isConnection {
            // The connection dropped (sleep, network change, server timeout): reconnect once.
            dropConnection()
            try await connectIfNeeded()
            return try await body()
        }
    }

    private func connectIfNeeded() async throws {
        if socket != nil { return }
        let s = TLSSocket(host: account.imapHost, port: account.imapPort)
        try await s.open()
        socket = s
        selected = nil
        do {
            let greeting = String(decoding: try await readResponseLine(s), as: UTF8.self).uppercased()
            if greeting.hasPrefix("* BYE") {
                throw MailError.connection("The mail server is not accepting connections right now.")
            }
            var loginParts: [Part] = [.text("LOGIN ")]
            loginParts += Self.astring(account.email)
            loginParts.append(.text(" "))
            loginParts += Self.astring(password)
            let login = try await run(loginParts)
            guard login.status == "OK" else {
                throw MailError.auth("Sign-in failed. Check your email address and password. (\(login.text))")
            }
            let caps = try await run([.text("CAPABILITY")])
            var found = Set<String>()
            for vals in caps.untagged where vals.first?.text?.uppercased() == "CAPABILITY" {
                for v in vals.dropFirst() {
                    if let t = v.text { found.insert(t.uppercased()) }
                }
            }
            capabilities = found
        } catch {
            dropConnection()
            throw error
        }
    }

    private func dropConnection() {
        socket?.close()
        socket = nil
        selected = nil
    }

    private func selectIfNeeded(_ folder: String) async throws -> Int {
        if selected == folder {
            try await run([.text("NOOP")]).check()
            return exists
        }
        selected = nil
        exists = 0
        try await run([.text("SELECT " + Self.quoted(folder))]).check()
        selected = folder
        return exists
    }

    private func expunge(_ set: String) async throws {
        if capabilities.contains("UIDPLUS") {
            try await run([.text("UID EXPUNGE \(set)")]).check()
        } else {
            try await run([.text("EXPUNGE")]).check()
        }
    }

    // MARK: Protocol

    @discardableResult
    private func run(_ parts: [Part]) async throws -> Response {
        guard let socket = socket else { throw MailError.connection("Not connected to the mail server.") }
        tagCounter += 1
        let tag = "A\(tagCounter)"
        var pending = Array("\(tag) ".utf8)
        var untagged: [[IMAPValue]] = []
        do {
            for part in parts {
                switch part {
                case .text(let s):
                    pending += Array(s.utf8)
                case .literal(let bytes):
                    pending += Array("{\(bytes.count)}\r\n".utf8)
                    try await socket.send(pending)
                    pending = []
                    // Wait for the server's go-ahead before sending the literal.
                    while true {
                        let line = try await readResponseLine(socket)
                        if line.first == 43 { break }
                        if line.first == 42 {
                            untagged.append(parseUntagged(line))
                            continue
                        }
                        if let rejected = Self.tagged(line, tag: tag, untagged: untagged) { return rejected }
                    }
                    pending += bytes
                }
            }
            pending += [13, 10]
            try await socket.send(pending)
            while true {
                let line = try await readResponseLine(socket)
                if line.first == 42 {
                    untagged.append(parseUntagged(line))
                    continue
                }
                if line.first == 43 { continue }
                if let response = Self.tagged(line, tag: tag, untagged: untagged) { return response }
            }
        } catch let error as MailError where error.isConnection {
            dropConnection()
            throw error
        }
    }

    private func parseUntagged(_ line: [UInt8]) -> [IMAPValue] {
        var parser = IMAPParser(bytes: line)
        var vals = parser.parseAll()
        if !vals.isEmpty { vals.removeFirst() }   // the "*"
        if vals.count >= 2, let kind = vals[1].text?.uppercased() {
            if kind == "EXISTS", let n = vals[0].int { exists = n }
            if kind == "EXPUNGE" { exists = max(0, exists - 1) }
        }
        return vals
    }

    /// Reads a full response line, pulling in any {n} literals it announces.
    private func readResponseLine(_ socket: TLSSocket) async throws -> [UInt8] {
        var line = try await socket.readLine()
        while let n = Self.literalLength(atEndOf: line) {
            line += [13, 10]
            line += try await socket.readBytes(n)
            line += try await socket.readLine()
        }
        return line
    }

    private static func literalLength(atEndOf line: [UInt8]) -> Int? {
        guard line.last == 125 else { return nil }
        var j = line.count - 2
        if j >= 0 && line[j] == 43 { j -= 1 }
        var digits: [UInt8] = []
        while j >= 0, line[j] >= 48, line[j] <= 57 {
            digits.insert(line[j], at: 0)
            j -= 1
        }
        guard j >= 0, line[j] == 123, !digits.isEmpty else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    private static func tagged(_ line: [UInt8], tag: String, untagged: [[IMAPValue]]) -> Response? {
        let s = String(decoding: line, as: UTF8.self)
        guard s.hasPrefix(tag + " ") else { return nil }
        let rest = s.dropFirst(tag.count + 1)
        let status = String(rest.prefix(while: { $0 != " " })).uppercased()
        let text = rest.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
        return Response(untagged: untagged, status: status, text: text)
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Quoted string when safe, otherwise a literal (e.g. passwords with non-ASCII characters).
    static func astring(_ s: String) -> [Part] {
        if s.allSatisfy({ $0.isASCII && !$0.isNewline }) { return [.text(quoted(s))] }
        return [.literal(Array(s.utf8))]
    }

    // MARK: Parsing results

    static func fetchItems(_ vals: [IMAPValue]) -> [String: IMAPValue] {
        guard vals.count >= 3, vals[1].text?.uppercased() == "FETCH", let list = vals[2].list else { return [:] }
        var items: [String: IMAPValue] = [:]
        var i = 0
        while i + 1 < list.count {
            if let key = list[i].text { items[key.uppercased()] = list[i + 1] }
            i += 2
        }
        return items
    }

    static func searchUIDs(_ untagged: [[IMAPValue]]) -> [UInt32] {
        var out: [UInt32] = []
        for vals in untagged where vals.first?.text?.uppercased() == "SEARCH" {
            for v in vals.dropFirst() {
                if let n = v.int, let uid = UInt32(exactly: n) { out.append(uid) }
            }
        }
        return out
    }

    static func summaries(from untagged: [[IMAPValue]], folder: String) -> [MessageSummary] {
        untagged.compactMap { makeSummary(fetchItems($0), folder: folder) }.sorted { $0.uid > $1.uid }
    }

    static func makeSummary(_ items: [String: IMAPValue], folder: String) -> MessageSummary? {
        guard let uidValue = items["UID"]?.int, let uid = UInt32(exactly: uidValue) else { return nil }
        var headerBytes: [UInt8] = []
        var textBytes: [UInt8] = []
        var hasHeader = false
        for (key, value) in items {
            if key.hasPrefix("BODY[HEADER") {
                headerBytes = value.bytes ?? []
                hasHeader = true
            } else if key.hasPrefix("BODY[TEXT]") {
                textBytes = value.bytes ?? []
            }
        }
        guard hasHeader else { return nil }   // e.g. a bare flag update

        let h = MIMEHeaders.parse(headerBytes)
        let flags = Set((items["FLAGS"]?.list ?? []).compactMap { $0.text?.lowercased() })
        let contentType = MIME.parseParams(h["content-type"] ?? "text/plain").main
        // In-Reply-To counts too: some mailers reply without a References header.
        let refs = ((h["references"] ?? "") + " " + (h["in-reply-to"] ?? ""))
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { String($0) }
            .filter { $0.hasPrefix("<") }

        return MessageSummary(
            folder: folder,
            uid: uid,
            from: MailAddress.parseList(h["from"]).first,
            to: MailAddress.parseList(h["to"]),
            cc: MailAddress.parseList(h["cc"]),
            replyTo: MailAddress.parseList(h["reply-to"]),
            subject: MIME.decodeHeader(h["subject"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            date: MailDate.parse(h["date"]) ?? MailDate.parseInternal(items["INTERNALDATE"]?.text) ?? Date(),
            snippet: textBytes.isEmpty ? "" : MIME.snippet(headers: headerBytes, partialBody: textBytes),
            seen: flags.contains("\\seen"),
            flagged: flags.contains("\\flagged"),
            answered: flags.contains("\\answered"),
            hasAttachments: contentType == "multipart/mixed",
            messageID: h["message-id"]?.trimmingCharacters(in: .whitespaces),
            references: refs,
            isAutomated: h["list-id"] != nil || h["list-unsubscribe"] != nil
                || ["bulk", "list", "junk"].contains(h["precedence"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
                || (h["auto-submitted"].map { $0.trimmingCharacters(in: .whitespaces).lowercased() != "no" } ?? false))
    }

    static func makeFolder(path: String, delimiter: String, flags: Set<String>) -> MailFolder {
        let decoded = MIME.decodeModifiedUTF7(path)
        let last = delimiter.isEmpty ? decoded : (decoded.components(separatedBy: delimiter).last ?? decoded)
        let lower = last.lowercased()
        var role = FolderRole.other
        if path.uppercased() == "INBOX" {
            role = .inbox
        } else if flags.contains("\\sent") || ["sent", "sent items", "sent messages", "sent mail", "sendt",
                                               "sendt post", "sendte elementer"].contains(lower) {
            role = .sent
        } else if flags.contains("\\drafts") || ["drafts", "draft", "kladder", "kladde"].contains(lower) {
            role = .drafts
        } else if flags.contains("\\trash") || ["trash", "deleted", "deleted items", "deleted messages",
                                                "papirkurv", "slettet post", "slettede elementer"].contains(lower) {
            role = .trash
        } else if flags.contains("\\junk") || ["junk", "spam", "junk e-mail", "junk email", "uønsket post",
                                               "uønsket e-mail"].contains(lower) {
            role = .junk
        } else if flags.contains("\\archive") || ["archive", "archives", "arkiv"].contains(lower) {
            role = .archive
        }
        return MailFolder(path: path, name: role.title ?? last, role: role)
    }
}

// MARK: - SMTP

enum SMTPSender {
    static func send(account: MailAccount, password: String, recipients: [String], message: [UInt8]) async throws {
        let socket = TLSSocket(host: account.smtpHost, port: account.smtpPort)
        socket.readTimeout = 120
        try await socket.open()
        defer { socket.close() }

        func readReply() async throws -> (code: Int, text: String) {
            var lines: [String] = []
            while true {
                let line = String(decoding: try await socket.readLine(), as: UTF8.self)
                lines.append(line)
                let chars = Array(line)
                if chars.count < 4 || chars[3] != "-" { break }
            }
            let code = Int(String((lines.last ?? "").prefix(3))) ?? 0
            return (code: code, text: lines.joined(separator: " "))
        }

        func command(_ line: String) async throws -> (code: Int, text: String) {
            try await socket.send(Array((line + "\r\n").utf8))
            return try await readReply()
        }

        func require(_ reply: (code: Int, text: String), _ accepted: ClosedRange<Int>, _ step: String) throws {
            guard accepted.contains(reply.code) else {
                throw MailError.server("Sending failed at \(step): \(reply.text)")
            }
        }

        let greeting = try await readReply()
        try require(greeting, 220...220, "connect")
        let ehlo = try await command("EHLO onecom-mail.local")
        try require(ehlo, 250...250, "EHLO")

        var plain: [UInt8] = [0]
        plain += Array(account.email.utf8)
        plain.append(0)
        plain += Array(password.utf8)
        let auth = try await command("AUTH PLAIN " + Data(plain).base64EncodedString())
        if auth.code != 235 {
            let start = try await command("AUTH LOGIN")
            guard start.code == 334 else { throw MailError.auth("The outgoing mail server rejected your login. (\(auth.text))") }
            let user = try await command(Data(account.email.utf8).base64EncodedString())
            guard user.code == 334 else { throw MailError.auth("The outgoing mail server rejected your login. (\(user.text))") }
            let pass = try await command(Data(password.utf8).base64EncodedString())
            guard pass.code == 235 else { throw MailError.auth("The outgoing mail server rejected your login. (\(pass.text))") }
        }

        let mailFrom = try await command("MAIL FROM:<\(account.email)>")
        try require(mailFrom, 250...250, "MAIL FROM")
        for r in recipients {
            let reply = try await command("RCPT TO:<\(r)>")
            try require(reply, 250...251, "recipient \(r)")
        }
        let data = try await command("DATA")
        try require(data, 354...354, "DATA")

        // Dot-stuffing: lines starting with "." get an extra ".".
        var payload: [UInt8] = []
        payload.reserveCapacity(message.count + 1024)
        var atLineStart = true
        for b in message {
            if atLineStart && b == 46 { payload.append(46) }
            payload.append(b)
            atLineStart = (b == 10)
        }
        if Array(payload.suffix(2)) != [13, 10] { payload += [13, 10] }
        payload += Array(".\r\n".utf8)
        try await socket.send(payload)
        let sent = try await readReply()
        try require(sent, 250...250, "sending the message")
        _ = try? await command("QUIT")
    }
}
