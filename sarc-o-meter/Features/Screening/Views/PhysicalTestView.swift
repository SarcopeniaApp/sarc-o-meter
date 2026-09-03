//  PhysicalTestView.swift
//
//  Step of the sarcopenia screen: mobility level + the timed tests AWGS uses for
//  strength and walking performance. Which fields show depends on mobility:
//  normal → chair-stand + gait speed; limited → Timed Up & Go; unable → flagged.

import SwiftUI

struct PhysicalTestView: View {
    @Binding var test: PhysicalTest
    var onBack: (() -> Void)? = nil
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(onBack: onBack)

            ScreenTitle(
                title: "Tes Gerak",
                subtitle: "Seberapa bebas Anda bergerak? Tambahkan waktu tes bila ada — ini menilai kekuatan kaki."
            )
            .padding(.top, 20)

            ScrollView {
                VStack(spacing: 16) {
                    mobilityPicker
                    conditionalFields
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 8)
            }

            PrimaryButton(title: "Lihat hasil saya", action: onNext)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var mobilityPicker: some View {
        VStack(spacing: 10) {
            ForEach(MobilityStatus.allCases, id: \.self) { m in
                Button { test.mobilityStatus = m } label: {
                    HStack(spacing: 12) {
                        Image(systemName: test.mobilityStatus == m ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(test.mobilityStatus == m ? Theme.accent : Theme.faint)
                        Text(label(m))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(test.mobilityStatus == m ? Theme.ink : Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner)
                            .stroke(test.mobilityStatus == m ? Theme.accent : .clear, lineWidth: 2)
                    )
                    .shadow(color: Theme.cardShadow, radius: 8, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var conditionalFields: some View {
        switch test.mobilityStatus {
        case .normal:
            DecimalField(title: "Tes berdiri dari kursi", subtitle: "Detik untuk berdiri dari kursi 5 kali",
                         unit: "dtk", value: $test.chairStandTestSeconds)
        case .limited:
            DecimalField(title: "Timed Up & Go", subtitle: "Detik untuk berdiri, jalan 3 m, berputar, dan duduk",
                         unit: "dtk", value: $test.timedUpAndGoSeconds)
        case .unable:
            infoCard("Tidak perlu tes mandiri — ini akan kami tandai untuk evaluasi langsung oleh fisioterapis atau dokter.")
        }
    }

    private func label(_ m: MobilityStatus) -> String {
        switch m {
        case .normal:  return "Saya bisa berjalan dan berdiri bebas"
        case .limited: return "Terbatas — saya butuh pegangan atau takut jatuh"
        case .unable:  return "Saya tidak bisa berjalan tanpa bantuan"
        }
    }

    private func infoCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.corner))
    }
}

/// A labelled decimal input that reads/writes an optional Double, styled to match
/// the rest of the flow.
private struct DecimalField: View {
    let title: String
    let subtitle: String?
    let unit: String
    @Binding var value: Double?
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                TextField("0", text: $text)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .onChange(of: text) { _, newValue in
                        value = Double(newValue.replacingOccurrences(of: ",", with: "."))
                    }
                Text(unit)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .shadow(color: Theme.cardShadow, radius: 8, y: 4)
        .onAppear {
            if let value, text.isEmpty {
                text = value == value.rounded() ? String(Int(value)) : String(value)
            }
        }
    }
}
