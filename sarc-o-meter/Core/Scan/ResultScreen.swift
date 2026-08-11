//  ResultScreen.swift
//
//  The scan payoff: a white card with a body glyph, a derived body-type label,
//  and the headline measurements (calf highlighted — it's what this app cares
//  about), plus Rescan / Finish. It reads whatever the model produced via the
//  BodyMeasurements subscript, so missing values degrade to a dash rather than 0.

import SwiftUI

struct ResultScreen: View {
    let measurements: BodyMeasurements
    let gender: Gender?
    let onRescan: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavHeader()

            ScreenTitle(
                title: "Hasil Pindai Tubuh",
                subtitle: "Berhasil! Ini hasil pindaian Anda. Jika ada yang kurang tepat, silakan pindai ulang kapan saja."
            )
            .padding(.top, 20)

            card
                .padding(.horizontal, 20)
                .padding(.top, 24)

            Spacer()

            HStack(spacing: 14) {
                SecondaryButton(title: "Pindai ulang", action: onRescan)
                PrimaryButton(title: "Lanjut", action: onFinish)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    // MARK: Result card

    private var card: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: "figure.stand")
                    .font(.system(size: 60))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 96, height: 134)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16))
                VStack(spacing: 2) {
                    Text("Tipe tubuh")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    Text(bodyType)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                measRow("Tinggi",   measurements["height"])
                measRow("Dada",     measurements["chest"])
                measRow("Pinggang", measurements["waist"])
                measRow("Pinggul",  measurements["hip"])
                measRow("Betis",    measurements["calf"], highlight: true)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .shadow(color: Theme.cardShadow, radius: 14, y: 8)
    }

    private func measRow(_ name: String, _ value: Double?, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if highlight {
                    Text("utama")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.accentSoft, in: Capsule())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map { String(format: "%.0f", $0) } ?? "–")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("cm")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    // Gender-specific classification per BODY_SHAPE_RULE.md.
    private var bodyType: String {
        BodyShape.classify(gender: gender, measurements: measurements)
    }
}
