//  BMNetPredictor.swift
//
//  On-device body-measurement inference.
//
//  Pipeline:  raw photo (front + side)  ->  Vision person segmentation  ->
//             a 3-channel float stack the model expects  ->  Core ML  ->
//             14 body measurements in cm.
//
//  SETUP
//  -----
//  1. Drag `bmnet.mlpackage` into your Xcode target (check "Copy items if
//     needed" and add to the app target). Xcode compiles it to `bmnet.mlmodelc`
//     inside the bundle at build time.
//  2. Add this file to the target.
//  3. Call `BMNetPredictor().predict(front:side:heightCm:weightKg:)`.
//
//  TWO THINGS THE MODEL IS PICKY ABOUT (both handled below, but know they exist):
//  - Channel memory layout: the input is [1, 3, 640, 960] laid out channel-major.
//    Channel 0 = the joined front|side silhouette (0/1), channel 1 = a constant
//    plane of the normalized height, channel 2 = a constant plane of the
//    normalized weight. Get the channel order or the normalization wrong and the
//    output is silently garbage.
//  - Vertical orientation: the silhouette must be head-up, feet-down (that is how
//    the model was trained). CGContext draws bottom-up, so we flip it; see
//    `binaryPlane`.
//
//  FRAMING NOTE: the person should fill the frame (head near the top, feet near
//  the bottom), because the training silhouettes did. The camera capture UI
//  should enforce that. We resize the whole mask to 480x640 to match training.

import CoreML
import CoreImage
import Vision
import CoreGraphics

// MARK: - Errors
//
// The result type `BodyMeasurements` lives in State/BodyMeasurements.swift.

enum BMNetError: Error {
    case modelNotFound
    case segmentationFailed
    case badImage
    case badOutput
}

// MARK: - Predictor

final class BMNetPredictor {

    // Geometry the model was trained on.
    private let viewW = 480          // width of ONE view
    private let viewH = 640          // height of both views
    private var joinedW: Int { viewW * 2 }   // 960

    // Normalization stats, copied verbatim from the trained checkpoint. These MUST
    // match training exactly; they are also embedded in the .mlpackage metadata.
    private let hMean = 171.26555963302752, hStd = 9.789797377515509
    private let wMean = 75.73591009174312,  wStd = 17.057817506556294

    // The population the model was trained on (BodyM adults). Outside this range
    // predictions are not just less accurate, they are meaningless.
    private let heightRange = 141.0 ... 198.0    // cm
    private let weightRange = 29.0 ... 185.0     // kg

    private let model: MLModel
    private let ciContext = CIContext()

    init() throws {
        guard let url = Bundle.main.url(forResource: "bmnet", withExtension: "mlmodelc") else {
            throw BMNetError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all               // Neural Engine + GPU + CPU
        self.model = try MLModel(contentsOf: url, configuration: config)
    }

    // MARK: Public entry — raw photos in, measurements out

    /// Segment both photos with Vision, build the model input, and predict.
    /// `warnings` is non-empty if height/weight fall outside the training range.
    func predict(front: CGImage, side: CGImage,
                 heightCm: Double, weightKg: Double,
                 orientation: CGImagePropertyOrientation = .up)
        throws -> (measurements: BodyMeasurements, warnings: [String]) {

        let frontMask = try personMask(from: front, orientation: orientation)
        let sideMask  = try personMask(from: side,  orientation: orientation)
        return try predict(frontMask: frontMask, sideMask: sideMask,
                           heightCm: heightCm, weightKg: weightKg)
    }

    /// Same, but for callers that already have silhouette masks (e.g. an upload
    /// path that segmented elsewhere). Masks are person masks; anything > mid-gray
    /// is treated as body.
    func predict(frontMask: CGImage, sideMask: CGImage,
                 heightCm: Double, weightKg: Double)
        throws -> (measurements: BodyMeasurements, warnings: [String]) {

        var warnings: [String] = []
        if !heightRange.contains(heightCm) {
            warnings.append("height \(heightCm) cm is outside the model's range \(heightRange)")
        }
        if !weightRange.contains(weightKg) {
            warnings.append("weight \(weightKg) kg is outside the model's range \(weightRange)")
        }

        let input = try makeStack(frontMask: frontMask, sideMask: sideMask,
                                  heightCm: heightCm, weightKg: weightKg)
        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["stack": MLFeatureValue(multiArray: input)])
        let out = try model.prediction(from: provider)

        guard let arr = out.featureValue(for: "measurements")?.multiArrayValue,
              arr.count >= BodyMeasurements.names.count else {
            throw BMNetError.badOutput
        }
        var values: [String: Double] = [:]
        for (i, name) in BodyMeasurements.names.enumerated() {
            values[name] = arr[i].doubleValue
        }
        return (BodyMeasurements(values: values), warnings)
    }

    // MARK: Build the 3-channel input tensor

    /// Front|side silhouette (channel 0) + constant height/weight planes
    /// (channels 1, 2) -> MLMultiArray of shape [1, 3, 640, 960].
    func makeStack(frontMask: CGImage, sideMask: CGImage,
                   heightCm: Double, weightKg: Double) throws -> MLMultiArray {

        let front = binaryPlane(from: frontMask, width: viewW, height: viewH)   // [640*480], 0/1, head-up
        let side  = binaryPlane(from: sideMask,  width: viewW, height: viewH)

        let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: viewH), NSNumber(value: joinedW)],
                                   dataType: .float32)
        let p = arr.dataPointer.bindMemory(to: Float32.self, capacity: arr.count)
        let plane = viewH * joinedW           // 640 * 960, the size of one channel

        // channel 0: the two views side by side
        for y in 0..<viewH {
            let rowBase = y * joinedW
            for x in 0..<joinedW {
                let v: Float32 = (x < viewW) ? front[y * viewW + x]
                                             : side[y * viewW + (x - viewW)]
                p[rowBase + x] = v            // channel 0 starts at offset 0
            }
        }

        // channels 1 and 2: the same normalized scalar everywhere
        let hn = Float32((heightCm - hMean) / hStd)
        let wn = Float32((weightKg - wMean) / wStd)
        for i in 0..<plane {
            p[1 * plane + i] = hn
            p[2 * plane + i] = wn
        }
        return arr
    }

    // MARK: Debug — the exact silhouette the model sees

    /// The 960x640 joined front|side binary silhouette (channel 0), as a grayscale
    /// image. Purely for debugging/preview — this is literally what the model reads.
    func silhouetteImage(frontMask: CGImage, sideMask: CGImage) -> CGImage? {
        let front = binaryPlane(from: frontMask, width: viewW, height: viewH)
        let side  = binaryPlane(from: sideMask,  width: viewW, height: viewH)
        var bytes = [UInt8](repeating: 0, count: viewH * joinedW)
        for y in 0..<viewH {
            for x in 0..<joinedW {
                let v: Float32 = (x < viewW) ? front[y * viewW + x] : side[y * viewW + (x - viewW)]
                bytes[y * joinedW + x] = v > 0.5 ? 255 : 0
            }
        }
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: joinedW, height: viewH,
                                  bitsPerComponent: 8, bytesPerRow: joinedW, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        return ctx.makeImage()
    }

    // MARK: Vision person segmentation

    /// Raw photo -> a person mask (grayscale CGImage, body = bright).
    func personMask(from image: CGImage,
                    orientation: CGImagePropertyOrientation = .up) throws -> CGImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first else { throw BMNetError.segmentationFailed }
        let ci = CIImage(cvPixelBuffer: result.pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else {
            throw BMNetError.segmentationFailed
        }
        return cg
    }

    // MARK: Mask -> binary plane

    /// Rasterize a mask into a `width x height` array of 0.0/1.0, row-major with
    /// row 0 = the TOP of the image (head). The vertical flip below is essential:
    /// CGContext's origin is bottom-left, so without it the silhouette would be
    /// upside-down and every measurement would be read at the wrong height.
    private func binaryPlane(from mask: CGImage, width: Int, height: Int) -> [Float32] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return [Float32](repeating: 0, count: width * height)
        }
        // Smoothing downscale + threshold, to match training's cv2.INTER_AREA on
        // the mask (nearest-neighbor would shift the body edge by ~1px, which the
        // model is mildly sensitive to).
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(height))  // flip so byte row 0 = image top
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))

        return bytes.map { $0 > 127 ? Float32(1) : Float32(0) }
    }
}
