//  AssessmentData.swift
//
//  The full sarcopenia-screening input, assembled across the flow: personal info
//  (gender/height/weight/age), clinical red-flag history, body measurements (waist
//  + calf come straight from the BMNet scan), and physical performance tests.
//
//  This is one half of the backend "API contract": it is Codable and its field
//  names/shape mirror `AssessmentData` in backend/models/schemas.py exactly, so
//  it POSTs to /assessments/analyze with no transformation. Keep the two in sync.

import Foundation

struct AssessmentData: Codable {
    var personalData: PersonalData
    var clinicalHistory: ClinicalHistory
    var bodyMeasurement: BodyMeasurement
    var physicalTest: PhysicalTest

    init() {
        personalData = PersonalData()
        clinicalHistory = ClinicalHistory()
        bodyMeasurement = BodyMeasurement()
        physicalTest = PhysicalTest()
    }
}

struct PersonalData: Codable {
    var age: Int?
    var gender: Gender = .male
    var heightCm: Double?
    var weightKg: Double?
}

struct ClinicalHistory: Codable {
    var hasRecentSurgeryOrHospitalization = false   // < 3 months
    var hasUnstableCardio = false
    var hasRecentFalls = false                      // < 12 months
    var hasAcuteJointPainOrFracture = false
    var hasNeurologicalCondition = false
    var otherConditions = ""
}

struct BodyMeasurement: Codable {
    var waistCircumferenceCm: Double?
    var calfCircumferenceCm: Double?
    var armCircumferenceCm: Double?
}

enum MobilityStatus: String, Codable, CaseIterable {
    case normal = "Normal"
    case limited = "Limited Mobility / Fall Risk"
    case unable = "Frail / Unable to Walk"
}

struct PhysicalTest: Codable {
    var mobilityStatus: MobilityStatus = .normal

    // Normal mobility: measured directly.
    var chairStandTestSeconds: Double?
    var gaitSpeedMetersPerSecond: Double?

    // Limited mobility: TUG used as the alternative performance test.
    var timedUpAndGoSeconds: Double?
}
