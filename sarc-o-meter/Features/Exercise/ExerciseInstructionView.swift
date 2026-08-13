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
    var stepIndex: Int? = nil
    var totalSteps: Int? = nil
    let onStart: () -> Void
    let onSkip: () -> Void
    var onBack: (() -> Void)? = nil

    private let VPW = UIScreen.main.bounds.size.width

    var body: some View {
        PageWrapper(
            title: mode.displayName,
            content: {
                VStack(spacing: 24) {
                    // Progress dots (only within the 3-exercise test).
                    if let stepIndex, let totalSteps {
                        HStack(spacing: 8) {
                            ForEach(0..<totalSteps, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(i <= stepIndex ? Theme.accent : Theme.faint)
                                    .frame(height: 6)
                            }
                        }
                    }
                    
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
                    .frame(width: VPW - 48, height: (VPW - 48))
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: Theme.cardShadow, radius: 10, y: 6)
                    
                    VStack(spacing: 8) {
                        Text("Panduan Latihan")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.ink)
                        Text(mode.instructionText)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
            },
            footer: {
                HStack(spacing: 14) {
                    SecondaryButton(title: "Lewati", action: onSkip)
                    PrimaryButton(title: "Mulai", action: onStart)
                }
            },
            onBack: onBack
        )
    }
}

// MARK: - Per-exercise instruction copy + placeholder video

extension ExerciseMode {
    var displayName: String {
        switch self {
        case .sitToStand: return "Sit to Stand"
        case .stepUp:     return "Step Up"
        case .calfRaise:  return "Calf Raises"
        }
    }

    var instructionText: String {
        switch self {
        case .sitToStand:
            return "Duduk di kursi yang kokoh, lalu berdiri tanpa bantuan tangan dan duduk kembali. Ulangi dengan gerakan yang nyaman. Pilih lewati apabila tidak bisa."
        case .stepUp:
            return "Naik ke atas step atau anak tangga dengan satu kaki, lalu turun. Bergantian kaki sambil menjaga keseimbangan. Pilih lewati apabila tidak bisa."
        case .calfRaise:
            return "Berdiri tegak (boleh berpegangan), angkat kedua tumit hingga berjinjit, lalu turunkan perlahan. Pilih lewati apabila tidak bisa."
        }
    }

    /// Bundled placeholder how-to video (Features/Exercise/Instructions/<key>.mp4).
    var instructionVideoURL: URL? {
        let keys: [String]
        switch self {
        case .sitToStand: keys = ["sit-to-stand", "sitToStand", "sit-to stand"]
        case .stepUp:     keys = ["step-up", "stepUp"]
        case .calfRaise:  keys = ["calf-raise", "calfRaise"]
        }
        for key in keys {
            if let url = Bundle.main.url(forResource: key, withExtension: "mp4") {
                return url
            }
        }
        return nil
    }
}
