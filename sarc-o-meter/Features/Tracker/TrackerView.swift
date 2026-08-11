//  TrackerView.swift
//
//  ══════════════════════ TRACKER — the returning-user home ═════════════════════
//  Shown immediately on launch once screening is done (the shell routes here when
//  a ScreeningRecord exists). It presents the saved analysis and the prescribed
//  workout; each exercise runs the SAME MediaPipe rep counter as the screening
//  test, but with the prescription's `intensity` — a 50%-intensity move counts a
//  rep with less range of motion.
//  ═════════════════════════════════════════════════════════════════════════════

import SwiftUI

struct TrackerView: View {
    let record: ScreeningRecord
    var onRestartScreening: () -> Void

    @State private var active: ExercisePrescription?          // exercise being run
    @State private var doneReps: [String: Int] = [:]          // mode → reps logged today

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: "Latihan Anda")

            ScrollView {
                VStack(spacing: 16) {
                    header
                    if !record.analysis.isEmpty { analysisCard }
                    ForEach(record.plan) { presc in
                        prescriptionCard(presc)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }

            SecondaryButton(title: "Ulangi skrining", action: onRestartScreening)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .fullScreenCover(item: $active) { presc in
            ExerciseView(
                fixedMode: ExerciseMode(rawValue: presc.mode) ?? .sitToStand,
                intensity: presc.intensity,
                headline: "\(displayName(presc.mode)) · intensitas \(Int(presc.intensity * 100))%"
            ) { reps in
                if let reps { doneReps[presc.mode, default: 0] += reps }
                active = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rencana latihan Anda")
                .font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Disesuaikan dari hasil skrining Anda. Lakukan dengan nyaman — kualitas gerakan lebih penting daripada jumlah.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Analisis", systemImage: "text.bubble.fill")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
            Text(record.analysis)
                .font(.system(size: 14)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .shadow(color: Theme.cardShadow, radius: 8, y: 4)
    }

    // MARK: Prescription card

    private func prescriptionCard(_ presc: ExercisePrescription) -> some View {
        let done = doneReps[presc.mode] ?? 0
        let reached = done >= presc.targetReps
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: reached ? "checkmark.circle.fill" : icon(presc.mode))
                    .font(.system(size: 24))
                    .foregroundStyle(reached ? .green : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(presc.mode))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("Target \(presc.targetReps) rep · intensitas \(Int(presc.intensity * 100))%")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text("\(done)/\(presc.targetReps)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(reached ? .green : Theme.accent)
            }

            Button { active = presc } label: {
                Text(done > 0 ? "Lanjutkan" : "Mulai")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .shadow(color: Theme.cardShadow, radius: 8, y: 4)
    }

    // MARK: Display helpers (ExerciseMode raw value → Indonesian)

    private func displayName(_ mode: String) -> String {
        switch mode {
        case "Sit to Stand": return "Berdiri dari kursi"
        case "Step Up":      return "Naik step"
        case "Calf Raise":   return "Jinjit (angkat tumit)"
        default:             return mode
        }
    }

    private func icon(_ mode: String) -> String {
        switch mode {
        case "Sit to Stand": return "figure.seated.side"
        case "Step Up":      return "figure.stairs"
        case "Calf Raise":   return "figure.walk"
        default:             return "figure.strengthtraining.functional"
        }
    }
}
