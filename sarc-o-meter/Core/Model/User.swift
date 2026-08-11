//  User.swift
//
//  The single source of truth for the whole app. One `User` is created at launch,
//  shared into every screen (each reads/writes it directly), and persisted by
//  UserStore — so a returning user, whose `screening` is already filled in, lands
//  straight in the tracker.
//
//  It holds everything about the person: their info + body measurements, the
//  safety checklist, the exercise-test reps, and — once screening completes — the
//  saved analysis + concrete workout plan (`screening`). There is deliberately no
//  parallel "assessment data" struct: this is it.

import Foundation
import Observation

/// The user's biological sex. Drives BMNet tailoring, the gender-specific
/// body-shape rules (BodyShape), and the AWGS calf/waist thresholds. Raw values
/// are the English labels the rule engine and analysis prompt read.
enum UserGender: String, Codable, Sendable, CaseIterable {
    case male = "Male"
    case female = "Female"
}

@Observable
final class User: Codable {

    // MARK: Information + measurements (cm / kg / years)
    var gender: UserGender?
    var age: Int?
    var height: Double?
    var weight: Double?
    var calf: Double?
    var chest: Double?
    var waist: Double?
    var hip: Double?
    var shoulderBreadth: Double?

    // MARK: Clinical history — a "yes" to any becomes a rule-engine red flag.
    var hasRecentSurgeryOrHospitalization = false   // < 3 months
    var hasUnstableCardio = false
    var hasRecentFalls = false                      // < 12 months
    var hasAcuteJointPainOrFracture = false
    var hasNeurologicalCondition = false
    var otherConditions = ""

    // MARK: Exercise test — reps per exercise; nil = skipped ("couldn't do it").
    var sitToStandReps: Int?
    var stepUpReps: Int?
    var calfRaiseReps: Int?

    // MARK: Screening outcome — saved analysis + workout plan; nil until done.
    var screening: ScreeningRecord?

    init() {}

    // MARK: Codable
    // Hand-written because the @Observable macro turns these into computed
    // properties, which defeats Codable *synthesis*. Everything is decoded
    // leniently (decodeIfPresent) so older saved blobs keep loading.
    enum CodingKeys: String, CodingKey {
        case gender, age, height, weight, calf, chest, waist, hip, shoulderBreadth
        case hasRecentSurgeryOrHospitalization, hasUnstableCardio, hasRecentFalls
        case hasAcuteJointPainOrFracture, hasNeurologicalCondition, otherConditions
        case sitToStandReps, stepUpReps, calfRaiseReps
        case screening
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gender = try c.decodeIfPresent(UserGender.self, forKey: .gender)
        age = try c.decodeIfPresent(Int.self, forKey: .age)
        height = try c.decodeIfPresent(Double.self, forKey: .height)
        weight = try c.decodeIfPresent(Double.self, forKey: .weight)
        calf = try c.decodeIfPresent(Double.self, forKey: .calf)
        chest = try c.decodeIfPresent(Double.self, forKey: .chest)
        waist = try c.decodeIfPresent(Double.self, forKey: .waist)
        hip = try c.decodeIfPresent(Double.self, forKey: .hip)
        shoulderBreadth = try c.decodeIfPresent(Double.self, forKey: .shoulderBreadth)
        hasRecentSurgeryOrHospitalization = try c.decodeIfPresent(Bool.self, forKey: .hasRecentSurgeryOrHospitalization) ?? false
        hasUnstableCardio = try c.decodeIfPresent(Bool.self, forKey: .hasUnstableCardio) ?? false
        hasRecentFalls = try c.decodeIfPresent(Bool.self, forKey: .hasRecentFalls) ?? false
        hasAcuteJointPainOrFracture = try c.decodeIfPresent(Bool.self, forKey: .hasAcuteJointPainOrFracture) ?? false
        hasNeurologicalCondition = try c.decodeIfPresent(Bool.self, forKey: .hasNeurologicalCondition) ?? false
        otherConditions = try c.decodeIfPresent(String.self, forKey: .otherConditions) ?? ""
        sitToStandReps = try c.decodeIfPresent(Int.self, forKey: .sitToStandReps)
        stepUpReps = try c.decodeIfPresent(Int.self, forKey: .stepUpReps)
        calfRaiseReps = try c.decodeIfPresent(Int.self, forKey: .calfRaiseReps)
        screening = try c.decodeIfPresent(ScreeningRecord.self, forKey: .screening)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(gender, forKey: .gender)
        try c.encodeIfPresent(age, forKey: .age)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(weight, forKey: .weight)
        try c.encodeIfPresent(calf, forKey: .calf)
        try c.encodeIfPresent(chest, forKey: .chest)
        try c.encodeIfPresent(waist, forKey: .waist)
        try c.encodeIfPresent(hip, forKey: .hip)
        try c.encodeIfPresent(shoulderBreadth, forKey: .shoulderBreadth)
        try c.encode(hasRecentSurgeryOrHospitalization, forKey: .hasRecentSurgeryOrHospitalization)
        try c.encode(hasUnstableCardio, forKey: .hasUnstableCardio)
        try c.encode(hasRecentFalls, forKey: .hasRecentFalls)
        try c.encode(hasAcuteJointPainOrFracture, forKey: .hasAcuteJointPainOrFracture)
        try c.encode(hasNeurologicalCondition, forKey: .hasNeurologicalCondition)
        try c.encode(otherConditions, forKey: .otherConditions)
        try c.encodeIfPresent(sitToStandReps, forKey: .sitToStandReps)
        try c.encodeIfPresent(stepUpReps, forKey: .stepUpReps)
        try c.encodeIfPresent(calfRaiseReps, forKey: .calfRaiseReps)
        try c.encodeIfPresent(screening, forKey: .screening)
    }
}
