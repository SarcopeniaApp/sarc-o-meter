//  SoundManager.swift
//
//  ══════════════════════ COUNTDOWN SOUND EFFECTS ══════════════════════
//  Provides sound effects & haptics for countdown (5, 4, 3, 2, 1) and START.
//  Uses synthesized PCM audio via AVAudioPlayer so sound works reliably on 
//  all devices and simulators, plus AudioServices system sounds & UIImpactFeedback.
//  ═════════════════════════════════════════════════════════════════════

import Foundation
import AVFoundation
import AudioToolbox
import UIKit

final class SoundManager {

    static let shared = SoundManager()

    private var audioPlayer: AVAudioPlayer?
    private var cachedPlayers: [Int: AVAudioPlayer] = [:]

    private init() {
        setupAudioSession()
        preloadCountdownSounds()
    }

    /// Setup audio session so sound plays even if silent switch is on (with mixWithOthers)
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("SoundManager: AudioSession setup error: \(error)")
        }
    }

    /// Pre-generate WAV PCM data for countdown numbers (5..1) and START (0)
    private func preloadCountdownSounds() {
        // Frequencies for 5, 4, 3, 2, 1 (rising pitch from 600 Hz to 1000 Hz)
        let freqs: [Int: Double] = [
            5: 600.0,
            4: 700.0,
            3: 800.0,
            2: 900.0,
            1: 1000.0,
            0: 1320.0  // GO / START sound
        ]

        for (num, freq) in freqs {
            let duration = num == 0 ? 0.25 : 0.12
            let wavData = generateBeepWAV(frequency: freq, duration: duration)
            if let player = try? AVAudioPlayer(data: wavData) {
                player.prepareToPlay()
                cachedPlayers[num] = player
            }
        }
    }

    /// Play countdown sound effect for a specific number (5, 4, 3, 2, 1)
    func playCountdownSound(number: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 1. Play synthesized audio beep
            if let player = self.cachedPlayers[number] {
                player.currentTime = 0
                player.play()
            } else {
                // Fallback synth on demand
                let freqs: [Int: Double] = [5: 600, 4: 700, 3: 800, 2: 900, 1: 1000]
                let f = freqs[number] ?? 800
                if let player = try? AVAudioPlayer(data: self.generateBeepWAV(frequency: f, duration: 0.12)) {
                    self.audioPlayer = player
                    player.play()
                }
            }

            // 2. Play iOS System Sound (1052: Tink)
            AudioServicesPlaySystemSound(1052)

            // 3. Trigger Haptic Feedback
            let haptic = UIImpactFeedbackGenerator(style: .medium)
            haptic.prepare()
            haptic.impactOccurred()
        }
    }

    /// Play START / GO sound effect when countdown reaches 0
    func playStartSound() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 1. Play high-pitched start sound (1320 Hz)
            if let player = self.cachedPlayers[0] {
                player.currentTime = 0
                player.play()
            } else if let player = try? AVAudioPlayer(data: self.generateBeepWAV(frequency: 1320, duration: 0.25)) {
                self.audioPlayer = player
                player.play()
            }

            // 2. Play iOS System Sound (1025: start chime / 1054: beep)
            AudioServicesPlaySystemSound(1054)

            // 3. Trigger Heavy/Success Haptic Feedback
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        }
    }

    // MARK: - PCM WAV Generator

    /// Generates a clean mono 16-bit 44.1kHz PCM WAV buffer with smooth envelope
    private func generateBeepWAV(frequency: Double, duration: Double, volume: Float = 0.7) -> Data {
        let sampleRate = 44100.0
        let numSamples = Int(sampleRate * duration)
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = Int32(sampleRate * Double(numChannels * (bitsPerSample / 8)))
        let blockAlign = Int16(numChannels * (bitsPerSample / 8))
        let dataSize = Int32(numSamples * Int(blockAlign))
        let chunkSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: [UInt8]("WAVE".utf8))

        // fmt subchunk
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        data.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data subchunk
        data.append(contentsOf: [UInt8]("data".utf8))
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        // Sine wave with smooth bell envelope (prevents clicking artifacts)
        for i in 0..<numSamples {
            let time = Double(i) / sampleRate
            let angle = 2.0 * .pi * frequency * time
            let progress = Double(i) / Double(numSamples)
            let envelope = sin(progress * .pi)

            let sampleValue = Int16(sin(angle) * Double(volume) * envelope * Double(Int16.max))
            data.append(contentsOf: withUnsafeBytes(of: sampleValue.littleEndian) { Array($0) })
        }

        return data
    }
}
