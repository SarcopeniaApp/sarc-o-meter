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
struct WorkoutItem: Codable, Identifiable, Sendable {
    var id: String { exercise }
    let exercise: String
    let intensity: Double   // 0…1, feeds RepCounter.intensity
    let repsPerSet: Int
    let setsPerDay: Int      // "how many times a day"
}

struct ScreeningRecord: Codable, Sendable {
    var completedAt: Date
    var overallRisk: String          // RiskCategory raw value
    var workoutRestriction: String   // WorkoutRestriction raw value
    var analysis: String             // the saved LLM analysis text
    var plan: [WorkoutItem]
}
