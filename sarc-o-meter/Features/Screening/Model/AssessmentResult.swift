//  AssessmentResult.swift
//
//  The deterministic output of the on-device AWGS rule engine (see RuleEngine).
//  The second half of the backend "API contract" — mirrors `AssessmentResult` in
//  backend/models/schemas.py. The backend never recomputes this; it only stores
//  it and uses the flags to drive knowledge retrieval + the LLM prompt.

import Foundation

enum StatusCategory: String, Codable {
    case normal = "Normal"
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

struct AssessmentResult: Codable {
    var muscleMassStatus: StatusCategory = .notAssessed
    var strengthStatus: StatusCategory = .notAssessed
    var performanceStatus: StatusCategory = .notAssessed

    var obesityFlags: [String] = []
    var redFlags: [String] = []

    var overallRisk: RiskCategory = .unassessed
    var workoutRestriction: WorkoutRestriction = .none
}
