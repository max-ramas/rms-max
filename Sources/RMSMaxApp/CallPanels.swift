// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

/// In-call chat (official calls platform chat: everyone in the call sees it).
struct CallChatPanel: View {
    @EnvironmentObject private var store: AppStore
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(store.activeCall.chat) { m in
                    VStack(alignment: m.mine ? .trailing : .leading, spacing: 2) {
                        Text(m.senderName + (m.direct ? " · лично" : "")).font(.caption).foregroundStyle(.secondary)
                        Text(m.text)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(m.mine ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
                    }
                    .frame(maxWidth: .infinity, alignment: m.mine ? .trailing : .leading)
                    .id(m.id)
                }
                .onChange(of: store.activeCall.chat.count) { _, _ in
                    if let last = store.activeCall.chat.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    store.markCallChatRead()
                }
            }
            HStack {
                TextField("Сообщение участникам", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .navigationTitle("Чат звонка")
        .task {
            store.markCallChatRead()
            await store.loadCallChatHistory()
        }
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await store.sendCallChat(text) }
    }
}

/// Participants with admin tools; waiting hall and recording for admins.
struct CallParticipantsPanel: View {
    @EnvironmentObject private var store: AppStore

    private var call: ActiveCallState { store.activeCall }

    var body: some View {
        List {
            if call.isAdmin {
                Section("Управление звонком") {
                    Button { Task { await store.adminMuteAll() } } label: { Label("Выключить микрофоны всем", systemImage: "mic.slash") }
                    Button { Task { await store.adminLowerAllHands() } } label: { Label("Опустить все руки", systemImage: "hand.raised.slash") }
                    Toggle(isOn: Binding(
                        get: { call.options.contains("WAITING_HALL") },
                        set: { on in Task { await store.setWaitingHall(on) } }
                    )) { Label("Зал ожидания", systemImage: "person.badge.clock") }
                    Button { Task { await store.toggleRecording() } } label: {
                        Label(call.recording ? "Остановить запись" : "Записать звонок", systemImage: call.recording ? "stop.circle" : "record.circle")
                    }
                }
                if call.options.contains("WAITING_HALL") {
                    Section("Ждут входа") {
                        if call.waitingHall.isEmpty { Text("Никого").foregroundStyle(.secondary) }
                        ForEach(call.waitingHall) { p in
                            HStack {
                                Text(p.name)
                                Spacer()
                                Button("Впустить") { Task { await store.admitFromWaitingHall(p.id) } }
                            }
                        }
                        if call.waitingHall.count > 1 {
                            Button("Впустить всех") { Task { await store.admitFromWaitingHall(nil) } }
                        }
                    }
                }
            }
            Section("Участники (\(call.participants.count + 1))") {
                HStack {
                    Text("Вы").bold()
                    if call.isAdmin { badge("админ") }
                    Spacer()
                    if call.handRaised { Image(systemName: "hand.raised.fill").foregroundStyle(.orange) }
                    Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill").foregroundStyle(.secondary)
                }
                ForEach(call.participants) { p in
                    HStack {
                        Text(p.name)
                        if p.isAdmin { badge("админ") }
                        if !p.joined { Text("вызов…").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if p.handRaised { Image(systemName: "hand.raised.fill").foregroundStyle(.orange) }
                        Image(systemName: p.audioEnabled ? "mic.fill" : "mic.slash.fill").foregroundStyle(.secondary)
                        if call.isAdmin {
                            Menu {
                                Button("Выключить микрофон") { Task { await store.adminMute(p.id) } }
                                Button("Выключить камеру") { Task { await store.adminMute(p.id, media: "VIDEO") } }
                                Button(p.isAdmin ? "Снять админа" : "Сделать админом") { Task { await store.adminSetAdmin(p.id, !p.isAdmin) } }
                                Button("Удалить из звонка", role: .destructive) { Task { await store.adminRemove(p.id) } }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .navigationTitle("Участники")
        .task { if call.isAdmin { await store.loadWaitingHall() } }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
    }
}
