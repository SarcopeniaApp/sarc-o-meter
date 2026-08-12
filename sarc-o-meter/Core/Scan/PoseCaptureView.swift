//  PoseCaptureView.swift
//
//  Hands-free capture, styled to match the rest of the scan flow: a light header,
//  the live camera in a big rounded frame (its border glows terracotta while you
//  hold the pose), and an instruction + step line below. Front A-pose first, then
//  side; `onComplete` fires with both photos. No shutter tap — PoseCamera watches
//  each frame and grabs it when the pose is held steady.

import SwiftUI
import UIKit

struct PoseCaptureView: View {
    let onComplete: (_ front: UIImage, _ side: UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = PoseCamera()

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: "Pindai Tubuh") {
                camera.stop(); dismiss()
            }

            cameraFrame
                .padding(.horizontal, 20)
                .padding(.top, 6)

            instructions
                .padding(.top, 22)

            Spacer(minLength: 12)

            Text(stepLabel)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear {
            camera.onComplete = { front, side in
                camera.stop()
                onComplete(front, side)
                dismiss()
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    // MARK: Camera frame

    private var cameraFrame: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            // Pose guide: shows the target pose (A-pose, then side). It's bold while
            // the person is too close (whole body not yet in frame) to nudge them to
            // step back, and fades once their full body is visible.
            Image(camera.phase == .side ? "PoseGuideSide" : "PoseGuideFront")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(.vertical, 34)
                .opacity(camera.bodyVisible ? 0.16 : 0.72)
                .animation(.easeInOut(duration: 0.3), value: camera.bodyVisible)
                .animation(.easeInOut(duration: 0.2), value: camera.phase)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(camera.poseDetected ? Color.green : Color.white.opacity(0.9),
                        lineWidth: 3)
                .animation(.easeInOut(duration: 0.15), value: camera.poseDetected)

            if !camera.authorized {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.black.opacity(0.8))
                Text("Akses kamera diperlukan.\nAktifkan di Pengaturan.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
            }

            // Hold-to-capture ring, tucked into the bottom of the frame.
            VStack {
                Spacer()
                ZStack {
                    Circle().stroke(.white.opacity(0.4), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: camera.progress)
                        .stroke(camera.poseDetected ? Color.green : Theme.accent,
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.1), value: camera.progress)
                }
                .frame(width: 58, height: 58)
                .padding(.bottom, 18)
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
    }

    // MARK: Instruction text

    private var instructions: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text(camera.guidance)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
        }
    }

    private var title: String {
        switch camera.phase {
        case .front: return "Foto depan"
        case .side:  return "Foto samping"
        case .done:  return "Selesai"
        }
    }

    private var stepLabel: String {
        switch camera.phase {
        case .front: return "langkah 1 dari 2"
        case .side:  return "langkah 2 dari 2"
        case .done:  return "selesai"
        }
    }
}
