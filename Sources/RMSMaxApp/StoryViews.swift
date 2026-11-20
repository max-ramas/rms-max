import SwiftUI
import RMSMaxCore

/// Row of story circles above the chat list.
struct StoriesBar: View {
    @EnvironmentObject private var store: AppStore
    @State private var open: StoryOwnerBox?

    struct StoryOwnerBox: Identifiable { let id = UUID(); let owner: StoryOwner }

    var body: some View {
        if !store.storyPreviews.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
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
                        Text(Date(timeIntervalSince1970: Double(story.time) / 1000).formatted(date: .omitted, time: .shortened))
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
