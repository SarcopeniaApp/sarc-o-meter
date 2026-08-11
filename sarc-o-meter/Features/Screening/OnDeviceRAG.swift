//  OnDeviceRAG.swift
//
//  A tiny on-device version of the Python RAG backend: tag-based retrieval over
//  the same curated AWGS knowledge base (knowledge_chunks.json, bundled), then a
//  grounded Bahasa-Indonesia prompt for the local LLM. It mirrors
//  backend/rag/retrieval.py + prompt_builder.py so the on-device path and the
//  server path stay conceptually identical.
//
//  This is the retrieval + prompt half; the generation half is the local LLM
//  (LLMManager). Keep it deterministic and auditable — exact tag matching, same
//  as the server, so every retrieved chunk is traceable to a rule-engine flag.

import Foundation

/// One curated knowledge snippet — mirrors an entry in knowledge_chunks.json.
struct KnowledgeChunk: Decodable, Sendable {
    let id: String
    let tags: [String]
    let source: String
    let content: String
}

enum OnDeviceRAG {

    // MARK: Knowledge base (loaded once from the bundled JSON)

    static let chunks: [KnowledgeChunk] = {
        guard let url = Bundle.main.url(forResource: "knowledge_chunks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([KnowledgeChunk].self, from: data)
        else {
            print("[OnDeviceRAG] knowledge_chunks.json not found in bundle")
            return []
        }
        return decoded
    }()

    // MARK: Retrieval (tag intersection — mirrors backend/rag/retrieval.py)

    /// Maps rule-engine output to knowledge-base tags. Straight port of
    /// `relevant_tags()` in retrieval.py.
    static func relevantTags(for result: AssessmentResult) -> Set<String> {
        var tags: Set<String> = ["general_exercise_principles", "nutrition"]
        if result.muscleMassStatus == .abnormal  { tags.insert("low_muscle_mass") }
        if result.strengthStatus == .abnormal     { tags.insert("low_strength") }
        if result.performanceStatus == .abnormal   { tags.insert("low_performance") }
        if !result.obesityFlags.isEmpty            { tags.insert("central_obesity") }
        if !result.redFlags.isEmpty                { tags.insert("contraindication") }
        switch result.overallRisk {
        case .low:    tags.insert("risk_low")
        case .mid:    tags.insert("risk_mid")
        case .high:   tags.insert("risk_high")
        case .severe: tags.insert("risk_severe")
        case .unassessed: break
        }
        return tags
    }

    /// Chunks whose tags intersect the given tags, capped at `limit` (order
    /// preserved). The cap keeps the prompt short enough for the 0.5B to prefill
    /// quickly — raise it once you're on a faster model / batched-prefill path.
    static func retrieve(tags: Set<String>, limit: Int = 2) -> [KnowledgeChunk] {
        Array(chunks.filter { !Set($0.tags).isDisjoint(with: tags) }.prefix(limit))
    }

    // MARK: Prompt (grounded — mirrors backend/rag/prompt_builder.py)

    private static let systemPrompt = """
    Kamu asisten yang menjelaskan hasil skrining sarkopenia dalam Bahasa Indonesia yang hangat \
    dan sederhana, lalu menyusun rencana latihan konkret. Kategori risiko dan status SUDAH \
    dihitung — jangan mengubahnya, hanya jelaskan. Dasarkan HANYA pada hasil + "Referensi"; \
    jangan mengarang. Jika ada "Tanda keselamatan", tekankan evaluasi profesional dan buat \
    rencana lebih ringan. Latihan HANYA boleh: "Sit to Stand", "Step Up", "Calf Raise". \
    Hindari kata "diagnosis".

    Balas HANYA dengan JSON valid (tanpa markdown), format persis:
    {"analysis":"<1-2 kalimat penjelasan + motivasi>","plan":[{"exercise":"Sit to Stand","intensity":0.7,"repsPerSet":10,"setsPerDay":2}]}
    intensity 0.0–1.0 (lebih rendah untuk risiko/keterbatasan lebih tinggi). Sertakan ketiga latihan kecuali dibatasi keselamatan.
    """

    /// Builds the grounded prompt: the user's real result summary, the deterministic
    /// baseline plan (the model refines it, and it's the parse fallback), and the
    /// retrieved references. A skipped exercise → an "unable to self-test" red flag
    /// here, which steers the analysis + gentles the plan.
    static func buildPrompt(question: String, result: AssessmentResult, maxChunks: Int = 3) -> String {
        let tags = relevantTags(for: result)
        let retrieved = retrieve(tags: tags, limit: maxChunks)
        print("[OnDeviceRAG] tags=\(tags.sorted()) → \(retrieved.count) chunks \(retrieved.map(\.id))")

        let references = retrieved
            .map { "[\($0.source)]\n\($0.content)" }
            .joined(separator: "\n\n")

        let baseline = ExercisePlan.derive(from: result)
            .map { "\($0.kind.rawValue): intensity \($0.intensity), \($0.repsPerSet) rep, \($0.setsPerDay)x/hari" }
            .joined(separator: "\n")

        return """
        Hasil skrining pengguna (sudah final — jelaskan, jangan ubah):
        \(resultSummary(result))

        Rencana latihan awal yang disarankan (silakan sesuaikan sedikit, tetap aman):
        \(baseline)

        Referensi relevan (dasar untuk penjelasan & saran):
        \(references)

        \(question)
        """
    }

    /// Parse the model's JSON reply → (analysis text, structured plan). Returns nil
    /// when the output isn't valid/usable so the caller can fall back to the
    /// deterministic plan. Defensive: strips markdown fences, keeps only the known
    /// exercises, and clamps numbers.
    static func parse(_ raw: String) -> (analysis: String, plan: [Workout])? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}") {
            s = String(s[open...close])
        }
        guard let data = s.data(using: .utf8),
              let out = try? JSONDecoder().decode(LLMOutput.self, from: data) else { return nil }

        // Keep only the known exercises (WorkoutKind validates the LLM's string)
        // and clamp the numbers.
        let plan = out.plan.compactMap { w -> Workout? in
            guard let kind = WorkoutKind(rawValue: w.exercise) else { return nil }
            return Workout(
                kind: kind,
                intensity: min(1, max(0, w.intensity)),
                repsPerSet: max(1, min(50, w.repsPerSet)),
                setsPerDay: max(1, min(6, w.setsPerDay))
            )
        }
        guard !plan.isEmpty else { return nil }
        let analysis = out.analysis.trimmingCharacters(in: .whitespacesAndNewlines)
        return (analysis.isEmpty ? "—" : analysis, plan)
    }

    // The model emits `{"exercise":"Sit to Stand", …}`; decode that shape, then
    // map it onto the Core `Workout` (whose kind is a WorkoutKind, not a string).
    private struct LLMOutput: Decodable {
        let analysis: String
        let plan: [LLMWorkout]
    }
    private struct LLMWorkout: Decodable {
        let exercise: String
        let intensity: Double
        let repsPerSet: Int
        let setsPerDay: Int
    }

    /// Human-readable Indonesian summary of the rule-engine result for the prompt.
    private static func resultSummary(_ r: AssessmentResult) -> String {
        var lines = [
            "- Estimasi risiko: \(riskLabel(r.overallRisk))",
            "- Massa otot: \(statusLabel(r.muscleMassStatus)); kekuatan: \(statusLabel(r.strengthStatus)); performa berjalan: \(statusLabel(r.performanceStatus))",
        ]
        if !r.redFlags.isEmpty {
            lines.append("- Tanda keselamatan: \(r.redFlags.joined(separator: "; "))")
        }
        if !r.obesityFlags.isEmpty {
            lines.append("- Tanda lain: \(r.obesityFlags.joined(separator: "; "))")
        }
        if r.workoutRestriction == .mobilityOnly {
            lines.append("- Pembatasan latihan: hanya gerakan ringan & keseimbangan (perlu izin profesional)")
        }
        return lines.joined(separator: "\n")
    }

    private static func riskLabel(_ r: RiskCategory) -> String {
        switch r {
        case .low:        return "Risiko Rendah"
        case .mid:        return "Risiko Menengah (kemungkinan sarkopenia)"
        case .high:       return "Risiko Tinggi (sarkopenia terkonfirmasi)"
        case .severe:     return "Risiko Berat (sarkopenia + performa rendah)"
        case .unassessed: return "Belum dinilai (data kurang)"
        }
    }

    private static func statusLabel(_ s: StatusCategory) -> String {
        switch s {
        case .normal:      return "normal"
        case .abnormal:    return "rendah"
        case .notAssessed: return "tidak dinilai"
        }
    }

    static func getSystemPrompt() -> String { systemPrompt }
}
