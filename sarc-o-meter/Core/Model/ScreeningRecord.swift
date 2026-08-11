//  ScreeningRecord.swift
//
//  The persisted outcome of a completed screening. Once this exists on disk the
//  app skips straight to the exercise tracker on future launches. It carries the
//  saved analysis (LLM output) plus the derived, per-exercise workout plan the
//  tracker runs — each prescription adjusts the rep counter's intensity.

import Foundation

/// One prescribed exercise for the tracker. `mode` is an ExerciseMode raw value
/// ("Sit to Stand" | "Step Up" | "Calf Raise") — stored as a String so this Core
/// type stays decoupled from the Exercise feature.
struct ExercisePrescription: Codable, Identifiable, Sendable {
    var id: String { mode }
    let mode: String
    let intensity: Double   // 0…1, feeds RepCounter.intensity
    let targetReps: Int
}

struct ScreeningRecord: Codable, Sendable {
    var completedAt: Date
    var overallRisk: String          // RiskCategory raw value
    var workoutRestriction: String   // WorkoutRestriction raw value
    var analysis: String             // the saved LLM analysis text
    var plan: [ExercisePrescription]
}
