import SwiftUI
import RMSMaxCore

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var newBlockedDomain = ""
    @AppStorage("voiceFormat") private var voiceFormat = "ogg"
    @State private var notifEnabled = NotificationService.shared.notificationsEnabled
    @State private var notifPreview = NotificationService.shared.showPreview
    @State private var notifSound = NotificationService.shared.soundEnabled

    var body: some View {
        Form {
            if let acc = store.currentAccount {
                Section("Профиль") {
                    LabeledContent("Имя", value: acc.displayName)
                    if let phone = acc.phone {
                        LabeledContent("Телефон", value: phone)
                    }
                    LabeledContent("Транспорт", value: acc.useMobileTransport ? "Mobile TLS (api2.oneme.ru)" : "WebSocket")
                    NavigationLink("Редактировать профиль") { ProfileEditView() }
                }

                Section("Приватность и телеметрия") {
                    LabeledContent("Телеметрия Max", value: "Отключена (\(store.telemetryMode))")
                    LabeledContent("Сбор IP / system trace", value: "Заблокирован")
                    Toggle("Блокировка по Face ID / Touch ID", isOn: Binding(
                        get: { acc.biometricLockEnabled },
                        set: { store.toggleBiometrics($0) }
                    ))
                }
            }

            Section("Блокировщик трекеров мини-приложений") {
                ForEach(store.customBlockedDomains, id: \.self) { domain in
                    HStack {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.orange)
                        Text(domain)
                            .font(.callout.monospaced())
                    }
                }
                HStack {
                    TextField("Добавить домен (например, metrics.example.ru)", text: $newBlockedDomain)
                    Button("Добавить") {
                        let d = newBlockedDomain.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !d.isEmpty && !store.customBlockedDomains.contains(d) {
                            store.customBlockedDomains.append(d)
                        }
                        newBlockedDomain = ""
                    }
                    .disabled(newBlockedDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section {
                Picker("Формат голосовых", selection: $voiceFormat) {
                    Text("Ogg/Opus (как Android и ПК)").tag("ogg")
                    Text("AAC/M4A (как Safari)").tag("m4a")
                }
            } header: {
                Text("Голосовые сообщения")
            } footer: {
                Text("Оба формата официальный клиент принимает. Ogg/Opus загружается напрямую; M4A сервер перекодирует сам.")
            }

            #if os(iOS)
            Section {
                Toggle("Принимать звонки в фоне", isOn: Binding(
                    get: { BackgroundKeepAlive.isEnabled },
                    set: { BackgroundKeepAlive.isEnabled = $0 }
                ))
            } header: {
                Text("Звонки")
            } footer: {
                Text("Приложение остаётся активным в фоне, чтобы входящие звонки доходили. Расходует заряд батареи. Без этого звонки приходят, только пока RMS MAKS открыт: системные VoIP-пуши MAX доступны лишь официальному приложению.")
            }
            #endif

            Section {
                Toggle("Расшифровка голосовых", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: AppStore.transcriptionSettingKey) },
                    set: { UserDefaults.standard.set($0, forKey: AppStore.transcriptionSettingKey); store.objectWillChange.send() }
                ))
            } header: {
                Text("Голосовые сообщения")
            } footer: {
                Text("Речь распознаёт сервер MAX — только по нажатию «Расшифровать». Для зашифрованных (E2E) голосовых недоступно.")
            }

            Section("Уведомления (macOS / iOS)") {
                Toggle("Показывать уведомления", isOn: $notifEnabled)
                    .onChange(of: notifEnabled) { _, v in NotificationService.shared.notificationsEnabled = v }
                Toggle("Показывать расшифрованный текст", isOn: $notifPreview)
                    .onChange(of: notifPreview) { _, v in NotificationService.shared.showPreview = v }
                Toggle("Звук уведомлений", isOn: $notifSound)
                    .onChange(of: notifSound) { _, v in NotificationService.shared.soundEnabled = v }
            }

            Section("Активные сессии") {
                Button("Обновить список сессий") {
                    Task { await store.refreshSessions() }
                }
                ForEach(store.sessions) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.client + (s.current ? " (текущая)" : ""))
                                .font(.headline)
                            Text(s.location.isEmpty ? s.info : s.location)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                if store.sessions.count > 1 {
                    Button("Завершить все остальные сессии", role: .destructive) {
                        Task { await store.closeOtherSessions() }
                    }
                }
            }

            Section {
                Button("Выйти из аккаунта", role: .destructive) {
                    Task { await store.logout() }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Настройки RMS MAKS")
        .task {
            if store.isConnected {
                await store.refreshSessions()
            }
        }
    }
}
