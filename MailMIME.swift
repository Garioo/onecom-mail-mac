// Mail data models, MIME parsing and outgoing-message building for the native mail client.

import Foundation
import UniformTypeIdentifiers

// MARK: - Models

struct MailAddress: Hashable {
    var name: String
    var email: String

    var display: String { name.isEmpty ? email : name }

    /// "Name <email>", as shown in the compose fields.
    var editable: String {
        guard !name.isEmpty else { return email }
        let needsQuotes = name.contains(where: { ",;<>\"@".contains($0) })
        let clean = name.replacingOccurrences(of: "\"", with: "")
        return needsQuotes ? "\"\(clean)\" <\(email)>" : "\(clean) <\(email)>"
    }

    var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            .filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap { $0.first }
        if !letters.isEmpty { return String(letters).uppercased() }
        return email.first.map { String($0).uppercased() } ?? "?"
    }

    static func parseList(_ raw: String?) -> [MailAddress] {
        guard let raw = raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var angle = 0
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "<" {
                angle += 1
                current.append(ch)
            } else if ch == ">" {
                angle = max(0, angle - 1)
                current.append(ch)
            } else if (ch == "," || ch == ";") && !inQuotes && angle == 0 {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)

        return items.compactMap { item -> MailAddress? in
            let t = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return nil }
            if let lt = t.lastIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
                let email = t[t.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
                var name = t[..<lt].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
                    name = String(name.dropFirst().dropLast())
                }
                name = name.replacingOccurrences(of: "\\\"", with: "\"")
                guard !email.isEmpty else { return nil }
                return MailAddress(name: MIME.decodeHeader(name), email: email)
            }
            var email = t
            if let p = email.firstIndex(of: "(") {
                email = email[..<p].trimmingCharacters(in: .whitespaces)
            }
            return MailAddress(name: "", email: email)
        }
    }
}

enum FolderRole: Int, Comparable {
    case inbox, drafts, sent, archive, junk, trash, other

    static func < (a: FolderRole, b: FolderRole) -> Bool { a.rawValue < b.rawValue }

    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .other: return "folder"
        }
    }

    var title: String? {
        switch self {
        case .inbox: return "Inbox"
        case .drafts: return "Drafts"
        case .sent: return "Sent"
        case .archive: return "Archive"
        case .junk: return "Junk"
        case .trash: return "Trash"
        case .other: return nil
        }
    }
}

struct MailFolder: Identifiable, Hashable {
    var path: String     // the server's name for it (used in commands)
    var name: String     // what we show
    var role: FolderRole
    var id: String { path }
}

struct MessageSummary: Identifiable, Equatable {
    var folder: String   // path of the folder it lives in
    var uid: UInt32
    var from: MailAddress?
    var to: [MailAddress]
    var cc: [MailAddress]
    var replyTo: [MailAddress]
    var subject: String
    var date: Date
    var snippet: String
    var seen: Bool
    var flagged: Bool
    var answered: Bool
    var hasAttachments: Bool
    var messageID: String?
    var references: [String]

    /// Unique across folders (UIDs are only unique within one folder).
    var id: String { folder + "\u{1}" + String(uid) }
}

/// One message as seen by Clean Up: just enough to group and filter.
struct CleanupItem {
    var uid: UInt32
    var from: MailAddress?
    var date: Date
    var size: Int
    var seen: Bool
    var isNewsletter: Bool
}

struct MailAttachment: Identifiable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
    var contentID: String?
}

struct ParsedMessage {
    var headers: MIMEHeaders
    var html: String?
    var text: String?
    var attachments: [MailAttachment]
    var hasRemoteContent: Bool
    var displayHTML: String

    /// The message as plain text, for quoting in replies and forwards.
    var plainText: String { text ?? html.map { MIME.htmlToText($0) } ?? "" }

    static func parse(_ bytes: [UInt8]) -> ParsedMessage {
        let root = MIMEPart(bytes: bytes)
        var html: String?
        var text: String?
        var attachments: [MailAttachment] = []

        func walk(_ part: MIMEPart) {
            if part.mimeType.hasPrefix("multipart/") {
                for child in part.children { walk(child) }
                return
            }
            let isAttachment = part.dispositionType == "attachment"
            if part.mimeType == "text/html" && !isAttachment && html == nil {
                html = part.text
                return
            }
            if part.mimeType == "text/plain" && !isAttachment && text == nil && part.filename == nil {
                text = part.text
                return
            }
            let data = Data(part.decodedBody)
            if data.isEmpty && part.filename == nil { return }
            attachments.append(MailAttachment(filename: part.filename ?? MIME.defaultFilename(for: part.mimeType),
                                              mimeType: part.mimeType, data: data, contentID: part.contentID))
        }
        walk(root)

        // Inline images referenced as cid: become data: URLs and leave the attachment list.
        if var h = html {
            attachments.removeAll { a in
                guard let cid = a.contentID, h.contains("cid:\(cid)") else { return false }
                h = h.replacingOccurrences(of: "cid:\(cid)",
                                           with: "data:\(a.mimeType);base64,\(a.data.base64EncodedString())")
                return true
            }
            html = h
        }

        let remotePattern = #"(src|background)\s*=\s*["']?\s*https?:|url\(\s*["']?\s*https?:"#
        let hasRemote = html.map {
            $0.range(of: remotePattern, options: [.regularExpression, .caseInsensitive]) != nil
        } ?? false

        let display = html ?? MailHTML.plainToHTML(text ?? "(This message has no text.)")
        return ParsedMessage(headers: root.headers, html: html, text: text, attachments: attachments,
                             hasRemoteContent: hasRemote, displayHTML: display)
    }
}

// MARK: - Bytes

extension Array where Element == UInt8 {
    func find(_ pattern: [UInt8], from start: Int = 0) -> Int? {
        guard !pattern.isEmpty, count >= pattern.count, start >= 0 else { return nil }
        let last = count - pattern.count
        let first = pattern[0]
        var i = start
        while i <= last {
            if self[i] == first {
                var j = 1
                while j < pattern.count && self[i + j] == pattern[j] { j += 1 }
                if j == pattern.count { return i }
            }
            i += 1
        }
        return nil
    }
}

// MARK: - Headers

struct MIMEHeaders {
    var fields: [(name: String, value: String)] = []

    subscript(_ name: String) -> String? {
        let key = name.lowercased()
        return fields.first(where: { $0.name == key })?.value
    }

    static func parse(_ bytes: [UInt8]) -> MIMEHeaders {
        var headers = MIMEHeaders()
        for rawLine in MIME.splitLines(bytes) {
            let line = MIME.decodeText(rawLine, charset: "utf-8")
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if (line.first == " " || line.first == "\t"), !headers.fields.isEmpty {
                headers.fields[headers.fields.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.fields.append((name: name, value: value))
        }
        return headers
    }
}

// MARK: - MIME parts

final class MIMEPart {
    let headers: MIMEHeaders
    let mimeType: String
    let params: [String: String]
    let rawBody: [UInt8]
    let dispositionType: String?
    let filename: String?
    private(set) var children: [MIMEPart] = []

    init(bytes: [UInt8], depth: Int = 0, defaultType: String = "text/plain") {
        let (head, body) = MIME.splitHeaderBody(bytes)
        let parsedHeaders = MIMEHeaders.parse(head)
        let contentType = MIME.parseParams(parsedHeaders["content-type"] ?? defaultType)
        let type = contentType.main.isEmpty ? defaultType : contentType.main
        let disposition = parsedHeaders["content-disposition"].map { MIME.parseParams($0) }
        let name = disposition?.params["filename"] ?? contentType.params["name"]

        headers = parsedHeaders
        mimeType = type
        params = contentType.params
        rawBody = body
        dispositionType = disposition?.main
        filename = (name?.isEmpty == false) ? name : nil

        var parts: [MIMEPart] = []
        if type.hasPrefix("multipart/"), let boundary = contentType.params["boundary"], !boundary.isEmpty, depth < 20 {
            let childDefault = type == "multipart/digest" ? "message/rfc822" : "text/plain"
            parts = MIME.splitMultipart(body, boundary: boundary).map {
                MIMEPart(bytes: $0, depth: depth + 1, defaultType: childDefault)
            }
        }
        children = parts
    }

    var transferEncoding: String {
        (headers["content-transfer-encoding"] ?? "7bit").trimmingCharacters(in: .whitespaces).lowercased()
    }

    var decodedBody: [UInt8] {
        switch transferEncoding {
        case "base64": return MIME.decodeBase64(rawBody)
        case "quoted-printable": return MIME.decodeQuotedPrintable(rawBody)
        default: return rawBody
        }
    }

    var text: String { MIME.decodeText(decodedBody, charset: params["charset"]) }

    var contentID: String? {
        guard let raw = headers["content-id"] else { return nil }
        let id = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        return id.isEmpty ? nil : id
    }
}

// MARK: - MIME helpers

enum MIME {
    static func splitLines(_ b: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var start = 0
        for i in 0..<b.count where b[i] == 10 {
            var end = i
            if end > start && b[end - 1] == 13 { end -= 1 }
            lines.append(Array(b[start..<end]))
            start = i + 1
        }
        if start < b.count { lines.append(Array(b[start...])) }
        return lines
    }

    static func splitHeaderBody(_ b: [UInt8]) -> ([UInt8], [UInt8]) {
        if b.first == 10 { return ([], Array(b.dropFirst())) }
        if b.count >= 2 && b[0] == 13 && b[1] == 10 { return ([], Array(b.dropFirst(2))) }
        let crlf = b.find([13, 10, 13, 10])
        let lf = b.find([10, 10])
        switch (crlf, lf) {
        case let (c?, l?):
            return c <= l ? (Array(b[..<c]), Array(b[(c + 4)...])) : (Array(b[..<l]), Array(b[(l + 2)...]))
        case let (c?, nil):
            return (Array(b[..<c]), Array(b[(c + 4)...]))
        case let (nil, l?):
            return (Array(b[..<l]), Array(b[(l + 2)...]))
        default:
            return (b, [])
        }
    }

    static func splitMultipart(_ b: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array(("--" + boundary).utf8)
        var marks: [(index: Int, closing: Bool)] = []
        var i = 0
        while let j = b.find(delimiter, from: i) {
            if j == 0 || b[j - 1] == 10 {
                let after = j + delimiter.count
                let closing = after + 1 < b.count && b[after] == 45 && b[after + 1] == 45
                marks.append((index: j, closing: closing))
                if closing { break }
            }
            i = j + delimiter.count
        }

        var parts: [[UInt8]] = []
        for (k, mark) in marks.enumerated() where !mark.closing {
            var begin = mark.index + delimiter.count
            while begin < b.count && b[begin] != 10 { begin += 1 }
            begin += 1
            var end = k + 1 < marks.count ? marks[k + 1].index : b.count
            if k + 1 < marks.count {
                if end > 0 && b[end - 1] == 10 { end -= 1 }
                if end > 0 && b[end - 1] == 13 { end -= 1 }
            }
            parts.append(begin < end ? Array(b[begin..<end]) : [])
        }
        return parts
    }

    /// Splits `type/subtype; key=value; ...`, including RFC 2231 encoded and continued parameters.
    static func parseParams(_ value: String) -> (main: String, params: [String: String]) {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in value {
            if ch == "\"" && !escaped {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == ";" && !inQuotes {
                pieces.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            escaped = (ch == "\\") && !escaped
        }
        pieces.append(current)

        let main = (pieces.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var raw: [(key: String, value: String)] = []
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2 && v.hasPrefix("\"") && v.hasSuffix("\"") {
                v = String(v.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            raw.append((key: key, value: v))
        }

        var params: [String: String] = [:]
        // Plain parameters first...
        for item in raw where !item.key.contains("*") {
            params[item.key] = decodeHeader(item.value)
        }
        // ...then RFC 2231 forms, which take precedence.
        var continued: [String: [(n: Int, value: String, encoded: Bool)]] = [:]
        for item in raw where item.key.contains("*") {
            guard let star = item.key.firstIndex(of: "*") else { continue }
            let base = String(item.key[..<star])
            let rest = item.key[item.key.index(after: star)...]
            if rest.isEmpty {
                params[base] = decodeRFC2231(item.value)
                continue
            }
            let encoded = rest.hasSuffix("*")
            let numberText = encoded ? String(rest.dropLast()) : String(rest)
            if let n = Int(numberText) {
                continued[base, default: []].append((n: n, value: item.value, encoded: encoded))
            }
        }
        for (base, segments) in continued {
            let sorted = segments.sorted { $0.n < $1.n }
            var charset: String?
            var bytes: [UInt8] = []
            for (index, seg) in sorted.enumerated() {
                var value = seg.value
                if seg.encoded {
                    if index == 0 {
                        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if parts.count == 3 {
                            charset = String(parts[0])
                            value = String(parts[2])
                        }
                    }
                    bytes += percentDecode(value)
                } else {
                    bytes += Array(value.utf8)
                }
            }
            params[base] = decodeText(bytes, charset: charset ?? "utf-8")
        }
        return (main, params)
    }

    static func decodeRFC2231(_ value: String) -> String {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3 {
            return decodeText(percentDecode(String(parts[2])), charset: String(parts[0]))
        }
        return decodeText(percentDecode(value), charset: "utf-8")
    }

    static func percentDecode(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < u.count {
            if u[i] == 37, i + 2 < u.count, let h = hex(u[i + 1]), let l = hex(u[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return out
    }

    static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    // MARK: Text and charsets

    static func encoding(forCharset name: String?) -> String.Encoding? {
        guard var n = name?.trimmingCharacters(in: .whitespaces).lowercased(), !n.isEmpty else { return nil }
        if let star = n.firstIndex(of: "*") { n = String(n[..<star]) }
        if n == "utf8" { n = "utf-8" }
        if n == "us-ascii" || n == "ascii" { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
        if cf == kCFStringEncodingInvalidId { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func decodeText(_ bytes: [UInt8], charset: String?) -> String {
        if let enc = encoding(forCharset: charset), let s = String(bytes: bytes, encoding: enc) { return s }
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        if let s = String(bytes: bytes, encoding: .windowsCP1252) { return s }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func decodeQuotedPrintable(_ b: [UInt8], header: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == 61 {
                if i + 1 < b.count && b[i + 1] == 10 { i += 2; continue }
                if i + 2 < b.count && b[i + 1] == 13 && b[i + 2] == 10 { i += 3; continue }
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                out.append(c)
                i += 1
            } else if header && c == 95 {
                out.append(32)
                i += 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Tolerant base64 decoder: skips line breaks and junk and copes with truncated input.
    static func decodeBase64(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count * 3 / 4)
        var acc: UInt32 = 0
        var bits = 0
        for c in b {
            let v: UInt32
            switch c {
            case 65...90: v = UInt32(c - 65)
            case 97...122: v = UInt32(c - 71)
            case 48...57: v = UInt32(c + 4)
            case 43, 45: v = 62
            case 47, 95: v = 63
            default: continue
            }
            acc = ((acc << 6) | v) & 0xFFFFFF
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    /// Decodes RFC 2047 encoded words ("=?utf-8?B?...?=") in a header value.
    static func decodeHeader(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        guard let re = try? NSRegularExpression(pattern: #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        var pendingBytes: [UInt8] = []
        var pendingCharset: String?

        func flush() {
            if !pendingBytes.isEmpty || pendingCharset != nil {
                result += decodeText(pendingBytes, charset: pendingCharset)
            }
            pendingBytes = []
            pendingCharset = nil
        }

        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let charset = ns.substring(with: m.range(at: 1))
            let kind = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = Array(ns.substring(with: m.range(at: 3)).utf8)
            let bytes = kind == "B" ? decodeBase64(payload) : decodeQuotedPrintable(payload, header: true)

            let adjacent = pendingCharset != nil && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if adjacent && pendingCharset?.lowercased() == charset.lowercased() {
                pendingBytes += bytes
            } else {
                flush()
                if !adjacent { result += between }
                pendingBytes = bytes
                pendingCharset = charset
            }
            last = m.range.location + m.range.length
        }
        flush()
        result += ns.substring(from: last)
        return result
    }

    /// The other direction: "Køb" becomes "K&APg-b".
    static func encodeModifiedUTF7(_ s: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let bytes = pending.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] }
            let b64 = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "/", with: ",")
            out += "&" + b64 + "-"
            pending = []
        }
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7e {
                flush()
                out += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: String(scalar).utf16)
            }
        }
        flush()
        return out
    }

    /// Mailbox names on the server use "modified UTF-7" for non-ASCII characters.
    static func decodeModifiedUTF7(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "&", let dash = s[i...].firstIndex(of: "-") else {
                out.append(c)
                i = s.index(after: i)
                continue
            }
            let encoded = s[s.index(after: i)..<dash]
            if encoded.isEmpty {
                out.append("&")
            } else {
                var b64 = encoded.replacingOccurrences(of: ",", with: "/")
                while b64.count % 4 != 0 { b64 += "=" }
                if let data = Data(base64Encoded: b64), let str = String(data: data, encoding: .utf16BigEndian) {
                    out += str
                } else {
                    out += String(s[i...dash])
                }
            }
            i = s.index(after: dash)
        }
        return out
    }

    // MARK: HTML to text and previews

    static func htmlToText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"(?is)<(style|script|head|title)[^>]*>.*?</\1\s*>"#, with: " ",
                                   options: .regularExpression)
        // A preview only fetches the first few KB, so a <style> block or a tag may never close.
        s = s.replacingOccurrences(of: #"(?is)<(style|script)[^>]*>.*$"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?s)<[^>]*$"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<!--.*?-->"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>|</p\s*>|</div\s*>|</tr\s*>|</h[1-6]\s*>|</li\s*>|</blockquote\s*>"#,
                                   with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: #"[ \t ]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var s = text
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                ("&#39;", "'"), ("&apos;", "'"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
                                ("&rdquo;", "”"), ("&ldquo;", "“"), ("&ndash;", "–"), ("&mdash;", "—"),
                                ("&hellip;", "…"), ("&zwnj;", ""), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        guard s.contains("&#"), let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let isHex = !ns.substring(with: m.range(at: 1)).isEmpty
            let digits = ns.substring(with: m.range(at: 2))
            if let n = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(n) {
                result.append(Character(scalar))
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// A short preview from the message's headers and the first few KB of its body.
    static func snippet(headers: [UInt8], partialBody: [UInt8]) -> String {
        var head = headers
        while let last = head.last, last == 10 || last == 13 { head.removeLast() }
        let parsed = ParsedMessage.parse(head + [13, 10, 13, 10] + partialBody)
        let full = parsed.text ?? parsed.html.map { htmlToText($0) } ?? ""
        let lines = full.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix(">")
        }
        let joined = lines.joined(separator: " ")
            // Some senders put stray CSS rules in the text itself: "body, td { margin: 0; }".
            .replacingOccurrences(of: #"[^{}]*\{([^{}]*:[^{}]*|\s*)\}"#, with: " ", options: .regularExpression)
            // Text-email decoration: rules of dashes, ** bullets, empty ( ) left by stripped links.
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[-=_*~#•]{3,}|(\*\s*){2,}|\(\s*\)|\[\s*\]"#, with: " ", options: .regularExpression)
            // Long tracking links say nothing in a two-line preview.
            .replacingOccurrences(of: #"\(?https?://\S+\)?"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(joined.prefix(220))
    }

    static func defaultFilename(for mimeType: String) -> String {
        switch mimeType {
        case "message/rfc822": return "Forwarded message.eml"
        case "text/calendar": return "invite.ics"
        default:
            if let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension { return "attachment.\(ext)" }
            return "attachment"
        }
    }
}

// MARK: - Dates

enum MailDate {
    private static let parsers: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss",
    ].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static let internalParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    static let outgoing: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private static let long: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func parse(_ value: String?) -> Date? {
        guard var s = value else { return nil }
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for parser in parsers {
            if let d = parser.date(from: s) { return d }
        }
        return nil
    }

    static func parseInternal(_ value: String?) -> Date? {
        guard let s = value?.trimmingCharacters(in: .whitespaces) else { return nil }
        return internalParser.date(from: s)
    }

    static func listString(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day,
           days > 0, days < 7 {
            return weekday.string(from: d)
        }
        return shortDate.string(from: d)
    }

    static func longString(_ d: Date) -> String { long.string(from: d) }
}

// MARK: - Building outgoing messages

struct OutgoingAttachment: Identifiable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
    /// Set for photos inside the message text (the HTML refers to them as "cid:…").
    var contentID: String? = nil
}

enum MessageBuilder {
    static func newMessageID(for email: String) -> String {
        let domain = email.split(separator: "@").last.map { String($0) } ?? "localhost"
        return "<\(UUID().uuidString.lowercased())@\(domain)>"
    }

    /// Builds an RFC 5322 message. With `html`, the body is multipart/alternative (plain text + HTML).
    /// `bcc` is only written into the message for drafts, so it survives reopening.
    static func build(from: MailAddress, to: [MailAddress], cc: [MailAddress], bcc: [MailAddress] = [],
                      subject: String, text: String, html: String?, inlineImages: [OutgoingAttachment] = [],
                      attachments: [OutgoingAttachment],
                      inReplyTo: String?, references: [String], messageID: String) -> [UInt8] {
        var headers: [String] = []
        headers.append("From: " + format(from))
        if !to.isEmpty { headers.append("To: " + to.map(format).joined(separator: ",\r\n ")) }
        if !cc.isEmpty { headers.append("Cc: " + cc.map(format).joined(separator: ",\r\n ")) }
        if !bcc.isEmpty { headers.append("Bcc: " + bcc.map(format).joined(separator: ",\r\n ")) }
        headers.append("Subject: " + encodeWord(singleLine(subject)))
        headers.append("Date: " + MailDate.outgoing.string(from: Date()))
        headers.append("Message-ID: " + singleLine(messageID))
        if let r = inReplyTo, !r.isEmpty { headers.append("In-Reply-To: " + singleLine(r)) }
        if !references.isEmpty { headers.append("References: " + references.map(singleLine).joined(separator: "\r\n ")) }
        headers.append("MIME-Version: 1.0")

        let textEntity = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            + quotedPrintable(text)
        var bodyEntity = textEntity
        if let html = html {
            let alt = "=_OneMailAlt_" + UUID().uuidString
            bodyEntity = "Content-Type: multipart/alternative; boundary=\"\(alt)\"\r\n\r\n"
                + "--\(alt)\r\n" + textEntity + "\r\n"
                + "--\(alt)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
                + quotedPrintable(html) + "\r\n"
                + "--\(alt)--"
            // Photos in the text travel with the HTML in a multipart/related block.
            if !inlineImages.isEmpty {
                let rel = "=_OneMailRel_" + UUID().uuidString
                var related = "Content-Type: multipart/related; boundary=\"\(rel)\"; type=\"multipart/alternative\"\r\n\r\n"
                    + "--\(rel)\r\n" + bodyEntity + "\r\n"
                for image in inlineImages {
                    related += "--\(rel)\r\n"
                    related += "Content-Type: \(image.mimeType); name=\(parameterValue(image.filename))\r\n"
                    related += "Content-ID: <\(image.contentID ?? "")>\r\n"
                    related += "Content-Disposition: inline; \(filenameParameter(image.filename))\r\n"
                    related += "Content-Transfer-Encoding: base64\r\n\r\n"
                    related += image.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn,
                                                                        .endLineWithLineFeed])
                    related += "\r\n"
                }
                bodyEntity = related + "--\(rel)--"
            }
        }

        var out = headers.joined(separator: "\r\n") + "\r\n"

        if attachments.isEmpty {
            out += bodyEntity + "\r\n"
        } else {
            let boundary = "=_OneMail_" + UUID().uuidString
            out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            out += "This is a multi-part message in MIME format.\r\n"
            out += "--\(boundary)\r\n" + bodyEntity + "\r\n"
            for a in attachments {
                out += "--\(boundary)\r\n"
                out += "Content-Type: \(a.mimeType); name=\(parameterValue(a.filename))\r\n"
                out += "Content-Disposition: attachment; \(filenameParameter(a.filename))\r\n"
                out += "Content-Transfer-Encoding: base64\r\n\r\n"
                out += a.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn,
                                                            .endLineWithLineFeed])
                out += "\r\n"
            }
            out += "--\(boundary)--\r\n"
        }
        return Array(out.utf8)
    }

    static func singleLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func isPlainASCII(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
    }

    static func format(_ a: MailAddress) -> String {
        let name = singleLine(a.name).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return a.email }
        if isPlainASCII(name) {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(a.email)>"
        }
        return encodeWord(name) + " <\(a.email)>"
    }

    /// RFC 2047 encoding for non-ASCII header text, split into short encoded words.
    static func encodeWord(_ s: String) -> String {
        guard !isPlainASCII(s) else { return s }
        var words: [String] = []
        var chunk: [UInt8] = []
        for ch in s {
            let bytes = Array(String(ch).utf8)
            if chunk.count + bytes.count > 45 {
                words.append("=?UTF-8?B?" + Data(chunk).base64EncodedString() + "?=")
                chunk = []
            }
            chunk += bytes
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?" + Data(chunk).base64EncodedString() + "?=") }
        return words.joined(separator: "\r\n ")
    }

    static func parameterValue(_ filename: String) -> String {
        let clean = singleLine(filename)
        if isPlainASCII(clean) { return "\"" + clean.replacingOccurrences(of: "\"", with: "'") + "\"" }
        return "\"" + encodeWord(clean).replacingOccurrences(of: "\r\n ", with: " ") + "\""
    }

    static func filenameParameter(_ filename: String) -> String {
        let clean = singleLine(filename)
        if isPlainASCII(clean) { return "filename=\"" + clean.replacingOccurrences(of: "\"", with: "'") + "\"" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = clean.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
        return "filename*=UTF-8''" + encoded
    }

    static func quotedPrintable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out = ""
        for (index, line) in normalized.components(separatedBy: "\n").enumerated() {
            if index > 0 { out += "\r\n" }
            let bytes = Array(line.utf8)
            var current = ""
            var currentLength = 0
            for (j, b) in bytes.enumerated() {
                let isLast = j == bytes.count - 1
                let piece: String
                if (b >= 33 && b <= 126 && b != 61) || ((b == 32 || b == 9) && !isLast) {
                    piece = String(Character(Unicode.Scalar(b)))
                } else {
                    piece = String(format: "=%02X", b)
                }
                if currentLength + piece.count > 75 {
                    out += current + "=\r\n"
                    current = ""
                    currentLength = 0
                }
                current += piece
                currentLength += piece.count
            }
            out += current
        }
        return out
    }
}
