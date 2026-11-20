import SwiftUI
import RMSMaxCore

/// ⌘K: type a name, Enter opens the first match, arrows/click pick another one.
struct QuickSwitcherSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Int64?

    private var results: [MaxChat] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = store.chats.sorted { $0.lastEventTime > $1.lastEventTime }
        guard !q.isEmpty else { return Array(sorted.prefix(12)) }
        return sorted.filter { store.resolvedChatTitle($0).lowercased().contains(q) }.prefix(30).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("", text: $query, prompt: Text("Куда перейти? Введите имя или название"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit { open(selection ?? results.first?.id) }
            Divider()
            List(selection: $selection) {
                ForEach(results) { chat in
                    HStack(spacing: 10) {
                        AvatarView(url: store.avatarURL(for: chat), title: store.resolvedChatTitle(chat),
                                   symbol: store.avatarURL(for: chat) == nil && chat.type != .dialog ? "person.3.fill" : nil, size: 30)
                        Text(store.resolvedChatTitle(chat)).lineLimit(1)
                        Spacer()
                        if chat.newMessages > 0 { Text("\(chat.newMessages)").font(.caption2.bold()).foregroundStyle(.secondary) }
                    }
                    .tag(chat.id)
                    .contentShape(Rectangle())
                    .onTapGesture { open(chat.id) }
                }
                if results.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary) }
            }
            .listStyle(.plain)
        }
        .macSheet(width: 460, height: 420)
        .onChange(of: query) { _, _ in selection = results.first?.id }
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
    }

    private func open(_ id: Int64?) {
        guard let id else { return }
        store.selectedChatId = id
        dismiss()
    }
}
