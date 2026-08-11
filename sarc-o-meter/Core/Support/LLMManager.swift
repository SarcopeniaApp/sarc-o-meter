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
        isLoading = true
        isLoaded = false
        progressText = "Loading \(modelID)…"
        progressValue = 0.0

        do {
            // The id-based loader needs a downloader + tokenizer loader injected;
            // the MLXHuggingFace macros provide the HuggingFace implementations.
            container = try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                id: modelID,
                progressHandler: { [weak self] progress in
                    // Log real bytes so we can tell "slow" from "stalled":
                    // completedUnitCount should climb even while the % looks like 0.
                    let mb = Double(progress.completedUnitCount) / 1_048_576
                    let totalMB = Double(progress.totalUnitCount) / 1_048_576
                    print(String(format: "[MLX dl] %.1f / %.1f MB  (%.0f%%)  %@",
                                 mb, totalMB, progress.fractionCompleted * 100,
                                 progress.localizedAdditionalDescription ?? ""))
                    Task { @MainActor in
                        self?.progressValue = progress.fractionCompleted
                        self?.progressText = totalMB > 0
                            ? String(format: "Downloading… %.0f / %.0f MB", mb, totalMB)
                            : "Downloading…"
                    }
                }
            )
            isLoaded = true
            progressText = "Model loaded."
            progressValue = 1.0
            print("MLX model loaded: \(modelID)")
        } catch {
            progressText = "Failed to load model: \(error.localizedDescription)"
            print("MLX load failed: \(error)")
        }
        isLoading = false
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
