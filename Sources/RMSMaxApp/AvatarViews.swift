import SwiftUI
import RMSMaxCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Round avatar: the remote photo when there is one, otherwise initials (or a symbol) on a tinted circle.
struct AvatarView: View {
    let url: String?
    let title: String
    var symbol: String? = nil
    var size: CGFloat = 42
    @State private var data: Data?

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.22))
            if let image = loadedImage {
                image.resizable().scaledToFill()
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: size * 0.4)).foregroundStyle(tint)
            } else {
                Text(initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: url) {
            data = nil
            if let url, !url.isEmpty { data = await MediaCache.remoteImage(url) }
        }
    }

    private var loadedImage: Image? {
        guard let data else { return nil }
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }

    private var initials: String {
        let parts = title.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined().uppercased()
        return s.isEmpty ? "?" : s
    }

    private var tint: Color {
        let palette: [Color] = [.blue, .teal, .indigo, .orange, .pink, .green, .purple]
        let h = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }
}

/// Full profile of a MAX user: photo, status, phone, nick link, about, registration date and actions.
struct UserProfileView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let userId: Int64
    /// Hides «Написать» when shown from inside that very dialog.
    var showsMessageButton = true
    /// When shown as the info of a dialog: media of that dialog and clear/delete actions.
    var chat: MaxChat? = nil
    @State private var showingPhotos = false
    @State private var renameTarget: MaxContact?
    @State private var complaint = false

    private var contact: MaxContact? { store.contacts[userId] }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    AvatarView(url: contact?.avatarURL, title: contact?.name ?? "", size: 96)
                        .onTapGesture { if contact?.avatarURL != nil { showingPhotos = true } }
                        .help("Фото профиля")
                    Text(contact?.name ?? "Пользователь").font(.title2.bold())
                    if contact?.isBot == true {
                        Text("бот").font(.subheadline).foregroundStyle(.secondary)
                    } else if let p = store.presence[userId] {
                        Text(p.label).font(.subheadline).foregroundStyle(p.isOnline ? Color.accentColor : .secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section("Информация") {
                if let own = contact?.profileName {
                    LabeledContent("Имя в профиле", value: own)
                }
                if let phone = contact?.phone, !phone.isEmpty {
                    LabeledContent("Телефон") {
                        Text(phone.hasPrefix("+") ? phone : "+" + phone).textSelection(.enabled)
                    }
                }
                if let link = contact?.link, !link.isEmpty {
                    LabeledContent("Ссылка") {
                        Button(link) { if let u = URL(string: link) { openURL(u) } }.buttonStyle(.borderless)
                    }
                }
                if let d = contact?.description, !d.isEmpty {
                    LabeledContent("О себе") { Text(d).textSelection(.enabled).multilineTextAlignment(.trailing) }
                }
                if let reg = contact?.registrationTime, reg > 0 {
                    LabeledContent("В MAX с", value: Date(timeIntervalSince1970: TimeInterval(reg) / 1000).formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU"))))
                }
                LabeledContent("ID", value: String(userId))
            }

            Section("Действия") {
                if showsMessageButton {
                    Button("Написать") {
                        store.openDialog(with: userId)
                        dismiss()
                    }
                }
                if contact?.isInContacts == true {
                    Button("Переименовать…") { renameTarget = contact }
                    Button("Удалить из контактов", role: .destructive) {
                        Task { await store.contactAction(userId, action: "REMOVE") }
                    }
                } else {
                    Button("Добавить в контакты") {
                        Task { await store.contactAction(userId, action: "ADD", firstName: contact?.firstName, lastName: contact?.lastName) }
                    }
                }
                if contact?.isBlocked == true {
                    Button("Разблокировать") { Task { await store.contactAction(userId, action: "UNBLOCK") } }
                } else {
                    Button("Заблокировать", role: .destructive) { Task { await store.contactAction(userId, action: "BLOCK") } }
                }
                if contact?.isBot == true {
                    Button("Остановить бота", role: .destructive) { Task { await store.suspendBot(botId: userId, stop: true) } }
                }
                Button("Пожаловаться…", role: .destructive) { complaint = true }
            }

            if let chat {
                ChatMediaSection(chatId: chat.id)
                ChatDangerSection(chat: chat)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(contact?.name ?? "Профиль")
        .task {
            await store.ensureContacts([userId], refresh: true)
            await store.loadPresence([userId])
        }
        .sheet(item: $renameTarget) { RenameContactSheet(contact: $0) }
        .sheet(isPresented: $showingPhotos) { ProfilePhotosSheet(userId: userId) }
        .sheet(isPresented: $complaint) { ComplaintSheet(target: .userProfile, ids: [userId], parentId: nil) }
    }
}
