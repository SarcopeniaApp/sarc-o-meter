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
//
//  v2: Detailed exercise prescription output with per-exercise safety thresholds,
//  tempo, rest, progression tips, and weekly schedule — matching SarcopeniaApp.

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

    /// Risk-aware chunk cap. Higher-risk users get more context because recall is
    /// more important when recommendations need stronger grounding.
    static func maxChunks(for result: AssessmentResult) -> Int {
        switch result.overallRisk {
        case .severe, .high: return 6
        case .mid: return 4
        case .low, .unassessed: return 3
        }
    }

    /// Chunks whose tags intersect the given tags, capped at `limit`. Safety-critical
    /// chunks are pinned first for red flags or severe risk, then normal JSON order is
    /// preserved for the remaining matching chunks.
    static func retrieve(tags: Set<String>, limit: Int, pinnedIDs: Set<String> = []) -> [KnowledgeChunk] {
        let matchingChunks = chunks.filter { !Set($0.tags).isDisjoint(with: tags) }
        let pinnedChunks = chunks.filter { pinnedIDs.contains($0.id) }
        let remainingChunks = matchingChunks.filter { !pinnedIDs.contains($0.id) }
        return Array((pinnedChunks + remainingChunks).prefix(limit))
    }

    private static func safetyCriticalChunkIDs(for result: AssessmentResult) -> Set<String> {
        guard !result.redFlags.isEmpty || result.overallRisk == .severe else { return [] }
        return ["kb_contraindication_01", "kb_risk_high_severe_01"]
    }

    // MARK: Prompt (grounded — mirrors backend/rag/prompt_builder.py)

    private static let systemPrompt = """
    Kamu adalah asisten exercise physiologist AI yang membuat rencana latihan personal \
    untuk orang dewasa usia menengah hingga lansia (40+). Tugasmu adalah menganalisis \
    kondisi pengguna berdasarkan profil mereka dan meresepkan latihan yang aman dan \
    berbasis bukti.

    ATURAN KETAT — WAJIB DIPATUHI:
    1. Kamu HANYA boleh meresepkan dari 3 latihan ini: Sit to Stand, Step Up, dan \
    Calf Raise. Jangan meresepkan latihan lain.
    2. Setiap latihan HARUS mencakup safety threshold yang spesifik: jumlah set, \
    repetisi, tempo gerakan, waktu istirahat, catatan keselamatan, dan tip progresif. \
    Parameter ini HARUS didasarkan pada "Referensi relevan" yang diberikan.
    3. Personalisasikan resep latihan berdasarkan usia, jenis kelamin, pengukuran tubuh, \
    dan riwayat klinis pengguna. Orang usia 40-54 bisa memulai lebih intensif dibanding 75+.
    4. Jika ada RED FLAG (kontraindikasi) pada data, PRIORITASKAN keselamatan: \
    kurangi intensitas drastis, tambahkan peringatan supervisi profesional, dan tekankan \
    pentingnya evaluasi medis dulu sebelum program latihan mandiri.
    5. JANGAN PERNAH gunakan kata "diagnosis", "Anda menderita", atau "terdiagnosis". \
    Gunakan istilah seperti "indikator", "estimasi", atau "sinyal awal".
    6. Selalu sertakan catatan bahwa ini adalah alat bantu, bukan pengganti evaluasi \
    medis profesional.
    7. Sertakan tips pernapasan: JANGAN menahan napas saat latihan, bernapas normal.
    8. Jika ada "Pembatasan latihan: hanya gerakan ringan", HANYA resepkan 1 latihan \
    ringan (Calf Raise) dengan intensitas sangat rendah. JANGAN resepkan 3 latihan.

    FORMAT OUTPUT — balas HANYA dengan JSON valid, tanpa markdown fence, dengan struktur \
    persis:
    {"insight":"1-2 paragraf menjelaskan kondisi pengguna berdasarkan profil dan \
    indikator yang tersedia (usia, massa otot, obesitas, riwayat klinis), dan apa \
    artinya untuk program latihan mereka.","exercises":[{"exercise":"Nama latihan \
    (salah satu dari: Sit to Stand, Step Up, Calf Raise)","sets":angka,"reps":angka,\
    "tempo":"Deskripsi tempo gerakan","restSeconds":angka,"safetyNotes":"Catatan \
    keselamatan spesifik","progressionTip":"Cara meningkatkan intensitas bertahap"}],\
    "weeklySchedule":"Jadwal mingguan"}

    PENTING: Jumlah latihan dalam array "exercises" tergantung kondisi pengguna:
    - Jika ada "Pembatasan latihan: hanya gerakan ringan", array HANYA berisi 1 objek \
    (Calf Raise saja).
    - Jika risiko "Berat" (severe), array berisi 1 objek (Calf Raise saja) karena \
    pengguna perlu memulai dari gerakan paling dasar dan aman.
    - Untuk risiko lainnya, array berisi tepat 3 objek (Sit to Stand, Step Up, Calf Raise).
    """

    /// Builds the grounded prompt: the user's real result summary, the deterministic
    /// baseline plan (the model refines it, and it's the parse fallback), and the
    /// retrieved references. A skipped exercise → an "unable to self-test" red flag
    /// here, which steers the analysis + gentles the plan.
    static func buildPrompt(question: String, result: AssessmentResult, user: User, maxChunks: Int? = nil) -> String {
        let tags = relevantTags(for: result)
        let effectiveMaxChunks = maxChunks ?? Self.maxChunks(for: result)
        let pinnedIDs = safetyCriticalChunkIDs(for: result)
        let retrieved = retrieve(tags: tags, limit: effectiveMaxChunks, pinnedIDs: pinnedIDs)
        print("[OnDeviceRAG] tags=\(tags.sorted()) maxChunks=\(effectiveMaxChunks) pinned=\(pinnedIDs.sorted()) → \(retrieved.count) chunks \(retrieved.map(\.id))")

        let references = retrieved
            .map { "[\($0.source)]\n\($0.content)" }
            .joined(separator: "\n\n")

        let baseline = ExercisePlan.derive(from: result)
            .map { "\($0.kind.rawValue): \($0.setsPerDay) set × \($0.repsPerSet) rep, tempo: \($0.tempo ?? "-"), rest: \($0.restSeconds ?? 30)s" }
            .joined(separator: "\n")

        // Build user profile context (mirrors SarcopeniaApp's prompt_builder.py)
        var bmi: Double? = nil
        if let h = user.height, let w = user.weight, h > 0 {
            let hm = h / 100.0
            bmi = (w / (hm * hm)).rounded(toPlaces: 1)
        }

        // Tailor the final instruction based on severity.
        let exerciseInstruction: String
        if result.workoutRestriction == .mobilityOnly || result.overallRisk == .severe {
            exerciseInstruction = """
            Buat output sesuai format JSON yang ditentukan di instruksi sistem. Karena \
            pengguna memiliki keterbatasan dan/atau risiko berat, array "exercises" HANYA \
            berisi 1 latihan: Calf Raise dengan intensitas sangat rendah, berpegangan \
            pada dinding/kursi. JANGAN masukkan Sit to Stand atau Step Up.
            """
        } else {
            exerciseInstruction = """
            Buat output sesuai format JSON yang ditentukan di instruksi sistem. Pastikan semua \
            3 latihan (Sit to Stand, Step Up, Calf Raise) ada dalam array "exercises" dengan \
            parameter yang dipersonalisasi untuk pengguna ini.
            """
        }

        return """
        Hasil skrining pengguna (sudah final — jelaskan, jangan ubah):
        \(resultSummary(result))

        Profil pengguna:
        - Usia: \(user.age.map(String.init) ?? "tidak diketahui") tahun
        - Jenis kelamin: \(user.gender?.rawValue ?? "tidak diketahui")
        - Tinggi: \(user.height.map { "\($0) cm" } ?? "tidak diketahui")
        - Berat: \(user.weight.map { "\($0) kg" } ?? "tidak diketahui")
        - BMI: \(bmi.map { "\($0)" } ?? "tidak diketahui")
        - Lingkar betis: \(user.calf.map { "\($0) cm" } ?? "tidak diketahui")
        - Lingkar pinggang: \(user.waist.map { "\($0) cm" } ?? "tidak diketahui")

        Riwayat klinis:
        - Operasi/rawat inap baru: \(user.hasRecentSurgeryOrHospitalization ? "Ya" : "Tidak")
        - Gangguan jantung (berdebar/diagnosis): \(user.hasHeartCondition ? "Ya" : "Tidak")
        - Tekanan darah tinggi tidak terkontrol: \(user.hasUncontrolledBP ? "Ya" : "Tidak")
        - Sering kehilangan keseimbangan/pusing: \(user.hasBalanceOrDizziness ? "Ya" : "Tidak")
        - Nyeri sendi/patah tulang: \(user.hasAcuteJointPainOrFracture ? "Ya" : "Tidak")
        - Kondisi neurologis: \(user.hasNeurologicalCondition ? "Ya" : "Tidak")
        - Mengonsumsi obat-obatan rutin: \(user.hasRoutineMedication ? "Ya" : "Tidak")
        - Menggunakan alat bantu jalan: \(user.hasWalkingAid ? "Ya" : "Tidak")

        Rencana latihan awal yang disarankan (silakan sesuaikan, tetap aman):
        \(baseline)

        Referensi relevan (satu-satunya dasar yang boleh kamu pakai untuk meresepkan \
        latihan dan menentukan safety threshold):
        \(references)

        \(exerciseInstruction)
        """
    }

    /// Parse the model's JSON reply → (analysis text, structured plan, weekly schedule).
    /// Returns nil when the output isn't valid/usable so the caller can fall back to the
    /// deterministic plan. Defensive: strips markdown fences, keeps only the known
    /// exercises, and clamps numbers.
    static func parse(_ raw: String, result: AssessmentResult) -> (analysis: String, plan: [Workout], weeklySchedule: String?)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}") {
            s = String(s[open...close])
        }
        guard let data = s.data(using: .utf8),
              let out = try? JSONDecoder().decode(LLMOutput.self, from: data) else { return nil }

        let prescribedIntensity = ExercisePlan.prescribedIntensity(for: result)

        // Keep only the known exercises (WorkoutKind validates the LLM's string)
        // and clamp the numbers.
        let plan = out.exercises.compactMap { w -> Workout? in
            guard let kind = WorkoutKind(rawValue: w.exercise) else { return nil }
            return Workout(
                kind: kind,
                intensity: prescribedIntensity,
                repsPerSet: max(1, min(50, w.reps)),
                setsPerDay: max(1, min(6, w.sets)),
                tempo: w.tempo,
                restSeconds: w.restSeconds.map { max(10, min(180, $0)) },
                safetyNotes: w.safetyNotes,
                progressionTip: w.progressionTip
            )
        }
        guard !plan.isEmpty else { return nil }
        let analysis = out.insight.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = out.weeklySchedule?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (analysis.isEmpty ? "—" : analysis, plan, schedule)
    }

    /// Best-effort extraction of just the "insight" text from raw LLM output.
    /// Handles cases where the full JSON can't be decoded (e.g. malformed
    /// exercises array) but the insight string is still there and readable.
    /// Returns nil when nothing useful can be salvaged.
    static func extractInsight(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Try to pull just the "insight" value via partial JSON decode.
        if let open = trimmed.firstIndex(of: "{"),
           let close = trimmed.lastIndex(of: "}") {
            let jsonSlice = String(trimmed[open...close])
            if let data = jsonSlice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let insight = obj["insight"] as? String {
                let clean = insight.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return clean }
            }
        }

        // 2. If the raw text doesn't look like JSON at all, it might be a
        //    plain-language response — return it directly.
        if !trimmed.contains("{\"insight") && !trimmed.contains("{\"exercises") {
            return trimmed
        }

        return nil
    }

    // The model emits `{"exercise":"Sit to Stand", …}`; decode that shape, then
    // map it onto the Core `Workout` (whose kind is a WorkoutKind, not a string).
    private struct LLMOutput: Decodable {
        let insight: String
        let exercises: [LLMExercise]
        let weeklySchedule: String?
    }
    private struct LLMExercise: Decodable {
        let exercise: String
        let sets: Int
        let reps: Int
        let tempo: String?
        let restSeconds: Int?
        let safetyNotes: String?
        let progressionTip: String?
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
        case .mid:        return "Risiko Menengah"
        case .high:       return "Risiko Tinggi"
        case .severe:     return "Risiko Berat"
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

// MARK: - Rounding helper

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

