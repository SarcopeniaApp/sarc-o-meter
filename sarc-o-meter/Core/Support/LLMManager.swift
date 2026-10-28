//  LLMManager.swift
//
//  On-device LLM via MLX Swift (Apple's array framework, runs on the Metal GPU).
//  Loads a quantized Qwen from HuggingFace and streams tokens. This replaces the
//  earlier CoreML-LLM path, which had broken model downloads, ANE-compile
//  failures, and slow monolithic prefill.
//
//  ── SETUP (Xcode) ────────────────────────────────────────────────────────────
//  1. File ▸ Add Package Dependencies…  →  https://github.com/ml-explore/mlx-swift-lm
//     Add the products **MLXLLM**, **MLXLMCommon**, and **MLXHuggingFace** to the
//     sarc-o-meter target. (MLXHuggingFace supplies the download + tokenizer
//     macros used below.) Transitive deps resolve automatically.
//  2. For multi-GB models, give the app the "Increased Memory Limit" capability
//     (entitlement com.apple.developer.kernel.increased-memory-limit) or iOS may
//     jetsam the app while the weights load.
//  3. Runs on the GPU — use a real device (Simulator has no Metal LLM path worth
//     using). First launch downloads the model (~1.8 GB for the 3B) once.

import Foundation
import SwiftUI
import MLXLLM
import MLXLMCommon
import MLXHuggingFace   // #hubDownloader(), #huggingFaceTokenizerLoader()

import HuggingFace
import Tokenizers

@Observable
final class LLMManager {
    var outputText = ""
    var isLoading = false
    var isLoaded = false
    var progressText = ""
    var progressValue = 0.0
    var downloadedMB: Double = 0
    var totalMB: Double = 0
    var lastError: String? = nil

    private var container: ModelContainer?
    private var instructions: String?

    // Swap this id to change model (all from the `mlx-community` HF org):
    //   Qwen2.5-3B-Instruct-4bit   ~1.8 GB · multilingual · needs an ~8 GB-RAM iPhone
    //   Qwen3-4B-4bit              ~2.3 GB · newer/stronger · high-RAM device
    //   Qwen2.5-1.5B-Instruct-4bit ~1.0 GB · lighter/faster fallback
    let modelID = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    let modelName = "Qwen 2.5 3B Instruct (4-bit)"
    let modelSize = "~1.8 GB"

    static let expectedModelBytes: Int64 = 1_747_851_324 // ~1666.88 MB
    static let expectedModelMB: Double = 1666.88

    init() {
        self.totalMB = Self.expectedModelMB
        if Self.isModelCachedOnDisk() {
            self.isLoaded = true
            self.downloadedMB = Self.expectedModelMB
            self.progressValue = 1.0
            self.progressText = "Model loaded."
        } else {
            self.isLoaded = false
            self.downloadedMB = 0.0
            self.progressValue = 0.0
            self.progressText = "Downloading…"
        }
    }

    /// Real-time URLSession download progress tracker that observes bytes received across all download tasks.
    private final class LLMDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Int64, Double) -> Void
        private let totalExpectedBytes: Int64
        private let lock = NSLock()
        private var taskDownloadedBytes: [Int: Int64] = [:]
        private var observations: [Int: NSKeyValueObservation] = [:]
        private var lastReportedTime: CFAbsoluteTime = 0
        private var lastReportedBytes: Int64 = 0

        init(totalExpectedBytes: Int64, onProgress: @escaping @Sendable (Int64, Double) -> Void) {
            self.totalExpectedBytes = totalExpectedBytes
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            // ONLY track actual download tasks (GET file downloads), ignore HEAD preflight and API data tasks!
            guard task is URLSessionDownloadTask else { return }
            guard task.originalRequest?.httpMethod == "GET" || task.originalRequest?.httpMethod == nil else { return }

            let taskID = task.taskIdentifier

            // Track actual raw bytes received via KVO (fires continuously as network buffers arrive)
            let observation = task.observe(\.countOfBytesReceived, options: [.new]) { [weak self] t, _ in
                guard let self else { return }
                let bytes = t.countOfBytesReceived
                guard bytes > 0 else { return }

                self.lock.lock()
                self.taskDownloadedBytes[taskID] = bytes
                self.updateProgressLocked()
                self.lock.unlock()
            }

            lock.lock()
            observations[taskID] = observation
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard task is URLSessionDownloadTask else { return }

            let taskID = task.taskIdentifier
            let finalBytes = task.countOfBytesReceived

            lock.lock()
            if error == nil && finalBytes > 0 {
                taskDownloadedBytes[taskID] = max(taskDownloadedBytes[taskID] ?? 0, finalBytes)
            }
            observations.removeValue(forKey: taskID)
            self.updateProgressLocked(force: true)
            lock.unlock()
        }

        private func updateProgressLocked(force: Bool = false) {
            let sumBytes = taskDownloadedBytes.values.reduce(0, +)
            let fraction = min(1.0, max(0.0, Double(sumBytes) / Double(totalExpectedBytes)))

            let now = CFAbsoluteTimeGetCurrent()
            // Throttle to every 100ms or 1MB delta to keep main UI smooth and responsive
            if force || now - lastReportedTime >= 0.1 || (sumBytes - lastReportedBytes) >= 1_000_000 || fraction >= 1.0 {
                lastReportedTime = now
                lastReportedBytes = sumBytes
                onProgress(sumBytes, fraction)
            }
        }
    }

    /// Checks candidate directories for the cached model (~1.65 GB weights), resolving symlinks.
    static func isModelCachedOnDisk() -> Bool {
        let fileManager = FileManager.default

        if let repoID = Repo.ID(rawValue: "mlx-community/Qwen2.5-3B-Instruct-4bit") {
            if let path = HubCache.default.cachedFilePath(repo: repoID, kind: .model, revision: "main", filename: "model.safetensors"),
               fileManager.fileExists(atPath: path.path) {
                return true
            }
        }

        var candidatePaths: [URL] = [
            URL.cachesDirectory.appendingPathComponent("huggingface/hub/models--mlx-community--Qwen2.5-3B-Instruct-4bit"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/hub/models--mlx-community--Qwen2.5-3B-Instruct-4bit"),
            URL.applicationSupportDirectory.appendingPathComponent("huggingface/hub/models--mlx-community--Qwen2.5-3B-Instruct-4bit")
        ]

        if let repoID = Repo.ID(rawValue: "mlx-community/Qwen2.5-3B-Instruct-4bit") {
            let hubDir = HubCache.default.repoDirectory(repo: repoID, kind: .model)
            candidatePaths.insert(hubDir, at: 0)
        }

        for dir in candidatePaths {
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let fileURL as URL in enumerator {
                let realPath = fileURL.resolvingSymlinksInPath().path
                if let attrs = try? fileManager.attributesOfItem(atPath: realPath),
                   let size = attrs[.size] as? Int64,
                   size >= 1_500_000_000 {
                    return true
                }
            }
        }
        return false
    }

    private var loadTask: Task<Void, Never>?

    /// Idempotent: the launch preload and the analysis step both call this, so
    /// concurrent callers join the same in-flight load rather than downloading twice.
    @MainActor
    func loadModel() async {
        if isLoaded && container != nil { return }
        if let existing = loadTask {
            await existing.value
            if isLoaded && container != nil { return }
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
    }

    @MainActor
    private func performLoad() async {
        isLoading = true
        if !Self.isModelCachedOnDisk() {
            isLoaded = false
            progressValue = 0.0
            downloadedMB = 0.0
            progressText = "Downloading…"
        } else {
            isLoaded = true
            progressValue = 1.0
            downloadedMB = Self.expectedModelMB
            progressText = "Model loaded."
        }

        do {
            let delegate = LLMDownloadDelegate(totalExpectedBytes: Self.expectedModelBytes) { [weak self] sumBytes, fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if fraction >= self.progressValue || self.progressValue == 0 {
                        self.progressValue = fraction
                        self.downloadedMB = Double(sumBytes) / (1024.0 * 1024.0)
                        self.progressText = String(format: "Downloading… %.0f / %.0f MB", min(self.downloadedMB, self.totalMB), self.totalMB)
                    }
                }
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let hubClient = HubClient(session: session)

            // The id-based loader needs a downloader + tokenizer loader injected;
            // the MLXHuggingFace macros provide the HuggingFace implementations.
            container = try await loadModelContainer(
                from: #hubDownloader(hubClient),
                using: #huggingFaceTokenizerLoader(),
                id: modelID,
                progressHandler: { _ in }
            )
            isLoaded = true
            downloadedMB = Self.expectedModelMB
            totalMB = Self.expectedModelMB
            progressValue = 1.0
            progressText = "Model loaded."
            print("MLX model loaded: \(modelID)")
        } catch {
            lastError = error.localizedDescription
            progressText = "Failed to load model: \(error.localizedDescription)"
            print("MLX load failed: \(error)")
            container = nil
            isLoaded = false
            loadTask = nil
        }
        isLoading = false
    }

    /// System prompt applied to the next generation (ChatSession `instructions`).
    func appendSystemMessage(_ prompt: String) {
        instructions = prompt
    }

    @MainActor
    func sendMessage(_ prompt: String) async -> String? {
        guard let container else {
            lastError = "Model container is nil (model not loaded or not downloaded)"
            return nil
        }
        isLoading = true
        outputText = ""
        defer { isLoading = false }

        // Fresh session per query: RAG retrieves new context for each question,
        // so we don't want a stale KV cache carried across unrelated turns.
        let session = ChatSession(container, instructions: instructions)
        do {
            for try await chunk in session.streamResponse(to: prompt) {
                outputText += chunk
            }
        } catch {
            lastError = error.localizedDescription
            outputText += "\n[Error generating response: \(error.localizedDescription)]"
        }
        return outputText
    }
}
