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
        if result.strengthStatus == .limited      { tags.insert("low_strength"); tags.insert("limited_ability") }
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
        case .severe, .high: return 8  // more chunks for exercise-specific safety knowledge
        case .mid: return 5
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
    - Jika pengguna telah melakukan tes, array HANYA berisi latihan yang BERHASIL \
    mereka lakukan (minimal 1 repetisi). JANGAN masukkan latihan yang ditandai \
    "Tidak bisa melakukan (dilewati)".
    - Jika pengguna sama sekali tidak bisa melakukan semua latihan, array berisi \
    1 objek (Calf Raise saja) karena perlu memulai dari gerakan paling dasar.
    - Sertakan parameter keselamatan SPESIFIK per latihan: tinggi step (cm), jenis \
    kursi (tinggi, stabilitas), kebutuhan pegangan, dari referensi yang diberikan.
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

        // Tailor the final instruction based on severity and demonstrated ability.
        let exerciseInstruction: String
        if result.workoutRestriction == .mobilityOnly {
            exerciseInstruction = """
            Buat output sesuai format JSON yang ditentukan di instruksi sistem. Karena \
            pengguna memiliki pembatasan keras, array "exercises" HANYA berisi 1 latihan: \
            Calf Raise dengan intensitas sangat rendah, berpegangan pada dinding/kursi. \
            JANGAN masukkan Sit to Stand atau Step Up.
            """
        } else if let ability = result.exerciseAbility {
            let unableAll = ability.grade(for: .sitToStand) == .unable &&
                            ability.grade(for: .stepUp) == .unable &&
                            ability.grade(for: .calfRaise) == .unable
            
            if unableAll {
                exerciseInstruction = """
                Buat output sesuai format JSON yang ditentukan di instruksi sistem. Karena \
                pengguna sama sekali tidak bisa melakukan tes kekuatan, array "exercises" \
                HANYA berisi 1 latihan dasar: Calf Raise dengan intensitas sangat rendah. \
                JANGAN masukkan Sit to Stand atau Step Up.
                """
            } else {
                exerciseInstruction = """
                Buat output sesuai format JSON yang ditentukan di instruksi sistem. Pastikan \
                array "exercises" HANYA berisi latihan yang BERHASIL dilakukan oleh pengguna. \
                Personalisasikan parameter (sets, reps, tempo, restSeconds) BERDASARKAN hasil \
                tes kekuatan per latihan di atas. Latihan dengan repetisi rendah harus mendapat \
                parameter lebih konservatif (reps lebih sedikit, tempo lebih lambat, istirahat \
                lebih lama). Sertakan parameter keselamatan spesifik per latihan (tinggi step, \
                jenis kursi, kebutuhan pegangan) dari referensi.
                """
            }
        } else {
            exerciseInstruction = """
            Buat output sesuai format JSON yang ditentukan di instruksi sistem. Personalisasikan \
            parameter latihan untuk pengguna ini dan sertakan catatan keselamatan dari referensi.
            """
        }

        // Classify clinical history into hard restrictions vs caution flags
        // so the LLM prompt gives accurate context.
        let hasHardRestriction = result.workoutRestriction == .mobilityOnly
        let cautionFlags: [String] = [
            user.hasRecentSurgeryOrHospitalization ? "operasi/rawat inap baru-baru ini" : nil,
            user.hasRoutineMedication ? "obat-obatan rutin" : nil,
            user.hasBalanceOrDizziness ? "gangguan keseimbangan/pusing" : nil,
        ].compactMap { $0 }

        let restrictionNote: String
        if hasHardRestriction {
            restrictionNote = "Status: PEMBATASAN KERAS — hanya gerakan ringan & keseimbangan (perlu izin profesional)."
        } else if !cautionFlags.isEmpty {
            restrictionNote = "Status: PERHATIAN — riwayat klinis berikut memerlukan penurunan intensitas tapi TIDAK menghalangi semua 3 latihan: \(cautionFlags.joined(separator: ", ")). Sesuaikan intensitas dan tambahkan catatan keselamatan yang relevan."
        } else if !result.redFlags.isEmpty {
            restrictionNote = "Status: ada tanda keselamatan — sesuaikan intensitas."
        } else {
            restrictionNote = "Status: tidak ada pembatasan khusus."
        }

        // Build strength test results section (per-exercise detail).
        let strengthTestSection: String
        if let ability = result.exerciseAbility {
            func repLine(_ name: String, _ reps: Int?, _ threshold: Int) -> String {
                guard let r = reps else { return "- \(name): Tidak bisa melakukan (dilewati)" }
                let status = r >= threshold ? "memenuhi ambang normal" : "di bawah ambang normal ≥\(threshold)"
                return "- \(name): \(r) repetisi dalam 30 detik (\(status))"
            }
            var lines = [
                "Hasil tes kekuatan (30 detik per latihan):",
                repLine("Sit to Stand", ability.sitToStandReps, 5),
                repLine("Step Up", ability.stepUpReps, 4),
                repLine("Calf Raise", ability.calfRaiseReps, 8),
            ]
            if ability.completedAll {
                let allLimited = ability.grade(for: .sitToStand) == .limited ||
                                 ability.grade(for: .stepUp) == .limited ||
                                 ability.grade(for: .calfRaise) == .limited
                if allLimited {
                    lines.append("→ Pengguna BISA melakukan semua 3 latihan tapi dengan jumlah terbatas. Resepkan semua 3 latihan dengan parameter yang disesuaikan per latihan berdasarkan repetisi yang berhasil.")
                } else {
                    lines.append("→ Pengguna berhasil memenuhi ambang normal pada semua latihan.")
                }
            } else {
                lines.append("→ Pengguna TIDAK bisa menyelesaikan semua latihan. JANGAN meresepkan latihan yang tidak bisa mereka lakukan (dilewati/0 rep). Fokus HANYA pada latihan yang berhasil dilakukan.")
            }
            strengthTestSection = lines.joined(separator: "\n")
        } else {
            strengthTestSection = "Hasil tes kekuatan: tidak tersedia."
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

        \(strengthTestSection)

        \(restrictionNote)

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
    // MARK: - Robust JSON & String Sanitization

    private static func cleanJSONString(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}") {
            s = String(s[open...close])
        }

        // Remove trailing commas before } or ]
        if let regex = try? NSRegularExpression(pattern: ",\\s*([}\\]])", options: []) {
            let range = NSRange(location: 0, length: s.utf16.count)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "$1")
        }

        return s
    }

    /// Normalizes exercise name variations from LLM to known WorkoutKind.
    private static func matchWorkoutKind(_ raw: String) -> WorkoutKind? {
        if let exact = WorkoutKind(rawValue: raw) { return exact }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.contains("sit") { return .sitToStand }
        if clean.contains("step") { return .stepUp }
        if clean.contains("calf") { return .calfRaise }
        return nil
    }

    /// Parse the model's JSON reply → (analysis text, structured plan, weekly schedule).
    /// Returns nil when the output isn't valid/usable so the caller can fall back to the
    /// deterministic plan. Defensive: strips markdown fences, handles trailing commas,
    /// normalizes exercise names, and clamps numbers.
    static func parse(_ raw: String, result: AssessmentResult) -> (analysis: String, plan: [Workout], weeklySchedule: String?)? {
        if raw.contains("[Error generating response") { return nil }

        let s = cleanJSONString(raw)
        guard let data = s.data(using: .utf8),
              let out = try? JSONDecoder().decode(LLMOutput.self, from: data) else { return nil }

        let prescribedIntensity = ExercisePlan.prescribedIntensity(for: result)

        // Keep only known exercises with tolerant matching and clamped numbers.
        let plan = out.exercises.compactMap { w -> Workout? in
            guard let kind = matchWorkoutKind(w.exercise) else { return nil }
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
    /// Handles multiline insight, unescaped newlines in JSON, regex extraction,
    /// and plain language responses while filtering out generation errors.
    static func extractInsight(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Ignore error text from streaming failure
        if trimmed.contains("[Error generating response") { return nil }

        // 1. Try to pull just the "insight" value via partial JSON decode.
        if let open = trimmed.firstIndex(of: "{"),
           let close = trimmed.lastIndex(of: "}") {
            let jsonSlice = String(trimmed[open...close])
            if let data = jsonSlice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let insight = obj["insight"] as? String {
                let clean = insight.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty && !clean.contains("[Error") { return clean }
            }
        }

        // 2. Multiline regex match for "insight" field (handles literal newlines inside quotes).
        let pattern = #""insight"\s*:\s*"((?:[^"\\]|\\.)*)""#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: trimmed) {
            let extracted = String(trimmed[r])
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !extracted.isEmpty && !extracted.contains("[Error") {
                return extracted
            }
        }

        // 3. Regex match for truncated insight (when tokens cut off before the closing quote).
        let truncatedPattern = #""insight"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"#
        if let regex = try? NSRegularExpression(pattern: truncatedPattern, options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)),
           match.numberOfRanges > 1,
           let r = Range(match.range(at: 1), in: trimmed) {
            let extracted = String(trimmed[r])
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if extracted.count > 25 && !extracted.contains("[Error") {
                return extracted
            }
        }

        // 4. Plain-language response fallback (if model replied in prose without JSON).
        if !trimmed.contains("{\"insight") && !trimmed.contains("{\"exercises") && !trimmed.contains("\"insight\"") {
            if trimmed.count > 20 && !trimmed.contains("[Error") {
                return trimmed
            }
        }

        return nil
    }

    /// Generates a comprehensive deterministic condition analysis when the LLM
    /// cannot generate or after retries fail. Based on AWGS 2019 guidelines and
    /// the user's specific anthropometrics, physical test, and clinical flags.
    static func fallbackAnalysis(for result: AssessmentResult, user: User, reason: String? = nil) -> String {
        var paragraphs: [String] = []

        if let reason, !reason.isEmpty {
            paragraphs.append("📌 Catatan Sistem: \(reason)")
        }

        // 1. Overall risk and demographic summary
        let ageStr = user.age.map { "\($0) tahun" } ?? "dewasa"
        let genderStr = user.gender?.rawValue.lowercased() ?? "individu"
        let riskDesc: String
        switch result.overallRisk {
        case .low:
            riskDesc = "menunjukkan estimasi risiko sarkopenia yang rendah. Kondisi fisik dan massa otot Anda berada dalam rentang baik untuk usia Anda."
        case .mid:
            riskDesc = "menunjukkan sinyal awal potensi penurunan massa atau kekuatan otot (risiko menengah). Langkah preventif melalui latihan teratur sangat disarankan."
        case .high:
            riskDesc = "mengindikasikan risiko tinggi terkait penurunan massa dan kekuatan otot. Diperlukan perhatian khusus pada penguatan otot secara bertahap dan pemenuhan nutrisi protein."
        case .severe:
            riskDesc = "menunjukkan indikasi risiko tinggi yang disertai keterbatasan performa fisik. Program latihan harus dilakukan dengan sangat hati-hati, berfokus pada keselamatan dan stabilitas gerak."
        case .unassessed:
            riskDesc = "memerlukan pemantauan berkala karena sebagian data pengukuran masih belum lengkap."
        }
        paragraphs.append("Berdasarkan evaluasi skrining untuk \(genderStr) berusia \(ageStr), profil Anda \(riskDesc)")

        // 2. Muscle mass & body measurement indicators
        var bodyPoints: [String] = []
        if let calf = user.calf {
            let calfStatus = result.muscleMassStatus == .abnormal ? "di bawah ambang batas acuan AWGS" : "dalam rentang normal"
            bodyPoints.append("Lingkar betis tercatat \(calf) cm (\(calfStatus))")
        }
        if let waist = user.waist {
            let waistNote = !result.obesityFlags.isEmpty ? " (terdapat indikasi perhatian pada lingkar pinggang)" : ""
            bodyPoints.append("lingkar pinggang \(waist) cm\(waistNote)")
        }
        if let h = user.height, let w = user.weight, h > 0 {
            let hm = h / 100.0
            let bmi = (w / (hm * hm)).rounded(toPlaces: 1)
            bodyPoints.append("Indeks Massa Tubuh (IMT) \(bmi) kg/m²")
        }
        if !bodyPoints.isEmpty {
            paragraphs.append("Pengukuran fisik menunjukkan: \(bodyPoints.joined(separator: ", ")). Status massa otot tergolong \(statusLabel(result.muscleMassStatus)).")
        }

        // 3. Physical test / Strength indicators
        if let ability = result.exerciseAbility {
            var repDetails: [String] = []
            if let sit = ability.sitToStandReps {
                repDetails.append("Sit to Stand: \(sit) repetisi")
            }
            if let step = ability.stepUpReps {
                repDetails.append("Step Up: \(step) repetisi")
            }
            if let calf = ability.calfRaiseReps {
                repDetails.append("Calf Raise: \(calf) repetisi")
            }
            let repSummary = repDetails.isEmpty ? "Tes fisik telah diselesaikan" : "Hasil tes kekuatan 30 detik: \(repDetails.joined(separator: ", "))"
            paragraphs.append("\(repSummary). Status kekuatan otot tubuh bagian bawah dinilai \(statusLabel(result.strengthStatus)).")
        }

        // 4. Clinical cautions & recommendation
        if result.workoutRestriction == .mobilityOnly {
            paragraphs.append("Catatan keselamatan: Terdapat indikasi pembatasan latihan. Disarankan fokus pada gerakan mobilitas ringan dan keseimbangan dengan berpegangan, serta konsultasikan dengan tenaga medis sebelum memulai latihan berintensitas lebih tinggi.")
        } else if !result.redFlags.isEmpty {
            paragraphs.append("Perhatian: Ditemukan tanda kehati-hatian (\(result.redFlags.joined(separator: ", "))). Lakukan latihan secara perlahan, bernapas normal tanpa menahan napas, dan segera istirahat apabila timbul rasa pusing atau nyeri.")
        } else {
            paragraphs.append("Rekomendasi: Lakukan program latihan terstruktur secara konsisten, prioritaskan kontrol dan kualitas gerakan, serta jaga asupan gizi seimbang untuk memelihara fungsi otot.")
        }

        return paragraphs.joined(separator: "\n\n")
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
            "- Massa otot: \(statusLabel(r.muscleMassStatus)); kekuatan: \(statusLabel(r.strengthStatus))",
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
        case .limited:     return "terbatas (bisa melakukan tapi di bawah ambang)"
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

