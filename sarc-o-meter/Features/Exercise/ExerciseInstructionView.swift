//  ExerciseInstructionView.swift
//
//  The how-to shown before every exercise session (screening test AND tracker).
//  Same layout language as the body-scan page: a framed (not full-screen) looping
//  video up top, text instructions below, a "Mulai" button, and — during the
//  screening — a "can't do it" skip. ExerciseView presents this first, then the
//  camera. Videos are bundled placeholders (Instructions/<key>.mp4) to be swapped
//  for real footage later; if none is found, a clear placeholder card shows.

import SwiftUI

struct ExerciseInstructionView: View {
    let mode: ExerciseMode
    var allowSkip: Bool = false
    let onStart: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: "Panduan Latihan")

            ScreenTitle(title: mode.displayName,
                        subtitle: "Lihat dulu caranya, lalu tekan Mulai ketika Anda siap.")
                .padding(.horizontal, 20)
                .padding(.top, 12)

            videoFrame
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Text(mode.instructionText)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.top, 18)

            Spacer(minLength: 12)

            VStack(spacing: 12) {
                PrimaryButton(title: "Mulai", action: onStart)
                if allowSkip {
                    Button(action: onSkip) {
                        Text("Saya tidak bisa melakukannya")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.muted)
                            .underline()
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var videoFrame: some View {
        ZStack {
            if let url = mode.instructionVideoURL {
                LoopingVideoPlayer(url: url)
            } else {
                Theme.accentSoft
                VStack(spacing: 10) {
                    Image(systemName: "film")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accent)
                    Text("Video panduan akan ditampilkan di sini")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 10, y: 6)
    }
}

// MARK: - Per-exercise instruction copy + placeholder video

extension ExerciseMode {
    var displayName: String {
        switch self {
        case .sitToStand: return "Berdiri dari Kursi"
        case .stepUp:     return "Naik Step"
        case .calfRaise:  return "Jinjit (Angkat Tumit)"
        }
    }

    var instructionText: String {
        switch self {
        case .sitToStand:
            return "Duduk di kursi yang kokoh, lalu berdiri tanpa bantuan tangan dan duduk kembali. Ulangi dengan gerakan yang nyaman."
        case .stepUp:
            return "Naik ke atas step atau anak tangga dengan satu kaki, lalu turun. Bergantian kaki sambil menjaga keseimbangan."
        case .calfRaise:
            return "Berdiri tegak (boleh berpegangan), angkat kedua tumit hingga berjinjit, lalu turunkan perlahan."
        }
    }

    /// Bundled placeholder how-to video (Features/Exercise/Instructions/<key>.mp4).
    var instructionVideoURL: URL? {
        let key: String
        switch self {
        case .sitToStand: key = "sitToStand"
        case .stepUp:     key = "stepUp"
        case .calfRaise:  key = "calfRaise"
        }
        return Bundle.main.url(forResource: key, withExtension: "mp4")
    }
}
