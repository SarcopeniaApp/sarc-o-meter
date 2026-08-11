//  ExercisePlan.swift
//
//  Turns the screening result into a concrete, adjustable workout plan for the
//  tracker. This is the deterministic "adjusted based on the analysis" step: the
//  overall risk sets each exercise's intensity (how full the range of motion must
//  be to count a rep) and target reps; a mobility restriction forces the gentlest
//  plan. The LLM's prose analysis is shown alongside, but the numeric adjustment
//  comes from here so it's reliable and reproducible.

import Foundation

enum ExercisePlan {

    // ExerciseMode raw values (kept as strings so this stays independent of the
    // Exercise feature). Must match RepCounter's ExerciseMode.
    private static let calfRaise = "Calf Raise"
    private static let stepUp = "Step Up"
    private static let sitToStand = "Sit to Stand"

    static func derive(from result: AssessmentResult) -> [ExercisePrescription] {
        // Safety first: mobility/balance-only clearance → one gentle, low-ROM move.
        if result.workoutRestriction == .mobilityOnly {
            return [ExercisePrescription(mode: calfRaise, intensity: 0.4, targetReps: 8)]
        }

        // Otherwise scale ROM + reps to the risk category.
        var intensity: Double
        var reps: Int
        switch result.overallRisk {
        case .low:        intensity = 1.0;  reps = 12
        case .mid:        intensity = 0.75; reps = 10
        case .high:       intensity = 0.6;  reps = 8
        case .severe:     intensity = 0.5;  reps = 6
        case .unassessed: intensity = 0.6;  reps = 8
        }

        // Any safety flag (recurrent falls, joint pain, a neurological condition,
        // or "couldn't do the exercise test") → prescribe more gently, even when
        // the risk category alone wouldn't require it.
        if !result.redFlags.isEmpty {
            intensity = min(intensity, 0.6)
            reps = min(reps, 8)
        }

        return [
            ExercisePrescription(mode: calfRaise,  intensity: intensity, targetReps: reps),
            ExercisePrescription(mode: stepUp,     intensity: intensity, targetReps: reps),
            ExercisePrescription(mode: sitToStand, intensity: intensity, targetReps: reps),
        ]
    }
}
