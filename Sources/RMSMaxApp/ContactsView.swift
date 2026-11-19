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

    @State private var searchText = ""
    @State private var newPhone = ""
    @State private var newFirst = ""
    @State private var newLast = ""
    @State private var addResult: String?
    @State private var renameTarget: MaxContact?

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
            Section("Добавить контакт") {
                TextField("Телефон (например, +79001234567)", text: $newPhone)
                TextField("Имя", text: $newFirst)
                TextField("Фамилия", text: $newLast)
                Button("Добавить") {
                    let phone = newPhone.trimmedForm
                    let first = newFirst.trimmedForm
                    let last = newLast.trimmedForm
                    Task {
                        if let c = await store.addContact(phone: phone, firstName: first, lastName: last) {
                            addResult = "Добавлен: \(c.name)"
                            newPhone = ""
                            newFirst = ""
                            newLast = ""
                        }
                    }
                }
                .disabled(newPhone.trimmedForm.isEmpty)
                if let addResult {
                    Text(addResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Контакты") {
                ForEach(visibleContacts) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name)
                        if let phone = c.phone {
                            Text(phone)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
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
        .searchable(text: $searchText, prompt: "Поиск контактов")
        .navigationTitle("Контакты")
        .task { await store.loadBlacklist() }
        .sheet(item: $renameTarget) { c in
            RenameContactSheet(contact: c)
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
