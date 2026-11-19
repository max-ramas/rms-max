import SwiftUI
import RMSMaxCore

struct CallHistoryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true

    var body: some View {
        List {
            if loading && store.callHistory.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if store.callHistory.isEmpty {
                Text("Звонков пока не было").foregroundStyle(.secondary)
            }
            ForEach(store.callHistory) { item in
                row(item)
                    .contextMenu {
                        Button("Позвонить") { Task { dismiss(); await store.callBack(item, video: false) } }
                        Button("Видеозвонок") { Task { dismiss(); await store.callBack(item, video: true) } }
                        Button("Удалить из истории", role: .destructive) { Task { await store.deleteCallHistory([item.id]) } }
                    }
            }
            .onDelete { idx in
                let ids = idx.map { store.callHistory[$0].id }
                Task { await store.deleteCallHistory(ids) }
            }
        }
        .navigationTitle("Звонки")
        .task {
            await store.loadCallHistory()
            loading = false
        }
    }

    private func row(_ item: CallHistoryItem) -> some View {
        let outgoing = item.callerId == store.currentAccount?.userId
        let chat = store.chats.first(where: { $0.id == item.chatId })
        let title = item.callName ?? chat.map { store.resolvedChatTitle($0) } ?? store.contacts[item.callerId]?.name ?? "Звонок"
        return HStack(spacing: 12) {
            Image(systemName: item.isMissed ? "phone.arrow.down.left.fill" : (outgoing ? "phone.arrow.up.right.fill" : "phone.arrow.down.left"))
                .foregroundStyle(item.isMissed ? .red : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(item.isMissed ? .red : .primary)
                Text(subtitle(item, outgoing: outgoing)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { dismiss(); await store.callBack(item, video: item.isVideo) }
            } label: {
                Image(systemName: item.isVideo ? "video" : "phone")
            }
            .buttonStyle(.borderless)
            .help("Перезвонить")
        }
    }

    private func subtitle(_ item: CallHistoryItem, outgoing: Bool) -> String {
        let date = Date(timeIntervalSince1970: Double(item.time) / 1000)
        let when = date.formatted(date: .abbreviated, time: .shortened)
        let kind: String
        switch item.hangupType {
        case "MISSED": kind = "Пропущенный"
        case "REJECTED": kind = outgoing ? "Отклонён" : "Отклонён вами"
        case "CANCELED": kind = "Отменён"
        default:
            let s = Int(item.durationMs / 1000)
            kind = (outgoing ? "Исходящий" : "Входящий") + (s > 0 ? String(format: " · %d:%02d", s / 60, s % 60) : "")
        }
        return (item.isGroup ? "Групповой · " : "") + kind + " · " + when
    }
}
