//
//  User.swift
//  sarc-o-meter
//
//  Created by Kemal Dwi Heldy Muhammad on 11/08/26.
//

import SwiftUI

@Observable
class User {
    enum UserGender { case male, female }
    
    // Information + Measurement
    var gender: UserGender? = nil
    var age: Int? = nil
    var height: Double? = nil // cm
    var weight: Double? = nil // kg
    var calf: Double? = nil // cm
    var chest: Double? = nil // cm
    var waist: Double? = nil // cm
    
    // Clinical History
    var hasRecentSurgeryOrHospitalization = false   // < 3 months
    var hasUnstableCardio = false
    var hasRecentFalls = false                      // < 12 months
    var hasAcuteJointPainOrFracture = false
    var hasNeurologicalCondition = false
    var otherConditions = ""

    // Physical Test
    var sitToStandReps: Int?
    var stepUpReps: Int?
    var calfRaiseReps: Int?

    // Screening outcome — analysis + concrete, adjustable workout plan (nil until
    // the screening is completed). This is the single source of truth the tracker,
    // reminders, and progress tracking read from.
    var screening: ScreeningRecord? = nil
}
