//  ExercisePlan.swift
//
//  Deterministic workout plan from the screening result. This is the LLM's
//  suggested baseline (passed into the prompt) AND the fallback used verbatim when
//  the LLM's JSON can't be parsed — so the tracker always has a safe, concrete plan
//  (exercise · intensity · reps/set · sets/day), whatever the model does.

import Foundation

enum ExercisePlan {

    // ExerciseMode raw values, as strings (independent of the Exercise feature).
    private static let calfRaise = "Calf Raise"
    private static let stepUp = "Step Up"
    private static let sitToStand = "Sit to Stand"

    static func derive(from result: AssessmentResult) -> [WorkoutItem] {
        // Safety first: mobility/balance-only clearance → one gentle, low-ROM move.
        if result.workoutRestriction == .mobilityOnly {
            return [WorkoutItem(exercise: calfRaise, intensity: 0.4, repsPerSet: 8, setsPerDay: 1)]
        }

        // Scale ROM (intensity), reps, and daily dose to the risk category.
        var intensity: Double
        var reps: Int
        var sets: Int
        switch result.overallRisk {
        case .low:        intensity = 1.0;  reps = 12; sets = 3
        case .mid:        intensity = 0.75; reps = 10; sets = 2
        case .high:       intensity = 0.6;  reps = 8;  sets = 2
        case .severe:     intensity = 0.5;  reps = 6;  sets = 1
        case .unassessed: intensity = 0.6;  reps = 8;  sets = 2
        }

        // Any safety flag (recurrent falls, joint pain, a neurological condition,
        // or "couldn't do the exercise test") → prescribe more gently.
        if !result.redFlags.isEmpty {
            intensity = min(intensity, 0.6)
            reps = min(reps, 8)
            sets = min(sets, 2)
        }

        return [
            WorkoutItem(exercise: calfRaise,  intensity: intensity, repsPerSet: reps, setsPerDay: sets),
            WorkoutItem(exercise: stepUp,     intensity: intensity, repsPerSet: reps, setsPerDay: sets),
            WorkoutItem(exercise: sitToStand, intensity: intensity, repsPerSet: reps, setsPerDay: sets),
        ]
    }
}
