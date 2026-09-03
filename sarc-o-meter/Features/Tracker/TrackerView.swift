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

    @State private var active: Workout?                       // exercise being run
    @State private var doneReps: [WorkoutKind: Int] = [:]     // exercise → reps logged today

    var body: some View {
        PageWrapper(
            title: "Latihan Anda",
            content: {
                VStack(spacing: 24) {
                    Subtitle("Disesuaikan dari hasil skrining Anda. Lakukan dengan nyaman, kualitas gerakan lebih penting daripada jumlah.")
                    if !record.analysis.isEmpty { analysisCard }
                    if let schedule = record.weeklySchedule, !schedule.isEmpty {
                        weeklyScheduleCard(schedule)
                    }
                    ForEach(record.plan) { presc in
                        prescriptionCard(presc)
                    }
                }
            },
            footer: {
                SecondaryButton(title: "Ulangi skrining", action: onRestartScreening)
            }
        )
        .fullScreenCover(item: $active) { item in
            ExerciseView(
                fixedMode: ExerciseMode(rawValue: item.kind.rawValue) ?? .sitToStand,
                intensity: item.intensity,
                headline: "\(displayName(item.kind)) · intensitas \(Int(item.intensity * 100))%"
            ) { reps in
                if let reps { doneReps[item.kind, default: 0] += reps }
                active = nil
            }
        }
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

    private func weeklyScheduleCard(_ schedule: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Jadwal Mingguan", systemImage: "calendar")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
            Text(schedule)
                .font(.system(size: 14)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .shadow(color: Theme.cardShadow, radius: 8, y: 4)
    }

    // MARK: Prescription card
    private func prescriptionCard(_ item: Workout) -> some View {
        let dailyTarget = item.repsPerSet * item.setsPerDay
        let done = doneReps[item.kind] ?? 0
        let reached = done >= dailyTarget
        return VStack(alignment: .leading, spacing: 12) {
            // Title row with progress
            HStack(spacing: 12) {
                Image(systemName: reached ? "checkmark.circle.fill" : icon(item.kind))
                    .font(.system(size: 24))
                    .foregroundStyle(reached ? .green : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(item.kind))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("\(item.repsPerSet) rep × \(item.setsPerDay)/hari · intensitas \(Int(item.intensity * 100))%")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text("\(done)/\(dailyTarget)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(reached ? .green : Theme.accent)
            }

            // Detail: Sets × Reps × Rest
            HStack(spacing: 16) {
                iconStat(icon: "arrow.triangle.2.circlepath", value: "\(item.setsPerDay) set")
                iconStat(icon: "repeat", value: "\(item.repsPerSet) reps")
                if let rest = item.restSeconds {
                    iconStat(icon: "timer", value: "\(rest)s rest")
                }
            }

            // Tempo
            if let tempo = item.tempo, !tempo.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("Tempo:")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(tempo)
                        .font(.system(size: 13)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Safety notes
            if let safety = item.safetyNotes, !safety.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                    Text(safety)
                        .font(.system(size: 12)).foregroundStyle(Color(red: 0.6, green: 0.4, blue: 0.0))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }

            // Progression tip
            if let tip = item.progressionTip, !tip.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                    Text(tip)
                        .font(.system(size: 12)).foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            Button { active = item } label: {
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

    private func iconStat(icon: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
        }
    }

    // MARK: Display helpers (WorkoutKind → Indonesian)

    private func displayName(_ kind: WorkoutKind) -> String {
        switch kind {
        case .sitToStand: return "Sit to Stand"
        case .stepUp:     return "Step Up"
        case .calfRaise:  return "Calf Raises"
        }
    }

    private func icon(_ kind: WorkoutKind) -> String {
        switch kind {
        case .sitToStand: return "figure.seated.side"
        case .stepUp:     return "figure.stairs"
        case .calfRaise:  return "figure.walk"
        }
    }
}

