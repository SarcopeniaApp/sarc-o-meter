//  PoseCamera.swift
//
//  Live camera + body-pose detection that auto-captures the front A-pose, then
//  the side profile, with no timer or shutter tap. It watches each frame; when
//  the target pose is held steadily for a fraction of a second, it grabs that
//  frame and advances.
//
//  Camera: front camera, so a solo user can watch themselves and the on-screen
//  guidance while posing. Prop the phone facing you and step back; a success
//  haptic fires on each capture so you know it worked without watching closely.
//
//  Threading: all per-frame logic runs on the capture (session) queue, which is
//  serial, so the frame state below needs no locking. The captured image is made
//  while the pixel buffer is still valid, and only finished values are marshaled
//  to the main queue for the @Published UI state.
//
//  ORIENTATION: the one fiddly constant. For the FRONT camera with the phone in
//  portrait, frames are landscape-and-mirrored and need `.leftMirrored` to read
//  upright. If your captured silhouette comes out sideways or upside-down on a
//  device, this is the knob to change (try `.right`, `.left`, `.rightMirrored`).

import AVFoundation
import AudioToolbox     // AudioServicesPlaySystemSound (capture "beep")
import Combine          // ObservableObject / @Published
import Vision
import CoreImage
import UIKit

// `nonisolated` opts this out of the project's MainActor-by-default isolation:
// the camera delegate runs on a background queue, and this class marshals every
// UI-state change to the main queue itself, so it needn't be main-actor-bound.
nonisolated final class PoseCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    enum Phase: Sendable { case front, side, done }

    // Published UI state — only ever written on the main queue.
    @Published var phase: Phase = .front
    @Published var guidance = "Hadap kamera, berdiri dengan pose A"
    @Published var progress: Double = 0        // 0…1 hold-to-capture progress
    @Published var poseDetected = false
    @Published var bodyVisible = false         // whole body (to the ankles) in frame
    @Published var authorized = true
    @Published var isTransitioning = false

    /// Called on the main queue when both photos are captured.
    var onComplete: ((_ front: UIImage, _ side: UIImage) -> Void)?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pose.camera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()
    private let orientation: CGImagePropertyOrientation = .leftMirrored   // front camera, portrait

    // Frame-logic state — touched only on sessionQueue (serial), so no locking.
    private var logicPhase: Phase = .front
    private var holdStartTime: Date?
    private let targetHoldDuration: TimeInterval = 2.0 // 2 seconds scan duration
    private var isTransitioningInternal = false
    private var frontImage: UIImage?
    private var configured = false

    // MARK: Lifecycle

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { self.authorized = granted }
            guard granted else { return }
            self.sessionQueue.async {
                self.configureIfNeeded()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        session.beginConfiguration()
        session.sessionPreset = .high

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        session.commitConfiguration()
    }

    // MARK: Per-frame (sessionQueue)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard logicPhase != .done,
              !isTransitioningInternal,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Detect + classify (a fresh request per frame keeps this fully local).
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        try? handler.perform([request])
        let observation = request.results?.first
        let kind: PoseKind = observation.map { PoseClassifier.classify($0).0 } ?? .none
        let fullyVisible = observation.map { PoseClassifier.fullBodyVisible($0) } ?? false

        // Require the whole body in frame before a pose can count — this stops the
        // capture from firing while the person is still too close to the camera.
        let target: PoseKind = (logicPhase == .front) ? .frontAPose : .side
        let match = fullyVisible && (kind == target)

        let now = Date()
        if match {
            if holdStartTime == nil {
                holdStartTime = now
            }
        } else {
            holdStartTime = nil
        }

        let elapsed = holdStartTime != nil ? now.timeIntervalSince(holdStartTime!) : 0
        let publishProgress = min(1.0, elapsed / targetHoldDuration)
        let publishGuidance = guidanceText(phase: logicPhase, matching: match, fullyVisible: fullyVisible)

        // Threshold reached (2 seconds hold): grab THIS frame now, while the buffer is valid.
        if elapsed >= targetHoldDuration, let image = uprightImage(from: pixelBuffer) {
            holdStartTime = nil
            isTransitioningInternal = true

            let currentPhase = logicPhase
            if currentPhase == .front {
                frontImage = image
                logicPhase = .side
            } else if currentPhase == .side {
                logicPhase = .done
            }

            DispatchQueue.main.async {
                self.progress = 1.0
                self.poseDetected = true
                self.isTransitioning = true

                // Feedback haptic + sound
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                AudioServicesPlaySystemSound(1057)

                // 2-second loading animation before moving to side pose or completing
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if currentPhase == .front {
                        self.phase = .side
                        self.guidance = "Putar 90° ke samping, tangan rileks"
                        self.progress = 0
                        self.poseDetected = false
                        self.isTransitioning = false
                        self.sessionQueue.async {
                            self.isTransitioningInternal = false
                        }
                    } else if currentPhase == .side {
                        self.phase = .done
                        self.isTransitioning = false
                        if let front = self.frontImage {
                            self.onComplete?(front, image)
                        }
                    }
                }
            }
            return
        }

        DispatchQueue.main.async {
            self.phase = self.logicPhase
            self.poseDetected = match
            self.bodyVisible = fullyVisible
            self.progress = publishProgress
            self.guidance = publishGuidance
        }
    }

    // MARK: Helpers

    private func guidanceText(phase: Phase, matching: Bool, fullyVisible: Bool) -> String {
        // Getting the whole body in frame comes first — nothing else matters until
        // the person has stepped back far enough.
        if !fullyVisible && phase != .done {
            return "Mundur beberapa langkah sampai seluruh tubuh Anda terlihat"
        }
        switch phase {
        case .front: return matching ? "Tahan…" : "Hadap kamera, rentangkan tangan membentuk pose A, kaki dibuka"
        case .side:  return matching ? "Tahan…" : "Putar 90° ke samping, tangan rileks"
        case .done:  return "Selesai"
        }
    }

    /// Convert a camera pixel buffer into an upright UIImage (applies `orientation`).
    private func uprightImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
