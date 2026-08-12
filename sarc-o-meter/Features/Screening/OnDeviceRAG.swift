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

    /// Chunks whose tags intersect the given tags, capped at `limit` (order
    /// preserved). The cap keeps the prompt short enough for the 0.5B to prefill
    /// quickly — raise it once you're on a faster model / batched-prefill path.
    static func retrieve(tags: Set<String>, limit: Int = 2) -> [KnowledgeChunk] {
        Array(chunks.filter { !Set($0.tags).isDisjoint(with: tags) }.prefix(limit))
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

    FORMAT OUTPUT — balas HANYA dengan JSON valid, tanpa markdown fence, dengan struktur \
    persis:
    {"insight":"1-2 paragraf menjelaskan kondisi pengguna berdasarkan profil dan \
    indikator yang tersedia (usia, massa otot, obesitas, riwayat klinis), dan apa \
    artinya untuk program latihan mereka.","exercises":[{"exercise":"Nama latihan \
    (salah satu dari: Sit to Stand, Step Up, Calf Raise)","sets":angka,"reps":angka,\
    "tempo":"Deskripsi tempo gerakan","restSeconds":angka,"safetyNotes":"Catatan \
    keselamatan spesifik","progressionTip":"Cara meningkatkan intensitas bertahap"}],\
    "weeklySchedule":"Jadwal mingguan"}

    PENTING: Array "exercises" HARUS berisi tepat 3 objek, satu untuk setiap latihan \
    (Sit to Stand, Step Up, Calf Raise). Setiap latihan harus dipersonalisasi \
    berdasarkan kondisi pengguna.
    """

    /// Builds the grounded prompt: the user's real result summary, the deterministic
    /// baseline plan (the model refines it, and it's the parse fallback), and the
    /// retrieved references. A skipped exercise → an "unable to self-test" red flag
    /// here, which steers the analysis + gentles the plan.
    static func buildPrompt(question: String, result: AssessmentResult, user: User, maxChunks: Int = 3) -> String {
        let tags = relevantTags(for: result)
        let retrieved = retrieve(tags: tags, limit: maxChunks)
        print("[OnDeviceRAG] tags=\(tags.sorted()) → \(retrieved.count) chunks \(retrieved.map(\.id))")

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
        - Kardiovaskular tidak stabil: \(user.hasUnstableCardio ? "Ya" : "Tidak")
        - Riwayat jatuh: \(user.hasRecentFalls ? "Ya" : "Tidak")
        - Nyeri sendi/patah tulang: \(user.hasAcuteJointPainOrFracture ? "Ya" : "Tidak")
        - Kondisi neurologis: \(user.hasNeurologicalCondition ? "Ya" : "Tidak")

        Rencana latihan awal yang disarankan (silakan sesuaikan, tetap aman):
        \(baseline)

        Referensi relevan (satu-satunya dasar yang boleh kamu pakai untuk meresepkan \
        latihan dan menentukan safety threshold):
        \(references)

        Buat output sesuai format JSON yang ditentukan di instruksi sistem. Pastikan semua \
        3 latihan (Sit to Stand, Step Up, Calf Raise) ada dalam array "exercises" dengan \
        parameter yang dipersonalisasi untuk pengguna ini.
        """
    }

    /// Parse the model's JSON reply → (analysis text, structured plan, weekly schedule).
    /// Returns nil when the output isn't valid/usable so the caller can fall back to the
    /// deterministic plan. Defensive: strips markdown fences, keeps only the known
    /// exercises, and clamps numbers.
    static func parse(_ raw: String) -> (analysis: String, plan: [Workout], weeklySchedule: String?)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}") {
            s = String(s[open...close])
        }
        guard let data = s.data(using: .utf8),
              let out = try? JSONDecoder().decode(LLMOutput.self, from: data) else { return nil }

        // Keep only the known exercises (WorkoutKind validates the LLM's string)
        // and clamp the numbers.
        let plan = out.exercises.compactMap { w -> Workout? in
            guard let kind = WorkoutKind(rawValue: w.exercise) else { return nil }
            return Workout(
                kind: kind,
                intensity: 0.7, // not set by LLM; use a sensible default
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

// MARK: - Rounding helper

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

