// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation
@preconcurrency import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shows notifications also while the app is in front (for chats other than the open one) and opens the chat on click.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onOpenChat: (@MainActor (Int64) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let chatId = (response.notification.request.content.userInfo["chatId"] as? NSNumber)?.int64Value
        completionHandler()
        guard let chatId else { return }
        Task { @MainActor [weak self] in
            #if os(macOS)
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            #endif
            self?.onOpenChat?(chatId)
        }
    }
}

@MainActor
public final class NotificationService {
    public static let shared = NotificationService()

    public var notificationsEnabled = true
    public var showPreview = true
    public var soundEnabled = true

    private var activeChatIds: Set<Int64> = []
    private var logged = 0

    /// Why a notification did or did not appear, in the protocol log (first lines per launch only; no message text).
    func logNote(_ s: String) {
        guard logged < 12 else { return }
        logged += 1
        ProtocolLog.add("notification: \(s)")
    }
    func logSkip(_ why: String) { logNote("skipped — \(why)") }

    /// Sends a visible test notification and reports what the system said about it.
    public func sendTest() async -> String {
        guard isBundledApp else { return "Уведомления работают только в собранном приложении." }
        await PermissionsCenter.shared.refresh()
        let st = PermissionsCenter.shared.state(.notifications)
        guard st != .notDetermined, st != .denied else { return "Система не разрешает уведомления: \(st.label). Включите их в настройках macOS." }
        let content = UNMutableNotificationContent()
        content.title = "RMS MAKS"
        content.body = "Пробное уведомление: если вы это видите, уведомления работают."
        if soundEnabled { content.sound = .default }
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "rmsmax_test_\(UUID().uuidString)", content: content, trigger: nil))
            return "Отправлено. Если баннера нет — проверьте стиль уведомлений для RMS MAKS и режим «Не беспокоить» в системе."
        } catch {
            return "Система отклонила уведомление: \(error.localizedDescription)"
        }
    }

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app" && Bundle.main.bundleIdentifier != nil
    }

    public init() {}

    private let delegate = NotificationDelegate()

    /// Must run before anything can be delivered: without a delegate macOS shows no banner while the app is in front
    /// and a click on a notification opens nothing.
    public func install(onOpenChat: @escaping @MainActor (Int64) -> Void) {
        guard isBundledApp else { return }
        delegate.onOpenChat = onOpenChat
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Asks once (the system prompt) when nothing was decided yet; the state is tracked in PermissionsCenter.
    public func requestAuthorization() async {
        await PermissionsCenter.shared.refresh()
        if PermissionsCenter.shared.state(.notifications) == .notDetermined {
            await PermissionsCenter.shared.request(.notifications)
        }
    }

    /// True when the user is looking at the app: the window is key and the app is in front.
    public var appIsActive: Bool {
        #if os(macOS)
        return NSApplication.shared.isActive && NSApplication.shared.keyWindow != nil
        #else
        return UIApplication.shared.applicationState == .active
        #endif
    }

    public func notifyIncomingMessage(
        chatId: Int64,
        messageId: String,
        title: String,
        body: String,
        senderName: String? = nil,
        isGroup: Bool = false
    ) async {
        guard notificationsEnabled else { logSkip("switched off in the app settings"); return }
        activeChatIds.insert(chatId)
        updateBadgeCount(activeChatIds.count)

        guard isBundledApp else { logSkip("not a bundled app"); return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        if !showPreview {
            content.body = "Новое сообщение"
        } else if isGroup, let senderName, !senderName.isEmpty, senderName != title {
            content.body = "\(senderName): \(body)"
        } else {
            content.body = body
        }
        content.threadIdentifier = String(chatId)
        if soundEnabled {
            content.sound = .default
        }
        content.userInfo = ["chatId": chatId, "messageId": messageId]

        let req = UNNotificationRequest(
            identifier: "rmsmax_chat_\(chatId)_\(messageId)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(req)
            logNote("handed to the system (permission: \(PermissionsCenter.shared.state(.notifications).label))")
        } catch {
            logNote("system refused — \(error.localizedDescription)")
        }
    }

    public func notifyIncomingCall(callerName: String, isVideo: Bool, conversationId: String) async {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = isVideo ? "Входящий видеозвонок" : "Входящий аудиозвонок"
        content.body = callerName.isEmpty ? "Входящий вызов" : callerName
        content.sound = soundEnabled ? .default : nil
        content.userInfo = ["conversationId": conversationId]

        let req = UNNotificationRequest(identifier: "rmsmax_incoming_call", content: content, trigger: nil)
        try? await center.add(req)
    }

    public func clearChatNotifications(chatId: Int64) {
        activeChatIds.remove(chatId)
        updateBadgeCount(activeChatIds.count)

        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        let prefix = "rmsmax_chat_\(chatId)_"
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
        center.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    public func clearCallNotifications() {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["rmsmax_incoming_call"])
        center.removePendingNotificationRequests(withIdentifiers: ["rmsmax_incoming_call"])
    }

    private func updateBadgeCount(_ count: Int) {
        #if os(macOS)
        if isBundledApp {
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
        #else
        if isBundledApp {
            UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
        }
        #endif
    }
}
