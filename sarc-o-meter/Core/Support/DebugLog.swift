//  DebugLog.swift
//
//  Streams pipeline artifacts (text + images) to the Mac debug server
//  (tools/debug_server.py) over the LAN, so you can watch every stage on your
//  computer while the app runs on the phone -- the same visibility the Mac-side
//  pipeline gave you. Everything also goes to os_log, so it shows in the Xcode
//  console even without the server.
//
//  Usage:
//      DebugLog.shared.serverBase = "http://192.168.1.20:8000"  // from the UI
//      DebugLog.shared.startRun()
//      DebugLog.shared.image("00_front", uiImage)
//      DebugLog.shared.text("04_measurements", "calf=35.4, chest=98.1")

import Foundation
import UIKit
import os

final class DebugLog {

    static let shared = DebugLog()

    private let log = Logger(subsystem: "com.sarcxey.bmnet", category: "pipeline")
    private let session = URLSession(configuration: .ephemeral)

    /// e.g. "http://192.168.1.20:8000". When nil, only os_log is used (no network).
    var serverBase: String?

    private(set) var runId = "none"

    /// Start a fresh run -> a new folder on the Mac.
    func startRun(_ tag: String = "run") {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        runId = "\(f.string(from: Date()))_\(tag)"
        text("start", "run \(runId)")
    }

    func text(_ name: String, _ message: String) {
        log.log("[\(name, privacy: .public)] \(message, privacy: .public)")
        send(path: "text", name: name, body: Data(message.utf8), contentType: "text/plain")
    }

    func image(_ name: String, _ image: UIImage) {
        guard let png = image.pngData() else { return }
        log.log("[\(name, privacy: .public)] image (\(png.count) bytes)")
        send(path: "image", name: name, body: png, contentType: "image/png")
    }

    func image(_ name: String, _ cg: CGImage) {
        image(name, UIImage(cgImage: cg))
    }

    // fire-and-forget POST; never blocks or throws into the pipeline
    private func send(path: String, name: String, body: Data, contentType: String) {
        guard let base = serverBase, !base.isEmpty else { return }
        let enc = { (s: String) in
            s.addingPercentEncoding(withAllowedCharacters: .bmnetQueryValue) ?? s
        }
        guard let url = URL(string: "\(base)/\(path)?run=\(enc(runId))&name=\(enc(name))") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        session.dataTask(with: req) { _, _, err in
            if let err = err {
                self.log.error("debug POST failed: \(err.localizedDescription, privacy: .public)")
            }
        }.resume()
    }
}

private extension CharacterSet {
    static let bmnetQueryValue: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()
}
