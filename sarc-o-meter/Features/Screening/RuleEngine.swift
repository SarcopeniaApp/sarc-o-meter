//  RuleEngine.swift
//
//  The deterministic sarcopenia screen, implementing the AWGS 2019 criteria. It
//  is the single source of truth for risk classification — it runs entirely
//  on-device and the backend never recomputes it, so the clinical logic lives in
//  exactly one place and can't silently drift between Swift and Python.
//
//  Inputs come from across the flow; notably the two body measurements it needs
//  (calf → muscle mass, waist → central obesity) come from the BMNet scan.

import Foundation

enum RuleEngine {

    static func evaluate(data: AssessmentData) -> AssessmentResult {
        var result = AssessmentResult()

        // 1. Red flags & contraindications.
        if data.clinicalHistory.hasRecentSurgeryOrHospitalization {
            result.redFlags.append("Operasi besar atau rawat inap baru-baru ini (< 3 bulan).")
        }
        if data.clinicalHistory.hasUnstableCardio {
            result.redFlags.append("Kondisi kardiovaskular tidak stabil.")
        }
        if data.clinicalHistory.hasRecentFalls {
            result.redFlags.append("Riwayat sering terjatuh.")
        }
        if data.clinicalHistory.hasAcuteJointPainOrFracture {
            result.redFlags.append("Nyeri sendi akut atau patah tulang belum sembuh.")
        }
        if data.clinicalHistory.hasNeurologicalCondition {
            result.redFlags.append("Kondisi neurologis yang memengaruhi keseimbangan.")
        }

        // Safety restriction: surgery/hospitalization or unstable cardio limits
        // the plan to supervised mobility & balance work only.
        if data.clinicalHistory.hasRecentSurgeryOrHospitalization || data.clinicalHistory.hasUnstableCardio {
            result.workoutRestriction = .mobilityOnly
        }

        // 2. Muscle mass (calf circumference) & central obesity (waist).
        if let calf = data.bodyMeasurement.calfCircumferenceCm {
            let isLowMass = (data.personalData.gender == .male && calf < 34.0) ||
                            (data.personalData.gender == .female && calf < 33.0)
            result.muscleMassStatus = isLowMass ? .abnormal : .normal
        }

        if let waist = data.bodyMeasurement.waistCircumferenceCm {
            let isObese = (data.personalData.gender == .male && waist >= 90.0) ||
                          (data.personalData.gender == .female && waist >= 80.0)
            if isObese {
                result.obesityFlags.append("Tanda Obesitas Sentral (Lingkar Pinggang)")
            }

            if let height = data.personalData.heightCm, height > 0 {
                let whtr = waist / height
                if whtr > 0.5 && !result.obesityFlags.contains(where: { $0.contains("Obesitas Sentral") }) {
                    result.obesityFlags.append("Tanda Obesitas Sentral (WHtR > 0,5)")
                }
            }
        }

        // 3. Strength & performance, scored from the three exercises' reps.
        //    IMPORTANT: these rep thresholds (counts in a ~10 s session) are
        //    heuristics, NOT AWGS-validated cutoffs like the old chair-stand/gait
        //    tests — tune them on real users (the ExerciseLab helps).
        let pt = data.physicalTest
        let sitToStandMin = 5   // fewer than this → weak legs
        let stepUpMin = 4       // functional mobility
        let calfRaiseMin = 8    // calf strength/endurance

        // Strength: lower-limb power. Sit-to-stand is primary; a low (present)
        // calf-raise reinforces it. A *skipped* sit-to-stand ("couldn't do it")
        // is itself a strong weakness signal.
        if let sit = pt.sitToStandReps {
            var low = sit < sitToStandMin
            if let calf = pt.calfRaiseReps, calf < calfRaiseMin { low = true }
            result.strengthStatus = low ? .abnormal : .normal
        } else {
            result.strengthStatus = .abnormal
        }

        // Performance: functional mobility from the step-up.
        if let step = pt.stepUpReps {
            result.performanceStatus = step < stepUpMin ? .abnormal : .normal
        } else {
            result.performanceStatus = .abnormal
        }

        // Any skipped exercise → flag for direct professional evaluation.
        if pt.sitToStandReps == nil || pt.stepUpReps == nil || pt.calfRaiseReps == nil {
            result.redFlags.append("Tidak dapat menyelesaikan sebagian tes latihan — perlu evaluasi langsung oleh fisioterapis/dokter.")
        }

        // 4. Combine into an overall risk category.
        let isLowMass = result.muscleMassStatus == .abnormal
        let isLowStrength = result.strengthStatus == .abnormal
        let isLowPerformance = result.performanceStatus == .abnormal

        let allNormal = result.muscleMassStatus == .normal &&
            (result.strengthStatus == .normal || result.strengthStatus == .notAssessed) &&
            (result.performanceStatus == .normal || result.performanceStatus == .notAssessed)

        if result.muscleMassStatus == .notAssessed {
            result.overallRisk = .unassessed
        } else if isLowMass && isLowStrength && isLowPerformance {
            result.overallRisk = .severe
        } else if isLowMass && (isLowStrength || isLowPerformance) {
            result.overallRisk = .high
        } else if isLowMass || isLowStrength || isLowPerformance {
            result.overallRisk = .mid
        } else if allNormal {
            result.overallRisk = .low
        } else {
            result.overallRisk = .unassessed
        }

        return result
    }
}
