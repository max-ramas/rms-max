import SwiftUI
import WebKit
import RMSMaxCore

enum YouTube {
    /// Video id from youtube.com/watch?v=, /shorts/, /live/, /embed/ and youtu.be links.
    static func videoId(_ s: String) -> String? {
        guard let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        var id: String?
        if host == "youtu.be" {
            id = parts.first
        } else if host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") {
            if parts.first == "watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["shorts", "live", "embed", "v"].contains(parts[0]) {
                id = parts[1]
            }
        }
        guard let id, id.count >= 6, id.count <= 20, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }

    static func isShorts(_ s: String) -> Bool { s.contains("/shorts/") }
}

/// First http(s) link in a text.
func firstLink(in text: String) -> String? {
    guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
    let ns = text as NSString
    return det.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        .flatMap { $0.url?.absoluteString }
        .flatMap { $0.hasPrefix("http") ? $0 : nil }
}

/// Text with tappable links.
/// Formatting from MAX (bold, links, mentions) first, plain-text links detected in whatever stays unstyled.
func linkifiedFormatted(_ text: String, elements: [TextElement]) -> AttributedString {
    var out = FormattedText.attributed(text, elements: elements)
    guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
    for m in det.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
        guard let url = m.url, let r = Range(m.range, in: text),
              let lo = AttributedString.Index(r.lowerBound, within: out),
              let hi = AttributedString.Index(r.upperBound, within: out), out[lo..<hi].link == nil else { continue }
        out[lo..<hi].link = url
    }
    return out
}

func linkified(_ text: String) -> AttributedString {
    var out = AttributedString(text)
    guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
    for m in det.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
        guard let url = m.url, let r = Range(m.range, in: text),
              let lo = AttributedString.Index(r.lowerBound, within: out),
              let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
        out[lo..<hi].link = url
    }
    return out
}

/// Link preview card: YouTube gets a thumbnail with an in-app player, other links the SHARE preview from MAX.
struct LinkCardView: View {
    let url: String
    var share: LinkShare? = nil
    @AppStorage("youtubePreviews") private var youtubePreviews = true
    @Environment(\.openURL) private var openURL
    @State private var playing: String?

    var body: some View {
        if let vid = YouTube.videoId(url) {
            VStack(alignment: .leading, spacing: 6) {
                Button { playing = vid } label: {
                    ZStack {
                        if youtubePreviews {
                            RemoteImage(url: "https://i.ytimg.com/vi/\(vid)/hqdefault.jpg")
                                .aspectRatio(16 / 9, contentMode: .fill)
                        } else {
                            Rectangle().fill(Color.black.opacity(0.85)).aspectRatio(16 / 9, contentMode: .fit)
                        }
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(.white, .red)
                            .shadow(radius: 6)
                    }
                    .frame(maxWidth: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                HStack(spacing: 4) {
                    Image(systemName: "play.rectangle.fill").foregroundStyle(.red)
                    Text(share?.title ?? (YouTube.isShorts(url) ? "YouTube Shorts" : "YouTube")).font(.caption.bold()).lineLimit(2)
                }
            }
            .sheet(item: Binding(get: { playing.map(PlayerItem.init) }, set: { playing = $0?.id })) { item in
                YouTubePlayerSheet(videoId: item.id, url: url)
            }
        } else if let share, share.title != nil || share.imageURL != nil {
            Button { if let u = URL(string: share.url) { openURL(u) } } label: {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(share.host ?? URL(string: share.url)?.host ?? "").font(.caption.bold()).foregroundStyle(Color.accentColor)
                        if let t = share.title { Text(t).font(.subheadline.bold()).lineLimit(2) }
                        if let d = share.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        if let img = share.imageURL {
                            RemoteImage(url: img).frame(maxWidth: 320, maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
        }
    }

    private struct PlayerItem: Identifiable { let id: String }
}

struct YouTubePlayerSheet: View {
    let videoId: String
    let url: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            YouTubeWebView(videoId: videoId)
                .aspectRatio(YouTube.isShorts(url) ? 9 / 16 : 16 / 9, contentMode: .fit)
                .background(Color.black)
                .navigationTitle("YouTube")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Открыть в браузере") { if let u = URL(string: url) { openURL(u) } }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: YouTube.isShorts(url) ? 380 : 800, minHeight: YouTube.isShorts(url) ? 700 : 500)
        #endif
    }
}

/// youtube-nocookie embed (no tracking cookies until playback), loaded only when the user presses play.
struct YouTubeWebView {
    let videoId: String

    fileprivate func makeWebView() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        #if os(iOS)
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        #endif
        let web = WKWebView(frame: .zero, configuration: cfg)
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="https://www.youtube-nocookie.com/embed/\(videoId)?autoplay=1&playsinline=1&rel=0"
        allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
        referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        web.loadHTMLString(html, baseURL: URL(string: "https://rms-ds.com/"))
        return web
    }
}

#if os(macOS)
extension YouTubeWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
extension YouTubeWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

/// «Пётр добавил(а) Анну», «Чат создан» … for `_type: CONTROL`.
struct ControlEventText: View {
    @EnvironmentObject private var store: AppStore
    let message: MaxMessage
    let event: ControlEvent

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .frame(maxWidth: .infinity)
    }

    private func name(_ id: Int64) -> String {
        id == store.currentAccount?.userId ? "Вы" : (store.contacts[id]?.name ?? "Участник")
    }

    private var text: String {
        let actor = name(message.senderId)
        let others = event.userIds.filter { $0 != message.senderId }.map(name).joined(separator: ", ")
        switch event.event {
        case "new": return "\(actor) создал(а) чат" + (event.title.map { " «\($0)»" } ?? "")
        case "add": return others.isEmpty ? "\(actor) вступил(а) в чат" : "\(actor) добавил(а) \(others)"
        case "remove": return "\(actor) исключил(а) \(others)"
        case "leave": return "\(actor) покинул(а) чат"
        case "joinByLink": return "\(actor) вступил(а) по ссылке"
        case "title": return "\(actor) изменил(а) название" + (event.title.map { " на «\($0)»" } ?? "")
        case "icon": return "\(actor) изменил(а) фото чата"
        case "pin": return "\(actor) закрепил(а) сообщение"
        case "botStarted": return "\(actor) запустил(а) бота"
        case "hello": return "\(name(message.senderId)) теперь в MAX — поздоровайтесь 👋"
        case "privacyWarning": return "\(actor) " + (event.kind == "screencast" ? "записывает экран" : "сделал(а) снимок экрана")
        case "sendContact": return "\(actor) предлагает обменяться контактами"
        case "system": return event.message ?? "Системное сообщение"
        default: return event.summary
        }
    }
}

/// `_type: CONTACT` and `_type: LOCATION` cards.
struct ContactAndLocationViews: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL
    let message: MaxMessage
    @State private var profile: Int64?

    var body: some View {
        ForEach(message.attaches.filter { $0.contactId != nil || $0.latitude != nil }) { att in
            if let cid = att.contactId {
                Button { profile = cid } label: {
                    HStack {
                        AvatarView(url: store.contacts[cid]?.avatarURL, title: store.contacts[cid]?.name ?? "Контакт", size: 34)
                        VStack(alignment: .leading) {
                            Text(store.contacts[cid]?.name ?? "Контакт").font(.subheadline.bold())
                            Text("Открыть профиль").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .task { await store.ensureContacts([cid]) }
            } else if let lat = att.latitude, let lon = att.longitude {
                Button {
                    if let u = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=%D0%93%D0%B5%D0%BE%D0%BF%D0%BE%D0%B7%D0%B8%D1%86%D0%B8%D1%8F") { openURL(u) }
                } label: {
                    Label(String(format: "Геопозиция %.5f, %.5f", lat, lon), systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: Binding(get: { profile.map(IdBox.init) }, set: { profile = $0?.id })) { box in
            NavigationStack {
                UserProfileView(userId: box.id)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { profile = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 560)
            #endif
        }
    }

    private struct IdBox: Identifiable { let id: Int64 }
}


/// «Исходящий видеозвонок · 1:23» — a call record in the timeline: centred, grey, no bubble.
struct CallEventRow: View {
    @EnvironmentObject private var store: AppStore
    let message: MaxMessage
    let call: CallAttach

    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        let outgoing = message.senderId == store.currentAccount?.userId
        HStack(spacing: 6) {
            Image(systemName: icon(outgoing))
                .foregroundStyle(call.isMissed && !outgoing ? Color.red : Color.secondary)
            Text(call.text(outgoing: outgoing))
                .foregroundStyle(call.isMissed && !outgoing ? Color.red : Color.secondary)
            Text(Self.time.string(from: message.date)).foregroundStyle(.tertiary)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .frame(maxWidth: .infinity)
    }

    private func icon(_ outgoing: Bool) -> String {
        if call.joinLink != nil { return "person.2.fill" }
        let base = call.isVideo ? "video" : "phone"
        if call.isMissed { return outgoing ? "\(base).arrow.up.right" : (call.isVideo ? "video.slash" : "phone.arrow.down.left") }
        return outgoing ? (call.isVideo ? "video.fill" : "phone.arrow.up.right") : (call.isVideo ? "video.fill" : "phone.arrow.down.left")
    }
}
