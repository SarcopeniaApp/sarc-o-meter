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

    /// Called on the main queue when both photos are captured.
    var onComplete: ((_ front: UIImage, _ side: UIImage) -> Void)?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pose.camera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()
    private let orientation: CGImagePropertyOrientation = .leftMirrored   // front camera, portrait

    // Frame-logic state — touched only on sessionQueue (serial), so no locking.
    private var logicPhase: Phase = .front
    private var holdCount = 0
    private let holdNeeded = 12                 // frames of a steady pose before capturing
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
        holdCount = match ? holdCount + 1 : 0

        var publishPhase = logicPhase
        var publishProgress = min(1, Double(holdCount) / Double(holdNeeded))
        var publishGuidance = guidanceText(phase: logicPhase, matching: match, fullyVisible: fullyVisible)
        var captured = false
        var finished: (UIImage, UIImage)?

        // Threshold reached: grab THIS frame now, while the buffer is valid.
        if holdCount >= holdNeeded, let image = uprightImage(from: pixelBuffer) {
            holdCount = 0
            captured = true
            publishProgress = 0
            switch logicPhase {
            case .front:
                frontImage = image
                logicPhase = .side
                publishPhase = .side
                publishGuidance = "Bagus — sekarang putar 90° ke samping"
            case .side:
                logicPhase = .done
                publishPhase = .done
                publishGuidance = "Selesai"
                if let front = frontImage { finished = (front, image) }
            case .done:
                break
            }
        }

        DispatchQueue.main.async {
            self.phase = publishPhase
            self.poseDetected = match
            self.bodyVisible = fullyVisible
            self.progress = publishProgress
            self.guidance = publishGuidance
            if captured {
                // Haptic + a short "beep" so the user knows the pose was captured
                // and it's time to move on. Placeholder tone — swap for a bundled
                // sound later.
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                AudioServicesPlaySystemSound(1057)
            }
            if let f = finished { self.onComplete?(f.0, f.1) }
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
