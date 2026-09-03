//  AssessmentResult.swift
//
//  The deterministic output of the on-device AWGS rule engine (see RuleEngine).
//  The second half of the backend "API contract" — mirrors `AssessmentResult` in
//  backend/models/schemas.py. The backend never recomputes this; it only stores
//  it and uses the flags to drive knowledge retrieval + the LLM prompt.

import Foundation

enum StatusCategory: String, Codable {
    case normal = "Normal"
    case limited = "Limited"             // can perform but below threshold
    case abnormal = "Abnormal / Low"
    case notAssessed = "Not Assessed"
}

enum RiskCategory: String, Codable {
    case low = "Low Risk"
    case mid = "Mid Risk (Possible Sarcopenia)"
    case high = "High Risk (Probable/Confirmed Sarcopenia)"
    case severe = "Severe Risk (Sarcopenia + Low Performance)"
    case unassessed = "Unassessed (Incomplete Data)"
}

enum WorkoutRestriction: String, Codable {
    case none = "None (Standard Workout)"
    case mobilityOnly = "Mobility & Balance Only (Requires Professional Clearance)"
}

/// Per-exercise grade derived from the 30-second strength test rep count.
enum ExerciseGrade: String, Codable {
    case unable   = "Unable"      // skipped / couldn't do it
    case limited  = "Limited"     // completed but below threshold
    case adequate = "Adequate"    // met or exceeded threshold
}

/// Per-exercise ability captured from the strength test. Lets downstream
/// systems (ExercisePlan, OnDeviceRAG) personalise per exercise instead
/// of relying on the single binary strengthStatus flag.
struct ExerciseAbility: Codable {
    /// nil = skipped ("couldn't do it"); 0+ = completed with this many reps in 30s
    let sitToStandReps: Int?
    let stepUpReps: Int?
    let calfRaiseReps: Int?

    /// true when the user completed all 3 exercises (regardless of rep count)
    var completedAll: Bool {
        sitToStandReps != nil && stepUpReps != nil && calfRaiseReps != nil
    }

    /// Per-exercise grade: .unable / .limited / .adequate
    func grade(for kind: WorkoutKind) -> ExerciseGrade {
        let reps: Int?
        let minAdequate: Int
        switch kind {
        case .sitToStand: reps = sitToStandReps; minAdequate = 5
        case .stepUp:     reps = stepUpReps;     minAdequate = 4
        case .calfRaise:  reps = calfRaiseReps;  minAdequate = 8
        }
        guard let r = reps else { return .unable }
        return r >= minAdequate ? .adequate : .limited
    }
}

struct AssessmentResult: Codable {
    var muscleMassStatus: StatusCategory = .notAssessed
    var strengthStatus: StatusCategory = .notAssessed
    var performanceStatus: StatusCategory = .notAssessed

    var obesityFlags: [String] = []
    var redFlags: [String] = []

    var overallRisk: RiskCategory = .unassessed
    var workoutRestriction: WorkoutRestriction = .none

    /// Per-exercise ability from the strength test; nil until the test runs.
    var exerciseAbility: ExerciseAbility?
}
