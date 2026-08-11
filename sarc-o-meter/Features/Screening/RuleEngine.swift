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

        // 3. Strength & performance (AWGS 2019).
        switch data.physicalTest.mobilityStatus {
        case .unable:
            result.strengthStatus = .notAssessed
            result.performanceStatus = .notAssessed
            result.redFlags.append("Tidak dapat dinilai lewat tes mandiri (Renta). Perlu evaluasi langsung oleh fisioterapis/dokter.")

        case .limited:
            // TUG used as the alternative performance test.
            if let tug = data.physicalTest.timedUpAndGoSeconds {
                if tug > 12.0 {
                    result.performanceStatus = .abnormal
                    result.redFlags.append("Risiko jatuh tinggi berdasarkan tes TUG > 12 dtk.")
                } else {
                    result.performanceStatus = .normal
                }
            }

        case .normal:
            if let chairStand = data.physicalTest.chairStandTestSeconds {
                result.strengthStatus = chairStand >= 12.0 ? .abnormal : .normal
            }
            if let gaitSpeed = data.physicalTest.gaitSpeedMetersPerSecond {
                result.performanceStatus = gaitSpeed < 1.0 ? .abnormal : .normal
            }
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
