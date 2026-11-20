import SwiftUI
import RMSMaxCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Slim banner above the chat list when a newer version is out.
struct UpdateBanner: View {
    @EnvironmentObject private var store: AppStore
    @State private var showing = false

    var body: some View {
        if let u = store.availableUpdate {
            Button { showing = true } label: {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Доступна версия \(u.version)").font(.subheadline.bold())
                    Spacer()
                    Text("Подробнее").font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showing) { UpdateSheet() }
        }
    }
}

struct UpdateSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let u = store.availableUpdate {
                    Text("RMS MAKS \(u.version)").font(.title2.bold())
                    Text("Установлена \(AppUpdater.currentVersion). Подпись выпуска проверена.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(LocalizedStringKey(u.notes.replacingOccurrences(of: "## ", with: "").replacingOccurrences(of: "### ", with: "")))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let status = store.updateStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    #if os(macOS)
                    Button {
                        Task { await store.installAvailableUpdate() }
                    } label: {
                        if store.isInstallingUpdate { ProgressView().controlSize(.small) } else { Text("Установить и перезапустить").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isInstallingUpdate)
                    #else
                    Button("Скачать для SideStore") { openURL(AppUpdater.downloadPage) }
                        .buttonStyle(.borderedProminent)
                    Text("После загрузки откройте файл в SideStore, как при первой установке. Данные сохранятся.")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                } else {
                    Text("Установлена последняя версия")
                }
            }
            .padding()
            .navigationTitle("Обновление")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Позже") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

/// Settings section: version, auto-check toggle, manual check.
struct UpdateSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var showing = false

    var body: some View {
        Section {
            LabeledContent("Версия", value: "\(AppUpdater.currentVersion) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
            Toggle("Проверять обновления автоматически", isOn: Binding(get: { store.autoUpdateCheck }, set: { store.autoUpdateCheck = $0 }))
            HStack {
                Button("Проверить сейчас") { Task { await store.checkForUpdates(manual: true) } }
                if store.availableUpdate != nil { Button("Подробнее") { showing = true } }
                Spacer()
                if let s = store.updateStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
        } header: {
            Text("Обновления")
        } footer: {
            Text("Сервер update.rms-ds.com. Проверка — обычный запрос каталога, данные о вас не передаются. Обновление ставится только если подпись выпуска и контрольная сумма сходятся.")
        }
        .sheet(isPresented: $showing) { UpdateSheet() }
    }
}

/// Settings: local diagnostics log (protocol errors and connection events, no message contents).
struct DiagnosticsSection: View {
    @State private var copied = false
    @State private var shown = false

    var body: some View {
        Section {
            Button(copied ? "Скопировано" : "Скопировать журнал") {
                copy(ProtocolLog.text)
                copied = true
            }
            Button("Показать журнал") { shown = true }
            Button("Очистить журнал", role: .destructive) { ProtocolLog.clear() }
        } header: {
            Text("Диагностика")
        } footer: {
            Text("Только номера команд, ошибки сервера и события соединения — без текста сообщений, номеров и токенов. Хранится на устройстве; отправьте его разработчику, если что-то не работает.")
        }
        .sheet(isPresented: $shown) {
            NavigationStack {
                ScrollView { Text(ProtocolLog.text).font(.caption.monospaced()).textSelection(.enabled).padding() }
                    .navigationTitle("Журнал")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { shown = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 420)
            #endif
        }
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
