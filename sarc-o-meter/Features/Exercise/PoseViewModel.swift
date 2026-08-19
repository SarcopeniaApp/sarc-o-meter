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

    // ── State Locking & Tracking Subjek Utama ──
    private var lockedCenter: CGPoint?
    private var framesSinceLastSeen: Int = 0
    private let maxLostFrames: Int = 15 // ~0.5 detik toleransi jika subjek terhalang sebentar

    override init() {
        super.init()
        poseService = PoseLandmarkerService()
        poseService?.delegate = self
        cameraManager.delegate = self
    }

    func start() {
        lockedCenter = nil
        framesSinceLastSeen = 0
        cameraManager.checkPermissionAndStart()
    }
    
    func stop() {
        cameraManager.stop()
        lockedCenter = nil
    }

    /// Reset lock subjek secara manual
    func unlockPerson() {
        lockedCenter = nil
        framesSinceLastSeen = 0
    }
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
        let detected = result.landmarks
        var targetPerson: [NormalizedLandmark]? = nil

        if let lastCenter = lockedCenter {
            // STATE: LOCKED — Cari skeleton yang lokasinya paling dekat dengan titik pusat subjek terkunci
            var bestMatch: [NormalizedLandmark]? = nil
            var minDistance: Double = .greatestFiniteMagnitude

            for person in detected {
                guard let center = centerPoint(of: person) else { continue }
                let dist = hypot(center.x - lastCenter.x, center.y - lastCenter.y)
                if dist < minDistance {
                    minDistance = dist
                    bestMatch = person
                }
            }

            // Batas maksimal pergerakan antar-frame (0.35 di koordinat ter-normalisasi [0..1])
            if let bestMatch, minDistance < 0.35, let newCenter = centerPoint(of: bestMatch) {
                targetPerson = bestMatch
                lockedCenter = newCenter
                framesSinceLastSeen = 0
            } else {
                // Toleransi kehilangan jejak sementara (misal terhalang objek sebentar)
                framesSinceLastSeen += 1
                if framesSinceLastSeen > maxLostFrames {
                    lockedCenter = nil // Lock di-reset jika hilang terlalu lama
                }
            }
        }

        // STATE: UNLOCKED — Jika belum ada lock, pilih orang dengan area terbesar (paling depan di kamera)
        if lockedCenter == nil {
            if let largestPerson = detected.max(by: { boundingBoxArea(of: $0) < boundingBoxArea(of: $1) }),
               let center = centerPoint(of: largestPerson) {
                targetPerson = largestPerson
                lockedCenter = center
                framesSinceLastSeen = 0
            }
        }

        DispatchQueue.main.async {
            if let targetPerson {
                self.landmarks = [targetPerson] // Overlay HANYA menggambar skeleton orang terpilih
                self.onPerson?(targetPerson)   // RepCounter HANYA memproses data orang terpilih
            } else {
                self.landmarks = []
            }
        }
    }

    // MARK: - Helpers Tracking Spatial

    /// Menghitung titik pusat torso/pinggul subjek
    private func centerPoint(of person: [NormalizedLandmark]) -> CGPoint? {
        guard person.count >= 25 else { return nil }
        let h1 = person[23], h2 = person[24]
        if (h1.presence ?? 1.0) > 0.2 || (h2.presence ?? 1.0) > 0.2 {
            return CGPoint(x: Double(h1.x + h2.x) / 2.0, y: Double(h1.y + h2.y) / 2.0)
        }
        let points = [11, 12, 23, 24].filter { $0 < person.count }
        guard !points.isEmpty else { return nil }
        let avgX = points.map { Double(person[$0].x) }.reduce(0, +) / Double(points.count)
        let avgY = points.map { Double(person[$0].y) }.reduce(0, +) / Double(points.count)
        return CGPoint(x: avgX, y: avgY)
    }

    /// Menghitung estimasi luas area bounding box subjek (untuk memilih orang paling depan)
    private func boundingBoxArea(of person: [NormalizedLandmark]) -> Double {
        guard !person.isEmpty else { return 0 }
        let xs = person.map { Double($0.x) }
        let ys = person.map { Double($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return 0 }
        return (maxX - minX) * (maxY - minY)
    }
}
