import SwiftUI
import RMSMaxCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ChatDetailView: View {
    @EnvironmentObject private var store: AppStore
    let chat: MaxChat

    @State private var draftText = ""
    @State private var replyTarget: MaxMessage?
    @State private var editTarget: MaxMessage?
    @State private var forwardTarget: MaxMessage?
    @State private var complaintTarget: MaxMessage?
    @State private var showingStickers = false
    @State private var showingPinned = false
    @State private var showingChatSearch = false
    @State private var showingTheme = false
    @State private var showingCircle = false
    @ObservedObject private var themes = ChatThemeStore.shared
    @State private var pinIndex = 0
    @State private var showingE2ESettings = false
    @State private var showingInfo = false
    @State private var callSecureByDefault = true
    @State private var highlightedId: String?
    @StateObject private var recorder = VoiceRecorder()
    @AppStorage("voiceFormat") private var voiceFormat = "ogg"

    private var messages: [MaxMessage] {
        store.messagesByChat[chat.id] ?? []
    }

    private var settings: ChatE2ESettings {
        store.chatSettingsByChat[chat.id] ?? ChatE2ESettings()
    }

    private var pendingRequest: PendingE2ERequest? {
        store.pendingE2ERequests[chat.id]
    }

    /// Live chat state (the passed-in `chat` is a snapshot).
    private var liveChat: MaxChat { store.chats.first(where: { $0.id == chat.id }) ?? chat }

    /// «Иван печатает…» / «в сети» / «был(а) 5 мин назад» / «12 участников».
    @ViewBuilder
    private var statusLine: some View {
        let typing = store.typingText(chatId: chat.id)
        let text: String? = typing ?? {
            if liveChat.type == .dialog, let pid = store.dialogPeerId(for: liveChat) {
                return store.contacts[pid]?.isBot == true ? "бот" : store.presence[pid]?.label
            }
            return liveChat.participantsCount.map { liveChat.type == .channel ? "\($0) подписчиков" : "\($0) участников" }
        }()
        if let text {
            Text(text)
                .font(.caption)
                .foregroundStyle(typing != nil || store.presence[store.dialogPeerId(for: liveChat) ?? 0]?.isOnline == true ? Color.accentColor : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.05))
                .animation(.easeInOut(duration: 0.15), value: typing)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let call = liveChat.activeCall, store.activeCall.conversationId != call.conversationId {
                activeCallBanner(call)
            }

            statusLine

            if let pinnedId = liveChat.pinnedMessageId {
                pinnedBar(pinnedId)
            }

            if let req = pendingRequest {
                e2eRequestBanner(req)
            }

            if settings.isActive {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text(chat.type == .chat
                        ? "Групповое E2E активно (\(max(1, settings.groupMembers.count)) уч.)"
                        : "Сквозное шифрование активно")
                        .font(.caption.bold())
                    if let fp = settings.session?.fingerprint {
                        Text(fp)
                            .font(.caption)
                    }
                    Spacer()
                    Button("Настроить") { showingE2ESettings = true }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        historyHeader(proxy: proxy)
                        ForEach(messages) { msg in
                            MessageBubbleView(
                                message: msg,
                                isMe: msg.senderId == store.currentAccount?.userId,
                                senderName: store.contacts[msg.senderId]?.name ?? "Участник",
                                isGroup: chat.type == .chat,
                                stats: store.postStats["\(chat.id)_\(msg.id)"],
                                outgoingColor: themes.theme(for: chat.id).outgoing,
                                showsTicks: chat.type == .dialog,
                                isRead: msg.timeMs <= store.peerReadMark(in: liveChat),
                                onReply: { replyTarget = msg },
                                onReact: { emoji in
                                    Task { await store.toggleReaction(chatId: chat.id, messageId: msg.id, emoji: emoji) }
                                },
                                onDelete: { forAll in
                                    Task { await store.deleteMessage(chatId: chat.id, messageId: msg.id, forEveryone: forAll) }
                                },
                                isPinned: (store.pinnedByChat[chat.id]?.contains { $0.id == msg.id }) ?? (liveChat.pinnedMessageId == msg.id),
                                onPin: {
                                    let already = (store.pinnedByChat[chat.id]?.contains { $0.id == msg.id }) ?? (liveChat.pinnedMessageId == msg.id)
                                    Task { await store.setPinned(chatId: chat.id, messageId: msg.id, pinned: !already) }
                                },
                                onForward: { forwardTarget = msg },
                                onComplain: { complaintTarget = msg },
                                onEdit: {
                                    editTarget = msg
                                    replyTarget = nil
                                    draftText = msg.bodyText
                                }
                            )
                            .id(msg.id)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.yellow.opacity(highlightedId == msg.id ? 0.25 : 0))
                            )
                        }

                        ForEach(store.failedSends[chat.id] ?? []) { item in
                            FailedSendRow(item: item)
                        }
                    }
                    .padding(14)
                }
                // Scroll to bottom only when a newer message arrives, not when older history is prepended.
                .onChange(of: messages.last?.id) { _, newId in
                    guard let newId, store.scrollTargetMessageId == nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newId, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let target = store.scrollTargetMessageId {
                        jump(to: target, proxy: proxy)
                    } else if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: store.scrollTargetMessageId) { _, target in
                    if let target { jump(to: target, proxy: proxy) }
                }
            }
            .background(ChatWallpaper(theme: themes.theme(for: chat.id)))

            Divider()

            if let edit = editTarget {
                HStack {
                    Image(systemName: "pencil").foregroundStyle(.tint)
                    Text("Редактирование: " + edit.bodyText).font(.caption).lineLimit(1)
                    Spacer()
                    Button {
                        editTarget = nil
                        draftText = ""
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
            }

            if let reply = replyTarget {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .foregroundStyle(.tint)
                    Text(reply.displayText)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
            }

            if messages.isEmpty && store.isBotDialog(liveChat) && store.isConnected {
                Button("Начать (/start)") { Task { await store.startBot(chatId: chat.id) } }
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
                    .help("Для диалога с ботом: отправляет команду запуска")
            }

            if recorder.isRecording {
                VoiceRecordingBar(
                    recorder: recorder,
                    encrypted: settings.isActive,
                    onSend: sendVoice,
                    onCancel: { recorder.cancel() }
                )
            } else {
                composeBar
            }
        }
        .navigationTitle(store.resolvedChatTitle(chat))
        .sheet(isPresented: $showingChatSearch) { ChatSearchSheet(chatId: chat.id) }
        .onAppear { restoreDraft() }
        .background {
            Group {
                Button("") { replyToLast() }.keyboardShortcut("r", modifiers: .command)
                Button("") { startRecording() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        #if os(macOS)
        .onExitCommand { if replyTarget != nil { replyTarget = nil } else { store.selectedChatId = nil } }
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingInfo = true
                } label: {
                    Label("Информация", systemImage: "info.circle")
                }
                Button {
                    showingTheme = true
                } label: {
                    Label("Фон чата", systemImage: "paintpalette")
                }
                .help("Фон и цвета чата")
                .popover(isPresented: $showingTheme) { ChatThemePicker(chatId: chat.id) }
                Button {
                    showingChatSearch = true
                } label: {
                    Label("Поиск в чате", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
                .help("Поиск в чате (⌘F)")
                if chat.type != .channel {
                    Button {
                        let peerId = store.dialogPeerId(for: chat)
                        Task { await store.startCall(chatId: chat.id, peerId: peerId, isVideo: false, secure: callSecureByDefault) }
                    } label: {
                        Label("Аудиозвонок", systemImage: "phone.fill")
                    }
                    Button {
                        let peerId = store.dialogPeerId(for: chat)
                        Task { await store.startCall(chatId: chat.id, peerId: peerId, isVideo: true, secure: callSecureByDefault) }
                    } label: {
                        Label("Видеозвонок", systemImage: "video.fill")
                    }
                    Button {
                        showingE2ESettings = true
                    } label: {
                        Label("Шифрование", systemImage: settings.isActive ? "lock.fill" : "lock.open")
                    }
                }
            }
        }
        .sheet(item: $forwardTarget) { msg in
            ForwardSheet(message: msg)
        }
        .sheet(item: $complaintTarget) { msg in
            ComplaintSheet(
                target: store.complaintTarget(forMessageIn: chat),
                ids: Int64(msg.id).map { [$0] } ?? [],
                parentId: chat.id
            )
        }
        .sheet(isPresented: $showingE2ESettings) {
            ChatE2ESettingsSheet(chat: chat)
                #if os(macOS)
                .frame(minWidth: 460, minHeight: 420)
                #endif
        }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                GroupInfoView(chatId: chat.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Готово") { showingInfo = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 600)
            #endif
        }
    }

    /// "A call is running in this chat" — joins via its link, like the official client's banner.
    private func activeCallBanner(_ call: ChatActiveCall) -> some View {
        HStack(spacing: 10) {
            Image(systemName: call.isVideo ? "video.fill" : "phone.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Идёт звонок").font(.subheadline.bold())
                if let n = call.participantsCount, n > 0 {
                    Text("Участников: \(n)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Присоединиться") {
                Task { await store.joinConferenceByLink(call.joinLink, isVideo: false, secure: false) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(store.activeCall.phase != .idle && store.activeCall.phase != .ended)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.12))
    }

    @ViewBuilder
    private func historyHeader(proxy: ScrollViewProxy) -> some View {
        if store.historyExhausted.contains(chat.id) {
            Text("Начало переписки")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
        } else if !messages.isEmpty {
            HStack {
                Spacer()
                if store.loadingOlderHistory.contains(chat.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Загрузить ранее") { loadOlder(proxy: proxy) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .onAppear { loadOlder(proxy: proxy) }
        }
    }

    private func loadOlder(proxy: ScrollViewProxy) {
        let anchorId = messages.first?.id
        Task {
            await store.loadOlderMessages(chatId: chat.id)
            if let anchorId { proxy.scrollTo(anchorId, anchor: .top) }
        }
    }

    private func jump(to messageId: String, proxy: ScrollViewProxy) {
        guard messages.contains(where: { $0.id == messageId }) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(messageId, anchor: .center)
        }
        highlightedId = messageId
        store.scrollTargetMessageId = nil
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { highlightedId = nil }
        }
    }

    private func e2eRequestBanner(_ req: PendingE2ERequest) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(req.isGroup ? "Запрос группового шифрования" : "Запрос секретного чата")
                    .font(.subheadline.bold())
                Text(req.isGroup
                    ? "Участник предлагает защитить переписку в группе (X25519 + ChaCha20-Poly1305)"
                    : "Собеседник предлагает включить E2E шифрование")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Отклонить") {
                Task { await store.respondToPendingE2E(chatId: chat.id, accept: false) }
            }
            .buttonStyle(.bordered)
            Button("Принять") {
                Task { await store.respondToPendingE2E(chatId: chat.id, accept: true) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1))
    }

    private var composeBar: some View {
        HStack(spacing: 10) {
            AttachButton(
                onPicked: { file in
                    let caption = draftText
                    draftText = ""
                    Task {
                        await store.sendAttachment(
                            chatId: chat.id, data: file.data, fileName: file.fileName, mime: file.mime,
                            caption: caption, width: file.width, height: file.height
                        )
                    }
                },
                onError: { store.errorBanner = $0 }
            )
            .disabled(store.isBusy)
            .help(settings.isActive ? "Вложение будет зашифровано" : "Прикрепить файл")

            if store.isBusy {
                ProgressView().controlSize(.small)
            }

            if store.isBotDialog(liveChat) {
                BotCommandsButton(chatId: chat.id) { cmd in
                    Task { await store.sendTextMessage(chatId: chat.id, plaintext: cmd) }
                }
                .buttonStyle(.plain)
                .font(.title3)
            }

            Button { showingStickers.toggle() } label: {
                Image(systemName: "face.smiling").font(.title3)
            }
            .buttonStyle(.plain)
            .help(settings.isActive ? "Эмодзи и стикеры (стикеры отправляются без шифрования)" : "Эмодзи и стикеры")
            .popover(isPresented: $showingStickers) {
                EmojiStickerPanel(
                    onEmoji: { draftText += $0 },
                    onSticker: { sticker in
                        showingStickers = false
                        let reply = replyTarget?.id
                        replyTarget = nil
                        Task { await store.sendSticker(sticker, chatId: chat.id, replyTo: reply) }
                    }
                )
            }

            TextField(
                settings.isActive ? "Зашифрованное сообщение..." : "Сообщение...",
                text: $draftText,
                axis: .vertical
            )
            .lineLimit(1...5)
            .textFieldStyle(.roundedBorder)
            .onSubmit { send() }
            .pasteImageHandler { sendPasted($0) }
            .onChange(of: draftText) { old, new in
                if editTarget == nil { store.setDraft(chatId: chat.id, text: new) }
                if new.count > old.count, !new.trimmingCharacters(in: .whitespaces).isEmpty { store.sendTyping(chatId: chat.id) }
            }

            #if os(iOS)
            if UIPasteboard.general.hasImages {
                Button { if let item = ClipboardImage.read() { sendPasted(item) } } label: {
                    Image(systemName: "doc.on.clipboard").font(.title3)
                }
                .buttonStyle(.plain)
                .help("Вставить изображение из буфера")
            }
            #endif

            if draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { showingCircle = true } label: {
                    Image(systemName: "video.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(store.isBusy)
                .help("Записать видеосообщение (кружок)")
                .sheet(isPresented: $showingCircle) { CircleRecorderSheet(chatId: chat.id) }
                Button {
                    startRecording()
                } label: {
                    Image(systemName: "mic.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(store.isBusy)
                .help("Записать голосовое сообщение")
            } else {
                Button(action: send) {
                    Image(systemName: settings.isActive ? "paperplane.circle.fill" : "paperplane.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
    }

    private func restoreDraft() {
        if draftText.isEmpty, let d = store.drafts[chat.id] { draftText = d }
    }

    private func startRecording() {
        guard !recorder.isRecording, !store.isBusy else { return }
        Task {
            store.sendTyping(chatId: chat.id, kind: "AUDIO")
            do { try await recorder.start() }
            catch { store.errorBanner = error.localizedDescription }
        }
    }

    /// ⌘R: reply to the last incoming message.
    private func replyToLast() {
        if let m = messages.last(where: { $0.senderId != store.currentAccount?.userId }) { replyTarget = m }
    }

    /// Clipboard image -> photo attachment; the current draft goes along as the caption.
    private func sendPasted(_ item: ClipboardImage.Item) {
        let caption = draftText
        draftText = ""
        Task {
            await store.sendAttachment(chatId: chat.id, data: item.data, fileName: item.fileName, mime: item.mime,
                                       caption: caption, width: item.width, height: item.height)
        }
    }

    private func sendVoice() {
        guard let result = recorder.stop(asOgg: voiceFormat == "ogg") else {
            store.errorBanner = "Запись слишком короткая"
            return
        }
        Task {
            await store.sendAttachment(
                chatId: chat.id, data: result.data,
                fileName: result.fileName, mime: result.mime,
                durationMs: result.durationMs, wave: result.wave
            )
        }
    }

    private func send() {
        let text = draftText
        let reply = replyTarget?.id
        draftText = ""
        replyTarget = nil
        if let edit = editTarget {
            editTarget = nil
            Task { await store.editMessage(chatId: chat.id, messageId: edit.id, newText: text) }
            return
        }
        Task { await store.sendTextMessage(chatId: chat.id, plaintext: text, replyToId: reply) }
    }

    private func pinnedBar(_ lastId: String) -> some View {
        let list = store.pinnedByChat[chat.id] ?? []
        let ids = list.isEmpty ? [lastId] : list.map(\.id)
        let idx = min(pinIndex, ids.count - 1)
        let current = ids[idx]
        let msg = list.first { $0.id == current } ?? messages.first { $0.id == current }
        let text = msg?.displayText ?? "Закреплённое сообщение"
        return HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(ids.count > 1 ? "Закреплено \(idx + 1) из \(ids.count)" : "Закреплено").font(.caption.bold()).foregroundStyle(.tint)
                Text(text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).font(.caption).lineLimit(1)
            }
            Spacer()
            if ids.count > 1 {
                Button { showingPinned = true } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(.plain)
                    .help("Все закреплённые")
            }
            Button {
                Task { await store.setPinned(chatId: chat.id, messageId: current, pinned: false); pinIndex = 0 }
            } label: { Image(systemName: "pin.slash") }
            .buttonStyle(.plain)
            .help("Открепить это сообщение")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.06))
        .contentShape(Rectangle())
        .onTapGesture {
            if let msg { Task { await store.openMessage(chatId: chat.id, message: msg) } }
            if ids.count > 1 { pinIndex = (idx + 1) % ids.count } // next tap shows the next pin, like the official client
        }
        .sheet(isPresented: $showingPinned) { PinnedMessagesSheet(chat: liveChat) }
    }
}

/// All pinned messages of a chat: jump to one, unpin one or all (op 241 / 242).
private struct PinnedMessagesSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chat: MaxChat
    @State private var confirmAll = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.pinnedByChat[chat.id] ?? []) { m in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.contacts[m.senderId]?.name ?? "Участник").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(m.displayText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).lineLimit(3)
                        }
                        Spacer()
                        Button { Task { await store.setPinned(chatId: chat.id, messageId: m.id, pinned: false) } } label: { Image(systemName: "pin.slash") }
                            .buttonStyle(.borderless)
                            .help("Открепить")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await store.openMessage(chatId: chat.id, message: m); dismiss() } }
                }
            }
            .navigationTitle("Закреплённые (\(store.pinnedByChat[chat.id]?.count ?? 0))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) { Button("Открепить все…") { confirmAll = true } }
            }
            .confirmationDialog("Открепить все сообщения?", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("Открепить все", role: .destructive) { Task { await store.unpinAll(chatId: chat.id); dismiss() } }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Они будут откреплены для всех участников.") }
        }
        .macSheet(width: 460, height: 460)
    }
}

private struct MessageBubbleView: View {
    @EnvironmentObject private var store: AppStore
    let message: MaxMessage
    let isMe: Bool
    let senderName: String
    let isGroup: Bool
    var stats: PostStats? = nil
    /// Outgoing bubble colour of the chat theme (nil = default look).
    var outgoingColor: Color? = nil
    var showsTicks = false
    var isRead = false
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onDelete: (_ forEveryone: Bool) -> Void
    var isPinned: Bool = false
    var onPin: () -> Void = {}
    var onForward: () -> Void = {}
    var onComplain: () -> Void = {}
    var onEdit: () -> Void = {}
    @State private var showingReactions = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        if let event = message.attaches.first(where: { $0.control != nil })?.control,
           message.bodyText.isEmpty {
            ControlEventText(message: message, event: event)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack {
            if isMe { Spacer(minLength: 60) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if isGroup && !isMe {
                    Text(senderName)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                if let fwd = message.forwardedFromId {
                    Label("Переслано от \(store.contacts[fwd]?.name ?? store.chats.first { $0.id == fwd }.map { store.resolvedChatTitle($0) } ?? "пользователя")",
                          systemImage: "arrowshape.turn.up.right.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .task { await store.ensureContacts([fwd]) }
                }

                ForEach(message.attaches.filter { $0.poll != nil }) { att in
                    PollView(chatId: message.chatId, messageId: message.id, poll: att.poll!)
                }

                MessageAttachmentsView(message: message)
                ContactAndLocationViews(message: message)

                if message.decrypted == nil, store.transcriptionEnabled,
                   let voice = message.attaches.first(where: { $0.kind == .audio }), let mediaId = voice.videoId {
                    TranscriptionView(chatId: message.chatId, messageId: message.id, mediaId: mediaId)
                }

                ForEach(message.attaches.filter { $0.keyboard != nil }) { att in
                    BotKeyboardView(keyboard: att.keyboard!, chatId: message.chatId, messageId: message.id)
                }

                let body = message.bodyText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let share = message.attaches.first(where: { $0.share != nil })?.share
                if !body.isEmpty || (message.attaches.isEmpty && message.decrypted?.media == nil) {
                    Text(linkified(body.isEmpty ? message.displayText : body))
                        .font(.body)
                        .textSelection(.enabled)
                }
                if let link = share?.url ?? firstLink(in: body) {
                    LinkCardView(url: link, share: share)
                }
                CommentsButton(message: message)

                HStack(spacing: 6) {
                    if message.decrypted?.isEncrypted == true {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(message.decrypted?.error == nil ? .green : .red)
                    }
                    if message.edited {
                        Text("изм.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(Self.formatter.string(from: message.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let stats {
                        Label(AppStore.compactCount(stats.views), systemImage: "eye")
                            .font(.caption2).foregroundStyle(.secondary).help("Просмотры")
                        if stats.forwards > 0 {
                            Label(AppStore.compactCount(stats.forwards), systemImage: "arrowshape.turn.up.right")
                                .font(.caption2).foregroundStyle(.secondary).help("Пересылки")
                        }
                    }
                    if isMe && showsTicks {
                        Text(isRead ? "✓✓" : "✓")
                            .font(.caption2.bold())
                            .foregroundStyle(isRead ? Color.accentColor : .secondary)
                            .help(isRead ? "Прочитано" : "Доставлено")
                    }
                }

                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.reactions, id: \.self) { r in
                            Button("\(r.reaction) \(r.count)") {
                                onReact(r.reaction)
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isMe && outgoingColor != nil ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isMe ? (outgoingColor.map { $0.opacity(0.88) } ?? Color.accentColor.opacity(0.18)) : Color.secondary.opacity(0.12))
            )
            .contextMenu {
                Button("Ответить", action: onReply)
                Button("👍") { onReact("👍") }
                Button("❤️") { onReact("❤️") }
                Button("🔥") { onReact("🔥") }
                Button("Копировать") { copyText(message.bodyText) }
                if !message.reactions.isEmpty {
                    Button("Кто отреагировал…") { showingReactions = true }
                }
                Button("Переслать…", action: onForward)
                Button(isPinned ? "Открепить" : "Закрепить", action: onPin)
                if isMe && message.attaches.isEmpty && message.decrypted?.media == nil {
                    Button("Изменить", action: onEdit)
                }
                Divider()
                if !isMe {
                    Button("Пожаловаться…", action: onComplain)
                }
                Button("Удалить у себя", role: .destructive) { onDelete(false) }
                if isMe {
                    Button("Удалить у всех", role: .destructive) { onDelete(true) }
                }
            }

            if !isMe { Spacer(minLength: 60) }
        }
        .sheet(isPresented: $showingReactions) { ReactionsDetailSheet(chatId: message.chatId, messageId: message.id) }
    }
}

private func copyText(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

/// Pick a chat to forward a message to.
private struct ForwardSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let message: MaxMessage
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(store.chats.filter { query.isEmpty || store.resolvedChatTitle($0).localizedCaseInsensitiveContains(query) }) { chat in
                Button {
                    Task {
                        await store.forward(message, to: chat.id)
                        dismiss()
                    }
                } label: {
                    HStack {
                        Text(store.resolvedChatTitle(chat))
                        Spacer()
                        if store.chatSettingsByChat[chat.id]?.isActive == true {
                            Image(systemName: "lock.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Кому переслать")
            .navigationTitle("Переслать")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 460)
        #endif
    }
}

private struct ChatE2ESettingsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chat: MaxChat
    @State private var passwordInput = ""

    private var settings: ChatE2ESettings {
        store.chatSettingsByChat[chat.id] ?? ChatE2ESettings()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(chat.type == .chat ? "Групповое E2E (X25519 + Ed25519)" : "Сквозное шифрование") {
                    HStack {
                        Text("Статус")
                        Spacer()
                        Text(settings.session != nil ? "Активно" : (settings.pending != nil ? "Ожидание ответа" : "Отключено"))
                            .foregroundStyle(settings.session != nil ? .green : .secondary)
                    }

                    if let fp = settings.session?.fingerprint {
                        HStack {
                            Text("Отпечаток ключа")
                            Spacer()
                            Text(fp)
                                .textSelection(.enabled)
                        }
                    }

                    if chat.type == .chat {
                        HStack {
                            Text("Участников с E2E-ключами")
                            Spacer()
                            Text("\(max(settings.groupMembers.count, settings.session != nil ? 1 : 0))")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(settings.session == nil ? "Включить E2E" : "Отключить E2E") {
                        Task { await store.toggleChatE2E(chatId: chat.id) }
                    }
                    .foregroundStyle(settings.session == nil ? Color.accentColor : Color.red)

                    if chat.type == .chat && settings.session != nil {
                        Button("Ротация группового ключа") {
                            Task { await store.initOrRotateGroupE2E(chatId: chat.id, forceRotate: true) }
                        }
                    }
                }

                Section("Дополнительный пароль чата (Argon2id + ChaCha20)") {
                    SecureField("Пароль", text: $passwordInput, prompt: Text("Общий секрет (необязательно)"))
                    Button("Сохранить пароль") {
                        Task { await store.updateChatPassword(chatId: chat.id, password: passwordInput) }
                    }
                }
            }
            .navigationTitle("Шифрование чата")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear {
                passwordInput = settings.password ?? ""
            }
        }
        .macSheet(width: 500, height: 440)
    }
}


/// «Не отправлено»: the message stays on the device until it is sent again or deleted.
private struct FailedSendRow: View {
    @EnvironmentObject private var store: AppStore
    let item: FailedSend
    @State private var retrying = false

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                Text(item.preview).textSelection(.enabled)
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text("Не отправлено").font(.caption.bold()).foregroundStyle(.red)
                }
                Text(item.error).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                HStack {
                    Button("Удалить", role: .destructive) { store.discardFailedSend(item) }
                    Button(retrying ? "Отправляем…" : "Повторить") {
                        retrying = true
                        Task { await store.retryFailedSend(item); retrying = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(retrying)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.red.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.red.opacity(0.4), lineWidth: 1))
        }
    }
}
