// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import AVKit
import SwiftUI

/// Plays the original audio or video, and reports where it is.
final class PlaybackController: ObservableObject {
    @Published var isLoaded = false
    @Published var isPlaying = false
    @Published var time = 0.0
    @Published var duration = 0.0
    @Published var rate: Float = 1
    @Published var hasVideo = false
    private(set) var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(_ url: URL) {
        teardown()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        isLoaded = true
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self, t.seconds.isFinite else { return }
            self.time = t.seconds
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.isPlaying = false
        }
        let asset = item.asset
        Task { @MainActor in
            if let d = try? await asset.load(.duration), d.seconds.isFinite { self.duration = d.seconds }
            if let tracks = try? await asset.loadTracks(withMediaType: .video) { self.hasVideo = !tracks.isEmpty }
        }
    }

    func toggle() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            if duration > 0, time >= duration - 0.1 { seek(to: 0, precise: true) }
            p.playImmediately(atRate: rate)
            isPlaying = true
        }
    }

    /// Moves to a time. A scrub seeks loosely, for speed; a jump to a place in the text seeks exactly.
    func seek(to t: Double, precise: Bool) {
        let target = min(max(t, 0), duration > 0 ? duration : t)
        let tolerance: CMTime = precise ? .zero : .positiveInfinity
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
        time = target
    }

    func setRate(_ r: Float) {
        rate = r
        if isPlaying { player?.rate = r }
    }

    func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        isLoaded = false
        isPlaying = false
        time = 0
        duration = 0
        hasVideo = false
    }
}

/// The picture of a video, without the system's own controls.
struct VideoView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
