//  Gender.swift
//
//  The user's selected gender. Drives BMNet tailoring, the gender-specific
//  body-shape rules (see BodyShape), and the AWGS sarcopenia rule engine.
//
//  Raw values are "Male"/"Female" to match the backend API contract
//  (models/schemas.py `Gender = Literal["Male", "Female"]`), so AssessmentData
//  encodes to JSON the FastAPI backend accepts with zero transformation.

enum Gender: String, Codable, Sendable, CaseIterable {
    case male = "Male"
    case female = "Female"
}
