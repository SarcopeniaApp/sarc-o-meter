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
    let onBack: () -> Void
    let onComplete: (_ front: UIImage, _ side: UIImage) -> Void
    
    @StateObject private var camera = PoseCamera()
    
    private let VPW = UIScreen.main.bounds.size.width

    var body: some View {
        PageWrapper(
            title: "Scan Tubuh",
            content: {
                VStack(spacing: 24) {
                    ZStack {
                        CameraPreview(session: camera.session)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        
                        // Pose guide: shows humanpose.png for front pose, and PoseGuideSide for side pose.
                        // It serves as a visual guide overlay on top of the camera feed.
                        if camera.phase == .front {
                            Image("humanpose")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(Color.yellow)
                                .padding(.vertical, 24)
                                .opacity(camera.bodyVisible ? 0.35 : 0.75)
                                .animation(.easeInOut(duration: 0.3), value: camera.bodyVisible)
                                .animation(.easeInOut(duration: 0.2), value: camera.phase)
                                .allowsHitTesting(false)
                        } else {
                            Image("sidepose")
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(Color.yellow)
                                .padding(.vertical, 24)
                                .opacity(camera.bodyVisible ? 0.35 : 0.75)
                                .animation(.easeInOut(duration: 0.3), value: camera.bodyVisible)
                                .animation(.easeInOut(duration: 0.2), value: camera.phase)
                                .allowsHitTesting(false)
                        }

                        
                        // Animated progress border filling from top clockwise
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .trim(from: 0, to: camera.poseDetected ? camera.progress : 0)
                            .stroke(frameBorderColor, style: StrokeStyle(lineWidth: 24, lineCap: .round))
                            .animation(.linear(duration: 0.1), value: camera.progress)
                            .animation(.easeInOut(duration: 0.25), value: frameBorderColor)
                        
                        if !camera.authorized {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(.black.opacity(0.8))
                            Text("Akses kamera diperlukan.\nAktifkan di Pengaturan.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                        }

                        
                        // Success transition overlay: green background + loading animation for 2s
                        if camera.isTransitioning {
                            ZStack {
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .fill(Color.green)
                                
                                VStack(spacing: 16) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 60, weight: .bold))
                                        .foregroundStyle(.white)
                                    
                                    ProgressView()
                                        .tint(.white)
                                        .controlSize(.large)
                                    
                                    Text("Berhasil Dipindai!")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.white)
                                    
                                    Text(camera.phase == .front ? "Menyiapkan pindai tubuh samping..." : "Memproses hasil...")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                                .padding(24)
                            }
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.3), value: camera.isTransitioning)
                        }
                    }
                    .frame(width: VPW - 48, height: (VPW - 48) * 1.4)

                    instructions
                    
                    //Spacer()
                    
                    // Footer
                    Text(stepLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                .frame(width: .infinity)
            },
            scrollable: false,
            onBack: {
                camera.stop()
                onBack()
            }
        )
        .onAppear {
            camera.onComplete = { front, side in
                camera.stop()
                onComplete(front, side)
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
    }
    
    private var frameBorderColor: Color {
        if camera.poseDetected {
            return camera.progress < 0.70 ? Color.yellow : Color.green
        } else {
            return Color.white.opacity(0.9)
        }
    }
    
    private var title: String {
        switch camera.phase {
            case .front: return "Hadap depan"
            case .side:  return "Hadap samping"
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

    // MARK: Instruction text

    private var instructions: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title.bold())
                .foregroundStyle(Theme.ink)
            Text(camera.guidance)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
        }
    }

    
}
