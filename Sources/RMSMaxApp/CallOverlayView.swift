import SwiftUI
import Combine
import RMSMaxCore
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
import AVKit
#endif

struct CallOverlayView: View {
    @EnvironmentObject private var store: AppStore
    @State private var now = Date()
    @State private var showChat = false
    @State private var showPeople = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var call: ActiveCallState { store.activeCall }

    /// 1:1 peer video, shown only while they report their camera on (otherwise libwebrtc renders black).
    private var peerVideo: CallVideoTrack? {
        guard !call.isGroup, call.remoteVideoEnabled, let peer = call.participants.first else { return nil }
        return store.callRemoteVideos[peer.id]
    }

    private var subtitle: String {
        switch call.phase {
        case .connecting: return call.isIncoming ? "Подключение…" : "Соединение…"
        case .ringing: return call.isIncoming ? "Входящий звонок" : "Вызов…"
        case .active:
            let secs = max(0, Int(now.timeIntervalSince(call.startedAt ?? now)))
            return String(format: "%02d:%02d", secs / 60, secs % 60)
        case .ended: return call.statusMessage ?? "Звонок завершён"
        case .idle: return ""
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.11, blue: 0.18), Color(red: 0.04, green: 0.06, blue: 0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let peerVideo, call.phase != .ended {
                CallVideoView(track: peerVideo)
                    .ignoresSafeArea()
                LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack(spacing: 20) {
                header
                if call.isGroup && call.phase != .ended {
                    participantGrid
                    titleBlock
                } else {
                    Spacer()
                    if peerVideo == nil { avatar }
                    titleBlock
                    Spacer()
                }
                if call.phase != .ended && !(call.isIncoming && call.phase == .ringing) {
                    secondaryControls
                }
                controls
                    .padding(.bottom, 36)
            }

            if let local = store.callLocalVideo, call.cameraEnabled, call.phase != .ended {
                VStack {
                    HStack {
                        Spacer()
                        CallVideoView(track: local, mirrored: true)
                            .frame(width: 120, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.35), lineWidth: 1))
                            .shadow(radius: 8)
                    }
                    Spacer()
                }
                .padding(.top, 64)
                .padding(.trailing, 16)
            }
        }
        .onReceive(timer) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(call.isGroup ? "Групповой звонок" : (call.isVideo ? "Видеозвонок" : "Аудиозвонок"),
                  systemImage: call.isGroup ? "person.3.fill" : (call.isVideo ? "video.fill" : "phone.fill"))
                .font(.subheadline.bold())
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if call.topology == "SERVER" && call.phase != .ended {
                badge("Через сервер", icon: "server.rack")
                    .help("Медиа идёт через сервер звонков MAX: прямое соединение недоступно или это групповой звонок")
            }
            if call.secureStatus == .active {
                badge("E2E", icon: "lock.fill")
                    .help("Звук и видео зашифрованы между двумя RMS MAKS. Сверьте код с собеседником.")
            } else if call.secureStatus == .pending {
                badge("E2E…", icon: "lock.open")
            }
            badge("Без телеметрии", icon: "eye.slash")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private func badge(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.15)))
            .foregroundStyle(.white)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(call.phase == .ringing ? 0.35 : 0.25))
                .frame(width: 112, height: 112)
            Image(systemName: "person.fill")
                .font(.system(size: 46))
                .foregroundStyle(.white)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 8) {
            Text(call.peerName)
                .font(call.isGroup ? .headline : .title.bold())
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            if call.secureStatus == .active, let fp = call.fingerprint {
                Text("Код сверки: \(fp)")
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.22)))
                    .foregroundStyle(.green)
            }
            if !call.isGroup && call.phase == .active && call.remoteMuted {
                Label("Собеседник выключил микрофон", systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if call.phase != .ended, let note = call.statusMessage {
                Text(note)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 32)
            }
            if call.phase != .ended {
                Button {
                    Task { if let link = await store.fetchCallInviteLink() { copyToClipboard(link) } }
                } label: {
                    Label(call.inviteLink == nil ? "Пригласить по ссылке" : "Скопировать ссылку", systemImage: "link").font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
    }

    private var participantGrid: some View {
        let people = call.participants
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: people.count <= 1 ? 1 : (people.count <= 4 ? 2 : 3))
        return ScrollView {
            if people.isEmpty {
                Text("Ждём участников…")
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 60)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(people) { p in
                    ParticipantTile(info: p, video: p.videoEnabled ? store.callRemoteVideos[p.id] : nil)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if call.phase == .ended {
            EmptyView()
        } else if call.isIncoming && call.phase == .ringing {
            HStack(spacing: call.isVideo ? 40 : 64) {
                callButton(icon: "phone.down.fill", label: "Отклонить", tint: .red) {
                    Task { await store.declineIncomingCall() }
                }
                callButton(icon: "phone.fill", label: call.isVideo ? "Голосом" : "Ответить", tint: .green) {
                    Task { await store.acceptIncomingCall(withVideo: false) }
                }
                if call.isVideo {
                    callButton(icon: "video.fill", label: "С видео", tint: .green) {
                        Task { await store.acceptIncomingCall(withVideo: true) }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        } else {
            HStack(spacing: 24) {
                callButton(
                    icon: call.cameraEnabled ? "video.fill" : "video.slash.fill",
                    label: call.cameraEnabled ? "Камера" : "Вкл. камеру",
                    tint: call.cameraEnabled ? .white.opacity(0.35) : .white.opacity(0.2)
                ) {
                    Task { await store.toggleCallCamera() }
                }
                #if os(iOS)
                if call.cameraEnabled {
                    callButton(icon: "arrow.triangle.2.circlepath.camera", label: "Перевернуть", tint: .white.opacity(0.2)) {
                        Task { await store.switchCallCamera() }
                    }
                }
                callButton(
                    icon: call.speakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                    label: "Динамик",
                    tint: call.speakerOn ? .white.opacity(0.35) : .white.opacity(0.2)
                ) {
                    store.toggleSpeaker()
                }
                VStack(spacing: 6) {
                    RoutePicker()
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color.white.opacity(0.2)))
                    Text("Звук").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                #else
                DevicesMenu {
                    Task { await store.reselectCamera() }
                }
                #endif
                callButton(
                    icon: call.isMuted ? "mic.slash.fill" : "mic.fill",
                    label: call.isMuted ? "Вкл. микр." : "Без звука",
                    tint: call.isMuted ? .orange : .white.opacity(0.2)
                ) {
                    store.toggleCallMute()
                }
                callButton(icon: "phone.down.fill", label: call.isGroup ? "Выйти" : "Завершить", tint: .red) {
                    Task { await store.hangupCall() }
                }
            }
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 18) {
            smallButton(call.handRaised ? "hand.raised.fill" : "hand.raised", call.handRaised ? "Опустить" : "Рука", active: call.handRaised) {
                Task { await store.toggleHand() }
            }
            smallButton("bubble.left.and.bubble.right", call.unreadChat > 0 ? "Чат (\(call.unreadChat))" : "Чат", active: call.unreadChat > 0) {
                showChat = true
            }
            smallButton("person.2", "Участники", active: false) { showPeople = true }
            #if os(macOS)
            smallButton(call.sharingScreen ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle", call.sharingScreen ? "Остановить показ" : "Экран", active: call.sharingScreen) {
                Task { await store.toggleScreenShare() }
            }
            #endif
            if call.recording {
                Label("Запись", systemImage: "record.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $showChat) {
            NavigationStack {
                CallChatPanel().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { showChat = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
            #endif
        }
        .sheet(isPresented: $showPeople) {
            NavigationStack {
                CallParticipantsPanel().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { showPeople = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 500)
            #endif
        }
    }

    private func smallButton(_ icon: String, _ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(active ? Color.orange.opacity(0.5) : Color.white.opacity(0.15)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func callButton(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(tint))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

#if os(iOS)
/// System audio route picker (Bluetooth, AirPods, speaker, receiver).
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemGreen
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
/// Microphone / speaker / camera choice on the Mac (switched inside WebRTC, system defaults untouched).
private struct DevicesMenu: View {
    let onCameraChanged: () -> Void
    @State private var refresh = 0

    var body: some View {
        VStack(spacing: 6) {
            Menu {
                Section("Микрофон") {
                    ForEach(CallDevices.microphones()) { d in
                        Button { CallDevices.selectMicrophone(d.id); refresh += 1 } label: { label(d) }
                    }
                }
                Section("Динамики") {
                    ForEach(CallDevices.speakers()) { d in
                        Button { CallDevices.selectSpeaker(d.id); refresh += 1 } label: { label(d) }
                    }
                }
                Section("Камера") {
                    ForEach(CallDevices.cameras()) { d in
                        Button {
                            CallDevices.preferredCameraId = d.id
                            refresh += 1
                            onCameraChanged()
                        } label: { label(d) }
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(Color.white.opacity(0.2)))
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 58, height: 58)
            .id(refresh)
            Text("Устройства").font(.caption).foregroundStyle(.white.opacity(0.85))
        }
    }

    private func label(_ d: CallDevice) -> some View {
        if d.isDefault { return AnyView(Label(d.name, systemImage: "checkmark")) }
        return AnyView(Text(d.name))
    }
}
#endif

private struct ParticipantTile: View {
    let info: CallParticipantInfo
    let video: CallVideoTrack?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08))
            if let video {
                CallVideoView(track: video)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "person.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.8))
                    if !info.joined {
                        Text("Вызов…").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 4) {
                if info.handRaised { Image(systemName: "hand.raised.fill").font(.caption2).foregroundStyle(.orange) }
                if !info.audioEnabled { Image(systemName: "mic.slash.fill").font(.caption2) }
                Text(info.name).font(.caption.bold()).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.45)))
            .foregroundStyle(.white)
            .padding(8)
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(info.speaking ? Color.green : .clear, lineWidth: 3)
        )
    }
}
