//  RepBeeper.swift
//
//  Plays a short pitched beep whenever a rep is completed.
//  Frequency rises linearly from rep 1 (low A, 220 Hz) to rep 15 (high A, 880 Hz)
//  and stays at 880 Hz for any rep beyond 15.

import AVFoundation
import Combine

final class RepBeeper: ObservableObject {

    // MARK: - Frequency range

    /// Frequency (Hz) played on the 1st rep.
    private static let minFreq: Float = 220.0   // A3
    /// Frequency (Hz) played on rep 15 and above.
    private static let maxFreq: Float = 880.0   // A5
    /// Rep number at which the frequency is capped.
    private static let repCap: Int = 15

    // MARK: - Audio engine

    // Use an explicit mono format everywhere so the buffer format
    // always matches the player→mixer connection format.
    private static let sampleRate: Double = 44_100
    private static let audioFormat = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channels: 1)!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private let audioQueue = DispatchQueue(label: "com.sarc-o-meter.beeper",
                                           qos: .userInitiated)

    init() {
        // Attach & connect on the audio queue to keep main thread free.
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.engine.attach(self.player)
            self.engine.connect(self.player,
                                to: self.engine.mainMixerNode,
                                format: Self.audioFormat)   // explicit mono ↔ matches buffer
            try? self.engine.start()
        }
    }

    // MARK: - Public API

    /// Call this every time a new rep completes.  `repNumber` is 1-indexed.
    func beep(forRep repNumber: Int) {
        let clamped = min(max(repNumber, 1), Self.repCap)
        let t       = Float(clamped - 1) / Float(Self.repCap - 1)   // 0…1
        let freq    = Self.minFreq + t * (Self.maxFreq - Self.minFreq)
        audioQueue.async { [weak self] in
            self?.play(frequency: freq)
        }
    }

    // MARK: - Synthesis

    private func play(frequency: Float) {
        let duration    = 0.12                                // seconds
        let rampSamples = 512                                 // cosine fade-out length
        let frameCount  = AVAudioFrameCount(Self.sampleRate * duration)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.audioFormat,
                                            frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]

        for i in 0..<Int(frameCount) {
            let sample = sinf(2 * .pi * frequency * Float(i) / Float(Self.sampleRate))
            // Cosine fade-out on the tail to eliminate the end-of-buffer click.
            let remaining = Int(frameCount) - i
            let env: Float = remaining < rampSamples
                ? 0.5 * (1 + cosf(.pi * Float(rampSamples - remaining) / Float(rampSamples)))
                : 1
            data[i] = sample * env * 0.6
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }
}
