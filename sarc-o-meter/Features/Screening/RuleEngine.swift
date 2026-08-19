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

    static func evaluate(_ user: User) -> AssessmentResult {
        var result = AssessmentResult()

        // 1. Red flags & contraindications.
        if user.hasRecentSurgeryOrHospitalization {
            result.redFlags.append("Operasi besar atau rawat inap baru-baru ini (< 3 bulan).")
        }
        if user.hasHeartCondition {
            result.redFlags.append("Gangguan jantung (sering berdebar-debar atau riwayat diagnosis jantung).")
        }
        if user.hasUncontrolledBP {
            result.redFlags.append("Tekanan darah tinggi tidak terkontrol.")
        }
        if user.hasBalanceOrDizziness {
            result.redFlags.append("Sering kehilangan keseimbangan atau merasa pusing.")
        }
        if user.hasAcuteJointPainOrFracture {
            result.redFlags.append("Nyeri sendi akut atau patah tulang belum sembuh.")
        }
        if user.hasNeurologicalCondition {
            result.redFlags.append("Kondisi neurologis yang memengaruhi keseimbangan.")
        }
        if user.hasRoutineMedication {
            result.redFlags.append("Mengonsumsi obat-obatan rutin (perlu pertimbangan interaksi obat & latihan).")
        }
        if user.hasWalkingAid {
            result.redFlags.append("Menggunakan alat bantu jalan — latihan harus disesuaikan.")
        }

        // Safety restriction: only conditions that DIRECTLY impair the ability
        // to safely perform lower-limb resistance exercises trigger the hard
        // mobility-only restriction.  Other flags (recent hospitalization,
        // routine medication, balance/dizziness) remain red-flag warnings that
        // reduce intensity via ExercisePlan's redFlags logic, but still allow
        // all three exercises — because e.g. recovering from typhus doesn't
        // prevent someone from doing Sit to Stand or Step Up.
        let hasHardRestriction = user.hasHeartCondition ||
                                 user.hasUncontrolledBP ||
                                 user.hasNeurologicalCondition ||
                                 user.hasWalkingAid ||
                                 user.hasAcuteJointPainOrFracture

        if hasHardRestriction {
            result.workoutRestriction = .mobilityOnly
        }

        // 2. Muscle mass (calf circumference) & central obesity (waist).
        if let calf = user.calf {
            let isLowMass = (user.gender == .male && calf < 34.0) ||
                            (user.gender == .female && calf < 33.0)
            result.muscleMassStatus = isLowMass ? .abnormal : .normal
        }

        if let waist = user.waist {
            let isObese = (user.gender == .male && waist >= 90.0) ||
                          (user.gender == .female && waist >= 80.0)
            if isObese {
                result.obesityFlags.append("Tanda Obesitas Sentral (Lingkar Pinggang)")
            }

            if let height = user.height, height > 0 {
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
        let sitToStandMin = 5   // fewer than this → weak legs
        let stepUpMin = 4       // functional mobility
        let calfRaiseMin = 8    // calf strength/endurance

        // Strength: lower-limb power. Sit-to-stand is primary; a low (present)
        // calf-raise reinforces it. A *skipped* sit-to-stand ("couldn't do it")
        // is itself a strong weakness signal.
        if let sit = user.sitToStandReps {
            var low = sit < sitToStandMin
            if let calf = user.calfRaiseReps, calf < calfRaiseMin { low = true }
            result.strengthStatus = low ? .abnormal : .normal
        } else {
            result.strengthStatus = .abnormal
        }

        // Performance: walking performance taken out.
        result.performanceStatus = .notAssessed

        // Any skipped exercise → flag for direct professional evaluation.
        if user.sitToStandReps == nil || user.stepUpReps == nil || user.calfRaiseReps == nil {
            result.redFlags.append("Tidak dapat menyelesaikan sebagian tes latihan — perlu evaluasi langsung oleh fisioterapis/dokter.")
        }

        // 4. Combine into an overall risk category.
        let isLowMass = result.muscleMassStatus == .abnormal
        let isLowStrength = result.strengthStatus == .abnormal

        let allNormal = result.muscleMassStatus == .normal &&
            (result.strengthStatus == .normal || result.strengthStatus == .notAssessed)

        if result.muscleMassStatus == .notAssessed {
            result.overallRisk = .unassessed
        } else if isLowMass && isLowStrength {
            result.overallRisk = .severe
        } else if isLowMass || isLowStrength {
            result.overallRisk = .high
        } else if allNormal {
            result.overallRisk = .low
        } else {
            result.overallRisk = .unassessed
        }

        return result
    }
}
