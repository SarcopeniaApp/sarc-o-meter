//  BodyShape.swift
//
//  Classifies a body shape from measurements, following BODY_SHAPE_RULE.md.
//  The rules are gender-specific and can overlap, so they're evaluated in a
//  priority order (most-specific signal first) with a Rectangle fallback.
//
//  Measurement mapping (model output name -> rule term):
//    waist      -> "waist"
//    hips       -> "hip"
//    chest      -> "chest"
//    shoulders  -> "shoulder-breadth"
//    upper_torso (female) = max(shoulders, chest)   [per the note in the rules]

import Foundation

enum BodyShape {

    static func classify(gender: Gender?, measurements m: BodyMeasurements) -> String {
        guard let chest = m["chest"], let waist = m["waist"], let hips = m["hip"],
              chest > 0, waist > 0, hips > 0 else { return "—" }
        let shoulders = m["shoulder-breadth"] ?? 0

        switch gender {
        case .female:
            let upper = max(shoulders, chest)          // upper_torso
            // Oval (Apple): waist is the widest of the three.
            if waist >= upper && waist >= hips { return "Oval" }
            // Hourglass: well-defined narrow waist against balanced top/bottom.
            if waist / upper <= 0.75 && waist / hips <= 0.75 { return "Jam pasir" }
            // Triangle (Pear): hips dominate the upper torso.
            if hips / upper >= 1.05 { return "Segitiga" }
            // Inverted Triangle: upper torso dominates the hips.
            if upper / hips >= 1.05 { return "Segitiga terbalik" }
            // Rectangle: straight torso, top ≈ bottom, no defined waist.
            return "Persegi panjang"

        case .male:
            // Oval: midsection is the single widest part.
            if waist > chest && waist > hips { return "Oval" }
            // Triangle: bottom-heavy — waist and hips both out-measure the chest.
            if waist >= chest && hips >= chest { return "Segitiga" }
            // Inverted Triangle: dramatic V — chest drastically wider than waist.
            if chest / waist >= 1.15 { return "Segitiga terbalik" }
            // Trapezoid: athletic — chest slightly wider than waist.
            if chest / waist >= 1.05 { return "Trapesium" }
            // Rectangle: chest and waist nearly identical.
            return "Persegi panjang"

        case .none:
            return "—"
        }
    }
}
