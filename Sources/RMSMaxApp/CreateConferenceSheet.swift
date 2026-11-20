// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A new conference room: the link to send to people, and a button to enter it yourself.
struct CreateConferenceSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var link: String?
    @State private var failed = false
    @State private var video = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Новая конференция").font(.headline)
            if let link {
                Text(link).textSelection(.enabled).font(.callout.monospaced()).multilineTextAlignment(.center)
                    .padding(10).frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                Text("Отправьте ссылку участникам — они подключатся из MAX на телефоне или компьютере.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button(copied ? "Скопировано" : "Скопировать ссылку") { copy(link); copied = true }
                    Toggle("С видео", isOn: $video)
                }
                Button {
                    let l = link, v = video
                    dismiss()
                    Task { await store.joinConferenceByLink(l, isVideo: v, secure: false) }
                } label: { Label("Войти в конференцию", systemImage: "video.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            } else if failed {
                Text("Не удалось создать конференцию").foregroundStyle(.secondary)
                Button("Повторить") { Task { await create() } }
            } else {
                ProgressView("Создаём…")
            }
            Button("Закрыть") { dismiss() }
        }
        .padding(20)
        .frame(width: 420)
        .task { await create() }
    }

    private func create() async {
        failed = false
        if let r = await store.createConference() { link = r.link } else { failed = true }
    }

    private func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}
