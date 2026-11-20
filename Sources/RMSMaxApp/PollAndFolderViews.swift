import SwiftUI
import RMSMaxCore

/// Poll card inside a message, with voting.
struct PollView: View {
    @EnvironmentObject private var store: AppStore
    let chatId: Int64
    let messageId: String
    let poll: MaxPoll
    @State private var selection: Set<Int> = []
    @State private var votersFor: VotersTarget?

    struct VotersTarget: Identifiable { let id: Int; let text: String }

    private var showResults: Bool { poll.hasVoted || poll.isClosed }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(poll.title, systemImage: poll.isQuiz ? "questionmark.circle" : "chart.bar")
                .font(.subheadline.bold())
                .sheet(item: $votersFor) { t in
                    PollVotersSheet(chatId: chatId, messageId: messageId, pollId: poll.pollId, answer: (Int64(t.id), t.text))
                }
            Text([poll.isAnonymous ? "Анонимный" : "Открытый", poll.isMultiple ? "несколько ответов" : nil, poll.isClosed ? "завершён" : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(poll.answers) { a in
                if showResults {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if a.votedByMe { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            Text(a.text)
                            Spacer()
                            Text("\(a.percent ?? 0)%").font(.caption.monospacedDigit())
                        }
                        GeometryReader { g in
                            Capsule().fill(Color.accentColor.opacity(0.25))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Color.accentColor).frame(width: g.size.width * CGFloat(a.percent ?? 0) / 100)
                                }
                        }
                        .frame(height: 5)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { votersFor = VotersTarget(id: a.id, text: a.text) }
                    .help("Кто голосовал")
                } else {
                    Button {
                        if poll.isMultiple {
                            if selection.contains(a.id) { selection.remove(a.id) } else { selection.insert(a.id) }
                        } else {
                            Task { await store.vote(chatId: chatId, messageId: messageId, poll: poll, answerIds: [a.id]) }
                        }
                    } label: {
                        HStack {
                            Image(systemName: selection.contains(a.id) ? "checkmark.square.fill" : (poll.isMultiple ? "square" : "circle"))
                            Text(a.text)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Голосов: \(poll.total)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !showResults && poll.isMultiple {
                    Button("Голосовать") {
                        Task { await store.vote(chatId: chatId, messageId: messageId, poll: poll, answerIds: Array(selection)) }
                    }
                    .disabled(selection.isEmpty)
                } else if poll.hasVoted && poll.canRevote && !poll.isClosed {
                    Button("Отменить голос") {
                        Task { await store.vote(chatId: chatId, messageId: messageId, poll: poll, answerIds: []) }
                    }
                    .font(.caption)
                }
            }
        }
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
    }
}

/// Folder tabs above the chat list ("Все" + server folders).
struct FolderBar: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showingManager: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(nil, "Все")
                chip(AppStore.chatsTabId, "Чаты")
                ForEach(store.folders) { f in chip(f.id, (f.emoji.map { $0 + " " } ?? "") + f.title) }
                Button { showingManager = true } label: { Image(systemName: "folder.badge.gearshape") }
                    .buttonStyle(.borderless)
                    .help("Папки")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private func chip(_ id: String?, _ title: String) -> some View {
        Button(title) { store.selectedFolderId = id }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(store.selectedFolderId == id ? .accentColor : .secondary)
    }
}

/// Create, edit and delete folders.
struct FolderManagerView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: ChatFolder?

    var body: some View {
        List {
            ForEach(store.folders) { f in
                HStack {
                    Text((f.emoji.map { $0 + " " } ?? "") + f.title)
                    Spacer()
                    Text("\(store.chats(in: f).count)").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { editing = f }
                .contextMenu {
                    Button("Изменить") { editing = f }
                    Button("Удалить", role: .destructive) { Task { await store.deleteFolder(f.id) } }
                }
            }
            Button {
                editing = ChatFolder(id: UUID().uuidString.lowercased(), title: "")
            } label: { Label("Новая папка", systemImage: "plus") }
        }
        .navigationTitle("Папки")
        .sheet(item: $editing) { f in
            FolderEditor(folder: f)
        }
    }
}

private struct FolderEditor: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var folder: ChatFolder

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $folder.title)
                Section("Включать автоматически") {
                    ForEach(ChatFolder.Filter.allCases.filter { $0 != .bot && $0 != .markedUnread }, id: \.rawValue) { f in
                        Toggle(f.title, isOn: Binding(
                            get: { folder.filters.contains(f.rawValue) },
                            set: { on in
                                if on { folder.filters.append(f.rawValue) } else { folder.filters.removeAll { $0 == f.rawValue } }
                            }
                        ))
                    }
                }
                Section("Чаты") {
                    ForEach(store.chats) { chat in
                        Toggle(store.resolvedChatTitle(chat), isOn: Binding(
                            get: { folder.include.contains(chat.id) },
                            set: { on in
                                if on { folder.include.append(chat.id) } else { folder.include.removeAll { $0 == chat.id } }
                            }
                        ))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(folder.title.isEmpty ? "Новая папка" : folder.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task { await store.saveFolder(folder); dismiss() }
                    }
                    .disabled(folder.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }
}
