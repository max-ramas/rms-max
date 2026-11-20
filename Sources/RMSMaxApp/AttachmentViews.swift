// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import QuickLook
import ImageIO
import UniformTypeIdentifiers
import RMSMaxCore
#if os(iOS)
import PhotosUI
#endif

// MARK: - Platform image helper

enum PlatformImage {
    static func image(contentsOf url: URL, maxPixel: CGFloat = 1200) -> Image? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}

// MARK: - Attachments inside a message bubble

/// One renderable item: either a plain server attach or an E2E-decrypted media descriptor.
private struct AttachmentItem: Identifiable {
    let id: String
    let attachment: MaxAttachment
    let kind: AttachmentKind
    let name: String?
    let size: UInt64?
    let encrypted: Bool
    var durationMs: Double? = nil
    var wave: [UInt8]? = nil
}

struct MessageAttachmentsView: View {
    @EnvironmentObject private var store: AppStore
    let message: MaxMessage

    private var items: [AttachmentItem] {
        if let media = message.decrypted?.media {
            // E2E media: the server-side attach is a disguised FILE; show the real type instead.
            guard let carrier = message.attaches.first(where: { $0.kind == .file }) else { return [] }
            return [AttachmentItem(
                id: carrier.id, attachment: carrier, kind: AttachmentKind(rawType: media.mediaType),
                name: media.name, size: media.size, encrypted: true,
                durationMs: media.duration, wave: media.wave
            )]
        }
        return message.attaches.filter { $0.kind != .other }.map {
            AttachmentItem(id: $0.id, attachment: $0, kind: $0.kind, name: $0.title, size: $0.size, encrypted: false,
                           durationMs: $0.durationMs, wave: $0.wave)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                if item.attachment.isVideoMessage {
                    VideoMessageView(message: message, attachment: item.attachment)
                } else {
                    AttachmentCell(item: item, message: message)
                }
            }
        }
    }
}

private struct AttachmentCell: View {
    @EnvironmentObject private var store: AppStore
    let item: AttachmentItem
    let message: MaxMessage

    @State private var localURL: URL?
    @State private var previewURL: URL?
    @State private var loading = false
    @State private var failed: String?

    var body: some View {
        Group {
            switch item.kind {
            case .photo, .sticker:
                photoView
            case .audio:
                VoiceMessageRow(
                    durationMs: item.durationMs, wave: item.wave, encrypted: item.encrypted,
                    loading: loading, failed: failed,
                    fetch: {
                        await load(open: false)
                        return localURL
                    }
                )
            default:
                fileRow
            }
        }
        .quickLookPreview($previewURL)
        .task(id: item.id) {
            // Photos (incl. encrypted ones) load automatically; other media on demand.
            if item.kind == .photo || item.kind == .sticker { await load(open: false) }
        }
    }

    @ViewBuilder
    private var photoView: some View {
        let maxSide: CGFloat = item.kind == .sticker ? 140 : 260
        if let localURL, let img = PlatformImage.image(contentsOf: localURL) {
            img.resizable()
                .scaledToFit()
                .frame(maxWidth: maxSide, maxHeight: maxSide)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) { if item.encrypted { lockBadge } }
                .onTapGesture { previewURL = localURL }
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 200, height: 140)
                .overlay {
                    if loading { ProgressView() }
                    else if let failed {
                        VStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(failed).font(.caption2).multilineTextAlignment(.center)
                            Button("Повторить") { Task { await load(open: false) } }.font(.caption)
                        }.padding(8)
                    } else {
                        Image(systemName: "photo")
                    }
                }
        }
    }

    private var fileRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 40, height: 40)
                if loading { ProgressView().controlSize(.small) }
                else { Image(systemName: icon).foregroundStyle(.tint) }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if item.encrypted { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green) }
                    Text(title).font(.subheadline).lineLimit(1)
                }
                Text(failed ?? subtitle).font(.caption2).foregroundStyle(failed == nil ? Color.secondary : Color.red)
            }
            Spacer(minLength: 0)
            if let localURL {
                ShareLink(item: localURL) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
            }
        }
        .frame(minWidth: 200, maxWidth: 280, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { Task { await load(open: true) } }
    }

    private var lockBadge: some View {
        Image(systemName: "lock.fill")
            .font(.caption2)
            .padding(5)
            .background(.ultraThinMaterial, in: Circle())
            .padding(6)
    }

    private var icon: String {
        switch item.kind {
        case .video: return "play.fill"
        case .audio: return "waveform"
        default: return "doc.fill"
        }
    }

    private var title: String {
        switch item.kind {
        case .video: return item.name ?? "Видео"
        case .audio: return item.name ?? "Голосовое сообщение"
        default: return item.name ?? "Файл"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let size = item.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let ms = item.attachment.durationMs, ms > 0 {
            let s = Int(ms / 1000)
            parts.append(String(format: "%d:%02d", s / 60, s % 60))
        }
        parts.append(localURL == nil ? "Нажмите, чтобы открыть" : "Скачано")
        return parts.joined(separator: " · ")
    }

    private func load(open: Bool) async {
        if let localURL {
            if open { previewURL = localURL }
            return
        }
        loading = true
        failed = nil
        defer { loading = false }
        do {
            let url = try await store.localFile(for: item.attachment, in: message)
            localURL = url
            if open { previewURL = url }
        } catch {
            failed = error.localizedDescription
        }
    }
}

// MARK: - Picking files to send

struct PickedFile: Sendable {
    let data: Data
    let fileName: String
    let mime: String
    let width: Int?
    let height: Int?
}

enum UploadPreparer {
    static let maxBytes = 512 * 1024 * 1024

    /// Reads a picked file and normalises images: anything other than JPEG/PNG/WebP is re-encoded to JPEG.
    static func prepare(data: Data, fileName: String, type: UTType?) throws -> PickedFile {
        guard data.count <= maxBytes else {
            throw MediaError.unsupported("Файл больше 512 МБ")
        }
        let utType = type ?? UTType(filenameExtension: (fileName as NSString).pathExtension) ?? .data
        var mime = utType.preferredMIMEType ?? "application/octet-stream"
        var payload = data
        var name = fileName
        var w: Int?
        var h: Int?

        if utType.conforms(to: .image), let src = CGImageSourceCreateWithData(data as CFData, nil) {
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                w = props[kCGImagePropertyPixelWidth] as? Int
                h = props[kCGImagePropertyPixelHeight] as? Int
            }
            if !["image/jpeg", "image/png", "image/webp"].contains(mime),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let out = NSMutableData()
                if let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                    if CGImageDestinationFinalize(dest) {
                        payload = out as Data
                        mime = "image/jpeg"
                        name = ((fileName as NSString).deletingPathExtension) + ".jpg"
                    }
                }
            }
        }
        return PickedFile(data: payload, fileName: name, mime: mime, width: w, height: h)
    }

    static func read(url: URL) throws -> PickedFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return try prepare(data: data, fileName: url.lastPathComponent, type: type)
    }
}

/// Paperclip menu: files on every platform, plus the photo library on iOS.
struct AttachButton: View {
    let onPicked: (PickedFile) -> Void
    let onError: (String) -> Void
    var onPoll: (() -> Void)? = nil

    @State private var showingImporter = false
    #if os(iOS)
    @State private var showingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    #endif

    var body: some View {
        Menu {
            #if os(iOS)
            Button { showingPhotos = true } label: { Label("Фото или видео", systemImage: "photo.on.rectangle") }
            #endif
            Button { showingImporter = true } label: { Label("Файл", systemImage: "doc") }
            if let onPoll { Button(action: onPoll) { Label("Опрос…", systemImage: "chart.bar") } }
        } label: {
            Image(systemName: "paperclip").font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    do { onPicked(try UploadPreparer.read(url: url)) }
                    catch { onError(error.localizedDescription) }
                }
            case .failure(let err):
                onError(err.localizedDescription)
            }
        }
        #if os(iOS)
        .photosPicker(isPresented: $showingPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items {
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { return }
                        let type = item.supportedContentTypes.first
                        let ext = type?.preferredFilenameExtension ?? "bin"
                        let picked = try UploadPreparer.prepare(data: data, fileName: "IMG_\(Int(Date().timeIntervalSince1970)).\(ext)", type: type)
                        await MainActor.run { onPicked(picked) }
                    } catch {
                        await MainActor.run { onError(error.localizedDescription) }
                    }
                }
            }
        }
        #endif
    }
}
