import SwiftUI
import RMSMaxCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

struct GroupInfoView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64

    @State private var members: [GroupMember] = []
    @State private var joinRequests: [MaxContact] = []
    @State private var links: [(id: Int64, url: String, title: String?)] = []
    @State private var titleDraft = ""
    @State private var descDraft = ""
    @State private var newLinkTitle = ""
    @State private var showingAddMembers = false
    @State private var showingPhotoImporter = false
    @State private var showingLeaveConfirm = false
    @State private var renameTarget: MaxContact?
    @State private var complaint: ComplaintRequest?

    struct ComplaintRequest: Identifiable {
        let id = UUID()
        let target: ComplaintTarget
        let ids: [Int64]
    }

    private static let optionLabels: [(key: String, label: String)] = [
        ("JOIN_REQUEST", "Вступление по заявке"),
        ("ONLY_ADMIN_CAN_ADD_MEMBER", "Добавлять участников могут только админы"),
        ("ONLY_ADMIN_CAN_CALL", "Звонить могут только админы"),
        ("ALL_CAN_PIN_MESSAGE", "Закреплять могут все"),
    ]

    private var chat: MaxChat? { store.chats.first { $0.id == chatId } }
    private var me: Int64? { store.currentAccount?.userId }

    private var isAdmin: Bool {
        guard let chat, let me else { return false }
        return chat.ownerId == me || chat.adminIds.contains(me)
    }

    var body: some View {
        Group {
            if let chat {
                if chat.type == .dialog {
                    dialogForm(chat)
                } else {
                    groupForm(chat)
                }
            } else {
                ContentUnavailableView("Чат не найден", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(chat.map { store.resolvedChatTitle($0) } ?? "Информация")
        .task { await reload() }
        .sheet(item: $complaint) { c in
            ComplaintSheet(target: c.target, ids: c.ids, parentId: nil)
        }
        .sheet(item: $renameTarget) { c in
            RenameContactSheet(contact: c)
        }
        .sheet(isPresented: $showingAddMembers, onDismiss: { Task { await reload() } }) {
            AddMembersSheet(chatId: chatId, existingIds: Set(members.map(\.id)))
        }
        .fileImporter(isPresented: $showingPhotoImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result, let photo = PhotoFileImport.load(url) else { return }
            let id = chatId
            Task {
                await store.setChatPhoto(chatId: id, data: photo.data, mime: photo.mime)
            }
        }
        .confirmationDialog("Покинуть группу?", isPresented: $showingLeaveConfirm, titleVisibility: .visible) {
            Button("Покинуть группу", role: .destructive) {
                let id = chatId
                Task {
                    await store.leaveChat(chatId: id)
                    dismiss()
                }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: - Loading

    private func reload() async {
        if let chat {
            titleDraft = chat.title
            descDraft = chat.chatDescription ?? ""
        }
        members = await store.loadMembers(chatId: chatId)
        if isAdmin {
            joinRequests = await store.loadJoinRequests(chatId: chatId)
            links = await store.inviteLinks(chatId: chatId)
        }
    }

    // MARK: - Dialog

    @ViewBuilder
    private func dialogForm(_ chat: MaxChat) -> some View {
        let peerId = store.dialogPeerId(for: chat)
        let peer = peerId.flatMap { store.contacts[$0] }
        Form {
            Section("Собеседник") {
                if let peer {
                    LabeledContent("Имя", value: peer.name)
                    if let phone = peer.phone {
                        LabeledContent("Телефон", value: phone)
                    }
                    if let d = peer.description, !d.isEmpty {
                        Text(d)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Нет данных о собеседнике")
                        .foregroundStyle(.secondary)
                }
            }

            if let peer, let pid = peerId {
                Section("Действия") {
                    if peer.isBlocked == true {
                        Button("Разблокировать") {
                            Task { await store.contactAction(pid, action: "UNBLOCK") }
                        }
                    } else {
                        Button("Заблокировать", role: .destructive) {
                            Task { await store.contactAction(pid, action: "BLOCK") }
                        }
                    }
                    Button("Переименовать…") { renameTarget = peer }
                    Button("Удалить из контактов", role: .destructive) {
                        Task { await store.contactAction(pid, action: "REMOVE") }
                    }
                    Button("Пожаловаться…", role: .destructive) {
                        complaint = ComplaintRequest(target: .userProfile, ids: [pid])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Group

    @ViewBuilder
    private func groupForm(_ chat: MaxChat) -> some View {
        Form {
            Section("Основное") {
                if isAdmin {
                    TextField("Название", text: $titleDraft)
                    TextField("Описание", text: $descDraft, axis: .vertical)
                    Button("Сохранить") {
                        let fields: [String: JSONValue] = [
                            "title": .string(titleDraft.trimmedForm),
                            "description": .string(descDraft.trimmedForm),
                        ]
                        let id = chatId
                        Task { await store.updateChat(chatId: id, fields: fields) }
                    }
                    .disabled(titleDraft.trimmedForm.isEmpty)
                    Button("Сменить фото") { showingPhotoImporter = true }
                } else {
                    LabeledContent("Название", value: store.resolvedChatTitle(chat))
                    if let d = chat.chatDescription, !d.isEmpty {
                        Text(d)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Участников", value: "\(chat.participantsCount ?? members.count)")
            }

            Section {
                ForEach(members) { m in
                    HStack {
                        Text(m.name)
                        Spacer()
                        if m.isOwner {
                            Text("владелец")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if m.isAdmin {
                            Text("админ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        if isAdmin, !m.isOwner, m.id != me {
                            if m.isAdmin {
                                Button("Снять админа") {
                                    Task {
                                        await store.changeMembers(chatId: chatId, userIds: [m.id], operation: "remove", type: "ADMIN")
                                        await reload()
                                    }
                                }
                            } else {
                                Button("Сделать админом") {
                                    Task {
                                        await store.changeMembers(chatId: chatId, userIds: [m.id], operation: "add", type: "ADMIN")
                                        await reload()
                                    }
                                }
                            }
                            Button("Удалить из группы", role: .destructive) {
                                Task {
                                    await store.changeMembers(chatId: chatId, userIds: [m.id], operation: "remove")
                                    await reload()
                                }
                            }
                        }
                    }
                }
                if isAdmin {
                    Button("Добавить участников") { showingAddMembers = true }
                }
            } header: {
                Text("Участники")
            }

            if isAdmin {
                Section("Заявки на вступление") {
                    if joinRequests.isEmpty {
                        Text("Заявок нет")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(joinRequests) { c in
                        HStack {
                            Text(c.name)
                            Spacer()
                            Button("Принять") {
                                Task {
                                    await store.changeMembers(chatId: chatId, userIds: [c.id], operation: "add", type: "JOIN_REQUEST")
                                    await reload()
                                }
                            }
                            .buttonStyle(.borderless)
                            Button("Отклонить", role: .destructive) {
                                Task {
                                    await store.changeMembers(chatId: chatId, userIds: [c.id], operation: "remove", type: "JOIN_REQUEST")
                                    await reload()
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Ссылки-приглашения") {
                    ForEach(links, id: \.id) { l in
                        VStack(alignment: .leading, spacing: 4) {
                            if let t = l.title, !t.isEmpty {
                                Text(t).font(.headline)
                            }
                            Text(l.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            HStack {
                                Button("Копировать") { copyToPasteboard(l.url) }
                                    .buttonStyle(.borderless)
                                Spacer()
                                Button("Удалить", role: .destructive) {
                                    let linkId = l.id
                                    let id = chatId
                                    Task {
                                        await store.deleteInviteLink(chatId: id, linkId: linkId)
                                        await reload()
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        TextField("Название новой ссылки", text: $newLinkTitle)
                        Button("Создать") {
                            let title = newLinkTitle.trimmedForm
                            let id = chatId
                            newLinkTitle = ""
                            Task {
                                await store.createInviteLink(chatId: id, title: title)
                                await reload()
                            }
                        }
                        .disabled(newLinkTitle.trimmedForm.isEmpty)
                    }
                }

                Section("Настройки группы") {
                    ForEach(Self.optionLabels, id: \.key) { opt in
                        Toggle(opt.label, isOn: Binding(
                            get: { chat.options[opt.key] ?? false },
                            set: { value in
                                let id = chatId
                                Task {
                                    await store.updateChat(chatId: id, fields: ["options": .object([opt.key: .bool(value)])])
                                }
                            }
                        ))
                    }
                }
                .disabled(!isAdmin)
            }

            Section {
                Button("Пожаловаться на группу…", role: .destructive) {
                    complaint = ComplaintRequest(target: chat.type == .channel ? .channel : .chat, ids: [chat.id])
                }
                Button("Покинуть группу", role: .destructive) {
                    showingLeaveConfirm = true
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Multi-select of saved contacts that are not yet in the group.
private struct AddMembersSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    let existingIds: Set<Int64>
    @State private var selected: Set<Int64> = []

    private var candidates: [MaxContact] {
        let me = store.currentAccount?.userId
        return store.contacts.values
            .filter { $0.isInContacts == true && $0.id != me && !existingIds.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { c in
                Button {
                    if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
                } label: {
                    HStack {
                        Text(c.name)
                        Spacer()
                        if selected.contains(c.id) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("Нет контактов для добавления", systemImage: "person.2")
                }
            }
            .navigationTitle("Добавить участников")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить (\(selected.count))") {
                        let ids = Array(selected)
                        let id = chatId
                        Task { await store.changeMembers(chatId: id, userIds: ids, operation: "add", showHistory: true) }
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}
