import SwiftUI
import RMSMaxCore

/// Thin bar above the chat list when notifications are off, like the update banner.
struct PermissionsBanner: View {
    @ObservedObject private var perms = PermissionsCenter.shared

    var body: some View {
        if perms.showsNotificationBanner {
            let state = perms.state(.notifications)
            HStack(spacing: 8) {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state == .notDetermined ? "Разрешите уведомления" : "Уведомления выключены")
                        .font(.subheadline.bold())
                    Text(state == .silenced ? "В настройках системы выключено: \(perms.notificationDetail)."
                         : "Иначе вы не увидите новые сообщения и звонки, пока приложение закрыто.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(state == .notDetermined ? "Разрешить" : "Открыть настройки") {
                    Task { await perms.request(.notifications) }
                }
                .controlSize(.small)
                Button { perms.dismissBanner() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Напомнить через неделю")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
        }
    }
}

/// Settings: every permission with its state and the one action that helps.
struct PermissionsSection: View {
    @ObservedObject private var perms = PermissionsCenter.shared

    var body: some View {
        Section {
            ForEach(PermissionKind.available) { kind in
                let state = perms.state(kind)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(state))
                        .foregroundStyle(color(state))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                        Text(kind.purpose).font(.caption).foregroundStyle(.secondary)
                        Text(state.label).font(.caption2).foregroundStyle(color(state))
                    }
                    Spacer()
                    if !state.isUsable {
                        Button(state == .notDetermined ? "Разрешить" : "Открыть настройки") {
                            Task { await perms.request(kind) }
                        }
                        .controlSize(.small)
                    }
                }
            }
            Button("Проверить снова") { Task { await perms.refresh() } }
        } header: {
            Text("Разрешения")
        } footer: {
            Text("Если разрешение отклонено, система больше не показывает запрос — включить его можно только в настройках системы. Изменения подхватываются, когда вы возвращаетесь в приложение.")
        }
        .task { await perms.refresh() }
    }

    private func icon(_ s: PermissionState) -> String {
        switch s {
        case .granted: return "checkmark.circle.fill"
        case .notDetermined: return "questionmark.circle"
        case .silenced: return "exclamationmark.circle.fill"
        default: return "xmark.circle.fill"
        }
    }

    private func color(_ s: PermissionState) -> Color {
        switch s {
        case .granted: return .green
        case .notDetermined: return .secondary
        case .silenced: return .orange
        default: return .red
        }
    }
}

extension View {
    /// «Нужно разрешение» window raised by features that cannot work without one.
    func permissionAlert() -> some View { modifier(PermissionAlertModifier()) }
}

private struct PermissionAlertModifier: ViewModifier {
    @ObservedObject private var perms = PermissionsCenter.shared

    func body(content: Content) -> some View {
        content.alert(
            "Нужно разрешение: \(perms.alert?.title.lowercased() ?? "")",
            isPresented: Binding(get: { perms.alert != nil }, set: { if !$0 { perms.alert = nil } })
        ) {
            Button("Открыть настройки") {
                if let k = perms.alert { perms.openSettings(for: k) }
                perms.alert = nil
            }
            Button("Отмена", role: .cancel) { perms.alert = nil }
        } message: {
            Text((perms.alert?.purpose ?? "") + "\nСистема больше не показывает запрос: включите доступ в настройках.")
        }
    }
}
