//  ScreeningRecord.swift
//
//  The persisted outcome of a completed screening — the single "result" object
//  (it's what User.screening holds). It carries the saved analysis plus a concrete,
//  structured workout plan the LLM produced (or the deterministic fallback): which
//  exercises, at what intensity, and the daily dose — enough to drive the tracker,
//  reminders, and progress tracking.

import Foundation

/// One prescribed exercise. `exercise` is an ExerciseMode raw value
/// ("Sit to Stand" | "Step Up" | "Calf Raise") — a String so this Core type stays
/// independent of the Exercise feature.
///
/// v2: now carries per-exercise detail fields (tempo, rest, safety notes,
/// progression tip) to match the detailed SarcopeniaApp prescription format.
struct Workout: Codable, Identifiable, Sendable {
    var id: WorkoutKind { kind }
    let kind: WorkoutKind
    let intensity: Double       // 0…1, feeds RepCounter.intensity
    let repsPerSet: Int
    let setsPerDay: Int          // "how many times a day"
    let tempo: String?           // e.g. "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
    let restSeconds: Int?        // seconds of rest between sets
    let safetyNotes: String?     // per-exercise safety note from the LLM
    let progressionTip: String?  // how to progressively increase

    init(kind: WorkoutKind, intensity: Double, repsPerSet: Int, setsPerDay: Int,
         tempo: String? = nil, restSeconds: Int? = nil,
         safetyNotes: String? = nil, progressionTip: String? = nil) {
        self.kind = kind
        self.intensity = intensity
        self.repsPerSet = repsPerSet
        self.setsPerDay = setsPerDay
        self.tempo = tempo
        self.restSeconds = restSeconds
        self.safetyNotes = safetyNotes
        self.progressionTip = progressionTip
    }
}

enum WorkoutKind: String, Codable {
    case sitToStand = "Sit to Stand"
    case stepUp = "Step Up"
    case calfRaise = "Calf Raise"
}

struct ScreeningRecord: Codable, Sendable {
    var completedAt: Date
    var overallRisk: String          // RiskCategory raw value
    var workoutRestriction: String   // WorkoutRestriction raw value
    var analysis: String             // the saved LLM analysis text
    var plan: [Workout]
    var weeklySchedule: String?      // e.g. "3x per minggu (Senin, Rabu, Jumat)"
}
