import SwiftUI
import RMSMaxCore
import UniformTypeIdentifiers

extension String {
    /// Whitespace/newline-trimmed copy, used by the contact and profile forms.
    var trimmedForm: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Reads a picked image file and derives its MIME type from the extension.
enum PhotoFileImport {
    static func load(_ url: URL) -> (data: Data, mime: String)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
        return (data, mime)
    }
}

struct ContactsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var newPhone = ""
    @State private var newFirst = ""
    @State private var newLast = ""
    @State private var addResult: String?
    @State private var renameTarget: MaxContact?
    @State private var profileTarget: ProfileTarget?
    @State private var found: MaxContact?
    @State private var searching = false
    @State private var notFound = false
    @State private var showingImport = false

    struct ProfileTarget: Identifiable { let id: Int64 }

    /// Only the user's own address book (flagged during sync / add), not group members seen elsewhere.
    private var visibleContacts: [MaxContact] {
        let me = store.currentAccount?.userId
        let q = searchText.trimmedForm.lowercased()
        return store.contacts.values
            .filter { $0.isInContacts == true && $0.id != me }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || ($0.phone ?? "").contains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("", text: $newPhone, prompt: Text("Номер телефона, например +79001234567"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(find)
                    Button("Найти", action: find)
                        .disabled(newPhone.filter(\.isNumber).count < 10 || searching)
                }
                if searching { ProgressView().controlSize(.small) }
                if notFound {
                    Text("Пользователь с этим номером не зарегистрирован в MAX или скрыл номер").font(.caption).foregroundStyle(.secondary)
                }
                if let c = found {
                    HStack(spacing: 10) {
                        AvatarView(url: c.avatarURL, title: c.name, size: 36)
                        Text(c.name)
                        Spacer()
                        Button("Профиль") { profileTarget = ProfileTarget(id: c.id) }.buttonStyle(.borderless)
                        Button("Написать") { store.openDialog(with: c.id); dismiss() }.buttonStyle(.borderless)
                    }
                    if c.isInContacts != true {
                        HStack {
                            TextField("", text: $newFirst, prompt: Text("Имя")).labelsHidden().textFieldStyle(.roundedBorder)
                            TextField("", text: $newLast, prompt: Text("Фамилия")).labelsHidden().textFieldStyle(.roundedBorder)
                            Button("Добавить в контакты") { add(c) }
                        }
                    }
                }
                if let addResult { Text(addResult).font(.caption).foregroundStyle(.secondary) }
                Button("Импорт из адресной книги…") { showingImport = true }
            } header: {
                Text("Найти или добавить по номеру")
            }

            Section("Контакты (\(visibleContacts.count))") {
                if visibleContacts.isEmpty {
                    Text(searchText.isEmpty ? "Контактов пока нет" : "Ничего не найдено").foregroundStyle(.secondary)
                }
                ForEach(visibleContacts) { c in
                    Button { profileTarget = ProfileTarget(id: c.id) } label: {
                        HStack(spacing: 10) {
                            AvatarView(url: c.avatarURL, title: c.name, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name)
                                Text(store.presence[c.id]?.label ?? (c.phone.map { $0.hasPrefix("+") ? $0 : "+" + $0 } ?? ""))
                                    .font(.caption)
                                    .foregroundStyle(store.presence[c.id]?.isOnline == true ? Color.accentColor : .secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Написать") { store.openDialog(with: c.id); dismiss() }
                        Button("Профиль") { profileTarget = ProfileTarget(id: c.id) }
                        Button("Переименовать…") { renameTarget = c }
                        Button("Удалить из контактов", role: .destructive) {
                            Task { await store.contactAction(c.id, action: "REMOVE") }
                        }
                        Button("Заблокировать", role: .destructive) {
                            Task { await store.contactAction(c.id, action: "BLOCK") }
                        }
                    }
                }
            }

            Section("Чёрный список") {
                if store.blockedContacts.isEmpty {
                    Text("Список пуст")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.blockedContacts) { c in
                    HStack {
                        AvatarView(url: c.avatarURL, title: c.name, size: 28)
                        Text(c.name)
                        Spacer()
                        Button("Разблокировать") {
                            Task { await store.contactAction(c.id, action: "UNBLOCK") }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .searchable(text: $searchText, prompt: "Поиск по контактам")
        .navigationTitle("Контакты")
        .task {
            await store.loadBlacklist()
            await store.loadPresence(visibleContacts.map(\.id))
        }
        .sheet(item: $renameTarget) { c in
            RenameContactSheet(contact: c)
        }
        .sheet(item: $profileTarget) { t in
            NavigationStack {
                UserProfileView(userId: t.id)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { profileTarget = nil } } }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 560)
            #endif
        }
        .sheet(isPresented: $showingImport) { AddressBookImportView() }
    }

    private func find() {
        let phone = newPhone.trimmedForm
        guard phone.filter(\.isNumber).count >= 10 else { return }
        searching = true
        notFound = false
        found = nil
        addResult = nil
        Task {
            let c = await store.findUser(phone: phone)
            searching = false
            found = c
            notFound = c == nil
            newFirst = c?.firstName ?? ""
            newLast = c?.lastName ?? ""
        }
    }

    private func add(_ c: MaxContact) {
        let phone = newPhone.trimmedForm
        let first = newFirst.trimmedForm.isEmpty ? c.firstName : newFirst.trimmedForm
        let last = newLast.trimmedForm
        Task {
            if let added = await store.addContact(phone: phone, firstName: first, lastName: last) {
                addResult = "Добавлен в контакты: \(added.name)"
                found = added
            }
        }
    }
}

/// Two-field rename sheet; saves with contactAction UPDATE.
struct RenameContactSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let contact: MaxContact
    @State private var first: String
    @State private var last: String

    init(contact: MaxContact) {
        self.contact = contact
        _first = State(initialValue: contact.firstName)
        _last = State(initialValue: contact.lastName)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Имя", text: $first)
                TextField("Фамилия", text: $last)
            }
            .navigationTitle("Переименовать")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let f = first.trimmedForm
                        let l = last.trimmedForm
                        let id = contact.id
                        Task { await store.contactAction(id, action: "UPDATE", firstName: f, lastName: l) }
                        dismiss()
                    }
                    .disabled(first.trimmedForm.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 200)
        #endif
    }
}
