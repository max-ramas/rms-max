import SwiftUI
import Contacts
import RMSMaxCore

/// Address-book import, user-driven: the device contacts are read locally; only the numbers the user ticks
/// are looked up on the MAX server (op 46, one by one), and found users can be added (op 41).
struct AddressBookImportView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    struct Entry: Identifiable, Hashable {
        let id: String // phone digits
        let name: String
        let phone: String
    }

    enum Lookup: Equatable { case pending, notFound, found(Int64), added(Int64) }

    @State private var entries: [Entry] = []
    @State private var selected: Set<String> = []
    @State private var results: [String: Lookup] = [:]
    @State private var denied = false
    @State private var running = false
    @State private var query = ""

    private var filtered: [Entry] {
        let q = query.lowercased()
        return q.isEmpty ? entries : entries.filter { $0.name.lowercased().contains(q) || $0.phone.contains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if denied {
                    ContentUnavailableView("Нет доступа к контактам",
                                           systemImage: "person.crop.circle.badge.xmark",
                                           description: Text("Разрешите доступ в Системных настройках → Конфиденциальность → Контакты."))
                } else {
                    List(filtered) { e in
                        HStack {
                            Button {
                                if selected.contains(e.id) { selected.remove(e.id) } else { selected.insert(e.id) }
                            } label: {
                                Image(systemName: selected.contains(e.id) ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(results[e.id] != nil)
                            VStack(alignment: .leading) {
                                Text(e.name)
                                Text(e.phone).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            status(e)
                        }
                    }
                    .searchable(text: $query, prompt: "Поиск в адресной книге")
                }
            }
            .navigationTitle("Адресная книга")
            .safeAreaInset(edge: .bottom) {
                Text("Номера отправляются на сервер MAX только для отмеченных контактов — как при поиске по номеру вручную.")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(running ? "Проверяем…" : "Найти в MAX (\(selected.count))") { Task { await lookup() } }
                        .disabled(selected.isEmpty || running)
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    @ViewBuilder
    private func status(_ e: Entry) -> some View {
        switch results[e.id] {
        case .pending: ProgressView().controlSize(.small)
        case .notFound: Text("нет в MAX").font(.caption).foregroundStyle(.secondary)
        case .found(let id):
            HStack {
                Button("Написать") { store.openDialog(with: id); dismiss() }.buttonStyle(.borderless)
                Button("Добавить") {
                    Task {
                        let parts = e.name.split(separator: " ", maxSplits: 1).map(String.init)
                        if await store.addContact(phone: e.id, firstName: parts.first ?? e.name, lastName: parts.count > 1 ? parts[1] : "") != nil {
                            results[e.id] = .added(id)
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
        case .added: Label("в контактах", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
        case nil: EmptyView()
        }
    }

    private func load() async {
        let store = CNContactStore()
        let granted: Bool
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: granted = true
        case .notDetermined: granted = (try? await store.requestAccess(for: .contacts)) ?? false
        default: granted = (CNContactStore.authorizationStatus(for: .contacts).rawValue == 4) // .limited (iOS 18)
        }
        guard granted else { denied = true; return }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let list: [Entry] = await Task.detached {
            var out: [Entry] = []
            var seen = Set<String>()
            let req = CNContactFetchRequest(keysToFetch: keys)
            try? store.enumerateContacts(with: req) { c, _ in
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                for num in c.phoneNumbers {
                    let raw = num.value.stringValue
                    var digits = raw.filter(\.isNumber)
                    if digits.count == 11, digits.hasPrefix("8") { digits = "7" + digits.dropFirst() }
                    if digits.count == 10 { digits = "7" + digits }
                    guard digits.count >= 11, seen.insert(digits).inserted else { continue }
                    out.append(Entry(id: digits, name: name.isEmpty ? raw : name, phone: "+" + digits))
                }
            }
            return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
        entries = list
    }

    private func lookup() async {
        running = true
        defer { running = false }
        for id in selected where results[id] == nil {
            results[id] = .pending
            if let c = await store.findUser(phone: id) {
                results[id] = c.isInContacts == true ? .added(c.id) : .found(c.id)
            } else {
                results[id] = .notFound
            }
            try? await Task.sleep(nanoseconds: 400_000_000) // gentle pacing, like a person typing numbers
        }
        selected.removeAll()
    }
}
