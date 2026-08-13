//  ExercisePlan.swift
//
//  Deterministic workout plan from the screening result. This is the LLM's
//  suggested baseline (passed into the prompt) AND the fallback used verbatim when
//  the LLM's JSON can't be parsed — so the tracker always has a safe, concrete plan
//  (exercise · intensity · reps/set · sets/day · tempo · rest · safety · progression),
//  whatever the model does.

import Foundation

enum ExercisePlan {

    static func prescribedIntensity(for result: AssessmentResult) -> Double {
        if result.workoutRestriction == .mobilityOnly { return 0.4 }

        let baseIntensity: Double
        switch result.overallRisk {
        case .low:        baseIntensity = 1.0
        case .mid:        baseIntensity = 0.75
        case .high:       baseIntensity = 0.6
        case .severe:     baseIntensity = 0.5
        case .unassessed: baseIntensity = 0.6
        }

        return result.redFlags.isEmpty ? baseIntensity : min(baseIntensity, 0.6)
    }

    static func derive(from result: AssessmentResult) -> [Workout] {
        let prescribedIntensity = prescribedIntensity(for: result)

        // Safety first: mobility/balance-only clearance → one gentle, low-ROM move.
        if result.workoutRestriction == .mobilityOnly {
            return [Workout(
                kind: .calfRaise, intensity: prescribedIntensity, repsPerSet: 8, setsPerDay: 1,
                tempo: "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)",
                restSeconds: 60,
                safetyNotes: "Lakukan dengan berpegangan pada dinding atau kursi. Hentikan jika merasa pusing atau nyeri.",
                progressionTip: "Setelah nyaman, coba lepaskan satu tangan dari pegangan."
            )]
        }

        // Severe risk → start with only Calf Raise (the most basic, safest
        // lower-limb exercise) until a professional can evaluate.
        if result.overallRisk == .severe {
            return [Workout(
                kind: .calfRaise, intensity: prescribedIntensity, repsPerSet: 6, setsPerDay: 1,
                tempo: "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)",
                restSeconds: 60,
                safetyNotes: "WAJIB dengan pendampingan profesional. Lakukan dengan berpegangan pada dinding atau kursi. Hentikan segera jika merasa pusing, nyeri, atau tidak stabil.",
                progressionTip: "Setelah 2-4 minggu rutin tanpa keluhan, konsultasikan dengan fisioterapis untuk menambah Sit to Stand secara bertahap."
            )]
        }

        // Scale ROM (intensity), reps, and daily dose to the risk category.
        let intensity = prescribedIntensity
        var reps: Int
        var sets: Int
        var restSec: Int
        var tempoDesc: String
        switch result.overallRisk {
        case .low:
            reps = 12; sets = 3; restSec = 30
            tempoDesc = "Terkontrol (2 detik naik, 2 detik turun)"
        case .mid:
            reps = 10; sets = 2; restSec = 30
            tempoDesc = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
        case .high:
            reps = 8;  sets = 2; restSec = 45
            tempoDesc = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
        case .severe:
            reps = 6;  sets = 1; restSec = 60
            tempoDesc = "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)"
        case .unassessed:
            reps = 8;  sets = 2; restSec = 30
            tempoDesc = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
        }

        // Any safety flag → prescribe more gently.
        if !result.redFlags.isEmpty {
            reps = min(reps, 8)
            sets = min(sets, 2)
            restSec = max(restSec, 45)
            tempoDesc = "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)"
        }

        return [
            Workout(
                kind: .sitToStand, intensity: intensity, repsPerSet: reps, setsPerDay: sets,
                tempo: tempoDesc, restSeconds: restSec,
                safetyNotes: "Jangan mengangkat bahu terlalu tinggi untuk mengurangi beban pada leher. Jika merasa kaki sakit, kurangi jumlah repetisi.",
                progressionTip: "Tambahkan beban ringan (misal: 2 kg) di belakang lutut atau lakukan 1 set tambahan."
            ),
            Workout(
                kind: .stepUp, intensity: intensity, repsPerSet: reps, setsPerDay: sets,
                tempo: "Kontrol gerakan (2 detik naik, 2 detik turun)",
                restSeconds: restSec,
                safetyNotes: "Pastikan alas kaki slip-proof dan tinggi step/meja 30-40 cm untuk meminimalkan risiko cedera lutut.",
                progressionTip: "Tambahkan beban 1-2 kg di kaki atau tingkatkan jumlah repetisi hingga 15."
            ),
            Workout(
                kind: .calfRaise, intensity: intensity, repsPerSet: max(reps, 10), setsPerDay: sets,
                tempo: "Lambat dan terkontrol (2 detik naik, 2 detik turun)",
                restSeconds: restSec,
                safetyNotes: "Jangan mengangkat tumit lebih dari 10 cm untuk menghindari cedera tendon Achilles.",
                progressionTip: "Tambahkan beban 1-2 kg di belakang lutut atau lakukan 1 set tambahan."
            ),
        ]
    }

    /// Default weekly schedule based on risk level.
    static func weeklySchedule(for result: AssessmentResult) -> String {
        switch result.overallRisk {
        case .low:
            return "Latihan 3x per minggu (Senin, Rabu, Jumat) dengan jeda 48 jam, kombinasikan dengan jalan kaki 5 hari/minggu (15-30 menit) untuk mengoptimalkan pembentukan otot dan kardiovaskular."
        case .mid:
            return "Latihan 3x per minggu (Senin, Rabu, Jumat) dengan jeda 48 jam, kombinasikan dengan jalan kaki harian 15-30 menit."
        case .high:
            return "Latihan 2-3x per minggu pada hari yang tidak berurutan, dengan pendampingan jika memungkinkan."
        case .severe:
            return "Latihan 2x per minggu pada hari yang tidak berurutan, WAJIB dengan pendampingan profesional."
        case .unassessed:
            return "Latihan 2-3x per minggu pada hari yang tidak berurutan."
        }
    }
}

