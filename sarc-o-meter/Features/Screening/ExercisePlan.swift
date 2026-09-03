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

        // If we have per-exercise ability data, dynamically prescribe ONLY the
        // exercises the user demonstrated they can perform.
        if let ability = result.exerciseAbility {
            var workouts: [Workout] = []
            
            if ability.grade(for: .sitToStand) != .unable {
                workouts.append(scaledWorkout(kind: .sitToStand, ability: ability, intensity: prescribedIntensity, result: result))
            }
            if ability.grade(for: .stepUp) != .unable {
                workouts.append(scaledWorkout(kind: .stepUp, ability: ability, intensity: prescribedIntensity, result: result))
            }
            if ability.grade(for: .calfRaise) != .unable {
                workouts.append(scaledWorkout(kind: .calfRaise, ability: ability, intensity: prescribedIntensity, result: result))
            }
            
            // If they skipped/couldn't do ANY exercise, give them the safest single exercise.
            if workouts.isEmpty {
                return [Workout(
                    kind: .calfRaise, intensity: prescribedIntensity, repsPerSet: 6, setsPerDay: 1,
                    tempo: "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)",
                    restSeconds: 60,
                    safetyNotes: "WAJIB dengan pendampingan profesional. Lakukan dengan berpegangan pada dinding atau kursi. Hentikan segera jika merasa pusing, nyeri, atau tidak stabil.",
                    progressionTip: "Setelah 2-4 minggu rutin tanpa keluhan, konsultasikan dengan fisioterapis untuk menambah Sit to Stand secara bertahap."
                )]
            }
            
            return workouts
        }

        // Fallback: no ability data — use uniform parameters by risk level.
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
                safetyNotes: "Gunakan kursi kokoh (tinggi 43-45 cm) menempel dinding. Jangan menahan napas. Jika merasa kaki sakit, kurangi jumlah repetisi.",
                progressionTip: "Tambahkan beban ringan (misal: 2 kg) di belakang lutut atau lakukan 1 set tambahan."
            ),
            Workout(
                kind: .stepUp, intensity: intensity, repsPerSet: reps, setsPerDay: sets,
                tempo: "Kontrol gerakan (2 detik naik, 2 detik turun)",
                restSeconds: restSec,
                safetyNotes: "Gunakan step 14-20 cm. Pastikan alas kaki anti-slip dan WAJIB berpegangan pada railing atau dinding.",
                progressionTip: "Tambahkan beban 1-2 kg di kaki atau tingkatkan jumlah repetisi hingga 15."
            ),
            Workout(
                kind: .calfRaise, intensity: intensity, repsPerSet: max(reps, 10), setsPerDay: sets,
                tempo: "Lambat dan terkontrol (2 detik naik, 2 detik turun)",
                restSeconds: restSec,
                safetyNotes: "Berpegangan pada meja/dinding. Angkat tumit setinggi yang nyaman (3-5 cm cukup untuk pemula). Lakukan di permukaan rata dan tidak licin.",
                progressionTip: "Setelah nyaman, lepaskan satu tangan dari pegangan, lalu tambah beban 1-2 kg."
            ),
        ]
    }

    // MARK: - Ability-scaled per-exercise prescription

    /// Builds a Workout for a specific exercise, scaling reps/sets/rest/safety
    /// based on the user's demonstrated ability from the 30-second strength test.
    private static func scaledWorkout(
        kind: WorkoutKind,
        ability: ExerciseAbility,
        intensity: Double,
        result: AssessmentResult
    ) -> Workout {
        let grade = ability.grade(for: kind)
        let demonstratedReps: Int
        switch kind {
        case .sitToStand: demonstratedReps = ability.sitToStandReps ?? 0
        case .stepUp:     demonstratedReps = ability.stepUpReps ?? 0
        case .calfRaise:  demonstratedReps = ability.calfRaiseReps ?? 0
        }

        let reps: Int
        let sets: Int
        let restSec: Int
        let tempo: String
        let safety: String
        let progression: String

        switch grade {
        case .limited:
            // Start conservative: ~60% of demonstrated, minimum 3
            reps = max(3, Int(Double(demonstratedReps) * 0.6))
            sets = 1
            restSec = 75
            tempo = "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)"

            switch kind {
            case .sitToStand:
                safety = "Gunakan kursi kokoh (tinggi 43-45 cm) menempel dinding. Boleh gunakan sandaran tangan sebagai bantuan awal. Hentikan jika pusing atau nyeri."
                progression = "Setelah 2 minggu nyaman, kurangi bantuan tangan dan tambah 1-2 repetisi."
            case .stepUp:
                safety = "Gunakan step rendah (14-15 cm). WAJIB berpegangan pada railing atau dinding. Pastikan alas kaki anti-slip."
                progression = "Tambah 1 repetisi per kaki setiap 2 minggu. Jangan naikkan tinggi step dulu."
            case .calfRaise:
                safety = "WAJIB berpegangan dengan kedua tangan pada meja/dinding. Angkat tumit setinggi yang nyaman (3-5 cm cukup). Lakukan di permukaan rata dan tidak licin."
                progression = "Setelah nyaman, coba lepaskan satu tangan dari pegangan, lalu tambah 2 repetisi."
            }

        case .adequate:
            // Meets threshold — use risk-appropriate params
            reps = demonstratedReps
            sets = result.overallRisk == .severe ? 1 : 2
            restSec = result.overallRisk == .severe ? 60 : 45
            tempo = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"

            switch kind {
            case .sitToStand:
                safety = "Gunakan kursi kokoh (tinggi 43-45 cm) menempel dinding. Jangan menahan napas."
                progression = "Tambahkan 1 set atau beban ringan (2 kg) setelah 2-4 minggu."
            case .stepUp:
                safety = "Gunakan step 15-20 cm. Berpegangan pada railing jika diperlukan. Pastikan alas kaki anti-slip."
                progression = "Tingkatkan repetisi ke 15 sebelum menambah tinggi step."
            case .calfRaise:
                safety = "Berpegangan ringan pada dinding atau kursi. Lakukan di permukaan rata."
                progression = "Coba lepaskan pegangan, lalu tambah beban 1-2 kg."
            }

        case .unable:
            // Safety fallback — shouldn't reach here if completedAll is true.
            reps = 3; sets = 1; restSec = 90
            tempo = "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)"
            safety = "Hanya lakukan dengan pendampingan profesional."
            progression = "Konsultasikan dengan fisioterapis sebelum meningkatkan."
        }

        // Apply red-flag dampening on top.
        let finalReps = result.redFlags.isEmpty ? reps : min(reps, 8)
        let finalSets = result.redFlags.isEmpty ? sets : min(sets, 2)
        let finalRest = result.redFlags.isEmpty ? restSec : max(restSec, 60)

        return Workout(
            kind: kind, intensity: intensity,
            repsPerSet: finalReps, setsPerDay: finalSets,
            tempo: tempo, restSeconds: finalRest,
            safetyNotes: safety, progressionTip: progression
        )
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

