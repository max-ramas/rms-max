// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

#if os(macOS)
/// Right-click (or Control-click) on a message. Only right clicks are intercepted, so selection, links and left clicks keep working.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onRightClick = onRightClick; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.onRightClick = onRightClick }

    final class CatcherView: NSView {
        var onRightClick: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let isRight = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return isRight ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { onRightClick() }
        override func mouseDown(with event: NSEvent) { if event.modifierFlags.contains(.control) { onRightClick() } else { super.mouseDown(with: event) } }
    }
}
#endif

/// Telegram-style message menu: a row of reactions (a chevron opens all of them) above the list of actions.
struct MessageActionsPopover: View {
    @EnvironmentObject private var store: AppStore
    let message: MaxMessage
    let isMe: Bool
    let isPinned: Bool
    let canEdit: Bool
    let onClose: () -> Void
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onForward: () -> Void
    let onEdit: () -> Void
    let onSelect: () -> Void
    let onWhoReacted: () -> Void
    let onComplain: () -> Void
    let onDelete: (_ forEveryone: Bool) -> Void

    @State private var expanded = false
    @State private var deleting = false

    private var reactions: [String] { store.availableReactions(chatId: message.chatId) }
    private let columns = Array(repeating: GridItem(.flexible(minimum: 30), spacing: 2), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !reactions.isEmpty { reactionBar }
            if deleting { deleteChoices } else if !expanded { actions }
        }
        .padding(8)
        .frame(width: 260)
    }

    // MARK: reactions

    @ViewBuilder private var reactionBar: some View {
        if expanded {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) { ForEach(reactions + EmojiCatalog.categories.flatMap(\.emoji).prefix(160).filter { !reactions.contains($0) }, id: \.self) { reactionButton($0) } }
            }
            .frame(height: 240)
        } else {
            HStack(spacing: 2) {
                ForEach(reactions.prefix(7), id: \.self) { reactionButton($0) }
                if reactions.count > 7 || store.chatReactions[message.chatId]?.ids.isEmpty != false {
                    Button { withAnimation(.easeOut(duration: 0.12)) { expanded = true } } label: {
                        Image(systemName: "chevron.down.circle.fill").font(.title3).foregroundStyle(.secondary).frame(width: 28, height: 32)
                    }.buttonStyle(.plain).help("Все реакции")
                }
            }
            .padding(.bottom, 6)
            Divider().padding(.bottom, 4)
        }
    }

    private func reactionButton(_ e: String) -> some View {
        Button { onReact(e); onClose() } label: {
            Text(e).font(.system(size: 22)).frame(width: 30, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(e == message.myReaction ? Color.accentColor.opacity(0.3) : .clear))
        }.buttonStyle(.plain)
    }

    // MARK: actions

    private func row(_ icon: String, _ title: String, tint: Color = .primary, _ action: @escaping () -> Void) -> some View {
        Button { onClose(); action() } label: {
            HStack(spacing: 10) { Image(systemName: icon).frame(width: 20); Text(title); Spacer() }
                .foregroundStyle(tint).padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }

    @ViewBuilder private var actions: some View {
        row("arrowshape.turn.up.left", "Ответить", onReply)
        if !message.bodyText.isEmpty { row("doc.on.doc", "Копировать текст", onCopy) }
        row(isPinned ? "pin.slash" : "pin", isPinned ? "Открепить" : "Закрепить", onPin)
        row("arrowshape.turn.up.right", "Переслать…", onForward)
        if canEdit { row("pencil", "Изменить", onEdit) }
        row("checkmark.circle", "Выделить", onSelect)
        if !message.reactions.isEmpty { row("face.smiling", "Кто отреагировал…", onWhoReacted) }
        Divider().padding(.vertical, 4)
        if !isMe { row("exclamationmark.bubble", "Пожаловаться…", tint: .red, onComplain) }
        Button { deleting = true } label: {
            HStack(spacing: 10) { Image(systemName: "trash").frame(width: 20); Text("Удалить"); Spacer() }
                .foregroundStyle(.red).padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }

    @ViewBuilder private var deleteChoices: some View {
        Text("Удалить сообщение?").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
        row("trash", "Удалить у себя", tint: .red) { onDelete(false) }
        if isMe { row("trash.fill", "Удалить у всех", tint: .red) { onDelete(true) } }
        Button { deleting = false } label: {
            HStack { Text("Отмена"); Spacer() }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(MenuRowStyle())
    }
}

private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Color.secondary.opacity(0.25) : .clear))
    }
}

#if os(macOS)
/// Right click → popover menu (kept out of the bubble's body so the compiler can type-check it).
struct MessageMenuModifier: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @Binding var isPresented: Bool
    let message: MaxMessage
    let isMe: Bool
    let isPinned: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onPin: () -> Void
    let onForward: () -> Void
    let onEdit: () -> Void
    let onSelect: () -> Void
    let onWhoReacted: () -> Void
    let onComplain: () -> Void
    let onDelete: (_ forEveryone: Bool) -> Void

    func body(content: Content) -> some View {
        content
            .overlay(RightClickCatcher { isPresented = true })
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                MessageActionsPopover(
                    message: message, isMe: isMe, isPinned: isPinned,
                    canEdit: isMe && message.attaches.isEmpty && message.decrypted?.media == nil,
                    onClose: { isPresented = false },
                    onReact: onReact, onReply: onReply, onCopy: onCopy, onPin: onPin, onForward: onForward,
                    onEdit: onEdit, onSelect: onSelect, onWhoReacted: onWhoReacted, onComplain: onComplain, onDelete: onDelete
                )
                .environmentObject(store)
            }
    }
}
#endif
