import SwiftUI
import RMSMaxCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Inline keyboard under a bot message.
struct BotKeyboardView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL
    let keyboard: BotKeyboard
    let chatId: Int64
    var messageId: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(keyboard.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(row) { b in
                        Button {
                            Task {
                                switch await store.pressBotButton(b, keyboard: keyboard, chatId: chatId, messageId: messageId) {
                                case .openURL(let url): openURL(url)
                                case .copy(let text): copy(text)
                                case .unsupported(let why): store.errorBanner = why
                                case .done: break
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(b.text).lineLimit(1)
                                if b.type == "LINK" { Image(systemName: "arrow.up.right.square").font(.caption2) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: 320)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// "Расшифровать" under a voice message (opt-in; recognition happens on the MAX server).
struct TranscriptionView: View {
    @EnvironmentObject private var store: AppStore
    let chatId: Int64
    let messageId: String
    let mediaId: Int64

    var body: some View {
        let key = "\(chatId):\(messageId)"
        if let text = store.transcriptions[key] {
            Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        } else {
            Button("Расшифровать") {
                Task { await store.requestTranscription(chatId: chatId, messageId: messageId, mediaId: mediaId) }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }
}

/// Open a MAX link to a channel, group or person: preview, then join.
struct JoinByLinkSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var initialLink: String = ""
    @State private var link = ""
    @State private var preview: AppStore.LinkPreview?
    @State private var checking = false
    @State private var notFound = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Ссылка", text: $link, prompt: Text("https://max.ru/…"))
                    .onSubmit(check)
                Button("Проверить", action: check).disabled(link.isEmpty || checking)
                if notFound { Text("По ссылке ничего не найдено").foregroundStyle(.secondary) }
                if let p = preview {
                    Section {
                        Label(p.title, systemImage: p.isChannel ? "megaphone" : (p.userId != nil ? "person" : "person.3"))
                        if let n = p.participants { Text(p.isChannel ? "Подписчиков: \(n)" : "Участников: \(n)").foregroundStyle(.secondary) }
                        if p.alreadyMember, let id = p.chatId {
                            Button("Открыть") { store.selectedChatId = id; dismiss() }
                        } else if p.chatId != nil {
                            Button(p.isChannel ? "Подписаться" : "Вступить") {
                                Task { await store.joinByLink(link); dismiss() }
                            }
                        } else if let uid = p.userId {
                            Button("Написать") { store.openDialog(with: uid); dismiss() }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Открыть ссылку")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
            .onAppear {
                if !initialLink.isEmpty && link.isEmpty { link = initialLink; check() }
            }
        }
        .macSheet(width: 460, height: 340)
    }

    private func check() {
        checking = true
        notFound = false
        Task {
            preview = await store.resolveLink(link)
            notFound = preview == nil
            checking = false
        }
    }
}
