import Foundation
@preconcurrency import UserNotifications
#if os(macOS)
import AppKit
#endif

@MainActor
public final class NotificationService {
    public static let shared = NotificationService()

    public var notificationsEnabled = true
    public var showPreview = true
    public var soundEnabled = true

    private var activeChatIds: Set<Int64> = []

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app" && Bundle.main.bundleIdentifier != nil
    }

    public init() {}

    public func requestAuthorization() async {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func notifyIncomingMessage(
        chatId: Int64,
        messageId: String,
        title: String,
        body: String,
        senderName: String? = nil,
        isGroup: Bool = false
    ) async {
        guard notificationsEnabled else { return }
        activeChatIds.insert(chatId)
        updateBadgeCount(activeChatIds.count)

        guard isBundledApp else { return }
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
        try? await center.add(req)
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
