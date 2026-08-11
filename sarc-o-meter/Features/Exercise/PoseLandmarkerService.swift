//
//  PoseLandmarkerService.swift
//  iOSMediaPipe
//
//  Created by Surya on 05/08/26.
//

import MediaPipeTasksVision
import AVFoundation

protocol PoseServiceDelegate: AnyObject {
    func poseService(_ service: PoseLandmarkerService,
                     didDetect result: PoseLandmarkerResult)
}

final class PoseLandmarkerService: NSObject {
    private var poseLandmarker: PoseLandmarker?
    weak var delegate: PoseServiceDelegate?

    // Guard untuk mencegah queue overload pada detectAsync
    private var isProcessing = false
    private let lock = NSLock()

    init?(modelName: String = "pose_landmarker") {
        super.init()
        guard let modelPath = Bundle.main.path(forResource: modelName,
                                               ofType: "task") else {
            print("Model \(modelName).task tidak ditemukan di bundle")
            return nil
        }
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .liveStream
        options.numPoses = 1
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.poseLandmarkerLiveStreamDelegate = self

        do {
            poseLandmarker = try PoseLandmarker(options: options)
        } catch {
            print("Gagal inisialisasi PoseLandmarker: \(error)")
            return nil
        }
    }

    func detect(sampleBuffer: CMSampleBuffer) {
        // Abaikan frame baru jika frame sebelumnya masih diproses (drop frame)
        lock.lock()
        guard !isProcessing else {
            lock.unlock()
            return
        }
        isProcessing = true
        lock.unlock()

        guard let image = try? MPImage(sampleBuffer: sampleBuffer) else {
            lock.lock()
            isProcessing = false
            lock.unlock()
            return
        }

        let timestampMs = Int(CMTimeGetSeconds(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000)
        do {
            try poseLandmarker?.detectAsync(image: image,
                                            timestampInMilliseconds: timestampMs)
        } catch {
            print("detectAsync error: \(error)")
            lock.lock()
            isProcessing = false
            lock.unlock()
        }
    }
}

extension PoseLandmarkerService: PoseLandmarkerLiveStreamDelegate {
    func poseLandmarker(_ poseLandmarker: PoseLandmarker,
                        didFinishDetection result: PoseLandmarkerResult?,
                        timestampInMilliseconds: Int,
                        error: Error?) {
        // Reset flag agar frame berikutnya bisa diproses
        lock.lock()
        isProcessing = false
        lock.unlock()

        guard let result else { return }
        delegate?.poseService(self, didDetect: result)
    }
}
