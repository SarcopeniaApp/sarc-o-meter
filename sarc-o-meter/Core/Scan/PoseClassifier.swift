//  PoseClassifier.swift
//
//  Turns a Vision body-pose observation into one of three states used to drive
//  the hands-free capture: a front A-pose, a side profile, or neither.
//
//  All geometry is done in Vision's normalized coordinates (0...1, origin
//  bottom-left, y increasing upward). Because we take absolute widths and
//  absolute arm angles, the logic is agnostic to left/right mirroring.
//
//  These thresholds are a sensible starting point; expect to tune them on a real
//  device with real people. The Mac debug log prints the measured ratios so you
//  can see why a pose was or wasn't accepted.

import Vision
import CoreGraphics

nonisolated enum PoseKind: Sendable {
    case frontAPose
    case side
    case none
}

nonisolated struct PoseClassifier {

    /// Debug detail for the last classification (so you can tune the thresholds).
    struct Detail {
        var kind: PoseKind = .none
        var shoulderRatio: Double = 0     // shoulder width / torso height
        var armAngles: (Double, Double)?  // degrees from vertical, if measured
        var note = ""
    }

    private static let minConfidence: Float = 0.3

    /// True when the whole body — down to the ankles — is in frame. Used to fade
    /// the on-screen pose guide: prominent while the person is too close (feet cut
    /// off), faint once they've stepped back and their full body is visible.
    nonisolated static func fullBodyVisible(_ obs: VNHumanBodyPoseObservation) -> Bool {
        let required: [VNHumanBodyPoseObservation.JointName] = [
            .leftShoulder, .rightShoulder, .leftHip, .rightHip,
            .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
        ]
        for joint in required {
            guard let p = try? obs.recognizedPoint(joint), p.confidence > 0.2 else { return false }
        }
        return true
    }

    nonisolated static func classify(_ obs: VNHumanBodyPoseObservation) -> (PoseKind, Detail) {
        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let p = try? obs.recognizedPoint(joint), p.confidence > minConfidence else { return nil }
            return p.location
        }

        var d = Detail()

        guard let ls = point(.leftShoulder), let rs = point(.rightShoulder),
              let lh = point(.leftHip), let rh = point(.rightHip) else {
            d.note = "torso joints not visible"
            return (.none, d)
        }

        let shoulderW = abs(ls.x - rs.x)
        let hipW = abs(lh.x - rh.x)
        let torsoH = abs((ls.y + rs.y) / 2 - (lh.y + rh.y) / 2)
        guard torsoH > 0.05 else {
            d.note = "person too small / bad detection"
            return (.none, d)
        }
        d.shoulderRatio = Double(shoulderW / torsoH)

        // Side profile: shoulders (and hips) collapse in x because one is behind
        // the other. This is the strongest, most reliable signal.
        if shoulderW / torsoH < 0.28 && hipW / torsoH < 0.32 {
            d.kind = .side
            d.note = "narrow shoulders → side"
            return (.side, d)
        }

        // Front A-pose: person is frontal (wide shoulders) AND both arms are
        // angled out-and-down (25°–70° from vertical), which separates an A-pose
        // from arms-straight-down (near 0°) and a T-pose (near 90°).
        let frontal = shoulderW / torsoH > 0.5
        if frontal, let lw = point(.leftWrist), let rw = point(.rightWrist) {
            func armAngle(shoulder: CGPoint, wrist: CGPoint) -> Double? {
                let drop = shoulder.y - wrist.y            // >0 when wrist is below shoulder
                guard drop > 0.02 else { return nil }
                let spread = abs(wrist.x - shoulder.x)
                return atan2(Double(spread), Double(drop)) * 180 / .pi
            }
            if let a1 = armAngle(shoulder: ls, wrist: lw),
               let a2 = armAngle(shoulder: rs, wrist: rw) {
                d.armAngles = (a1, a2)
                if (25...70).contains(a1) && (25...70).contains(a2) {
                    d.kind = .frontAPose
                    d.note = "frontal + arms out → A-pose"
                    return (.frontAPose, d)
                }
                d.note = "frontal but arms not in A (\(Int(a1))°, \(Int(a2))°)"
                return (.none, d)
            }
        }

        d.note = frontal ? "frontal but wrists not visible" : "not frontal, not side"
        return (.none, d)
    }
}
