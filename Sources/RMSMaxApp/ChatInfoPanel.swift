import SwiftUI
import RMSMaxCore

/// Telegram-style info panel that sits to the right of the chat: header with avatar and status, action tiles,
/// details, media counters, members and the actions of the chat or contact.
struct ChatInfoPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL
    let chatId: Int64
    var onClose: () -> Void = {}
    var onSearch: () -> Void = {}
    var onCall: (_ video: Bool) -> Void = { _ in }

    @State private var members: [GroupMember] = []
    @State private var counts: [MediaKind: Int] = [:]
    @State private var mediaSheet: MediaKind?
    @State private var profileOf: Int64?
    @State private var showingManage = false
    @State private var showingAdd = false
    @State private var showingPhotos = false
    @State private var renameTarget: MaxContact?
    @State private var complaint: ComplaintTarget?
    @State private var confirmLeave = false
    @State private var confirmClear = false
    @State private var confirmDelete = false

    enum MediaKind: String, CaseIterable, Identifiable {
        case photo = "PHOTO", video = "VIDEO", file = "FILE", audio = "AUDIO"
        var id: String { rawValue }
        var icon: String {
            switch self { case .photo: return "photo"; case .video: return "video"; case .file: return "doc"; case .audio: return "mic" }
        }
        func title(_ n: Int, capped: Bool) -> String {
            let num = capped ? "\(n)+" : "\(n)"
            let forms: (String, String, String)
            switch self {
            case .photo: forms = ("фотография", "фотографии", "фотографий")
            case .video: forms = ("видео", "видео", "видео")
            case .file: forms = ("файл", "файла", "файлов")
            case .audio: forms = ("голосовое сообщение", "голосовых сообщения", "голосовых сообщений")
            }
            let m10 = n % 10, m100 = n % 100
            let word = (m10 == 1 && m100 != 11) ? forms.0 : ((2...4).contains(m10) && !(12...14).contains(m100)) ? forms.1 : forms.2
            return "\(num) \(word)"
        }
    }

    private static let cap = 200

    private var chat: MaxChat? { store.chats.first { $0.id == chatId } }
    private var me: Int64? { store.currentAccount?.userId }
    private var peerId: Int64? { chat.flatMap { store.dialogPeerId(for: $0) } }
    private var peer: MaxContact? { peerId.flatMap { store.contacts[$0] } }
    private var isDialog: Bool { chat?.type == .dialog }
    private var isAdmin: Bool { guard let chat, let me else { return false }; return chat.ownerId == me || chat.adminIds.contains(me) }

    var body: some View {
        ScrollView {
            if let chat {
                VStack(spacing: 10) {
                    header(chat)
                    actionTiles(chat)
                    detailsCard(chat)
                    mediaCard
                    if !isDialog { membersCard(chat) }
                    dangerCard(chat)
                }
                .padding(12)
            } else {
                ContentUnavailableView("Чат не найден", systemImage: "questionmark.circle").padding(.top, 60)
            }
        }
        .background(Color.secondary.opacity(0.06))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) { Image(systemName: "xmark").font(.body.weight(.semibold)).padding(10) }
                .buttonStyle(.plain).help("Закрыть")
        }
        .task(id: chatId) { await load() }
        .sheet(item: $mediaSheet) { kind in ChatMediaListSheet(chatId: chatId, kind: kind) }
        .sheet(item: Binding(get: { profileOf.map(ProfileTarget.init) }, set: { profileOf = $0?.id })) { t in
            NavigationStack { UserProfileView(userId: t.id).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { profileOf = nil } } } }
                .environmentObject(store)
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 560)
                #endif
        }
        .sheet(isPresented: $showingManage, onDismiss: { Task { await load() } }) {
            NavigationStack {
                GroupInfoView(chatId: chatId).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { showingManage = false } } }
            }
            .environmentObject(store)
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 600)
            #endif
        }
        .sheet(isPresented: $showingPhotos) { if let id = peerId { ProfilePhotosSheet(userId: id) } }
        .sheet(item: $renameTarget) { RenameContactSheet(contact: $0) }
        .sheet(item: Binding(get: { complaint.map(ComplaintBox.init) }, set: { complaint = $0?.target })) { c in
            ComplaintSheet(target: c.target, ids: [c.target == .userProfile ? (peerId ?? chatId) : chatId], parentId: nil)
        }
        .confirmationDialog("Покинуть группу?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Покинуть", role: .destructive) { Task { await store.leaveChat(chatId: chatId); onClose() } }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Очистить историю?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Только у меня", role: .destructive) { Task { await store.clearHistory(chatId: chatId, forAll: false) } }
            if isDialog { Button("У меня и у собеседника", role: .destructive) { Task { await store.clearHistory(chatId: chatId, forAll: true) } } }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Сообщения будут удалены без возможности восстановления.") }
        .confirmationDialog("Удалить чат?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить у меня", role: .destructive) { Task { await store.deleteChat(chatId: chatId, forAll: false); onClose() } }
            if isDialog { Button("Удалить у обоих", role: .destructive) { Task { await store.deleteChat(chatId: chatId, forAll: true); onClose() } } }
            Button("Отмена", role: .cancel) {}
        } message: { Text("Чат и его история пропадут из списка. Это нельзя отменить.") }
    }

    private struct ProfileTarget: Identifiable { let id: Int64 }
    private struct ComplaintBox: Identifiable { let target: ComplaintTarget; var id: Int { target.rawValue } }

    // MARK: - Loading

    private func load() async {
        guard let chat else { return }
        if isDialog {
            if let id = peerId { await store.ensureContacts([id], refresh: true); await store.loadPresence([id]) }
        } else {
            members = await store.loadMembers(chatId: chatId)
            await store.loadPresence(Array(members.prefix(100).map(\.id)))
        }
        for kind in MediaKind.allCases {
            let n = await store.chatMedia(chatId: chat.id, types: [kind.rawValue], count: Self.cap).count
            counts[kind] = n
        }
    }

    // MARK: - Header

    private func header(_ chat: MaxChat) -> some View {
        VStack(spacing: 6) {
            AvatarView(url: isDialog ? peer?.avatarURL : chat.avatarURL, title: store.resolvedChatTitle(chat), size: 96)
                .onTapGesture { if isDialog, peer?.avatarURL != nil { showingPhotos = true } }
            Text(store.resolvedChatTitle(chat)).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            statusLine(chat)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18).padding(.bottom, 4)
    }

    @ViewBuilder private func statusLine(_ chat: MaxChat) -> some View {
        if isDialog {
            if peer?.isBot == true { Text("бот").foregroundStyle(.secondary) }
            else if let id = peerId, let p = store.presence[id] { Text(p.label).foregroundStyle(p.isOnline ? Color.accentColor : .secondary) }
        } else {
            let total = chat.participantsCount ?? members.count
            let online = members.filter { store.presence[$0.id]?.isOnline == true }.count
            let noun = chat.type == .channel ? "подписчиков" : "участников"
            Text(online > 0 ? "\(total) \(noun), \(online) в сети" : "\(total) \(noun)").foregroundStyle(.secondary)
        }
    }

    // MARK: - Action tiles

    private func actionTiles(_ chat: MaxChat) -> some View {
        HStack(spacing: 8) {
            Menu {
                if chat.isMuted {
                    Button("Включить уведомления") { Task { await store.setChatMuted(chatId, muted: false) } }
                } else {
                    Button("На 1 час") { Task { await store.setChatMuted(chatId, muted: true, forHours: 1) } }
                    Button("На 8 часов") { Task { await store.setChatMuted(chatId, muted: true, forHours: 8) } }
                    Button("На 2 дня") { Task { await store.setChatMuted(chatId, muted: true, forHours: 48) } }
                    Button("Навсегда") { Task { await store.setChatMuted(chatId, muted: true) } }
                }
            } label: { tile(chat.isMuted ? "bell.slash.fill" : "bell.fill", chat.isMuted ? "Без звука" : "Звук") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)

            if chat.type != .channel {
                Button { onCall(false) } label: { tile("phone.fill", "Звонок") }.buttonStyle(.plain)
            }
            Button(action: onSearch) { tile("magnifyingglass", "Поиск") }.buttonStyle(.plain)
            if !isDialog {
                Button { confirmLeave = true } label: { tile("rectangle.portrait.and.arrow.right", "Покинуть", tint: .red) }.buttonStyle(.plain)
            }
        }
    }

    private func tile(_ icon: String, _ title: String, tint: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3)
            Text(title).font(.caption)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.12)))
    }

    // MARK: - Details

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.12)))
    }

    private func infoRow(_ value: String, _ caption: String, accent: Bool = false, copy: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).foregroundStyle(accent ? Color.accentColor : .primary).textSelection(.enabled)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func detailsCard(_ chat: MaxChat) -> some View {
        let id = isDialog ? (peerId ?? chat.id) : chat.id
        card {
            if isDialog {
                if let phone = peer?.phone, !phone.isEmpty { infoRow(phone.hasPrefix("+") ? phone : "+" + phone, "Телефон") }
                if let d = peer?.description, !d.isEmpty { infoRow(d, "О себе") }
                if let link = peer?.link, !link.isEmpty {
                    Button { if let u = URL(string: link) { openURL(u) } } label: { infoRow(link, "Ссылка", accent: true) }.buttonStyle(.plain)
                }
                if let reg = peer?.registrationTime, reg > 0 {
                    infoRow(Date(timeIntervalSince1970: TimeInterval(reg) / 1000).formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU"))), "В MAX с")
                }
            } else {
                if let d = chat.chatDescription, !d.isEmpty { infoRow(d, "Описание") }
                if let link = chat.link, !link.isEmpty {
                    Button { copyText(link) } label: { infoRow(link, "Ссылка-приглашение (нажмите, чтобы скопировать)", accent: true) }.buttonStyle(.plain)
                }
            }
            Button { copyText(String(id)) } label: { infoRow("id: \(id)", "Нажмите, чтобы скопировать", accent: true) }.buttonStyle(.plain)
        }
    }

    // MARK: - Media

    private var mediaCard: some View {
        card {
            ForEach(MediaKind.allCases) { kind in
                if let n = counts[kind], n > 0 {
                    Button { mediaSheet = kind } label: {
                        HStack(spacing: 14) {
                            Image(systemName: kind.icon).frame(width: 24).foregroundStyle(.secondary)
                            Text(kind.title(n, capped: n >= Self.cap))
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if counts.values.allSatisfy({ $0 == 0 }) && counts.count == MediaKind.allCases.count {
                Text("Общих медиа пока нет").foregroundStyle(.secondary).padding(14)
            } else if counts.count < MediaKind.allCases.count {
                ProgressView().controlSize(.small).padding(14)
            }
        }
    }

    // MARK: - Members

    @ViewBuilder private func membersCard(_ chat: MaxChat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(chat.participantsCount ?? members.count) \(chat.type == .channel ? "ПОДПИСЧИКОВ" : "УЧАСТНИКОВ")")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6)
            card {
                ForEach(members) { m in
                    Button { profileOf = m.id } label: {
                        HStack(spacing: 10) {
                            AvatarView(url: store.contacts[m.id]?.avatarURL, title: m.name, size: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name).lineLimit(1)
                                if let p = store.presence[m.id] { Text(p.label).font(.caption).foregroundStyle(p.isOnline ? Color.accentColor : .secondary) }
                            }
                            Spacer()
                            if m.isOwner || m.isAdmin {
                                Text(m.isOwner ? "владелец" : "админ").font(.caption).foregroundStyle(.purple)
                                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.purple.opacity(0.15)))
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if isAdmin, !m.isOwner, m.id != me {
                            Button(m.isAdmin ? "Снять админа" : "Сделать админом") {
                                Task { await store.changeMembers(chatId: chatId, userIds: [m.id], operation: m.isAdmin ? "remove" : "add", type: "ADMIN"); await load() }
                            }
                            Button("Удалить из группы", role: .destructive) {
                                Task { await store.changeMembers(chatId: chatId, userIds: [m.id], operation: "remove"); await load() }
                            }
                        }
                    }
                }
                if members.isEmpty { ProgressView().controlSize(.small).padding(14) }
                if isAdmin {
                    Divider().padding(.leading, 14)
                    Button { showingManage = true } label: { rowLabel("slider.horizontal.3", "Управление группой…") }.buttonStyle(.plain)
                }
            }
        }
    }

    private func rowLabel(_ icon: String, _ title: String, tint: Color = .primary) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).frame(width: 24)
            Text(title)
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
    }

    // MARK: - Actions

    @ViewBuilder private func dangerCard(_ chat: MaxChat) -> some View {
        card {
            if isDialog, let id = peerId {
                if peer?.isInContacts == true {
                    Button { renameTarget = peer } label: { rowLabel("pencil", "Изменить контакт") }.buttonStyle(.plain)
                    Button { Task { await store.contactAction(id, action: "REMOVE") } } label: { rowLabel("trash", "Удалить контакт") }.buttonStyle(.plain)
                } else {
                    Button { Task { await store.contactAction(id, action: "ADD", firstName: peer?.firstName, lastName: peer?.lastName) } } label: { rowLabel("person.badge.plus", "Добавить в контакты") }.buttonStyle(.plain)
                }
                if peer?.isBlocked == true {
                    Button { Task { await store.contactAction(id, action: "UNBLOCK") } } label: { rowLabel("hand.raised", "Разблокировать") }.buttonStyle(.plain)
                } else {
                    Button { Task { await store.contactAction(id, action: "BLOCK") } } label: { rowLabel("hand.raised.fill", "Заблокировать", tint: .red) }.buttonStyle(.plain)
                }
                Button { complaint = .userProfile } label: { rowLabel("exclamationmark.bubble", "Пожаловаться…", tint: .red) }.buttonStyle(.plain)
            } else {
                Button { complaint = chat.type == .channel ? .channel : .chat } label: { rowLabel("exclamationmark.bubble", "Пожаловаться…", tint: .red) }.buttonStyle(.plain)
            }
            Button { confirmClear = true } label: { rowLabel("eraser", "Очистить историю…", tint: .red) }.buttonStyle(.plain)
            Button { confirmDelete = true } label: { rowLabel("trash", isDialog ? "Удалить чат…" : "Удалить и покинуть…", tint: .red) }.buttonStyle(.plain)
        }
    }

    private func copyText(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}

/// Everything of one kind in a chat (photo and video as a grid, files and voice as a list).
struct ChatMediaListSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    let kind: ChatInfoPanel.MediaKind
    @State private var items: [MaxMessage] = []
    @State private var loaded = false
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if !loaded { ProgressView().padding(40) }
                else if kind == .photo || kind == .video {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(items) { m in
                            if let url = m.attaches.first(where: { $0.url != nil })?.url {
                                RemoteImage(url: url).aspectRatio(1, contentMode: .fill).frame(minHeight: 100).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .onTapGesture { Task { await store.openMessage(chatId: chatId, message: m) } }
                            }
                        }
                    }.padding(8)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { m in
                            Button { Task { await store.openMessage(chatId: chatId, message: m) } } label: {
                                HStack {
                                    Image(systemName: kind.icon).foregroundStyle(.secondary)
                                    VStack(alignment: .leading) {
                                        Text(m.displayText).lineLimit(1)
                                        Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }.padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if loaded && items.isEmpty { Text("Ничего нет").foregroundStyle(.secondary).padding(40) }
            }
            .navigationTitle(kind.title(items.count, capped: false))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task { items = await store.chatMedia(chatId: chatId, types: [kind.rawValue], count: 200); loaded = true }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}
