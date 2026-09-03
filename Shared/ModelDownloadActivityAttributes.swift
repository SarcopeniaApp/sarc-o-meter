//  ModelDownloadActivityAttributes.swift
//  Shared between main app & widget extension targets
//
//  Definisi ActivityAttributes yang HARUS identik di kedua target agar
//  ActivityKit bisa mencocokkan tipe saat aplikasi utama memicu Live Activity
//  dan widget extension merender tampilannya.

import ActivityKit

struct ModelDownloadActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progress: Double       // 0.0 .. 1.0
        var percent: Int           // 0 .. 100
        var progressText: String   // e.g. "Downloading… 45% (750.0 / 1665.3 MB)"
    }

    var modelName: String          // e.g. "Qwen 2.5 3B AI"
}
