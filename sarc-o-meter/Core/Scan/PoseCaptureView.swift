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
                GeometryReader { geo in
                    let availableHeight = geo.size.height
                    let targetHeight = (VPW - 48) * 1.72
                    let frameHeight = min(targetHeight, availableHeight > 0 ? availableHeight : targetHeight)
                    
                    VStack(spacing: 0) {
                        ZStack {
                            CameraPreview(session: camera.session)
                                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            
                            // Pose guide: shows humanpose.png for front pose, and sidepose for side pose.
                            // Positioned aligned to top and scaled down to leave space for bottom instructions overlay.
                            VStack {
                                Group {
                                    if camera.phase == .front {
                                        Image("humanpose")
                                            .renderingMode(.template)
                                            .resizable()
                                            .scaledToFit()
                                    } else {
                                        Image("sidepose")
                                            .renderingMode(.template)
                                            .resizable()
                                            .scaledToFit()
                                    }
                                }
                                .foregroundStyle(Color.yellow)
                                .padding(.top, 20)
                                .padding(.horizontal, 62)
                                .opacity(camera.bodyVisible ? 0.35 : 0.75)
                                .animation(.easeInOut(duration: 0.3), value: camera.bodyVisible)
                                .animation(.easeInOut(duration: 0.2), value: camera.phase)
                                .allowsHitTesting(false)
                                
                                Spacer(minLength: 120)
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

                            // Instruction text overlay inside camera frame (bottom position)
                            overlayInstructions

                            
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
                        .frame(width: VPW - 48, height: frameHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
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

    // MARK: Overlay instruction text inside camera frame

    private var overlayInstructions: some View {
        VStack {
            Spacer()
            
            VStack(spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text(camera.guidance)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(stepLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }
}
