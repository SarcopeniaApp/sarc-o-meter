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

    private var container: ModelContainer?
    private var instructions: String?

    // Swap this id to change model (all from the `mlx-community` HF org):
    //   Qwen2.5-3B-Instruct-4bit   ~1.8 GB · multilingual · needs an ~8 GB-RAM iPhone
    //   Qwen3-4B-4bit              ~2.3 GB · newer/stronger · high-RAM device
    //   Qwen2.5-1.5B-Instruct-4bit ~1.0 GB · lighter/faster fallback
    private let modelID = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    private var loadTask: Task<Void, Never>?

    /// Idempotent: the launch preload and the analysis step both call this, so
    /// concurrent callers join the same in-flight load rather than downloading twice.
    @MainActor
    func loadModel() async {
        if isLoaded { return }
        if let loadTask { await loadTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
    }

    @MainActor
    private func performLoad() async {
        let cached = isModelCached()

        if cached {
            // Model sudah ada di cache — load langsung tanpa banner download
            print("[MLX] Model cached, loading silently…")
            do {
                container = try await loadModelContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    id: modelID
                )
                isLoaded = true
                print("MLX model loaded from cache: \(modelID)")
            } catch {
                print("MLX load from cache failed: \(error)")
            }
            return
        }

        // Model belum ada — tampilkan banner download + Live Activity
        isLoading = true
        isLoaded = false
        progressText = "Downloading… 0%"
        progressValue = 0.0

        var currentPercent = 0
        let totalMB = 1665.3
        var isFinished = false

        ModelDownloadActivityManager.shared.startActivity(modelName: "Qwen 2.5 3B AI")

        let reportProgress: @MainActor (Int) -> Void = { [weak self] percent in
            guard let self else { return }
            let frac = Double(percent) / 100.0
            self.progressValue = frac
            let currentMB = (Double(percent) / 100.0) * totalMB
            if percent == 100 {
                self.progressText = "Model loaded."
            } else {
                self.progressText = String(format: "Downloading… %d%% (%.1f / %.1f MB)", percent, currentMB, totalMB)
            }
            print(String(format: "[MLX dl] %d%% (%.1f / %.1f MB)", percent, currentMB, totalMB))

            ModelDownloadActivityManager.shared.updateProgress(
                percent: percent,
                progressValue: frac,
                text: self.progressText
            )
        }

        // Task tunggal yang mengalirkan progres 0% → 100% secara mulus dan kontinu.
        // Fase 1 (downloading): naik perlahan dari 0→95% menggunakan kurva ease-out
        //   agar terasa natural (cepat di awal, makin pelan mendekati 95%).
        // Fase 2 (setelah download selesai): lanjut 95→100% dengan kecepatan tetap.
        let progressTask = Task { @MainActor in
            let tickMs: UInt64 = 100_000_000  // 100ms per tick
            var elapsed: Double = 0.0

            while currentPercent < 100 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: tickMs)
                elapsed += 0.1

                if isFinished {
                    // Fase 2: download selesai, isi sisa ke 100% dengan kecepatan tetap
                    currentPercent = min(currentPercent + 2, 100)
                } else {
                    // Fase 1: kurva ease-out logaritmik, maks 95%
                    // progress = 95 * (1 - e^(-elapsed/timeConstant))
                    let timeConstant: Double = 18.0
                    let eased = 95.0 * (1.0 - exp(-elapsed / timeConstant))
                    let target = min(Int(eased), 95)
                    if target > currentPercent {
                        currentPercent = target
                    }
                }

                reportProgress(currentPercent)
            }
        }

        do {
            container = try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                id: modelID
            )
            
            isFinished = true
            // Tunggu hingga progressTask menyelesaikan alirannya sampai 100% secara mulus
            await progressTask.value

            isLoaded = true
            progressText = "Model loaded."
            progressValue = 1.0
            print("MLX model loaded: \(modelID)")
            ModelDownloadActivityManager.shared.stopActivity()
        } catch {
            isFinished = true
            progressTask.cancel()
            progressText = "Failed to load model: \(error.localizedDescription)"
            print("MLX load failed: \(error)")
            ModelDownloadActivityManager.shared.stopActivity()
        }
        isLoading = false
    }

    /// Cek apakah model sudah ter-cache di folder HuggingFace Hub lokal.
    /// HF Hub menyimpan model di: Caches/huggingface/hub/models--{org}--{name}/snapshots/
    private func isModelCached() -> Bool {
        let fm = FileManager.default
        guard let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return false
        }
        // modelID "mlx-community/Qwen2.5-3B-Instruct-4bit" → "models--mlx-community--Qwen2.5-3B-Instruct-4bit"
        let folderName = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let snapshotsDir = cacheDir
            .appendingPathComponent("huggingface/hub", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)

        // Jika folder snapshots ada dan tidak kosong, model sudah pernah diunduh
        guard let contents = try? fm.contentsOfDirectory(atPath: snapshotsDir.path),
              !contents.isEmpty else {
            return false
        }
        return true
    }

    /// Menghitung total ukuran berkas yang terunduh di folder Cache HuggingFace / tmp
    private func getDownloadedCacheBytesMB() -> Double {
        let fm = FileManager.default
        let cacheUrls = fm.urls(for: .cachesDirectory, in: .userDomainMask)
        guard let cacheDir = cacheUrls.first else { return 0.0 }
        
        let hfDir = cacheDir.appendingPathComponent("huggingface", isDirectory: true)
        let tmpDir = fm.temporaryDirectory

        func directorySize(at url: URL) -> Int64 {
            guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    total += Int64(size)
                }
            }
            return total
        }

        let totalBytes = directorySize(at: hfDir) + directorySize(at: tmpDir)
        return Double(totalBytes) / 1_048_576
    }

    /// System prompt applied to the next generation (ChatSession `instructions`).
    func appendSystemMessage(_ prompt: String) {
        instructions = prompt
    }

    @MainActor
    func sendMessage(_ prompt: String) async -> String? {
        guard let container else { return nil }
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
            outputText += "\n[Error generating response: \(error.localizedDescription)]"
        }
        return outputText
    }
}
