// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore
#if os(macOS)
import AppKit
#endif

/// Facts shown in «О программе», the settings block and the footer of the chat list.
enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    static var versionLine: String { "Версия \(version) (\(build)) • AGPLv3" }
    static let website = URL(string: "https://rms-ds.com")!
    static let sourceCode = URL(string: "https://github.com/max-ramas/rms-max")!
    static let license = URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!
    static let boosty = URL(string: "https://boosty.to/rmsds")!
    static let kofi = URL(string: "https://ko-fi.com/maxramas")!
}

/// The same list of links in the About window and in the settings.
struct AboutLinks: View {
    var body: some View {
        Link(destination: AppInfo.website) { Label("rms-ds.com", systemImage: "globe") }
        Link(destination: AppInfo.sourceCode) { Label("Исходный код на GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
        Link(destination: AppInfo.license) { Label("Лицензия GNU AGPLv3", systemImage: "doc.text") }
    }
}

struct SupportLinks: View {
    var body: some View {
        Link(destination: AppInfo.boosty) { Label("Boosty", systemImage: "cup.and.saucer.fill") }
        Link(destination: AppInfo.kofi) { Label("Ko-fi", systemImage: "cup.and.saucer.fill") }
    }
}

/// «О программе»: version and licence, links, ways to support the project.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            icon.frame(width: 72, height: 72)
            VStack(spacing: 3) {
                Text("RMS MAKS").font(.title2.weight(.bold))
                Text(AppInfo.versionLine).font(.subheadline).foregroundStyle(.secondary)
                Text("Клиент MAX без телеметрии. Открытый код.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) { AboutLinks() }
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Поддержать разработку").font(.subheadline.weight(.semibold))
                SupportLinks()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Закрыть") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 320)
    }

    @ViewBuilder private var icon: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit()
        #else
        Image(systemName: "bubble.left.and.bubble.right.fill").resizable().scaledToFit().foregroundStyle(Color.accentColor)
        #endif
    }
}

/// Settings block, the same content as the About window.
struct AboutSettingsSection: View {
    @AppStorage("rmsmaks.showSupportBar") private var showSupportBar = true

    var body: some View {
        Section {
            LabeledContent("RMS MAKS", value: AppInfo.versionLine)
            AboutLinks()
            DisclosureGroup("Поддержать разработку") { SupportLinks() }
            Toggle("Панель с сайтом и поддержкой внизу списка чатов", isOn: $showSupportBar)
        } header: {
            Text("О приложении")
        } footer: {
            Text("RMS MAKS распространяется по лицензии GNU AGPLv3: любая производная работа должна оставаться открытой.")
        }
    }
}

/// Thin strip at the bottom of the chat list: the site and «Поддержать» (the version is in «О программе», which it opens).
/// It does not float over chats or nag, never wraps (a narrow list just shows less), and can be hidden in the settings
/// or from its own context menu.
struct SupportBar: View {
    @AppStorage("rmsmaks.showSupportBar") private var showSupportBar = true

    var body: some View {
        if showSupportBar {
            HStack(spacing: 10) {
                Link("rms-ds.com", destination: AppInfo.website)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { AppAction.about.post() } label: {
                    Label("Поддержать", systemImage: "heart.fill")
                        .foregroundStyle(Color.pink)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("О программе и поддержка разработки")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .contextMenu { Button("Скрыть панель") { showSupportBar = false } }
        }
    }
}
