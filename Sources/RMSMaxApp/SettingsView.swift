// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var newBlockedDomain = ""
    @State private var showingProfileEdit = false
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("youtubePreviews") private var youtubePreviews = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("voiceFormat") private var voiceFormat = "ogg"
    @State private var showingMyPhotos = false
    @State private var showingTwoFactor = false
    @AppStorage("rmsmaks.sendKey") private var sendKey = "return"
    @State private var callSounds = CallSounds.shared.enabled
    @State private var notifTestResult: String?
    @State private var notifEnabled = NotificationService.shared.notificationsEnabled
    @State private var notifPreview = NotificationService.shared.showPreview
    @State private var notifSound = NotificationService.shared.soundEnabled

    /// 79001234567 → +7 900 123 4567.
    static func formattedPhone(_ raw: String) -> String {
        let d = raw.filter(\.isNumber)
        guard d.count == 11, d.first == "7" else { return raw.hasPrefix("+") ? raw : "+" + d }
        let c = Array(d)
        return "+7 \(String(c[1...3])) \(String(c[4...6])) \(String(c[7...10]))"
    }

    var body: some View {
        Form {
            if let acc = store.currentAccount {
                Section("Профиль") {
                    VStack(spacing: 6) {
                        AvatarView(url: acc.userId.flatMap { store.contacts[$0] }?.avatarURL, title: acc.displayName, size: 96)
                            .onTapGesture { if acc.userId.flatMap { store.contacts[$0] }?.avatarURL != nil { showingMyPhotos = true } }
                        Text(acc.displayName).font(.title3.weight(.semibold))
                        if store.isConnected { Text("в сети").foregroundStyle(Color.accentColor) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    LabeledContent("Имя", value: acc.displayName)
                    if let phone = acc.phone {
                        LabeledContent("Телефон", value: Self.formattedPhone(phone))
                    }
                    if let about = acc.userId.flatMap { store.contacts[$0] }?.description, !about.isEmpty {
                        LabeledContent("О себе") { Text(about).multilineTextAlignment(.trailing) }
                    }
                    if let link = acc.userId.flatMap { store.contacts[$0] }?.link, !link.isEmpty {
                        LabeledContent("Ссылка", value: link)
                    }
                    if let uid = acc.userId { LabeledContent("ID", value: String(uid)) }
                    #if os(macOS)
                    Toggle("Значок в строке меню", isOn: $showMenuBarExtra)
                    #endif
                    LabeledContent("Клиент для сервера", value: acc.identity.isDesktop
                                   ? "MAX для компьютера \(acc.identity.userAgent.appVersion)"
                                   : "MAX для Android \(acc.identity.userAgent.appVersion)")
                    if !acc.identity.isDesktop {
                        Button("Перейти на клиент для компьютера…") { Task { await store.switchToDesktopClient() } }
                            .help("Нужно будет ввести код из SMS. Открывает истории, ссылки-приглашения и историю звонков в полном объёме.")
                    }
                    LabeledContent("Транспорт", value: acc.useMobileTransport ? "Mobile TLS (api2.oneme.ru)" : "WebSocket")
                    Button("Редактировать профиль…") { showingProfileEdit = true }
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
                    TextField("", text: $newBlockedDomain, prompt: Text("Домен, например metrics.example.ru"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
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

            Section {
                Toggle("Сообщать, что я печатаю", isOn: Binding(get: { store.sendsTyping }, set: { store.sendsTyping = $0 }))
            } header: {
                Text("Приватность чатов")
            } footer: {
                Text("Собеседник видит «печатает…», пока вы набираете текст. Если выключить, ничего не отправляется (как у официального клиента при скрытом статусе).")
            }

            Section {
                Toggle("Превью видео YouTube", isOn: $youtubePreviews)
            } header: {
                Text("Ссылки")
            } footer: {
                Text("Обложка ролика загружается с i.ytimg.com. Сам плеер (youtube-nocookie.com, без сохранения cookie) открывается только по нажатию.")
            }

            Section {
                Picker("Тема приложения", selection: $appearance) {
                    Text("Как в системе").tag("system")
                    Text("Светлая").tag("light")
                    Text("Тёмная").tag("dark")
                }
                ChatThemePicker(chatId: nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Оформление")
            } footer: {
                Text("Фон и цвет ваших сообщений. Для отдельного чата тему можно задать кнопкой с палитрой в его заголовке.")
            }

            Section {
                Button("Пароль для входа…") { showingTwoFactor = true }
            } header: {
                Text("Безопасность")
            } footer: {
                Text("Двухфакторная защита: при входе на новом устройстве после кода из SMS потребуется пароль.")
            }

            PrivacySettingsSection()

            AboutSettingsSection()

            Section {
                Picker("Отправка сообщения", selection: $sendKey) {
                    Text("Return (Shift+Return — новая строка)").tag("return")
                    Text("⌘Return (Return — новая строка)").tag("cmdReturn")
                }
            } header: {
                Text("Ввод текста")
            } footer: {
                Text("Форматирование: ⌘B жирный, ⌘I курсив, ⌘U подчёркнутый, ⇧⌘X зачёркнутый, ⇧⌘. цитата, ⇧⌘M моноширинный, ⌘K ссылка, ⇧⌘N без форматирования.")
            }

            DataAndStorageSection()

            PermissionsSection()

            UpdateSettingsSection()

            DiagnosticsSection()

            Section("Уведомления (macOS / iOS)") {
                Toggle("Показывать уведомления", isOn: $notifEnabled)
                    .onChange(of: notifEnabled) { _, v in NotificationService.shared.notificationsEnabled = v }
                Toggle("Показывать расшифрованный текст", isOn: $notifPreview)
                    .onChange(of: notifPreview) { _, v in NotificationService.shared.showPreview = v }
                Toggle("Звук уведомлений", isOn: $notifSound)
                    .onChange(of: notifSound) { _, v in NotificationService.shared.soundEnabled = v }
                Toggle("Звуки звонков (гудки при дозвоне, рингтон, сигнал завершения)", isOn: $callSounds)
                    .onChange(of: callSounds) { _, v in CallSounds.shared.enabled = v }
                Button("Отправить пробное уведомление") { Task { notifTestResult = await NotificationService.shared.sendTest() } }
                if let r = notifTestResult { Text(r).font(.caption).foregroundStyle(.secondary) }
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
        .sheet(isPresented: $showingProfileEdit) {
            NavigationStack {
                ProfileEditView()
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { showingProfileEdit = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 460)
            #endif
        }
        .sheet(isPresented: $showingTwoFactor) { TwoFactorSheet(store: store).environmentObject(store) }
        .sheet(isPresented: $showingMyPhotos) {
            if let id = store.currentAccount?.userId { ProfilePhotosSheet(userId: id) }
        }
        .task {
            if store.isConnected {
                await store.refreshSessions()
                if let id = store.currentAccount?.userId { await store.ensureContacts([id], refresh: true) }
            }
        }
    }
}
