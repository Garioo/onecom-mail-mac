// Run: bash checks/run.sh — asserts thread grouping, unsubscribe links, codes, attachment parts and Send Later headers.
import Foundation

/// The real one lives in MailViews.swift, which needs the whole app.
enum MailHTML { static func plainToHTML(_ s: String) -> String { s } }
struct MailAccount { var email = "", name = "", imapHost = "", smtpHost = ""; var imapPort = 0, smtpPort = 0 }

func msg(_ uid: UInt32, id: String, refs: [String] = []) -> MessageSummary {
    MessageSummary(folder: "INBOX", uid: uid, from: nil, to: [], cc: [], replyTo: [], subject: "s",
                   date: Date(timeIntervalSince1970: Double(uid)), snippet: "", seen: true, flagged: false,
                   answered: false, hasAttachments: false, messageID: id, references: refs)
}

@main
struct ThreadsCheck {
    static func main() {
        // Newest first: 5 replies to 2 (which replies to 1); 4 and 3 stand alone; 6 references a message we don't have.
        let list = [msg(6, id: "<f>", refs: ["<gone>"]), msg(5, id: "<e>", refs: ["<a>", "<b>"]),
                    msg(4, id: "<d>"), msg(3, id: "<c>"), msg(2, id: "<b>", refs: ["<a>"]), msg(1, id: "<a>")]
        let groups = Threads.group(list).map { $0.map { $0.uid } }
        assert(groups == [[6], [5, 2, 1], [4], [3]], "\(groups)")

        let both = Unsubscribe(header: "<mailto:leave@list.example?subject=stop>, <https://list.example/u?x=1>",
                               post: "List-Unsubscribe=One-Click")!
        assert(both.oneClick && both.mailto != nil && both.web?.host == "list.example" && both.isAutomatic)
        let webOnly = Unsubscribe(header: "<http://list.example/u>", post: nil)!
        assert(!webOnly.oneClick && !webOnly.isAutomatic)
        let notHTTPS = Unsubscribe(header: "<http://list.example/u>", post: "List-Unsubscribe=One-Click")!
        assert(!notHTTPS.oneClick, "one-click needs https")
        assert(Unsubscribe(header: "nonsense", post: nil) == nil)
        assert(Unsubscribe(header: nil, post: nil) == nil)
        // One-time codes
        assert(SmartMail.code(in: "Your verification code is 482 913") == "482913")
        assert(SmartMail.code(in: "Din engangskode: 7731") == "7731")
        assert(SmartMail.code(in: "G-552019 is your Google verification code") == "552019")
        assert(SmartMail.code(in: "Order 1234 confirmed") == nil, "no code word")
        assert(SmartMail.code(in: "Sign-in alert © 2026") == nil, "a year isn't a code")
        assert(SmartMail.code(in: "Rabatkode: spar 1299 kr") == nil, "a price isn't a code")

        // BODYSTRUCTURE: multipart/mixed with a text/alternative pair, a PDF and an inline logo.
        var parser = IMAPParser(bytes: Array("""
        (("TEXT" "PLAIN" ("CHARSET" "utf-8") NIL NIL "7BIT" 120 4 NIL NIL NIL)("TEXT" "HTML" ("CHARSET" "utf-8") NIL NIL "7BIT" 900 20 NIL NIL NIL) "ALTERNATIVE")("APPLICATION" "PDF" ("NAME" "Faktura.pdf") NIL NIL "BASE64" 40000 NIL ("ATTACHMENT" ("FILENAME" "Faktura.pdf")) NIL)("IMAGE" "PNG" ("NAME" "logo.png") NIL NIL "BASE64" 3000 NIL ("INLINE" ("FILENAME" "logo.png")) NIL) "MIXED"
        """.utf8))
        let structure = parser.parseAll()
        let parts = AttachmentInfo.parts(of: structure)
        assert(parts.count == 1 && parts[0].part == "2" && parts[0].filename == "Faktura.pdf"
               && parts[0].mimeType == "application/pdf" && parts[0].encoding == "base64", "\(parts)")
        var single = IMAPParser(bytes: Array(#"("IMAGE" "JPEG" ("NAME" "IMG_1.jpg") NIL NIL "BASE64" 90000 NIL NIL NIL)"#.utf8))
        let one = AttachmentInfo.parts(of: single.parseAll()[0].list ?? [])
        assert(one.count == 1 && one[0].part == "1", "\(one)")

        // Send Later: Bcc leaves the headers but stays a recipient; Date is renewed.
        let draft = Array("From: me@x.dk\r\nTo: Anna <anna@y.dk>\r\nBcc: boss@z.dk,\r\n secret@z.dk\r\nDate: Mon, 1 Jan 2024 10:00:00 +0000\r\nSubject: Hi\r\n\r\nBody".utf8)
        let ready = SmartMail.prepareScheduled(draft, now: Date(timeIntervalSince1970: 0))
        let text = String(decoding: ready.message, as: UTF8.self)
        assert(!text.lowercased().contains("bcc") && !text.contains("secret") && !text.contains("2024"), text)
        assert(text.contains("Subject: Hi\r\n\r\nBody") && text.contains("Date: Thu, 01 Jan 1970"), text)
        assert(ready.recipients == ["anna@y.dk", "boss@z.dk", "secret@z.dk"], "\(ready.recipients)")
        print("ok")
    }
}
