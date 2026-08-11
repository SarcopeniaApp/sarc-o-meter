//  BodyMeasurements.swift
//
//  The 14 body measurements the BMNet model predicts, in centimeters, plus the
//  canonical output order. Produced by the scan pipeline or filled in by manual
//  entry — either way, this is the measurement "state" the result screen reads.

/// The 14 measurements the model predicts, in centimeters.
struct BodyMeasurements {

    /// Fixed output order of the model. Do not reorder.
    static let names = [
        "ankle", "arm-length", "bicep", "calf", "chest", "forearm", "height",
        "hip", "leg-length", "shoulder-breadth", "shoulder-to-crotch", "thigh",
        "waist", "wrist",
    ]

    /// name -> value in cm
    let values: [String: Double]

    subscript(_ name: String) -> Double? { values[name] }

    var calf: Double? { values["calf"] }
    var chest: Double? { values["chest"] }
    var waist: Double? { values["waist"] }
}
