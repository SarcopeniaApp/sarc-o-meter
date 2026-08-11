import SwiftUI
import MediaPipeTasksVision
import AVFoundation
import Combine

final class PoseViewModel: NSObject, ObservableObject {
    @Published var landmarks: [[NormalizedLandmark]] = []
    @Published var imageSize: CGSize = .zero

    let cameraManager = CameraManager()
    private var poseService: PoseLandmarkerService?

    // Dipanggil tiap kali satu orang terdeteksi (untuk RepCounter)
    var onPerson: (([NormalizedLandmark]) -> Void)?

    override init() {
        super.init()
        poseService = PoseLandmarkerService()
        poseService?.delegate = self
        cameraManager.delegate = self
    }

    func start() { cameraManager.checkPermissionAndStart() }
    func stop() { cameraManager.stop() }
}

extension PoseViewModel: CameraManagerDelegate {
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        if imageSize == .zero, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            DispatchQueue.main.async { self.imageSize = CGSize(width: w, height: h) }
        }
        poseService?.detect(sampleBuffer: sampleBuffer)
    }
}

extension PoseViewModel: PoseServiceDelegate {
    func poseService(_ service: PoseLandmarkerService, didDetect result: PoseLandmarkerResult) {
        DispatchQueue.main.async {
            self.landmarks = result.landmarks
            if let first = result.landmarks.first {
                self.onPerson?(first)
            }
        }
    }
}
