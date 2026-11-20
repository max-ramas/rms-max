import Foundation

/// Formats the composer can apply to a selection (each maps to a MAX text element type).
public enum RichFormat: String, CaseIterable, Sendable {
    case strong = "STRONG", emphasized = "EMPHASIZED", underline = "UNDERLINE"
    case strikethrough = "STRIKETHROUGH", monospaced = "MONOSPACED", quote = "QUOTE"

    public var key: NSAttributedString.Key { NSAttributedString.Key("rms.fmt." + rawValue) }
    public var title: String {
        switch self {
        case .strong: return "Жирный"
        case .emphasized: return "Курсив"
        case .underline: return "Подчёркнутый"
        case .strikethrough: return "Зачёркнутый"
        case .monospaced: return "Моноширинный"
        case .quote: return "Цитата"
        }
    }
}

/// Link and mention carry a value, so they have their own keys.
public enum RichKeys {
    public static let link = NSAttributedString.Key("rms.fmt.LINK")          // String url
    public static let mention = NSAttributedString.Key("rms.fmt.USER_MENTION") // NSNumber entityId
}

/// Composer content ⇄ MAX elements. Ranges are UTF-16 (NSString), exactly what the server expects.
public enum RichText {
    /// Plain text + custom attributes only (the view layer adds fonts and colours).
    public static func attributed(_ text: String, elements: [TextElement]) -> NSMutableAttributedString {
        let s = NSMutableAttributedString(string: text)
        let len = (text as NSString).length
        for e in elements where e.length > 0 && e.from >= 0 && e.from + e.length <= len {
            let r = NSRange(location: e.from, length: e.length)
            if let f = RichFormat(rawValue: e.type) { s.addAttribute(f.key, value: true, range: r) }
            else if e.type == "CODE" { s.addAttribute(RichFormat.monospaced.key, value: true, range: r) }
            else if e.type == "HEADING" { s.addAttribute(RichFormat.strong.key, value: true, range: r) }
            else if e.type == "LINK", let u = e.url { s.addAttribute(RichKeys.link, value: u, range: r) }
            else if e.type == "USER_MENTION", let id = e.entityId { s.addAttribute(RichKeys.mention, value: NSNumber(value: id), range: r) }
        }
        return s
    }

    /// Touching ranges that carry the same value become one element.
    public static func elements(from s: NSAttributedString) -> [TextElement] {
        let full = NSRange(location: 0, length: s.length)
        guard full.length > 0 else { return [] }
        var out: [TextElement] = []
        func collect(_ key: NSAttributedString.Key, make: (Any, NSRange) -> TextElement?) {
            var pending: (value: AnyHashable, range: NSRange, el: TextElement)?
            s.enumerateAttribute(key, in: full, options: []) { v, r, _ in
                guard let v, let el = make(v, r) else {
                    if let p = pending { out.append(p.el); pending = nil }
                    return
                }
                let h = AnyHashable(String(describing: v))
                if var p = pending, p.value == h, NSMaxRange(p.range) == r.location {
                    p.range.length += r.length; p.el.length = p.range.length; pending = p
                } else {
                    if let p = pending { out.append(p.el) }
                    pending = (h, r, el)
                }
            }
            if let p = pending { out.append(p.el) }
        }
        for f in RichFormat.allCases {
            collect(f.key) { _, r in TextElement(type: f.rawValue, from: r.location, length: r.length) }
        }
        collect(RichKeys.link) { v, r in (v as? String).map { TextElement(type: "LINK", from: r.location, length: r.length, url: $0) } }
        collect(RichKeys.mention) { v, r in (v as? NSNumber).map { TextElement(type: "USER_MENTION", from: r.location, length: r.length, entityId: $0.int64Value) } }
        return out.sorted { ($0.from, $0.type) < ($1.from, $1.type) }
    }

    /// Elements for explicitly formatted text after the outer whitespace was trimmed.
    public static func shifted(_ elements: [TextElement], original: String, trimmed: String) -> [TextElement] {
        let o = original as NSString
        let lead = trimmed.isEmpty ? 0 : o.range(of: trimmed).location
        guard lead != NSNotFound else { return [] }
        let total = (trimmed as NSString).length
        return elements.compactMap { e in
            var e = e
            e.from -= lead
            if e.from < 0 { e.length += e.from; e.from = 0 }
            if e.from + e.length > total { e.length = total - e.from }
            return e.length > 0 ? e : nil
        }
    }

    /// `@Name` typed for a chat member becomes a mention unless that range is already styled as one.
    public static func mentionElements(in text: String, candidates: [MentionCandidate], existing: [TextElement]) -> [TextElement] {
        let ns = text as NSString
        var out: [TextElement] = []
        for c in candidates.sorted(by: { $0.name.count > $1.name.count }) {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: "@" + c.name, options: [], range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                from = r.location + r.length
                let overlaps = (existing + out).contains { $0.type == "USER_MENTION" && NSIntersectionRange(NSRange(location: $0.from, length: $0.length), r).length > 0 }
                if !overlaps { out.append(TextElement(type: "USER_MENTION", from: r.location, length: r.length, entityId: c.id)) }
            }
        }
        return out
    }
}

extension AppStore {
    /// Formatting chosen in the editor wins; plain text typed with Markdown markers still works as a fallback.
    func formatOutgoing(_ trimmed: String, original: String, rich: [TextElement], chatId: Int64) -> (text: String, elements: [TextElement]) {
        let candidates = mentionCandidates(chatId: chatId)
        guard !rich.isEmpty else { return TextFormatter.parse(trimmed, mentions: candidates) }
        let shifted = RichText.shifted(rich.filter { $0.type != "ANIMOJI" }, original: original, trimmed: trimmed)
        return (trimmed, shifted + RichText.mentionElements(in: trimmed, candidates: candidates, existing: shifted))
    }
}
