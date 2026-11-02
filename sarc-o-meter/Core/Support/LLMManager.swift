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
    var isDownloaded = false
    var progressText = ""
    var progressValue = 0.0
    var downloadedMB: Double = 0
    var totalMB: Double = 0
    var lastError: String? = nil

    private var container: ModelContainer?
    private var instructions: String?

    var isReady: Bool {
        isLoaded && container != nil
    }

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
            self.isDownloaded = true
            self.isLoaded = false
            self.downloadedMB = Self.expectedModelMB
            self.progressValue = 1.0
            self.progressText = "Model siap dimuat."
        } else {
            self.isDownloaded = false
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

    /// Finds the snapshot directory containing the valid, fully-downloaded model files on local disk.
    static func localModelDirectory() -> URL? {
        let fileManager = FileManager.default
        var candidateRoots: [URL] = []

        if let repoID = Repo.ID(rawValue: "mlx-community/Qwen2.5-3B-Instruct-4bit") {
            let snapshots = HubCache.default.snapshotsDirectory(repo: repoID, kind: .model)
            candidateRoots.append(snapshots)
        }

        let standardHubCandidates: [URL] = [
            URL.cachesDirectory.appendingPathComponent("huggingface/hub/models--mlx-community--Qwen2.5-3B-Instruct-4bit/snapshots"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/huggingface/hub/models--mlx-community--Qwen2.5-3B-Instruct-4bit/snapshots"),
            URL.applicationSupportDirectory.appendingPathComponent("huggingface/hub/models--mlx-community--Qwen2.5-3B-Instruct-4bit/snapshots")
        ]
        candidateRoots.append(contentsOf: standardHubCandidates)

        for snapshotsDir in candidateRoots {
            guard fileManager.fileExists(atPath: snapshotsDir.path) else { continue }
            guard let commitDirs = try? fileManager.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil) else { continue }
            for commitDir in commitDirs {
                let configFile = commitDir.appendingPathComponent("config.json")
                let modelFile = commitDir.appendingPathComponent("model.safetensors")
                let tokenizerFile = commitDir.appendingPathComponent("tokenizer.json")

                if fileManager.fileExists(atPath: configFile.path) &&
                   fileManager.fileExists(atPath: modelFile.path) &&
                   fileManager.fileExists(atPath: tokenizerFile.path) {
                    let realPath = modelFile.resolvingSymlinksInPath().path
                    if let attrs = try? fileManager.attributesOfItem(atPath: realPath),
                       let size = attrs[.size] as? Int64,
                       size >= 1_500_000_000 {
                        return commitDir
                    }
                }
            }
        }
        return nil
    }

    /// Checks candidate directories for the cached model (~1.65 GB weights), resolving symlinks.
    static func isModelCachedOnDisk() -> Bool {
        return localModelDirectory() != nil
    }

    private var loadTask: Task<Void, Never>?

    /// Idempotent: callers join the same in-flight load rather than downloading twice.
    @MainActor
    func loadModel() async {
        if isReady { return }
        if let existing = loadTask {
            await existing.value
            if isReady { return }
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
        if isReady { return }
        isLoading = true
        lastError = nil

        // Step 1: Fast local disk load if the model is already downloaded
        if let localDir = Self.localModelDirectory() {
            isDownloaded = true
            downloadedMB = Self.expectedModelMB
            totalMB = Self.expectedModelMB
            progressValue = 1.0
            progressText = "Memuat model ke memori…"

            do {
                container = try await loadModelContainer(
                    from: localDir,
                    using: #huggingFaceTokenizerLoader()
                )
                isLoaded = true
                progressText = "Model loaded."
                print("MLX model loaded from local disk: \(localDir.path)")
                isLoading = false
                return
            } catch {
                print("Local disk load failed, will attempt downloader: \(error)")
                lastError = error.localizedDescription
            }
        }

        // Step 2: Download via HubClient
        isDownloaded = false
        isLoaded = false
        progressValue = 0.0
        downloadedMB = 0.0
        progressText = "Downloading…"

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

            container = try await loadModelContainer(
                from: #hubDownloader(hubClient),
                using: #huggingFaceTokenizerLoader(),
                id: modelID,
                progressHandler: { _ in }
            )
            session.finishTasksAndInvalidate()

            isDownloaded = true
            isLoaded = true
            downloadedMB = Self.expectedModelMB
            totalMB = Self.expectedModelMB
            progressValue = 1.0
            progressText = "Model loaded."
            print("MLX model downloaded and loaded: \(modelID)")
        } catch {
            lastError = error.localizedDescription
            progressText = "Failed to load model: \(error.localizedDescription)"
            print("MLX load failed: \(error)")

            // Recovery: Check if the snapshot finished downloading to disk despite the error
            if let localDir = Self.localModelDirectory() {
                do {
                    container = try await loadModelContainer(
                        from: localDir,
                        using: #huggingFaceTokenizerLoader()
                    )
                    isDownloaded = true
                    isLoaded = true
                    downloadedMB = Self.expectedModelMB
                    totalMB = Self.expectedModelMB
                    progressValue = 1.0
                    progressText = "Model loaded."
                    lastError = nil
                    print("MLX model recovered and loaded from local disk cache!")
                    isLoading = false
                    return
                } catch {
                    print("Recovery from disk cache also failed: \(error)")
                }
            }

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
        // If container is not loaded yet, attempt to load it immediately
        if container == nil {
            await loadModel()
        }

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
