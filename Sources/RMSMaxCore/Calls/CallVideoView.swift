// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
@preconcurrency import LiveKitWebRTC

/// Opaque handle to a local or remote video track, so the app never imports WebRTC itself.
public final class CallVideoTrack: @unchecked Sendable, Equatable {
    let track: RTCVideoTrack
    init(_ track: RTCVideoTrack) { self.track = track }
    public static func == (a: CallVideoTrack, b: CallVideoTrack) -> Bool { a.track === b.track }
}

/// Metal renderer for a call video track (aspect-fill for the peer, aspect-fit available for previews).
public struct CallVideoView: View {
    let track: CallVideoTrack
    let mirrored: Bool
    let fill: Bool

    public init(track: CallVideoTrack, mirrored: Bool = false, fill: Bool = true) {
        self.track = track
        self.mirrored = mirrored
        self.fill = fill
    }

    public var body: some View {
        Renderer(track: track, fill: fill)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
    }
}

#if os(iOS)
private struct Renderer: UIViewRepresentable {
    let track: CallVideoTrack
    let fill: Bool

    final class Coordinator { var attached: RTCVideoTrack? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView(frame: .zero)
        v.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        v.clipsToBounds = true
        attach(v, context.coordinator)
        return v
    }

    func updateUIView(_ v: RTCMTLVideoView, context: Context) {
        v.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        attach(v, context.coordinator)
    }

    static func dismantleUIView(_ v: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attached?.remove(v)
        coordinator.attached = nil
    }

    private func attach(_ v: RTCMTLVideoView, _ c: Coordinator) {
        guard c.attached !== track.track else { return }
        c.attached?.remove(v)
        track.track.add(v)
        c.attached = track.track
    }
}
#else
private struct Renderer: NSViewRepresentable {
    let track: CallVideoTrack
    let fill: Bool

    final class Coordinator { var attached: RTCVideoTrack? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView(frame: .zero)
        v.wantsLayer = true
        attach(v, context.coordinator)
        return v
    }

    func updateNSView(_ v: RTCMTLVideoView, context: Context) {
        attach(v, context.coordinator)
    }

    static func dismantleNSView(_ v: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attached?.remove(v)
        coordinator.attached = nil
    }

    private func attach(_ v: RTCMTLVideoView, _ c: Coordinator) {
        guard c.attached !== track.track else { return }
        c.attached?.remove(v)
        track.track.add(v)
        c.attached = track.track
    }
}
#endif
