//  ExerciseView.swift
//
//  ══════════════════════ EXERCISE FEATURE — ENTRY POINT ══════════════════════
//  One configurable MediaPipe exercise session, used in two places:
//    • Screening exercise test → fixedMode + allowSkip: true (driven by ContentView)
//    • Tracker                 → fixedMode + intensity from the prescribed plan
//
//  Layout follows the scan flow (see PoseCaptureView): the camera lives inside a
//  rounded rectangle frame, with the live status/instructions BELOW it (position
//  prompt → countdown → timer ring + rep count → result), all inside PageWrapper.
//
//  Config:
//    fixedMode  — lock to one movement (nil shows counter's default)
//    intensity  — 0…1, passed to RepCounter (lower = less ROM needed per rep)
//    allowSkip  — show a "can't do this" button (screening)
//    showInstructions — play the how-to pre-roll first (default true; off for the Lab)
//    stepIndex/totalSteps — progress dots for the 3-exercise screening test
//    nextExerciseName — label the "continue" button on the result
//    onFinish(reps?) — reps done, or nil if skipped / closed
//
//  Everything under Features/Exercise/ is the exercise maintainer's; keep this
//  entry (`ExerciseView(...)` + `onFinish`) stable. Depends on MediaPipe.
//  ═════════════════════════════════════════════════════════════════════════════

import SwiftUI
import UIKit
import AVFoundation

struct ExerciseView: View {
    var fixedMode: ExerciseMode? = nil
    var intensity: Double = 1.0
    var allowSkip: Bool = false
    var headline: String? = nil
    var showInstructions: Bool = true
    var stepIndex: Int? = nil
    var totalSteps: Int? = nil
    var nextExerciseName: String? = nil
    var onBack: (() -> Void)? = nil
    let onFinish: (_ reps: Int?) -> Void

    @StateObject private var viewModel = PoseViewModel()
    @StateObject private var counter = RepCounter()
    @StateObject private var beeper  = RepBeeper()
    @State private var inCamera = false        // false → showing the how-to pre-roll
    @State private var cameraBlurred = false   // blur the frame once finished
    @AppStorage("showExerciseLandmarks") private var showSkeleton = true     // toggle skeleton overlay on/off (persisted across exercises)

    private let VPW = UIScreen.main.bounds.size.width

    var body: some View {
        if showInstructionScreen {
            ExerciseInstructionView(
                mode: fixedMode ?? counter.mode,
                allowSkip: allowSkip,
                stepIndex: stepIndex,
                totalSteps: totalSteps,
                onStart: { inCamera = true },
                onSkip: { finish(nil) },
                onBack: onBack            // back on the pre-roll → previous exercise
            )
        } else {
            cameraBody
        }
    }

    // The how-to pre-roll runs before a specific exercise; the free-picker Lab
    // (fixedMode == nil) and any caller that opts out go straight to the camera.
    private var showInstructionScreen: Bool {
        showInstructions && fixedMode != nil && !inCamera
    }

    // Back from the camera returns to THIS exercise's pre-roll (resetting the
    // session), when there is one; otherwise it pops out to the caller (e.g. the
    // Lab has no pre-roll).
    private var cameraBackAction: (() -> Void)? {
        if showInstructions && fixedMode != nil {
            return {
                counter.stopSession()
                cameraBlurred = false
                inCamera = false
            }
        }
        return onBack
    }

    // MARK: - Camera screen (framed, PoseCaptureView-style)

    private var cameraBody: some View {
        PageWrapper(
            title: headline ?? counter.mode.rawValue,
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
                        cameraFrame
                        
                        VStack(spacing: 0) {
                            Spacer()
                            if case .countdown(let s) = counter.session {
                                VStack(spacing: 4) {
                                    Text("Mulai Dalam")
                                        .font(.title2.bold())
                                        .foregroundStyle(.white)
                                    Text("\(s)")
                                        .font(.system(size: 54, weight: .bold, design: .rounded))
                                        .foregroundStyle(.yellow)
                                        .contentTransition(.numericText())
                                        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: s)
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20))
                            } else if case .running = counter.session {
                                timerRing
                            } else {
                                EmptyView()
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }

                    statusBelow
                    
                    Spacer()

                    bottomAction
                }
                .frame(maxWidth: .infinity)
            },
            trailing: {
                HStack(spacing: 8) {
                    Text("Show Landmarks")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.muted)
                    Toggle("", isOn: $showSkeleton)
                        .labelsHidden()
                        .tint(Theme.accent)
                }
            },
            scrollable: false,
            onBack: cameraBackAction   // back on the camera → this exercise's pre-roll
        )
        .onAppear {
            if let fixedMode { counter.mode = fixedMode }
            counter.intensity = intensity
            viewModel.onPerson = { counter.process($0) }
            viewModel.start()
        }
        .onDisappear { viewModel.stop() }
        .onChange(of: counter.session) { _, newState in
            if case .finished = newState {
                cameraBlurred = true
                viewModel.stop()
            }
        }
        .onChange(of: counter.repCount) { _, newCount in
            // Only beep while the session is running (ignore resets to 0).
            if case .running = counter.session, newCount > 0 {
                beeper.beep(forRep: newCount)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: cameraBlurred)
    }

    // MARK: Camera frame (camera + skeleton overlay, both aspect-fill into the frame)

    private var cameraFrame: some View {
        ZStack {
            ExerciseCameraPreview(session: viewModel.cameraManager.session)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .blur(radius: cameraBlurred ? 18 : 0)

            if !cameraBlurred && showSkeleton {
                PoseOverlayView(landmarks: viewModel.landmarks, imageSize: viewModel.imageSize)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            }

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(frameBorderColor, lineWidth: 3)
                .animation(.easeInOut(duration: 0.2), value: counter.session)
                .animation(.easeInOut(duration: 0.2), value: counter.isPostureStabilizing)
        }
        .frame(width: VPW - 48, height: (VPW - 48) * 1.2)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        // Tap-to-start fallback (the counter also auto-starts on a steady posture).
        .onTapGesture {
            if case .idle = counter.session { counter.startSession() }
        }
    }

    private var frameBorderColor: Color {
        switch counter.session {
        case .running, .finished: return .green
        case .countdown:          return .yellow
        case .idle:               return counter.isPostureStabilizing ? .green : Color.white.opacity(0.9)
        }
    }

    // MARK: Status below the frame (the "instructions")

    @ViewBuilder
    private var statusBelow: some View {
        VStack(spacing: 4) {
            switch counter.session {
            case .idle:
                positionPrompt

            case .countdown:
                VStack(spacing: 6) {
                    Text("Posisi Terdeteksi!")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Tahan posisi — latihan mulai otomatis")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }

            case .running:
                VStack(spacing: 6) {
                    Text("Latihan Berlangsung")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Lakukan gerakan senyaman & seaman mungkin")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }

            case .finished:
                VStack(spacing: 6) {
                    Text("Selesai!")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.green)
                    Text("\(counter.repCount) repetisi berhasil")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .frame(height: 60)
    }

    private var positionPrompt: some View {
        let stabilizing = counter.isPostureStabilizing
        let sit = counter.mode == .sitToStand
        return VStack(spacing: 6) {
            Text(stabilizing ? "Posisi Terdeteksi!" : (sit ? "Silakan Duduk di Kursi" : "Berdiri Tampak Samping"))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text(stabilizing
                 ? "Tahan posisi — latihan mulai otomatis"
                 : (sit ? "Ambil posisi duduk di kursi untuk mulai otomatis"
                        : "Berdiri tegak menghadap samping untuk mulai otomatis"))
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
        }
    }

    private var timerRing: some View {
        let progress = counter.elapsedFraction
        return ZStack {
            Circle()
                .fill(.white)
                .frame(width: 90, height: 90)
                .overlay(
                    Text("\(counter.repCount)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                )
            
            Circle()
                .stroke(Theme.faint.opacity(0.5), lineWidth: 14)
                .frame(width: 118, height: 118)
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(timerColor(progress), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .frame(width: 118, height: 118)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.05), value: progress)
        }
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }

    private func timerColor(_ progress: Double) -> Color {
        if progress > 0.5 { return .green }
        if progress > 0.25 { return .yellow }
        return .red
    }

    // MARK: Bottom action (continue when finished; skip otherwise)

    @ViewBuilder
    private var bottomAction: some View {
        VStack {
            switch counter.session {
            case .finished:
                PrimaryButton(title: nextExerciseName != nil ? "Lanjut ke \(nextExerciseName!)" : "Selesai") {
                    finish(counter.repCount)
                }
            default:
                if allowSkip {
                    Button { finish(nil) } label: {
                        Text("Saya tidak bisa melakukannya")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.muted)
                            .underline()
                    }
                }
            }
        }
        .frame(height: 50)
    }

    private func finish(_ reps: Int?) {
        viewModel.stop()
        onFinish(reps)
    }
}
