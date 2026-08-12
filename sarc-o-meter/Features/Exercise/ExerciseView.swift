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
//    showInstructions — play the how-to pre-roll first (default true; off for the Lab)
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
    var showInstructions: Bool = true
    var stepIndex: Int? = nil
    var totalSteps: Int? = nil
    var nextExerciseName: String? = nil
    let onFinish: (_ reps: Int?) -> Void

    @StateObject private var viewModel = PoseViewModel()
    @StateObject private var counter = RepCounter()
    @State private var inCamera = false        // false → showing the how-to pre-roll

    /// Apakah sheet hasil sedang ditampilkan
    @State private var showResultSheet = false
    /// Apakah kamera perlu di-blur (setelah finished)
    @State private var cameraBlurred = false

    var body: some View {
        if showInstructionScreen {
            ExerciseInstructionView(
                mode: fixedMode ?? counter.mode,
                allowSkip: allowSkip,
                onStart: { inCamera = true },
                onSkip: { finish(nil) }
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

    private var cameraBody: some View {
        ZStack {
            // ── Layer 1: Camera feed ──────────────────────────────────────
            ExerciseCameraPreview(session: viewModel.cameraManager.session)
                .ignoresSafeArea()
                .blur(radius: cameraBlurred ? 20 : 0)

            // ── Layer 2: Skeleton overlay (hidden when finished) ──────────
            if !cameraBlurred {
                PoseOverlayView(landmarks: viewModel.landmarks, imageSize: viewModel.imageSize)
                    .ignoresSafeArea()
            }

            // ── Layer 3: UI controls (z di atas kamera) ──────────────────
            VStack(spacing: 0) {
                topBar
                Spacer()
                centerContent
                Spacer()
                bottomControls
            }
        }
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
                // Sedikit delay agar animasi blur selesai sebelum sheet muncul
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showResultSheet = true
                }
            }
        }
        .sheet(isPresented: $showResultSheet, onDismiss: {
            finish(counter.repCount)
        }) {
            ResultSheetView(
                exerciseName: counter.mode.rawValue,
                duration: 30,
                repCount: counter.repCount,
                nextExerciseName: nextExerciseName
            )
        }
        .animation(.easeInOut(duration: 0.3), value: cameraBlurred)
    }

    // MARK: - Top Bar (bentuk sudut iPhone, menutupi Dynamic Island)

    private var topBar: some View {
        VStack(spacing: 0) {
            // Area yang menutupi Dynamic Island / notch
            Color.white
                .frame(height: 0) // Tinggi diatur oleh safe area padding

            VStack(alignment: .leading, spacing: 12) {
                // Stepper indicator (jika berada dalam rangkaian tes)
                if let stepIndex = stepIndex, let totalSteps = totalSteps {
                    HStack(spacing: 8) {
                        ForEach(0..<totalSteps, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(i <= stepIndex ? Theme.accent : Theme.faint)
                                .frame(height: 6)
                        }
                    }
                }

                HStack {
                    // Nama exercise / headline
                    Text(headline ?? counter.mode.rawValue)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.ink)

                    Spacer()

                    if allowSkip {
                        Button {
                            finish(nil)
                        } label: {
                            Text("Skip")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.red)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(20)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                Color.white
                    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .edgesIgnoringSafeArea(.top)
            )
        }
    }

    // MARK: - Center Content (countdown besar di tengah layar)

    @ViewBuilder
    private var centerContent: some View {
        switch counter.session {
        case .idle:
            positionPromptCard

        case .countdown(let s):
            // Angka countdown besar di tengah layar
            Text("\(s)")
                .font(.system(size: 140, weight: .bold, design: .rounded))
                .foregroundColor(.yellow)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .transition(.scale(scale: 1.3).combined(with: .opacity))
                .id("countdown-\(s)")
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: s)

            Text("Bersiap…")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

        default:
            EmptyView()
        }
    }

    // MARK: - Bottom Controls

    @ViewBuilder
    private var bottomControls: some View {
        switch counter.session {
        case .idle, .countdown:
            // Otomatis mulai dari deteksi posisi — tidak ada tombol manual
            EmptyView()

        case .running(let s):
            timerCircle(remaining: s)
                .padding(.bottom, 60)

        case .finished:
            EmptyView()
        }
    }

    // MARK: - Kartu Petunjuk Posisi (Auto Start)

    private var positionPromptCard: some View {
        let isStabilizing = counter.isPostureStabilizing

        return VStack(spacing: 10) {
            Image(systemName: isStabilizing ? "checkmark.circle.fill" : (counter.mode == .sitToStand ? "figure.seat.row.left" : "figure.stand"))
                .font(.system(size: 40))
                .foregroundColor(isStabilizing ? .green : .yellow)
                .scaleEffect(isStabilizing ? 1.15 : 1.0)
                .animation(.spring(response: 0.3), value: isStabilizing)

            Text(isStabilizing ? "Posisi Terdeteksi!" : (counter.mode == .sitToStand ? "Silakan Duduk di Kursi" : "Berdiri Tampak Samping"))
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)

            Text(isStabilizing ? "Tahan posisi" : (counter.mode == .sitToStand ? "Ambil posisi duduk di kursi untuk mulai otomatis" : "Berdiri tegak menghadap samping untuk mulai otomatis"))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(isStabilizing ? Color.green.opacity(0.8) : Color.yellow.opacity(0.6), lineWidth: 1.5)
                )
        )
        .padding(.horizontal, 30)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
        .animation(.easeInOut(duration: 0.2), value: isStabilizing)
        .onTapGesture {
            counter.startSession()
        }
    }

    // MARK: - Timer Circle (running state)

    private func timerCircle(remaining: Int) -> some View {
        let progress = counter.elapsedFraction
        let timerColor = timerStrokeColor(progress: progress)

        return ZStack {
            // Background ring (track)
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 18)
                .frame(width: 150, height: 150)

            // Animated progress ring
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(timerColor, style: StrokeStyle(lineWidth: 18, lineCap: .butt))
                .frame(width: 150, height: 150)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.05), value: progress)

            // White fill circle
            Circle()
                .fill(Color.white)
                .frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.1), radius: 6, y: 3)

            // Rep count inside
            Text("\(counter.repCount)")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.black)

            // Sisa waktu kecil di bawah angka
            Text("repetisi")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.gray)
                .offset(y: 30)
        }
    }

    /// Warna border berdasarkan progress: hijau → kuning → merah
    private func timerStrokeColor(progress: Double) -> Color {
        if progress > 0.5 {
            return .green
        } else if progress > 0.25 {
            return .yellow
        } else {
            return .red
        }
    }

    private func finish(_ reps: Int?) {
        viewModel.stop()
        onFinish(reps)
    }
}

// MARK: - Result Sheet

struct ResultSheetView: View {
    let exerciseName: String
    let duration: Int
    let repCount: Int
    var nextExerciseName: String? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Handle bar
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 12)

            // Title
            Text("Hasil Latihan")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Theme.ink)

            // Results cards
            VStack(spacing: 12) {
                resultRow(icon: "figure.strengthtraining.traditional",
                          label: "Jenis Latihan",
                          value: exerciseName)

                resultRow(icon: "clock.fill",
                          label: "Durasi",
                          value: "\(duration) detik")

                resultRow(icon: "repeat",
                          label: "Repetisi",
                          value: "\(repCount) kali",
                          valueColor: Theme.ink)
            }
            .padding(.horizontal, 24)

            Spacer()

            // Tombol selesai
            Button {
                dismiss()
            } label: {
                Text(nextExerciseName != nil ? "Lanjut ke \(nextExerciseName!)" : "Selesai")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.card)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Theme.accent)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .padding(.vertical, 16)
        .background(Theme.bg.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(false)
    }

    private func resultRow(icon: String, label: String, value: String,
                           valueColor: Color? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accentSoft, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(valueColor ?? Theme.ink)
            }

            Spacer()
        }
        .padding(14)
        .background(Theme.card)
        .cornerRadius(12)
    }
}
