//  ExercisePlan.swift
//
//  Deterministic workout plan from the screening result. This is the LLM's
//  suggested baseline (passed into the prompt) AND the fallback used verbatim when
//  the LLM's JSON can't be parsed — so the tracker always has a safe, concrete plan
//  (exercise · intensity · reps/set · sets/day · tempo · rest · safety · progression),
//  whatever the model does.

import Foundation

enum ExercisePlan {

    static func derive(from result: AssessmentResult) -> [Workout] {
        // Safety first: mobility/balance-only clearance → one gentle, low-ROM move.
        if result.workoutRestriction == .mobilityOnly {
            return [Workout(
                kind: .calfRaise, intensity: 0.4, repsPerSet: 8, setsPerDay: 1,
                tempo: "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)",
                restSeconds: 60,
                safetyNotes: "Lakukan dengan berpegangan pada dinding atau kursi. Hentikan jika merasa pusing atau nyeri.",
                progressionTip: "Setelah nyaman, coba lepaskan satu tangan dari pegangan."
            )]
        }

        // Scale ROM (intensity), reps, and daily dose to the risk category.
        var intensity: Double
        var reps: Int
        var sets: Int
        var restSec: Int
        var tempoDesc: String
        switch result.overallRisk {
        case .low:
            intensity = 1.0;  reps = 12; sets = 3; restSec = 30
            tempoDesc = "Terkontrol (2 detik naik, 2 detik turun)"
        case .mid:
            intensity = 0.75; reps = 10; sets = 2; restSec = 30
            tempoDesc = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
        case .high:
            intensity = 0.6;  reps = 8;  sets = 2; restSec = 45
            tempoDesc = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
        case .severe:
            intensity = 0.5;  reps = 6;  sets = 1; restSec = 60
            tempoDesc = "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)"
        case .unassessed:
            intensity = 0.6;  reps = 8;  sets = 2; restSec = 30
            tempoDesc = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
        }

        // Any safety flag → prescribe more gently.
        if !result.redFlags.isEmpty {
            intensity = min(intensity, 0.6)
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
                kind: .calfRaise, intensity: intensity, repsPerSet: max(reps, 15), setsPerDay: sets,
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

