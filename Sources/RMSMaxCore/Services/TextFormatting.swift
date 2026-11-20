import Foundation

/// One formatted range of a message, as MAX sends it: `{type, from, length, entityId?, attributes:{url}}`.
/// `from` / `length` count UTF-16 code units (JavaScript string indices).
public struct TextElement: Codable, Sendable, Equatable {
    public var type: String       // STRONG EMPHASIZED UNDERLINE STRIKETHROUGH MONOSPACED CODE QUOTE HEADING LINK USER_MENTION
    public var from: Int
    public var length: Int
    public var url: String?
    public var entityId: Int64?

    public init(type: String, from: Int, length: Int, url: String? = nil, entityId: Int64? = nil) {
        self.type = type; self.from = from; self.length = length; self.url = url; self.entityId = entityId
    }

    init?(_ v: JSONValue) {
        guard let type = v["type"]?.stringValue else { return nil }
        self.init(type: type, from: Int(v["from"]?.int64Value ?? 0), length: Int(v["length"]?.int64Value ?? 0),
                  url: v["attributes"]?["url"]?.stringValue, entityId: v["entityId"]?.int64Value)
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["type": .string(type), "from": .int(Int64(from)), "length": .int(Int64(length))]
        if let url { o["attributes"] = .object(["url": .string(url)]) }
        if let entityId { o["entityId"] = .int(entityId) }
        return .object(o)
    }
}

public struct MentionCandidate: Sendable, Equatable {
    public let id: Int64
    public let name: String
    public init(id: Int64, name: String) { self.id = id; self.name = name }
}

/// Markdown-style input → plain text + formatting ranges.
/// `**жирный**`, `*курсив*` / `_курсив_`, `__подчёркнутый__`, `~~зачёркнутый~~`, `` `моно` ``, ```` ```код``` ````,
/// `[текст](https://…)`, `> цитата` и `# Заголовок` в начале строки, `@Имя` для выбранных упоминаний.
/// Unmatched markers stay as typed.
public enum TextFormatter {
    public static func parse(_ input: String, mentions: [MentionCandidate] = []) -> (text: String, elements: [TextElement]) {
        var out = ""
        var elements: [TextElement] = []
        var outLen: Int { out.utf16.count }
        let chars = Array(input)
        var i = 0
        var lineStart = true

        func isWordChar(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }

        /// Index of `marker` after `from` on the same line, with a non-empty content in between.
        func closing(_ marker: [Character], from: Int, multiline: Bool = false) -> Int? {
            var j = from
            while j + marker.count <= chars.count {
                if !multiline && chars[j] == "\n" { return nil }
                if Array(chars[j..<j + marker.count]) == marker && j > from { return j }
                j += 1
            }
            return nil
        }

        func emit(_ type: String, _ content: String, url: String? = nil) {
            let start = outLen
            out += content
            elements.append(TextElement(type: type, from: start, length: content.utf16.count, url: url))
        }

        while i < chars.count {
            let c = chars[i]
            // line-level markers
            if lineStart {
                if c == ">" && i + 1 < chars.count && chars[i + 1] == " " {
                    let end = chars[i...].firstIndex(of: "\n") ?? chars.count
                    let content = String(chars[(i + 2)..<end])
                    if !content.isEmpty { emit("QUOTE", content); i = end; lineStart = false; continue }
                }
                if c == "#" && i + 1 < chars.count && chars[i + 1] == " " {
                    let end = chars[i...].firstIndex(of: "\n") ?? chars.count
                    let content = String(chars[(i + 2)..<end])
                    if !content.isEmpty { emit("HEADING", content); i = end; lineStart = false; continue }
                }
            }
            lineStart = (c == "\n")

            func take(_ marker: String, _ type: String, multiline: Bool = false) -> Bool {
                let m = Array(marker)
                guard i + m.count <= chars.count, Array(chars[i..<i + m.count]) == m,
                      let end = closing(m, from: i + m.count, multiline: multiline) else { return false }
                let content = String(chars[(i + m.count)..<end])
                guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                emit(type, content)
                i = end + m.count
                return true
            }

            if take("```", "CODE", multiline: true) { continue }
            if take("**", "STRONG") { continue }
            if take("__", "UNDERLINE") { continue }
            if take("~~", "STRIKETHROUGH") { continue }
            if take("`", "MONOSPACED") { continue }
            if (c == "*" || c == "_"), !isWordChar(i > 0 ? chars[i - 1] : nil),
               let end = closing([c], from: i + 1), !isWordChar(end + 1 < chars.count ? chars[end + 1] : nil),
               chars[i + 1] != " ", chars[end - 1] != " " {
                emit("EMPHASIZED", String(chars[(i + 1)..<end]))
                i = end + 1
                continue
            }
            if c == "[", let close = closing(["]"], from: i + 1), close + 1 < chars.count, chars[close + 1] == "(",
               let paren = closing([")"], from: close + 2) {
                let label = String(chars[(i + 1)..<close])
                let url = String(chars[(close + 2)..<paren])
                if !label.isEmpty, URL(string: url)?.scheme?.hasPrefix("http") == true {
                    emit("LINK", label, url: url)
                    i = paren + 1
                    continue
                }
            }
            if c == "@", !isWordChar(i > 0 ? chars[i - 1] : nil) {
                // longest matching candidate name first
                let rest = String(chars[(i + 1)...])
                if let m = mentions.sorted(by: { $0.name.count > $1.name.count }).first(where: { rest.hasPrefix($0.name) }) {
                    let start = outLen
                    out += "@" + m.name
                    elements.append(TextElement(type: "USER_MENTION", from: start, length: (m.name.utf16.count) + 1, entityId: m.id))
                    i += 1 + m.name.count
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return (out, elements)
    }
}

/// Elements → styled text for display.
public enum FormattedText {
    public static func attributed(_ text: String, elements: [TextElement]) -> AttributedString {
        var result = AttributedString(text)
        let u16 = Array(text.utf16)
        for e in elements where e.length > 0 && e.from >= 0 && e.from + e.length <= u16.count {
            let lo = String.Index(utf16Offset: e.from, in: text)
            let hi = String.Index(utf16Offset: e.from + e.length, in: text)
            guard let a = AttributedString.Index(lo, within: result), let b = AttributedString.Index(hi, within: result), a < b else { continue }
            switch e.type {
            case "STRONG", "HEADING": result[a..<b].inlinePresentationIntent = .stronglyEmphasized
            case "EMPHASIZED", "QUOTE": result[a..<b].inlinePresentationIntent = .emphasized
            case "MONOSPACED", "CODE": result[a..<b].inlinePresentationIntent = .code
            case "UNDERLINE": result[a..<b].underlineStyle = .single
            case "STRIKETHROUGH": result[a..<b].strikethroughStyle = .single
            case "LINK": if let u = e.url.flatMap(URL.init(string:)) { result[a..<b].link = u }
            case "USER_MENTION":
                // a link with a private scheme: drawn in the accent colour, a tap opens the profile (handled by the view)
                if let id = e.entityId, let u = URL(string: "rmsmaks-user://\(id)") { result[a..<b].link = u }
            default: break
            }
        }
        return result
    }
}
