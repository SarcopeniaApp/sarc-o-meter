//  ExerciseView.swift
//
//  ══════════════════════ EXERCISE FEATURE — ENTRY POINT ══════════════════════
//  One configurable MediaPipe exercise session, used in two places:
//    • Screening exercise test → fixedMode: .sitToStand, allowSkip: true
//    • Tracker                 → fixedMode + intensity from the prescribed plan
//
//  Config:
//    fixedMode  — lock to one movement (nil shows the free 3-way picker)
//    intensity  — 0…1, passed to RepCounter (lower = less ROM needed per rep)
//    allowSkip  — show a "can't do this" button (screening)
//    onFinish(reps?) — reps done, or nil if skipped / closed
//
//  Everything under Features/Exercise/ is the exercise maintainer's; keep this
//  entry (`ExerciseView(...)` + `onFinish`) stable. Depends on MediaPipe (build
//  via the .xcworkspace after `pod install`).
//  ═════════════════════════════════════════════════════════════════════════════

import SwiftUI

struct ExerciseView: View {
    var fixedMode: ExerciseMode? = nil
    var intensity: Double = 1.0
    var allowSkip: Bool = false
    var headline: String? = nil
    let onFinish: (_ reps: Int?) -> Void

    @StateObject private var viewModel = PoseViewModel()
    @StateObject private var counter = RepCounter()

    private var startLabel: String {
        switch counter.session {
        case .running, .countdown: return "Batal"
        case .finished:            return "Ulangi"
        default:                   return "Mulai"
        }
    }

    var body: some View {
        ZStack {
            ExerciseCameraPreview(session: viewModel.cameraManager.session)
                .ignoresSafeArea()
            PoseOverlayView(landmarks: viewModel.landmarks, imageSize: viewModel.imageSize)
                .ignoresSafeArea()

            VStack {
                topBar
                modeHeader
                Spacer()
                statusDisplay
                calibrationHint
                controls
            }
        }
        .onAppear {
            if let fixedMode { counter.mode = fixedMode }
            counter.intensity = intensity
            viewModel.onPerson = { counter.process($0) }
            viewModel.start()
        }
        .onDisappear { viewModel.stop() }
    }

    // MARK: Top bar — close + optional skip

    private var topBar: some View {
        HStack {
            Button { finish(nil) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.4))
            }
            Spacer()
            // "Selesai" reports the reps done so far and moves on.
            if case .finished = counter.session {
                Button { finish(counter.repCount) } label: {
                    Text("Selesai")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(Color.green, in: Capsule())
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: Mode label / picker

    @ViewBuilder
    private var modeHeader: some View {
        if let headline {
            Text(headline)
                .font(.headline).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.black.opacity(0.4), in: Capsule())
                .padding(.top, 4)
        }
        if fixedMode == nil {
            Picker("Mode", selection: $counter.mode) {
                ForEach(ExerciseMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            .background(.ultraThinMaterial)
        } else {
            Text(counter.mode.rawValue)
                .font(.subheadline).foregroundColor(.white.opacity(0.9))
        }
    }

    // MARK: Status (rep count / countdown / finished)

    @ViewBuilder
    private var statusDisplay: some View {
        switch counter.session {
        case .idle:
            Text("\(counter.repCount)")
                .font(.system(size: 84, weight: .bold, design: .rounded)).foregroundColor(.white)
            Text("Tekan Mulai untuk memulai")
                .font(.headline).foregroundColor(.white.opacity(0.8))
        case .countdown(let s):
            Text("\(s)")
                .font(.system(size: 120, weight: .bold, design: .rounded)).foregroundColor(.yellow)
            Text("Bersiap…").font(.headline).foregroundColor(.white.opacity(0.8))
        case .running(let s):
            Text("\(counter.repCount)")
                .font(.system(size: 84, weight: .bold, design: .rounded)).foregroundColor(.white)
            Text("Sisa waktu: \(s) detik").font(.headline).foregroundColor(.green)
        case .finished:
            Text("\(counter.repCount)")
                .font(.system(size: 84, weight: .bold, design: .rounded)).foregroundColor(.white)
            Text("Selesai! Total \(counter.repCount) repetisi")
                .font(.headline).foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var calibrationHint: some View {
        switch counter.session {
        case .countdown, .running:
            Text(counter.isReady ? "Terkalibrasi" : "Bergeraklah untuk kalibrasi")
                .font(.subheadline)
                .foregroundColor(counter.isReady ? .green : .white.opacity(0.7))
                .padding(.top, 4)
        default:
            EmptyView()
        }
    }

    // MARK: Controls — start/stop + skip

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                switch counter.session {
                case .running, .countdown: counter.stopSession()
                default:                   counter.startSession()
                }
            } label: {
                Text(startLabel)
                    .padding(.horizontal, 32).padding(.vertical, 12)
                    .background(Color.green, in: Capsule())
                    .foregroundColor(.white)
            }

            if allowSkip {
                Button { finish(nil) } label: {
                    Text("Saya tidak bisa melakukannya")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .underline()
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 40)
    }

    private func finish(_ reps: Int?) {
        viewModel.stop()
        onFinish(reps)
    }
}
