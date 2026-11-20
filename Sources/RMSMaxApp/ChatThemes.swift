// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI

/// Chat appearance: wallpaper gradient and the colour of my bubbles. Purely local, like the official client's themes.
struct ChatTheme: Identifiable, Equatable {
    let id: String
    let title: String
    /// Wallpaper gradient (empty = plain system background).
    let wallpaper: [Color]
    /// Outgoing bubble colour (nil = the app accent).
    let outgoing: Color?

    static let standard = ChatTheme(id: "standard", title: "Стандартная", wallpaper: [], outgoing: nil)

    static let all: [ChatTheme] = [
        standard,
        ChatTheme(id: "ocean", title: "Океан", wallpaper: [Color(red: 0.05, green: 0.25, blue: 0.45), Color(red: 0.05, green: 0.55, blue: 0.65)], outgoing: Color(red: 0.07, green: 0.45, blue: 0.75)),
        ChatTheme(id: "forest", title: "Лес", wallpaper: [Color(red: 0.05, green: 0.30, blue: 0.20), Color(red: 0.30, green: 0.55, blue: 0.25)], outgoing: Color(red: 0.12, green: 0.50, blue: 0.30)),
        ChatTheme(id: "sunset", title: "Закат", wallpaper: [Color(red: 0.55, green: 0.15, blue: 0.30), Color(red: 0.95, green: 0.55, blue: 0.25)], outgoing: Color(red: 0.80, green: 0.30, blue: 0.25)),
        ChatTheme(id: "lilac", title: "Сирень", wallpaper: [Color(red: 0.30, green: 0.20, blue: 0.55), Color(red: 0.70, green: 0.45, blue: 0.80)], outgoing: Color(red: 0.50, green: 0.30, blue: 0.75)),
        ChatTheme(id: "mint", title: "Мята", wallpaper: [Color(red: 0.10, green: 0.45, blue: 0.45), Color(red: 0.50, green: 0.85, blue: 0.70)], outgoing: Color(red: 0.10, green: 0.55, blue: 0.50)),
        ChatTheme(id: "graphite", title: "Графит", wallpaper: [Color(red: 0.12, green: 0.14, blue: 0.18), Color(red: 0.30, green: 0.33, blue: 0.40)], outgoing: Color(red: 0.35, green: 0.40, blue: 0.50)),
        ChatTheme(id: "rose", title: "Роза", wallpaper: [Color(red: 0.65, green: 0.20, blue: 0.40), Color(red: 0.95, green: 0.60, blue: 0.70)], outgoing: Color(red: 0.85, green: 0.30, blue: 0.50)),
    ]

    static func byId(_ id: String?) -> ChatTheme { all.first { $0.id == id } ?? standard }
}

/// Default theme + per-chat overrides, persisted in UserDefaults.
@MainActor
final class ChatThemeStore: ObservableObject {
    static let shared = ChatThemeStore()
    private let defaultKey = "rmsmaks.theme.default"
    private let overridesKey = "rmsmaks.theme.overrides"

    @Published private(set) var defaultId: String
    @Published private(set) var overrides: [Int64: String]

    private init() {
        defaultId = UserDefaults.standard.string(forKey: defaultKey) ?? ChatTheme.standard.id
        let raw = UserDefaults.standard.dictionary(forKey: overridesKey) as? [String: String] ?? [:]
        overrides = raw.reduce(into: [:]) { if let id = Int64($1.key) { $0[id] = $1.value } }
    }

    func theme(for chatId: Int64) -> ChatTheme { ChatTheme.byId(overrides[chatId] ?? defaultId) }
    func hasOverride(_ chatId: Int64) -> Bool { overrides[chatId] != nil }

    func setDefault(_ id: String) {
        defaultId = id
        UserDefaults.standard.set(id, forKey: defaultKey)
    }

    /// `nil` removes the override (the chat follows the default again).
    func set(chatId: Int64, themeId: String?) {
        overrides[chatId] = themeId
        UserDefaults.standard.set(overrides.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }, forKey: overridesKey)
    }
}

struct ChatWallpaper: View {
    let theme: ChatTheme
    var body: some View {
        if theme.wallpaper.count >= 2 {
            LinearGradient(colors: theme.wallpaper.map { $0.opacity(0.30) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            Color.clear
        }
    }
}

/// Swatches for one chat, or for all chats when `chatId` is nil.
struct ChatThemePicker: View {
    @ObservedObject private var themes = ChatThemeStore.shared
    let chatId: Int64?
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 10)]

    private var selectedId: String {
        if let chatId { return themes.theme(for: chatId).id }
        return themes.defaultId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(chatId == nil ? "Оформление чатов" : "Фон этого чата").font(.headline)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ChatTheme.all) { t in
                    Button {
                        if let chatId { themes.set(chatId: chatId, themeId: t.id) } else { themes.setDefault(t.id) }
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(t.wallpaper.count >= 2
                                          ? AnyShapeStyle(LinearGradient(colors: t.wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing))
                                          : AnyShapeStyle(Color.secondary.opacity(0.15)))
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(t.outgoing ?? Color.accentColor)
                                    .frame(width: 34, height: 14)
                                    .offset(x: 12, y: 8)
                            }
                            .frame(height: 52)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: selectedId == t.id ? 3 : 0))
                            Text(t.title).font(.caption2).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let chatId, themes.hasOverride(chatId) {
                Button("Как во всех чатах") { themes.set(chatId: chatId, themeId: nil) }
            }
        }
        .padding(14)
        .frame(width: 420)
    }
}
