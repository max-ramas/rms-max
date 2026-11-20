import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RMSMaxCore

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var searchText = ""
    @State private var showingSettings = false
    @State private var showingJoinCallSheet = false
    @State private var showingNewGroupSheet = false
    @State private var showingCallHistory = false
    @State private var showingContacts = false
    @State private var showingQuickSwitch = false
    @State private var showingCreateConference = false
    @State private var joinLinkInput = ""
    @State private var joinSecureCall = true
    @State private var joinVideoCall = false

    @State private var showingFolders = false
    @State private var showingJoinLink = false

    private var folderChats: [MaxChat] {
        guard let id = store.selectedFolderId, let f = store.folders.first(where: { $0.id == id }) else { return store.withPinnedFirst(store.chats) }
        return store.withPinnedFirst(store.chats(in: f))
    }

    var filteredChats: [MaxChat] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return folderChats }
        return store.chats.filter {
            store.resolvedChatTitle($0).lowercased().contains(q)
                || ($0.lastMessage?.displayText.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        ZStack {
            if store.isLocked {
                biometricLockScreen
            } else if store.authStep != .authenticated {
                AuthView()
            } else {
                NavigationSplitView {
                    chatListSidebar
                        .safeAreaInset(edge: .top) {
                            VStack(spacing: 0) {
                                PermissionsBanner()
                                UpdateBanner()
                                StoriesBar()
                                if !store.folders.isEmpty || store.isConnected {
                                    FolderBar(showingManager: $showingFolders)
                                }
                            }
                        }
                        .sheet(isPresented: $showingFolders) {
                            NavigationStack {
                                FolderManagerView()
                                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { showingFolders = false } } }
                            }
                            #if os(macOS)
                            .frame(minWidth: 420, minHeight: 460)
                            #endif
                        }
                        .navigationTitle("RMS MAKS")
                        #if os(macOS)
                        // Wide enough for every toolbar button of the column; narrower, macOS folds the last ones into «»».
                        .navigationSplitViewColumnWidth(min: 400, ideal: 420, max: 560)
                        #endif
                        .searchable(text: $searchText, prompt: "Поиск чатов и сообщений")
                        .task(id: searchText) {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard !Task.isCancelled else { return }
                            await store.searchMessages(searchText)
                        }
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) {
                                Button {
                                    showingNewGroupSheet = true
                                } label: {
                                    Label("Новая группа", systemImage: "square.and.pencil")
                                }
                                .help("Новая группа")
                                Button {
                                    showingJoinLink = true
                                } label: {
                                    Label("Открыть ссылку", systemImage: "link")
                                }
                                .help("Открыть ссылку")
                                Button {
                                    showingCallHistory = true
                                } label: {
                                    Label("Звонки", systemImage: "phone.badge.clock")
                                }
                                .help("Звонки")
                                Button {
                                    showingContacts = true
                                } label: {
                                    Label("Контакты", systemImage: "person.crop.circle")
                                }
                                .help("Контакты")
                                Menu {
                                    Button("Создать конференцию…") { showingCreateConference = true }
                                    Button("Присоединиться по ссылке…") { showingJoinCallSheet = true }
                                } label: {
                                    Label("Конференция", systemImage: "video.badge.plus")
                                }
                                .help("Создать конференцию или присоединиться по ссылке")
                                Button {
                                    showingSettings = true
                                } label: {
                                    Label("Настройки", systemImage: "gearshape")
                                }
                                .help("Настройки")
                            }
                        }
                } detail: {
                    if let chatId = store.selectedChatId,
                       let chat = store.chats.first(where: { $0.id == chatId }) {
                        ChatDetailView(chat: chat)
                            .id(chat.id)
                    } else {
                        ContentUnavailableView(
                            "Выберите чат",
                            systemImage: "lock.shield",
                            description: Text("RMS MAKS — нативный клиент без телеметрии со сквозным шифрованием переписки и звонков.")
                        )
                    }
                }
            }

            if store.activeCall.phase != .idle {
                CallOverlayView()
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .alert("Ошибка", isPresented: Binding(
            get: { store.errorBanner != nil },
            set: { if !$0 { store.errorBanner = nil } }
        )) {
            Button("ОК", role: .cancel) { store.errorBanner = nil }
        } message: {
            Text(store.errorBanner ?? "")
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Готово") { showingSettings = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 540, minHeight: 580)
            #endif
        }
        .sheet(isPresented: $showingJoinCallSheet) {
            joinConferenceSheet
        }
        .sheet(isPresented: $showingNewGroupSheet) {
            NewChatSheet()
        }
        .sheet(isPresented: $showingJoinLink) {
            JoinByLinkSheet()
        }
        .sheet(isPresented: $showingCallHistory) {
            NavigationStack {
                CallHistoryView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Готово") { showingCallHistory = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 520)
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: AppAction.notification)) { note in
            switch AppAction(rawValue: note.object as? String ?? "") {
            case .contacts: showingContacts = true
            case .newGroup: showingNewGroupSheet = true
            case .callHistory: showingCallHistory = true
            case .joinCall: showingJoinCallSheet = true
            case .createConference: showingCreateConference = true
            case .openLink: showingJoinLink = true
            case .quickSwitch: showingQuickSwitch = true
            case .nextChat, .previousChat:
                let list = store.chats.sorted { $0.lastEventTime > $1.lastEventTime }
                guard !list.isEmpty else { break }
                let cur = list.firstIndex { $0.id == store.selectedChatId } ?? -1
                let step = AppAction(rawValue: note.object as? String ?? "") == .nextChat ? 1 : -1
                store.selectedChatId = list[(cur + step + list.count) % list.count].id
            case .checkUpdates:
                Task {
                    if store.availableUpdate == nil { await store.checkForUpdates(manual: true) }
                    store.updatePromptShown = true
                }
            case nil: break
            }
        }
        .permissionAlert()
        .sheet(isPresented: $store.updatePromptShown) { UpdateSheet() }
        .sheet(isPresented: $showingQuickSwitch) { QuickSwitcherSheet() }
        .sheet(isPresented: $showingCreateConference) { CreateConferenceSheet() }
        .sheet(isPresented: $showingContacts) {
            NavigationStack {
                ContactsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Готово") { showingContacts = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 540)
            #endif
        }
    }

    private var chatListSidebar: some View {
        List(selection: Binding(
            get: { store.selectedChatId },
            set: { newId in
                Task { await store.selectChat(newId) }
            }
        )) {
            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(store.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(store.isConnected ? "Подключено" : "Переподключение...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("Телеметрия: выкл", systemImage: "hand.raised.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                Section("Чаты") {
                    ForEach(filteredChats) { chat in
                        ChatRowView(chat: chat)
                            .tag(chat.id)
                    }
                }
                Section {
                    if store.isSearchingMessages && store.messageSearchHits.isEmpty {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if store.messageSearchHits.isEmpty {
                        Text(searchText.count < 2 ? "Введите хотя бы 2 символа" : "Ничего не найдено")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.messageSearchHits) { hit in
                        Button {
                            Task { await store.openMessage(chatId: hit.chatId, message: hit.message) }
                        } label: {
                            SearchHitRow(hit: hit, query: searchText)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Сообщения")
                }
                if searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
                    PublicSearchSection(query: searchText)
                }
            } else {
                ForEach(filteredChats) { chat in
                    ChatRowView(chat: chat)
                        .tag(chat.id)
                }
            }
        }
    }

    private var biometricLockScreen: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.applewatch")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text("RMS MAKS заблокирован")
                .font(.title2.bold())
            Button("Разблокировать") {
                Task { await store.authenticateBiometrics() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await store.authenticateBiometrics()
        }
    }

    private var joinConferenceSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ссылка", text: $joinLinkInput, prompt: Text("https://max.ru/joincall/…"))
                } footer: {
                    Text("Ссылка на звонок MAX или его идентификатор.")
                }
                Section {
                    Toggle("Сквозное шифрование (только между RMS MAKS)", isOn: $joinSecureCall)
                    Toggle("Начать с видео", isOn: $joinVideoCall)
                }
            }
            .navigationTitle("Присоединиться к звонку")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showingJoinCallSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Войти") {
                        let link = joinLinkInput
                        showingJoinCallSheet = false
                        Task {
                            await store.joinConferenceByLink(link, isVideo: joinVideoCall, secure: joinSecureCall)
                        }
                    }
                    .disabled(joinLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 220)
        #endif
    }

}

private struct SearchHitRow: View {
    @EnvironmentObject private var store: AppStore
    let hit: MessageSearchHit
    let query: String

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var highlighted: AttributedString {
        let clean = hit.snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        var attr = AttributedString(clean)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let range = attr.range(of: q, options: .caseInsensitive) {
            attr[range].font = .subheadline.bold()
            attr[range].foregroundColor = .accentColor
        }
        return attr
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if hit.isLocalE2E {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green)
                }
                Text(store.chats.first(where: { $0.id == hit.chatId }).map { store.resolvedChatTitle($0) } ?? "Чат")
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Text(Self.formatter.string(from: hit.message.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(highlighted)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct ChatRowView: View {
    @EnvironmentObject private var store: AppStore
    let chat: MaxChat
    enum Confirm { case clear, delete }
    @State private var confirm: Confirm?
    @State private var profileFor: Int64?

    var body: some View {
        let settings = store.chatSettingsByChat[chat.id]
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(url: store.avatarURL(for: chat), title: store.resolvedChatTitle(chat),
                           symbol: store.avatarURL(for: chat) == nil && chat.type != .dialog ? (chat.type == .channel ? "megaphone.fill" : "person.3.fill") : nil)
                if chat.type == .dialog, let pid = store.dialogPeerId(for: chat), store.presence[pid]?.isOnline == true {
                    Circle().fill(.green).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(store.resolvedChatTitle(chat))
                        .font(.headline)
                        .lineLimit(1)
                    if settings?.isActive == true {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                if let typing = store.typingText(chatId: chat.id) {
                    Text(typing)
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                } else if let draft = store.drafts[chat.id], store.selectedChatId != chat.id {
                    (Text("Черновик: ").foregroundStyle(.red) + Text(draft.replacingOccurrences(of: "\n", with: " ")).foregroundStyle(.secondary))
                        .font(.subheadline)
                        .lineLimit(1)
                } else if (store.failedSends[chat.id]?.isEmpty == false) {
                    Label("Не отправлено", systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if let last = chat.lastMessage {
                    Text(last.displayText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if store.isChatPinned(chat.id) {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
            }
            if chat.isMuted {
                Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.secondary)
            }
            if chat.newMessages > 0 {
                Text("\(chat.newMessages)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(chat.isMuted ? Color.secondary.opacity(0.4) : Color.accentColor))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if chat.newMessages > 0 {
                Button("Отметить прочитанным") { Task { await store.markChatRead(chat.id) } }
            }
            if chat.isMuted {
                Button("Включить уведомления") { Task { await store.setChatMuted(chat.id, muted: false) } }
            } else {
                Menu("Отключить уведомления") {
                    Button("На 1 час") { Task { await store.setChatMuted(chat.id, muted: true, forHours: 1) } }
                    Button("На 8 часов") { Task { await store.setChatMuted(chat.id, muted: true, forHours: 8) } }
                    Button("На 2 дня") { Task { await store.setChatMuted(chat.id, muted: true, forHours: 48) } }
                    Button("Навсегда") { Task { await store.setChatMuted(chat.id, muted: true) } }
                }
            }
            Button(store.isChatPinned(chat.id) ? "Открепить чат" : "Закрепить чат") {
                Task { await store.togglePinChat(chat.id) }
            }
            if !store.folders.isEmpty {
                Menu("В папку") {
                    ForEach(store.folders) { f in
                        Button {
                            Task { await store.toggleChat(chat.id, in: f) }
                        } label: {
                            if store.isChat(chat.id, in: f) { Label(f.title, systemImage: "checkmark") } else { Text(f.title) }
                        }
                    }
                }
            }
            if chat.type == .dialog, let pid = store.dialogPeerId(for: chat) {
                Button("Профиль") { profileFor = pid }
            }
            if let link = chat.link, !link.isEmpty {
                Button("Скопировать ссылку") { copyChatLink(link) }
            }
            Divider()
            Button("Очистить историю…", role: .destructive) { confirm = .clear }
            Button(chat.type == .dialog ? "Удалить чат…" : "Удалить и покинуть…", role: .destructive) { confirm = .delete }
        }
        .sheet(item: Binding(get: { profileFor.map(RowUserBox.init) }, set: { profileFor = $0?.id })) { box in
            NavigationStack {
                UserProfileView(userId: box.id, showsMessageButton: false)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { profileFor = nil } } }
            }
            .macSheet(width: 440, height: 560)
        }
        .confirmationDialog(confirm == .clear ? "Очистить историю?" : "Удалить чат?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible) {
            if confirm == .clear {
                Button("Только у меня", role: .destructive) { Task { await store.clearHistory(chatId: chat.id, forAll: false) } }
                if chat.type == .dialog {
                    Button("У меня и у собеседника", role: .destructive) { Task { await store.clearHistory(chatId: chat.id, forAll: true) } }
                }
            } else {
                Button("Удалить у меня", role: .destructive) { Task { await store.deleteChat(chatId: chat.id, forAll: false) } }
                if chat.type == .dialog {
                    Button("Удалить у обоих", role: .destructive) { Task { await store.deleteChat(chatId: chat.id, forAll: true) } }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это нельзя отменить.")
        }
    }

    private func copyChatLink(_ link: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        #else
        UIPasteboard.general.string = link
        #endif
    }
}

private struct RowUserBox: Identifiable { let id: Int64 }
