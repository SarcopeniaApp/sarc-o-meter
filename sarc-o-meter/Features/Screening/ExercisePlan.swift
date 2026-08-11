//  ExercisePlan.swift
//
//  Deterministic workout plan from the screening result. This is the LLM's
//  suggested baseline (passed into the prompt) AND the fallback used verbatim when
//  the LLM's JSON can't be parsed — so the tracker always has a safe, concrete plan
//  (exercise · intensity · reps/set · sets/day), whatever the model does.

import Foundation

enum ExercisePlan {

    static func derive(from result: AssessmentResult) -> [Workout] {
        // Safety first: mobility/balance-only clearance → one gentle, low-ROM move.
        if result.workoutRestriction == .mobilityOnly {
            return [Workout(kind: .calfRaise, intensity: 0.4, repsPerSet: 8, setsPerDay: 1)]
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
            Workout(kind: .calfRaise,  intensity: intensity, repsPerSet: reps, setsPerDay: sets),
            Workout(kind: .stepUp,     intensity: intensity, repsPerSet: reps, setsPerDay: sets),
            Workout(kind: .sitToStand, intensity: intensity, repsPerSet: reps, setsPerDay: sets),
        ]
    }
}
