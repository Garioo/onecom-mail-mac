// Rich-text composing: the editor (an NSTextView), its formatting commands, and conversion of the
// formatted text to email HTML / plain text (and back, for editing saved drafts).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum RichText {
    static let baseFont = NSFont.systemFont(ofSize: 14)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.textColor]
    }

    /// Quoted text in replies: grey and indented (becomes a <blockquote> in the sent email).
    static var quoteAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 14
        paragraph.firstLineHeadIndent = 14
        return [.font: baseFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
    }

    static func plain(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: baseAttributes)
    }

    static func quoted(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: quoteAttributes)
    }

    // MARK: Export

    private static func paragraphs(of s: NSAttributedString) -> [NSRange] {
        let ns = s.string as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < ns.length {
            var end = 0
            var contentsEnd = 0
            ns.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            ranges.append(NSRange(location: location, length: contentsEnd - location))
            if end <= location { break }
            location = end
        }
        return ranges
    }

    private static func isQuote(_ s: NSAttributedString, _ range: NSRange) -> Bool {
        guard range.location < s.length else { return false }
        let style = s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        return (style?.headIndent ?? 0) > 0
    }

    static func plainText(_ s: NSAttributedString) -> String {
        let ns = s.string as NSString
        var lines: [String] = []
        for range in paragraphs(of: s) {
            var line = ""
            if range.length > 0 {
                s.enumerateAttributes(in: range) { attrs, sub, _ in
                    let piece = ns.substring(with: sub).replacingOccurrences(of: "\u{FFFC}", with: "")
                    line += piece
                    if let href = linkString(attrs[.link]), href != piece, !href.hasPrefix("mailto:") {
                        line += " <\(href)>"
                    }
                }
            }
            lines.append(isQuote(s, range) ? "> " + line : line)
        }
        return lines.joined(separator: "\n")
    }

    /// The message as email HTML, plus the photos in it. Each photo is sent as an inline part that
    /// the HTML points to with "cid:", so it shows inside the text in the recipient's mail.
    static func html(_ s: NSAttributedString) -> (html: String, images: [OutgoingAttachment]) {
        let ns = s.string as NSString
        let token = UUID().uuidString.prefix(8).lowercased()
        var images: [OutgoingAttachment] = []
        var out = "<div style=\"font-family:-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif;font-size:14px;line-height:1.4\">"
        var inQuote = false
        for range in paragraphs(of: s) {
            let quote = isQuote(s, range)
            if quote && !inQuote {
                out += "<blockquote style=\"margin:0 0 0 0.8ex;border-left:2px solid #ccc;padding-left:1ex;color:#6e6e73\">"
                inQuote = true
            } else if !quote && inQuote {
                out += "</blockquote>"
                inQuote = false
            }
            var content = ""
            if range.length > 0 {
                s.enumerateAttributes(in: range) { attrs, sub, _ in
                    if let attachment = attrs[.attachment] as? NSTextAttachment {
                        guard let image = emailImage(attachment) else { return }
                        let n = images.count + 1
                        let cid = "image\(n).\(token)@onecom-mail"
                        images.append(OutgoingAttachment(filename: "image\(n).\(image.ext)", mimeType: image.mimeType,
                                                         data: image.data, contentID: cid))
                        content += "<img src=\"cid:\(cid)\" alt=\"\" style=\"max-width:100%;height:auto\">"
                        return
                    }
                    content += htmlRun(ns.substring(with: sub), attrs)
                }
            }
            out += "<div>" + (content.isEmpty ? "<br>" : content) + "</div>"
        }
        if inQuote { out += "</blockquote>" }
        out += "</div>"
        return ("<!doctype html><html><head><meta charset=\"utf-8\"></head><body>" + out + "</body></html>", images)
    }

    // MARK: Photos in the message

    /// The bytes to send for a photo: JPEG, PNG and GIF go as they are when reasonably sized;
    /// anything bigger or in another format (HEIC, TIFF from a paste) becomes a JPEG of at most
    /// 2048 pixels on the long side, so emails stay a sensible size.
    static func emailImage(_ attachment: NSTextAttachment) -> (data: Data, mimeType: String, ext: String)? {
        let raw = attachment.fileWrapper?.regularFileContents ?? attachment.contents
        if let raw = raw, let kind = imageKind(raw), raw.count <= 3_000_000,
           let rep = NSBitmapImageRep(data: raw), max(rep.pixelsWide, rep.pixelsHigh) <= 2560 {
            return (raw, kind.mimeType, kind.ext)
        }
        guard let image = raw.flatMap(NSImage.init(data:)) ?? attachment.image
                ?? (attachment.attachmentCell as? NSTextAttachmentCell)?.image else { return nil }
        let pixels = pixelSize(image)
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let scale = min(1, 2048 / max(pixels.width, pixels.height))
        let w = Int((pixels.width * scale).rounded()), h = Int((pixels.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()   // JPEG has no transparency
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        return (jpeg, "image/jpeg", "jpg")
    }

    private static func imageKind(_ d: Data) -> (mimeType: String, ext: String)? {
        let b = [UInt8](d.prefix(4))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return ("image/jpeg", "jpg") }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
        if b.starts(with: [0x47, 0x49, 0x46]) { return ("image/gif", "gif") }
        return nil
    }

    private static func pixelSize(_ image: NSImage) -> CGSize {
        let reps = image.representations
        if let best = reps.max(by: { $0.pixelsWide < $1.pixelsWide }), best.pixelsWide > 0 {
            return CGSize(width: best.pixelsWide, height: best.pixelsHigh)
        }
        return image.size
    }

    /// Photos show in the editor at most this wide (the full photo is still what gets sent).
    static let maxDisplayWidth: CGFloat = 420

    static func fitForDisplay(_ attachment: NSTextAttachment) {
        guard let image = (attachment.attachmentCell as? NSTextAttachmentCell)?.image ?? attachment.image
                ?? (attachment.fileWrapper?.regularFileContents).flatMap(NSImage.init(data:)),
              image.size.width > maxDisplayWidth else { return }
        let small = image.copy() as! NSImage
        small.size = NSSize(width: maxDisplayWidth, height: image.size.height * maxDisplayWidth / image.size.width)
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: small)
    }

    private static func htmlRun(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> String {
        var t = escape(text)
            .replacingOccurrences(of: "  ", with: " &nbsp;")
            .replacingOccurrences(of: "\t", with: "&nbsp;&nbsp;&nbsp;&nbsp;")
            .replacingOccurrences(of: "\u{2028}", with: "<br>")

        var styles: [String] = []
        var bold = false
        var italic = false
        if let font = attrs[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            bold = traits.contains(.boldFontMask)
            italic = traits.contains(.italicFontMask)
            if abs(font.pointSize - baseFont.pointSize) > 0.5 {
                styles.append("font-size:\(Int(font.pointSize.rounded()))px")
            }
            if let family = font.familyName, !family.hasPrefix("."), family != baseFont.familyName {
                let clean = family.replacingOccurrences(of: "'", with: "")
                styles.append("font-family:'\(clean)',sans-serif")
            }
        }
        if let color = attrs[.foregroundColor] as? NSColor, let hex = cssColor(color) {
            styles.append("color:\(hex)")
        }
        if let background = attrs[.backgroundColor] as? NSColor, let hex = cssColor(background) {
            styles.append("background-color:\(hex)")
        }
        if !styles.isEmpty { t = "<span style=\"\(styles.joined(separator: ";"))\">\(t)</span>" }
        if bold { t = "<b>\(t)</b>" }
        if italic { t = "<i>\(t)</i>" }
        if let u = attrs[.underlineStyle] as? Int, u != 0 { t = "<u>\(t)</u>" }
        if let st = attrs[.strikethroughStyle] as? Int, st != 0 { t = "<s>\(t)</s>" }
        if let href = linkString(attrs[.link]) { t = "<a href=\"\(escape(href))\">\(t)</a>" }
        return t
    }

    private static func linkString(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        if let s = value as? String, !s.isEmpty { return s }
        return nil
    }

    /// CSS colour for an explicit text colour; nil for the default text colour (so dark mode isn't baked in).
    private static func cssColor(_ color: NSColor) -> String? {
        if color.type == .catalog {
            let name: String = color.colorNameComponent
            if ["textColor", "labelColor", "controlTextColor", "textBackgroundColor"].contains(name) { return nil }
            if name == "secondaryLabelColor" { return "#6e6e73" }
        }
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Import (for editing saved drafts and forwarding formatted mail)

    static func fromHTML(_ html: String) -> NSAttributedString {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let data = html.data(using: .utf8),
              let imported = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil)
        else {
            return plain(MIME.htmlToText(html))
        }
        let full = NSRange(location: 0, length: imported.length)
        let fm = NSFontManager.shared

        // Use the system font throughout, keeping size, bold and italic.
        imported.enumerateAttribute(.font, in: full) { value, range, _ in
            let old = value as? NSFont ?? baseFont
            let traits = fm.traits(of: old)
            var font = NSFont.systemFont(ofSize: old.pointSize > 0 ? old.pointSize : baseFont.pointSize)
            if traits.contains(.boldFontMask) { font = fm.convert(font, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { font = fm.convert(font, toHaveTrait: .italicFontMask) }
            imported.addAttribute(.font, value: font, range: range)
        }
        // Plain black text becomes the adaptive text colour so it reads in dark mode.
        imported.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = value as? NSColor else {
                imported.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
                return
            }
            if let rgb = color.usingColorSpace(.sRGB),
               rgb.redComponent < 0.08, rgb.greenComponent < 0.08, rgb.blueComponent < 0.08 {
                imported.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
            }
        }
        // Drop the trailing line break the importer adds.
        while imported.length > 0, imported.string.hasSuffix("\n") {
            imported.deleteCharacters(in: NSRange(location: imported.length - 1, length: 1))
        }
        return imported
    }
}

// MARK: - Editor controller

@MainActor
final class RichTextController: NSObject, ObservableObject, NSTextViewDelegate, NSTextStorageDelegate {
    weak var textView: NSTextView?
    let initial: NSAttributedString
    var onChange: (() -> Void)?
    /// Files that aren't photos, dropped on the text: they become ordinary attachments.
    var onFiles: (([URL]) -> Void)?

    /// Scales photos down to fit the editor however they arrive (dropped, pasted or from a draft).
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        textStorage.enumerateAttribute(.attachment, in: editedRange) { value, _, _ in
            if let attachment = value as? NSTextAttachment { RichText.fitForDisplay(attachment) }
        }
    }

    init(initial: NSAttributedString) {
        self.initial = initial
        super.init()
    }

    var attributedText: NSAttributedString {
        guard let tv = textView else { return initial }
        return NSAttributedString(attributedString: tv.attributedString())
    }

    func textDidChange(_ notification: Notification) {
        onChange?()
    }

    private func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: Bold / italic

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView else { return }
        focus()
        let fm = NSFontManager.shared
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let font = attrs[.font] as? NSFont ?? RichText.baseFont
            let has = fm.traits(of: font).contains(trait)
            attrs[.font] = has ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
            tv.typingAttributes = attrs
            return
        }
        guard let storage = tv.textStorage, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        let first = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? RichText.baseFont
        let add = !fm.traits(of: first).contains(trait)
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = value as? NSFont ?? RichText.baseFont
            storage.addAttribute(.font, value: add ? fm.convert(font, toHaveTrait: trait) : fm.convert(font, toNotHaveTrait: trait),
                                 range: sub)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    // MARK: Underline / strikethrough

    func toggleUnderline() { toggleLine(.underlineStyle) }
    func toggleStrikethrough() { toggleLine(.strikethroughStyle) }

    private func toggleLine(_ key: NSAttributedString.Key) {
        guard let tv = textView else { return }
        focus()
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            if (attrs[key] as? Int ?? 0) != 0 {
                attrs.removeValue(forKey: key)
            } else {
                attrs[key] = NSUnderlineStyle.single.rawValue
            }
            tv.typingAttributes = attrs
            return
        }
        guard let storage = tv.textStorage, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        let isOn = (storage.attribute(key, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        storage.beginEditing()
        if isOn {
            storage.removeAttribute(key, range: range)
        } else {
            storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    // MARK: Size

    func bigger() { changeSize(by: 2) }
    func smaller() { changeSize(by: -2) }

    private func changeSize(by delta: CGFloat) {
        guard let tv = textView else { return }
        focus()
        let fm = NSFontManager.shared
        func resized(_ font: NSFont) -> NSFont {
            fm.convert(font, toSize: min(48, max(9, font.pointSize + delta)))
        }
        let range = tv.selectedRange()
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.font] = resized(attrs[.font] as? NSFont ?? RichText.baseFont)
            tv.typingAttributes = attrs
            return
        }
        guard let storage = tv.textStorage, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            storage.addAttribute(.font, value: resized(value as? NSFont ?? RichText.baseFont), range: sub)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    // MARK: Bullets

    func toggleBullets() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        focus()
        let ns = storage.string as NSString
        let selection = tv.selectedRange()
        let block = ns.paragraphRange(for: selection)

        var starts: [Int] = []
        var location = block.location
        while location < NSMaxRange(block) {
            starts.append(location)
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if NSMaxRange(paragraph) <= location { break }
            location = NSMaxRange(paragraph)
        }
        if starts.isEmpty { starts = [block.location] }

        let bullet = "• "
        func hasBullet(_ at: Int) -> Bool {
            at + 2 <= ns.length && ns.substring(with: NSRange(location: at, length: 2)) == bullet
        }
        let removing = starts.allSatisfy { hasBullet($0) }

        for start in starts.reversed() {
            if removing {
                let r = NSRange(location: start, length: 2)
                if tv.shouldChangeText(in: r, replacementString: "") {
                    storage.replaceCharacters(in: r, with: "")
                    tv.didChangeText()
                }
            } else if !hasBullet(start) {
                let attrs = start < storage.length ? storage.attributes(at: start, effectiveRange: nil) : tv.typingAttributes
                let r = NSRange(location: start, length: 0)
                if tv.shouldChangeText(in: r, replacementString: bullet) {
                    storage.replaceCharacters(in: r, with: NSAttributedString(string: bullet, attributes: attrs))
                    tv.didChangeText()
                }
            }
        }
    }

    // MARK: Links

    func insertLink() {
        guard let tv = textView, let window = tv.window else { return }
        let range = tv.selectedRange()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "https://example.com"
        if range.length > 0, let storage = tv.textStorage,
           let existing = storage.attribute(.link, at: range.location, effectiveRange: nil) {
            field.stringValue = (existing as? URL)?.absoluteString ?? (existing as? String) ?? ""
        }
        let alert = NSAlert()
        alert.messageText = range.length > 0 ? "Link the selected text" : "Insert a link"
        alert.informativeText = "Enter a web address or an email address."
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.applyLink(field.stringValue, range: range)
        }
    }

    private func applyLink(_ raw: String, range: NSRange) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let typed = raw.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        var address = typed
        if !address.contains("://") && !address.lowercased().hasPrefix("mailto:") {
            address = (address.contains("@") && !address.contains("/")) ? "mailto:" + address : "https://" + address
        }
        guard let url = URL(string: address) else { return }
        if range.length > 0 {
            guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.addAttribute(.link, value: url, range: range)
            tv.didChangeText()
        } else {
            var attrs = tv.typingAttributes
            attrs[.link] = url
            let text = NSAttributedString(string: typed, attributes: attrs)
            guard tv.shouldChangeText(in: range, replacementString: typed) else { return }
            storage.replaceCharacters(in: range, with: text)
            tv.didChangeText()
            var after = tv.typingAttributes
            after.removeValue(forKey: .link)
            tv.typingAttributes = after
        }
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: Panels

    func showFonts() {
        focus()
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    func showColors() {
        focus()
        NSApp.orderFrontColorPanel(nil)
    }
}

// MARK: - Editor view

struct RichTextEditor: NSViewRepresentable {
    let controller: RichTextController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let tv = ComposeTextView(frame: .zero)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.backgroundColor = .textBackgroundColor
        scroll.documentView = tv
        tv.onFiles = { [weak controller] urls in controller?.onFiles?(urls) }
        tv.isRichText = true
        tv.allowsUndo = true
        tv.importsGraphics = true
        tv.usesFontPanel = true
        tv.usesFindBar = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.textContainerInset = NSSize(width: 16, height: 14)
        tv.textStorage?.delegate = controller
        tv.textStorage?.setAttributedString(controller.initial)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.typingAttributes = RichText.baseAttributes
        tv.delegate = controller
        controller.textView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// The message editor. Photos dropped on it go into the text where you let go; other files
/// become attachments (an NSTextView would otherwise show them as icons inside the text).
final class ComposeTextView: NSTextView {
    var onFiles: (([URL]) -> Void)?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        let isPhoto = { (url: URL) in UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false }
        let others = urls.filter { !isPhoto($0) }
        if !others.isEmpty { onFiles?(others) }

        let photos = urls.filter(isPhoto).compactMap { try? FileWrapper(url: $0) }
        guard !photos.isEmpty else { return true }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        let inserted = NSMutableAttributedString()
        for photo in photos {
            inserted.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: photo)))
        }
        inserted.addAttributes(RichText.baseAttributes, range: NSRange(location: 0, length: inserted.length))
        window?.makeFirstResponder(self)
        insertText(inserted, replacementRange: NSRange(location: index, length: 0))
        return true
    }
}

struct FormatBar: View {
    let editor: RichTextController

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    var body: some View {
        HStack(spacing: 2) {
            button("bold", "Bold (⌘B)") { editor.toggleBold() }
            button("italic", "Italic (⌘I)") { editor.toggleItalic() }
            button("underline", "Underline (⌘U)") { editor.toggleUnderline() }
            button("strikethrough", "Strikethrough") { editor.toggleStrikethrough() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            button("textformat.size.smaller", "Smaller text") { editor.smaller() }
            button("textformat.size.larger", "Bigger text") { editor.bigger() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            button("list.bullet", "Bulleted list") { editor.toggleBullets() }
            button("link", "Add link (⌘K)") { editor.insertLink() }
            Divider().frame(height: 16).padding(.horizontal, 4)
            button("textformat", "Fonts (⌘T)") { editor.showFonts() }
            button("paintpalette", "Text colour (⇧⌘C)") { editor.showColors() }
            Spacer()
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}
