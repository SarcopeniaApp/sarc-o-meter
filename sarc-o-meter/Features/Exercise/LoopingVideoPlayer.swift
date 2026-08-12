//  LoopingVideoPlayer.swift
//
//  A controls-free, muted, auto-looping video — for the exercise how-to preview
//  shown before each session. Wraps an AVPlayerLayer so there's no scrubber or
//  play/pause chrome (unlike AVKit's VideoPlayer): it just loops quietly.

import SwiftUI
import AVFoundation

struct LoopingVideoPlayer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer(playerItem: item)
        queue.isMuted = true
        // AVPlayerLooper must be retained for looping to keep working.
        view.looper = AVPlayerLooper(player: queue, templateItem: item)
        view.playerLayer.player = queue
        view.playerLayer.videoGravity = .resizeAspectFill
        view.player = queue
        queue.play()
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.player?.pause()
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }
}
