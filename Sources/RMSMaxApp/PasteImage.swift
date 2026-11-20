// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Image from the clipboard as PNG/JPEG data plus pixel size, or nil when the clipboard holds no image.
enum ClipboardImage {
    struct Item { let data: Data; let fileName: String; let mime: String; let width: Int; let height: Int }

    static func read() -> Item? {
        #if os(macOS)
        let pb = NSPasteboard.general
        // A copied image file (Finder) — send the original bytes.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
            let rep = img.representations.first
            return Item(data: data, fileName: url.lastPathComponent, mime: type.preferredMIMEType ?? "image/jpeg",
                        width: rep?.pixelsWide ?? Int(img.size.width), height: rep?.pixelsHigh ?? Int(img.size.height))
        }
        // Screenshot / image copied from an app.
        guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else { return nil }
        return Item(data: png, fileName: "image.png", mime: "image/png", width: bmp.pixelsWide, height: bmp.pixelsHigh)
        #else
        guard let img = UIPasteboard.general.image, let jpg = img.jpegData(compressionQuality: 0.9) else { return nil }
        return Item(data: jpg, fileName: "image.jpg", mime: "image/jpeg",
                    width: Int(img.size.width * img.scale), height: Int(img.size.height * img.scale))
        #endif
    }

    static var hasImage: Bool {
        #if os(macOS)
        let pb = NSPasteboard.general
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) && pb.string(forType: .string) == nil { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first, let t = UTType(filenameExtension: u.pathExtension) { return t.conforms(to: .image) }
        return false
        #else
        return UIPasteboard.general.hasImages
        #endif
    }
}

#if os(macOS)
/// Invisible ⌘V handler: an image on the clipboard is sent as a photo, anything else is pasted into the field as usual.
struct PasteImageShortcut: View {
    let onImage: (ClipboardImage.Item) -> Void

    var body: some View {
        Button("") {
            if ClipboardImage.hasImage, let item = ClipboardImage.read() {
                onImage(item)
            } else {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            }
        }
        .keyboardShortcut("v", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
#endif

extension View {
    /// macOS: ⌘V with an image on the clipboard sends it; iOS: no-op (a paste button is shown instead).
    func pasteImageHandler(_ onImage: @escaping (ClipboardImage.Item) -> Void) -> some View {
        #if os(macOS)
        return self.background(PasteImageShortcut(onImage: onImage))
        #else
        return self
        #endif
    }
}
