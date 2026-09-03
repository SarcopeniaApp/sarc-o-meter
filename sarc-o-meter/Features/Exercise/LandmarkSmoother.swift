//
//  LandmarkSmoother.swift
//  iOSMediaPipe
//
//  Created by Surya on 06/08/26.
//

import SwiftUI
import Foundation
import MediaPipeTasksVision

// Penghalus koordinat landmark dengan Exponential Moving Average.
// alpha kecil = lebih halus tapi lebih lambat; alpha besar = lebih responsif.
final class LandmarkSmoother {
    private var smoothed: [Int: (x: Double, y: Double)] = [:]
    private let alpha: Double
    private let resetVisibility: Float

    init(alpha: Double = 0.4, resetVisibility: Float = 0.5) {
        self.alpha = alpha
        self.resetVisibility = resetVisibility
    }

    func reset() { smoothed.removeAll() }

    // Ambil koordinat (x, y) landmark ke-i yang sudah dihaluskan
    func point(_ p: [NormalizedLandmark], _ i: Int) -> (x: Double, y: Double)? {
        guard i < p.count else { return nil }
        let vis = p[i].visibility?.floatValue ?? 1
        let rawX = Double(p[i].x)
        let rawY = Double(p[i].y)

        // Bila titik tak terlihat, jangan cemari nilai halus — pakai nilai lama bila ada
        guard vis >= resetVisibility else { return smoothed[i] }

        if let prev = smoothed[i] {
            let nx = alpha * rawX + (1 - alpha) * prev.x
            let ny = alpha * rawY + (1 - alpha) * prev.y
            smoothed[i] = (nx, ny)
        } else {
            smoothed[i] = (rawX, rawY)
        }
        return smoothed[i]
    }

    /// Menghaluskan seluruh array landmark tubuh dengan Exponential Moving Average (EMA)
    func smooth(_ p: [NormalizedLandmark]) -> [NormalizedLandmark] {
        var result: [NormalizedLandmark] = []
        result.reserveCapacity(p.count)
        for (i, lm) in p.enumerated() {
            let vis = lm.visibility?.floatValue ?? 1
            let rawX = Double(lm.x)
            let rawY = Double(lm.y)

            if vis >= resetVisibility {
                if let prev = smoothed[i] {
                    let nx = Float(alpha * rawX + (1 - alpha) * prev.x)
                    let ny = Float(alpha * rawY + (1 - alpha) * prev.y)
                    smoothed[i] = (Double(nx), Double(ny))
                    result.append(NormalizedLandmark(x: nx, y: ny, z: lm.z, visibility: lm.visibility, presence: lm.presence))
                } else {
                    smoothed[i] = (rawX, rawY)
                    result.append(lm)
                }
            } else {
                if let prev = smoothed[i] {
                    result.append(NormalizedLandmark(x: Float(prev.x), y: Float(prev.y), z: lm.z, visibility: lm.visibility, presence: lm.presence))
                } else {
                    result.append(lm)
                }
            }
        }
        return result
    }
}
