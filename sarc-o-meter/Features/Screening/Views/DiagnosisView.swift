//  DiagnosisView.swift
//
//  The screening payoff: the deterministic AWGS rule result (risk, per-indicator
//  status, flags) plus the on-device LLM's plain-language analysis. "Mulai
//  latihan" saves the screening and moves the user into the tracker.

import SwiftUI

struct DiagnosisView: View {
    let result: AssessmentResult
    let analysis: String?      // on-device LLM output; nil while generating
    let isGenerating: Bool
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(title: "Hasil Skrining")

            ScrollView {
                VStack(spacing: 16) {
                    riskCard
                    statusCard
                    if !result.redFlags.isEmpty {
                        flagCard("Tanda keselamatan", result.redFlags, icon: "exclamationmark.triangle.fill", tint: .red)
                    }
                    if !result.obesityFlags.isEmpty {
                        flagCard("Tanda lain", result.obesityFlags, icon: "flag.fill", tint: Theme.accent)
                    }
                    if result.workoutRestriction == .mobilityOnly { restrictionCard }
                    analysisSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
            }

            PrimaryButton(title: "Mulai latihan", enabled: !isGenerating, action: onFinish)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    // MARK: Rule-engine summary

    private var riskCard: some View {
        HStack(spacing: 14) {
            Circle().fill(riskColor).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("Estimasi risiko")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                Text(riskLabel)
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(riskColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    private var statusCard: some View {
        VStack(spacing: 0) {
            statusRow("Massa otot", result.muscleMassStatus)
            Divider().padding(.leading, 18)
            statusRow("Kekuatan", result.strengthStatus)
            Divider().padding(.leading, 18)
            statusRow("Performa berjalan", result.performanceStatus)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .shadow(color: Theme.cardShadow, radius: 8, y: 4)
    }

    private func statusRow(_ name: String, _ status: StatusCategory) -> some View {
        HStack {
            Text(name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
            Spacer()
            Text(statusLabel(status))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor(status))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(statusColor(status).opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
    }

    private func flagCard(_ title: String, _ items: [String], icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold)).foregroundStyle(tint)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(tint)
                    Text(item).font(.system(size: 13)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    private var restrictionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.red)
            Text("Demi keselamatan Anda, latihan dibatasi pada gerakan ringan & keseimbangan — minta izin profesional sebelum latihan yang lebih berat.")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.corner))
    }

    // MARK: On-device analysis

    @ViewBuilder
    private var analysisSection: some View {
        if isGenerating {
            VStack(spacing: 14) {
                ProgressView().tint(Theme.accent)
                Text("Menyusun analisis di perangkat…")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 28)
        } else if let analysis, !analysis.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Analisis & saran", systemImage: "text.bubble.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                Text(analysis)
                    .font(.system(size: 14)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
            .shadow(color: Theme.cardShadow, radius: 8, y: 4)

            disclaimer
        }
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(Theme.muted)
            Text("Ini alat skrining, bukan diagnosis medis. Untuk evaluasi lengkap, konsultasikan ke dokter atau fisioterapis.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.faint.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Labels & colors (Indonesian display; raw values stay English)

    private var riskLabel: String {
        switch result.overallRisk {
        case .low:        return "Risiko Rendah"
        case .mid:        return "Risiko Menengah (Kemungkinan Sarkopenia)"
        case .high:       return "Risiko Tinggi (Sarkopenia Terkonfirmasi)"
        case .severe:     return "Risiko Berat (Sarkopenia + Performa Rendah)"
        case .unassessed: return "Belum Dinilai (Data Kurang)"
        }
    }

    private func statusLabel(_ s: StatusCategory) -> String {
        switch s {
        case .normal:      return "Normal"
        case .abnormal:    return "Rendah"
        case .notAssessed: return "Tidak dinilai"
        }
    }

    private var riskColor: Color {
        switch result.overallRisk {
        case .low:        return .green
        case .mid:        return .orange
        case .high:       return Color(red: 0.85, green: 0.42, blue: 0.20)
        case .severe:     return .red
        case .unassessed: return Theme.muted
        }
    }

    private func statusColor(_ s: StatusCategory) -> Color {
        switch s {
        case .normal:      return .green
        case .abnormal:    return .red
        case .notAssessed: return Theme.muted
        }
    }
}
