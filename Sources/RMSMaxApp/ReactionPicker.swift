import SwiftUI
import RMSMaxCore

/// Reaction bar like Telegram's: the first ones in a row, a chevron opens the full set. The chat's allowed reactions
/// (op 258) are used when the server names them, otherwise the standard set plus any emoji from the catalogue.
struct ReactionPicker: View {
    @EnvironmentObject private var store: AppStore
    let chatId: Int64
    let current: String?
    let onPick: (String) -> Void
    @State private var expanded = false

    private var main: [String] { store.availableReactions(chatId: chatId) }
    private var extra: [String] {
        guard store.chatReactions[chatId]?.ids.isEmpty != false else { return [] }   // a restricted chat offers only its own set
        let mainSet = Set(main)
        return (EmojiCatalog.categories.first { $0.id == "smileys" }?.emoji ?? []).filter { !mainSet.contains($0) }
            + (EmojiCatalog.categories.first { $0.id == "people" }?.emoji ?? []).prefix(30)
    }
    private let columns = Array(repeating: GridItem(.flexible(minimum: 30), spacing: 2), count: 8)

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(main.prefix(expanded ? 0 : 8), id: \.self) { e in button(e) }
                if !expanded && (main.count > 8 || !extra.isEmpty) {
                    Button { withAnimation(.easeOut(duration: 0.15)) { expanded = true } } label: {
                        Image(systemName: "chevron.down.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Все реакции")
                }
            }
            if expanded {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(main + extra, id: \.self) { e in button(e) }
                    }
                }
                .frame(width: 300, height: 220)
            }
        }
        .padding(10)
    }

    private func button(_ e: String) -> some View {
        Button { onPick(e) } label: {
            Text(e).font(.system(size: 26))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(e == current ? Color.accentColor.opacity(0.3) : .clear))
        }
        .buttonStyle(.plain)
    }
}
