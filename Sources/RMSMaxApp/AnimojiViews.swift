import SwiftUI
import Lottie
import Compression
import RMSMaxCore

/// Lottie animation of an animoji. The emoji itself shows while the animation loads (or if it cannot be read),
/// so a text never loses its meaning. Lottie renders on this device; nothing is reported anywhere.
struct AnimojiView: View {
    let emoji: String
    let url: String?
    var size: CGFloat = 28
    @State private var animation: LottieAnimation?

    var body: some View {
        Group {
            if let animation {
                LottieView(animation: animation)
                    .playing(loopMode: .loop)
                    .configuration(LottieConfiguration(renderingEngine: .mainThread))
                    .frame(width: size, height: size)
            } else {
                Text(emoji).font(.system(size: size * 0.8)).frame(width: size, height: size)
            }
        }
        .task(id: url) {
            guard let url, let data = await MediaCache.remoteImage(url) else { return }
            animation = AnimojiDecoder.animation(from: data)
        }
    }
}

enum AnimojiDecoder {
    /// Lottie JSON, plain or gzipped (the .tgs flavour).
    static func animation(from data: Data) -> LottieAnimation? {
        if let a = try? LottieAnimation.from(data: data) { return a }
        if data.count > 18, data[0] == 0x1f, data[1] == 0x8b, let raw = inflate(data) { return try? LottieAnimation.from(data: raw) }
        return nil
    }

    private static func inflate(_ gz: Data) -> Data? {
        // gzip = 10-byte header (no optional fields assumed) + raw deflate + 8-byte trailer
        let body = gz.subdata(in: 10..<(gz.count - 8))
        let cap = 8 * 1024 * 1024
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n > 0 ? out.prefix(n) : nil
    }
}

/// «Анимодзи» tab of the emoji panel: packs on top, the chosen pack's animation below.
struct AnimojiPicker: View {
    @EnvironmentObject private var store: AppStore
    let onPick: (Animoji) -> Void
    @State private var selected: Int64?
    private let columns = Array(repeating: GridItem(.flexible(minimum: 40), spacing: 6), count: 6)

    private var pack: AnimojiSet? { store.animojiSets.first { $0.id == selected } ?? store.animojiSets.first }

    var body: some View {
        VStack(spacing: 8) {
            if store.animojiSets.isEmpty {
                Text("Анимодзи пока недоступны для этого аккаунта").font(.caption).foregroundStyle(.secondary).padding()
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(store.animojiSets) { s in
                            Button { selected = s.id } label: { Text(s.name).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(pack?.id == s.id ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1))) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach((pack?.animojiIds ?? []).compactMap { store.animojiCache[$0] }) { a in
                            Button { onPick(a) } label: { AnimojiView(emoji: a.emoji, url: a.animationURL, size: 44) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
        .task { if store.animojiSets.isEmpty { await store.loadAnimojiSets() } }
        .task(id: pack?.id) { if let p = pack { await store.ensureAnimoji(p.animojiIds) } }
    }
}

/// A message made only of animoji: big animated emoji in a row, like the official client.
struct AnimojiRow: View {
    @EnvironmentObject private var store: AppStore
    let text: String
    let elements: [TextElement]

    static func isPure(text: String, elements: [TextElement]) -> Bool {
        let a = elements.filter { $0.type == "ANIMOJI" }
        guard !a.isEmpty else { return false }
        let ns = text as NSString
        var rest = text
        for e in a.sorted(by: { $0.from > $1.from }) where e.from >= 0 && e.from + e.length <= ns.length {
            rest = (rest as NSString).replacingCharacters(in: NSRange(location: e.from, length: e.length), with: "")
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let ns = text as NSString
        HStack(spacing: 4) {
            ForEach(Array(elements.filter { $0.type == "ANIMOJI" && $0.from + $0.length <= ns.length }.sorted { $0.from < $1.from }.enumerated()), id: \.offset) { _, e in
                let known = e.entityId.flatMap { store.animojiCache[$0] }
                AnimojiView(emoji: ns.substring(with: NSRange(location: e.from, length: e.length)),
                            url: e.animojiLottieUrl ?? known?.animationURL, size: 56)
            }
        }
    }
}

/// Text with animoji in it: words and animated emoji flow on one line and wrap together, so the animation sits where
/// the emoji was typed. Formatting (bold, links, mentions) is kept inside each word.
struct AnimojiFlowText: View {
    @EnvironmentObject private var store: AppStore
    let text: String
    let elements: [TextElement]

    private enum Token: Identifiable {
        case word(AttributedString, Int)
        case animoji(String, String?, Int)
        case lineBreak(Int)
        var id: Int { switch self { case .word(_, let i), .animoji(_, _, let i), .lineBreak(let i): return i } }
    }

    private var tokens: [Token] {
        let ns = text as NSString
        let animojis = elements.filter { $0.type == "ANIMOJI" && $0.from >= 0 && $0.from + $0.length <= ns.length }.sorted { $0.from < $1.from }
        let styled = linkifiedFormatted(text, elements: elements.filter { $0.type != "ANIMOJI" })
        var out: [Token] = []
        var n = 0
        func addText(_ range: NSRange) {
            guard range.length > 0 else { return }
            var wordStart: Int?
            func flush(_ end: Int) {
                guard let ws = wordStart else { return }
                wordStart = nil
                let lo = String.Index(utf16Offset: ws, in: text), hi = String.Index(utf16Offset: end, in: text)
                if let a = AttributedString.Index(lo, within: styled), let b = AttributedString.Index(hi, within: styled), a < b {
                    out.append(.word(AttributedString(styled[a..<b]), n)); n += 1
                }
            }
            for i in range.location..<(range.location + range.length) {
                let c = ns.character(at: i)
                if c == 10 { flush(i); out.append(.lineBreak(n)); n += 1 }
                else if c == 32 || c == 9 { flush(i) }
                else if wordStart == nil { wordStart = i }
            }
            flush(range.location + range.length)
        }
        var cursor = 0
        for e in animojis where e.from >= cursor {
            addText(NSRange(location: cursor, length: e.from - cursor))
            let known = e.entityId.flatMap { store.animojiCache[$0] }
            out.append(.animoji(ns.substring(with: NSRange(location: e.from, length: e.length)), e.animojiLottieUrl ?? known?.animationURL, n)); n += 1
            cursor = e.from + e.length
        }
        addText(NSRange(location: cursor, length: ns.length - cursor))
        return out
    }

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 2) {
            ForEach(tokens) { t in
                switch t {
                case .word(let a, _): Text(a).font(.body).textSelection(.enabled)
                case .animoji(let emoji, let url, _): AnimojiView(emoji: emoji, url: url, size: 26)
                case .lineBreak: Color.clear.frame(width: 100000, height: 0)   // forces a new line
                }
            }
        }
    }
}

/// Left-to-right layout that wraps to the next line when a view does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 400, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews: subviews)
        for (i, f) in r.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if s.width > width {                       // a line-break marker: start a new line
                if x > 0 { y += lineH + lineSpacing; x = 0; lineH = 0 }
                frames.append(CGRect(x: 0, y: y, width: 0, height: 0)); continue
            }
            if x > 0, x + s.width > width { y += lineH + lineSpacing; x = 0; lineH = 0 }
            frames.append(CGRect(x: x, y: y, width: s.width, height: s.height))
            x += s.width + spacing; lineH = max(lineH, s.height); maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + lineH), frames)
    }
}
