// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation
import CoreGraphics
import AVFoundation
import Contacts
@preconcurrency import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case notifications, microphone, camera, contacts, screen
    public var id: String { rawValue }

    /// Permissions that exist on this platform (screen recording is a Mac thing).
    public static var available: [PermissionKind] {
        #if os(macOS)
        return allCases
        #else
        return allCases.filter { $0 != .screen }
        #endif
    }

    public var title: String {
        switch self {
        case .notifications: return "Уведомления"
        case .microphone: return "Микрофон"
        case .camera: return "Камера"
        case .contacts: return "Контакты"
        case .screen: return "Запись экрана"
        }
    }

    /// Why the app asks for it — shown next to the switch and in the system prompt hint.
    public var purpose: String {
        switch self {
        case .notifications: return "Показывать новые сообщения и входящие звонки, когда приложение не на экране."
        case .microphone: return "Голосовые сообщения и звонки."
        case .camera: return "Видеозвонки."
        case .contacts: return "Импорт номеров из адресной книги — только по вашей кнопке, на сервер уходят лишь отмеченные номера."
        case .screen: return "Демонстрация экрана в звонках. Когда macOS выдаст доступ, она предложит перезапустить приложение."
        }
    }
}

public enum PermissionState: Equatable, Sendable {
    case notDetermined, granted, denied, restricted
    /// Notifications are allowed, but both banners and sounds are switched off in system settings.
    case silenced

    public var isUsable: Bool { self == .granted }

    public var label: String {
        switch self {
        case .notDetermined: return "Не запрошено"
        case .granted: return "Разрешено"
        case .denied: return "Запрещено"
        case .restricted: return "Ограничено системой"
        case .silenced: return "Разрешено, но баннеры и звук выключены"
        }
    }

    static func from(_ s: AVAuthorizationStatus) -> PermissionState {
        switch s {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }

    static func from(_ s: CNAuthorizationStatus) -> PermissionState {
        switch s {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        default: return .granted // .limited (iOS 18 / macOS 15): the user picked some contacts, that is enough for the import
        }
    }

    static func from(_ s: UNAuthorizationStatus, alertsOn: Bool, soundOn: Bool) -> PermissionState {
        switch s {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return (alertsOn && soundOn) ? .granted : .silenced
        }
    }
}

/// Knows the state of every permission the app uses, asks for the missing ones and sends the user to the system
/// settings when a permission was denied (the system never shows its prompt a second time).
@MainActor
public final class PermissionsCenter: ObservableObject {
    public static let shared = PermissionsCenter()

    @Published public private(set) var states: [PermissionKind: PermissionState] = [:]
    /// Set when a feature cannot work without a permission: the window shows «Нужно разрешение» with a settings button.
    @Published public var alert: PermissionKind?
    /// «баннеры: вкл, звук: выкл» — what exactly is switched off for notifications.
    @Published public private(set) var notificationDetail = ""

    private static let bannerKey = "rmsmaks.permissions.bannerDismissedUntil"

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app" && Bundle.main.bundleIdentifier != nil
    }

    public func state(_ k: PermissionKind) -> PermissionState { states[k] ?? .notDetermined }

    public func refresh() async {
        var next: [PermissionKind: PermissionState] = [:]
        next[.microphone] = .from(AVCaptureDevice.authorizationStatus(for: .audio))
        next[.camera] = .from(AVCaptureDevice.authorizationStatus(for: .video))
        next[.contacts] = .from(CNContactStore.authorizationStatus(for: .contacts))
        #if os(macOS)
        next[.screen] = CGPreflightScreenCaptureAccess() ? .granted : (UserDefaults.standard.bool(forKey: "rmsmaks.screenAsked") ? .denied : .notDetermined)
        #endif
        if isBundledApp {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            next[.notifications] = .from(s.authorizationStatus, alertsOn: s.alertSetting == .enabled && s.alertStyle != .none, soundOn: s.soundSetting == .enabled)
            notificationDetail = "баннеры: \(s.alertSetting == .enabled && s.alertStyle != .none ? "вкл" : "выкл"), звук: \(s.soundSetting == .enabled ? "вкл" : "выкл")"
        }
        states = next
    }

    /// Shows the system prompt when the permission was never asked, otherwise opens the system settings.
    @discardableResult
    public func request(_ kind: PermissionKind) async -> PermissionState {
        await refresh()
        guard state(kind) == .notDetermined else {
            if !state(kind).isUsable { openSettings(for: kind) }
            return state(kind)
        }
        switch kind {
        case .notifications:
            if isBundledApp { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .screen:
            #if os(macOS)
            UserDefaults.standard.set(true, forKey: "rmsmaks.screenAsked")
            _ = CGRequestScreenCaptureAccess()    // shows the system prompt; the grant takes effect after a restart
            #endif
        }
        await refresh()
        return state(kind)
    }

    /// Microphone check for voice messages and calls: asks if needed; on a denial raises the settings alert.
    public func ensureMicrophone() async -> Bool {
        let result = await request(.microphone)
        if !result.isUsable { alert = .microphone }
        return result.isUsable
    }

    public func openSettings(for kind: PermissionKind) {
        #if os(macOS)
        let anchor: String
        switch kind {
        case .notifications: anchor = "com.apple.Notifications-Settings.extension"
        case .microphone: anchor = "com.apple.preference.security?Privacy_Microphone"
        case .camera: anchor = "com.apple.preference.security?Privacy_Camera"
        case .contacts: anchor = "com.apple.preference.security?Privacy_Contacts"
        case .screen: anchor = "com.apple.preference.security?Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:\(anchor)") { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }

    // MARK: - Banner

    /// The notification banner is shown when notifications are off or not asked yet, unless dismissed in the last 7 days.
    public var showsNotificationBanner: Bool {
        guard state(.notifications) != .granted, states[.notifications] != nil else { return false }
        return Date().timeIntervalSince1970 > UserDefaults.standard.double(forKey: Self.bannerKey)
    }

    public func dismissBanner() {
        UserDefaults.standard.set(Date().addingTimeInterval(7 * 86_400).timeIntervalSince1970, forKey: Self.bannerKey)
        objectWillChange.send()
    }
}
