// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

#if os(macOS)
import SwiftUI
import AppKit

/// Remembers the window frame (and the chat-list width) under OUR OWN stable keys and enforces the list's width limits.
///
/// Why not rely on SwiftUI: it saves the window under a key made from the generic type of everything wrapped around the
/// content, so every modifier added or removed around `ContentView` silently started a new, empty state (size, position and
/// the list width were forgotten after updates). And `navigationSplitViewColumnWidth` was not honoured by the real window,
/// so the list could be dragged down to a few letters and the toolbar buttons dropped into the overflow menu.
struct WindowStateKeeper: NSViewRepresentable {
    let frameKey: String
    var splitKey: String? = nil
    /// Width limits of the first column; the minimum is what the whole top button panel needs.
    var sidebarMin: CGFloat = 0
    var sidebarMax: CGFloat = .greatestFiniteMagnitude
    var minWindowWidth: CGFloat = 0

    func makeNSView(context: Context) -> KeeperView {
        let v = KeeperView(); v.config = self; return v
    }
    func updateNSView(_ v: KeeperView, context: Context) { v.config = self }

    final class KeeperView: NSView {
        var config: WindowStateKeeper!
        private var observers: [NSObjectProtocol] = []
        private weak var configuredSplit: NSSplitView?
        private var restoringWidth = false

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window, observers.isEmpty else { return }
            // After SwiftUI has finished its own first layout and restoration, so that ours wins.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.attach(w) }
        }

        private func attach(_ w: NSWindow) {
            restoreFrame(w)
            let nc = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
                observers.append(nc.addObserver(forName: name, object: w, queue: .main) { [weak self, weak w] _ in
                    guard let self, let w else { return }
                    self.saveFrame(w)
                })
            }
            if config.splitKey != nil {
                // The list exists only after sign-in, so (re)configure whenever a split view of this window lays out.
                observers.append(nc.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak self, weak w] n in
                    guard let self, let w, let split = n.object as? NSSplitView, split.window === w else { return }
                    self.splitDidResize(split)
                })
                if let s = Self.findSplit(w.contentView) { configure(s) }
            }
        }

        // MARK: window frame

        private func restoreFrame(_ w: NSWindow) {
            guard let s = UserDefaults.standard.string(forKey: config.frameKey) else { return }
            var r = NSRectFromString(s)
            guard r.width >= max(config.minWindowWidth, 300), r.height >= 300,
                  NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) else { return }
            r.size.width = max(r.size.width, config.minWindowWidth)
            w.setFrame(r, display: true)
        }

        private func saveFrame(_ w: NSWindow) {
            guard !w.styleMask.contains(.fullScreen), !w.isMiniaturized else { return }
            UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: config.frameKey)
        }

        // MARK: list width

        static func findSplit(_ v: NSView?) -> NSSplitView? {
            guard let v else { return nil }
            if let s = v as? NSSplitView, s.arrangedSubviews.count >= 2 { return s }
            for c in v.subviews { if let s = findSplit(c) { return s } }
            return nil
        }

        private func configure(_ split: NSSplitView) {
            guard configuredSplit !== split else { return }
            configuredSplit = split
            if let item = (split.delegate as? NSSplitViewController)?.splitViewItems.first {
                item.minimumThickness = config.sidebarMin
                item.maximumThickness = config.sidebarMax
            }
            restoringWidth = true
            let saved = CGFloat(UserDefaults.standard.double(forKey: config.splitKey ?? ""))
            let current = split.arrangedSubviews[0].frame.width
            let target = min(max(saved > 0 ? saved : current, config.sidebarMin), config.sidebarMax)
            if abs(target - current) > 0.5 { split.setPosition(target, ofDividerAt: 0) }
            endRestore(split)
        }

        /// Ends the guard window and records the width the list really ended up with (SwiftUI may settle it elsewhere).
        private func endRestore(_ split: NSSplitView) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak split] in
                guard let self, let split, let key = self.config.splitKey else { return }
                self.restoringWidth = false
                let first = split.arrangedSubviews[0]
                let w = first.frame.width
                if !split.isSubviewCollapsed(first), w >= self.config.sidebarMin - 0.5, w <= self.config.sidebarMax + 0.5 {
                    UserDefaults.standard.set(Double(w), forKey: key)
                }
            }
        }

        private func splitDidResize(_ split: NSSplitView) {
            if configuredSplit !== split { configure(split); return }
            guard !restoringWidth, let key = config.splitKey else { return }
            let first = split.arrangedSubviews[0]
            guard !split.isSubviewCollapsed(first) else { return }
            let w = first.frame.width
            if w < config.sidebarMin - 0.5 {                       // something squeezed the list: put it back
                restoringWidth = true
                split.setPosition(config.sidebarMin, ofDividerAt: 0)
                endRestore(split)
            } else if w <= config.sidebarMax + 0.5 {
                UserDefaults.standard.set(Double(w), forKey: key)
            }
        }
    }
}
#endif
