import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import RMSMaxCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Row of story circles above the chat list.
struct StoriesBar: View {
    @EnvironmentObject private var store: AppStore
    @State private var open: StoryOwnerBox?
    @State private var showingNew = false

    struct StoryOwnerBox: Identifiable { let id = UUID(); let owner: StoryOwner }

    var body: some View {
        if store.currentAccount != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button { showingNew = true } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                AvatarView(url: store.currentAccount?.avatarURL, title: store.currentAccount?.displayName ?? "", size: 40)
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16)).foregroundStyle(.white, Color.accentColor)
                                    .background(Circle().fill(.background).frame(width: 14, height: 14))
                                    .offset(x: 15, y: 15)
                            }
                            .frame(width: 46, height: 46)
                            Text("Моя история").font(.caption2).lineLimit(1).frame(width: 60)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Опубликовать историю")
                    ForEach(store.storyPreviews) { p in
                        Button { open = StoryOwnerBox(owner: p.owner) } label: {
                            VStack(spacing: 3) {
                                AvatarView(url: p.owner.type == 0 ? store.contacts[p.owner.id]?.avatarURL : store.chats.first { $0.id == p.owner.id }?.avatarURL,
                                           title: store.storyOwnerName(p.owner), size: 40)
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(p.hasUnread ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 2.5))
                                    .frame(width: 46, height: 46)
                                Text(store.storyOwnerName(p.owner)).font(.caption2).lineLimit(1).frame(width: 60)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .sheet(item: $open) { box in
                StoryViewer(owner: box.owner)
            }
            .sheet(isPresented: $showingNew) { NewStorySheet() }
        }
    }
}

/// Swipe/tap through an owner's stories; marks them viewed and allows a reaction.
struct StoryViewer: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let owner: StoryOwner
    @State private var stories: [Story] = []
    @State private var index = 0
    @State private var loading = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if loading {
                ProgressView().tint(.white)
            } else if stories.isEmpty {
                VStack(spacing: 8) {
                    Text("Историю не удалось загрузить").foregroundStyle(.white)
                    Text("Возможно, она уже истекла или скрыта автором.").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            } else {
                let story = stories[index]
                VStack(spacing: 10) {
                    HStack {
                        Text(store.storyOwnerName(owner)).bold()
                        Text(Date(timeIntervalSince1970: Double(story.time) / 1000).formatted(.dateTime.hour().minute().locale(Locale(identifier: "ru_RU"))))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal)
                    HStack(spacing: 3) {
                        ForEach(stories.indices, id: \.self) { i in
                            Capsule().fill(i <= index ? Color.white : Color.white.opacity(0.3)).frame(height: 3)
                        }
                    }
                    .padding(.horizontal)
                    ZStack {
                        if let url = story.imageURL { RemoteImage(url: url) } else { Color.gray.opacity(0.3) }
                        if story.isVideo {
                            Label("Видео — откройте в приложении MAX", systemImage: "video")
                                .font(.caption).padding(6).background(Capsule().fill(.black.opacity(0.6))).foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { next() }
                    HStack(spacing: 14) {
                        ForEach(["❤️", "🔥", "👍", "😂", "😮"], id: \.self) { e in
                            Button(e) {
                                let remove = stories[index].myReaction == e
                                stories[index].myReaction = remove ? nil : e
                                Task { await store.reactToStory(story, emoji: remove ? nil : e) }
                            }
                            .font(.title2)
                            .buttonStyle(.plain)
                            .opacity(story.myReaction == nil || story.myReaction == e ? 1 : 0.4)
                        }
                        Spacer()
                        if owner.type == 0 && owner.id == store.currentAccount?.userId {
                            Label("\(story.viewsCount)", systemImage: "eye").foregroundStyle(.white)
                            Button(role: .destructive) {
                                Task { await store.deleteStories([story.id]); dismiss() }
                            } label: { Image(systemName: "trash") }
                        }
                    }
                    .padding()
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Закрыть (Esc)")
            .padding(10)
        }
        .background {
            Group {
                Button("") { if index > 0 { index -= 1 } }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { next() }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
        }
        .frame(minWidth: 360, minHeight: 600)
        .task {
            stories = await store.stories(of: owner)
            loading = false
            if let first = stories.first { await store.markStoryViewed(first) }
        }
        .onChange(of: index) { _, i in
            guard stories.indices.contains(i) else { return }
            Task { await store.markStoryViewed(stories[i]) }
        }
    }

    private func next() {
        if index + 1 < stories.count { index += 1 } else { dismiss() }
    }
}


/// Publish a photo or a video story (op 80/82 upload + op 215).
struct NewStorySheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var photo: Data?
    @State private var photoMime = "image/jpeg"
    @State private var video: Data?
    @State private var videoName = "story.mp4"
    @State private var durationMs = 0
    @State private var contactsOnly = false
    @State private var publishing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let photo, let img = Self.preview(photo) {
                        img.resizable().scaledToFit().frame(maxHeight: 280).frame(maxWidth: .infinity)
                    } else if video != nil {
                        Label("Видео \(String(format: "%d:%02d", durationMs / 60000, durationMs / 1000 % 60))", systemImage: "film")
                    } else {
                        Text("Выберите фото или видео — история будет доступна 24 часа.").foregroundStyle(.secondary)
                    }
                    Button(photo == nil && video == nil ? "Выбрать файл…" : "Выбрать другой…") { importing = true }
                }
                Section {
                    Picker("Кто увидит", selection: $contactsOnly) {
                        Text("Все").tag(false)
                        Text("Только контакты").tag(true)
                    }
                }
            }
            .navigationTitle("Новая история")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(publishing ? "Публикуем…" : "Опубликовать") {
                        publishing = true
                        Task {
                            let ok = await store.publishStory(photo: photo, mime: photoMime, video: video, videoFileName: videoName,
                                                              durationMs: durationMs, contactsOnly: contactsOnly)
                            publishing = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled((photo == nil && video == nil) || publishing)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie, .mpeg4Movie]) { result in
                guard case .success(let url) = result else { return }
                load(url)
            }
        }
        .macSheet(width: 460, height: 460)
    }

    private static func preview(_ data: Data) -> Image? {
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { store.errorBanner = "Не удалось прочитать файл"; return }
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) {
            video = data; photo = nil; videoName = "story.\(ext == "mov" ? "mov" : "mp4")"
            Task {
                let d = try? await AVURLAsset(url: url).load(.duration)
                durationMs = Int((d?.seconds ?? 0) * 1000)
            }
        } else {
            photo = data; video = nil; photoMime = ext == "png" ? "image/png" : "image/jpeg"
        }
    }
}

