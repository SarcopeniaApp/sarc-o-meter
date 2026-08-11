//  ScanIntroView.swift
//
//  The page shown right before capture. It tells the user to wear something
//  skin-tight (so the silhouette is clean), shows a front + side pose reference,
//  then offers two ways forward: run the camera scan, or type measurements in by
//  hand (which reuses the same keypad screen as height/weight).
//
//  The figures are SF Symbol stand-ins (front = standing, side = walking profile),
//  gender-aware. Swap in a real illustration asset when you have one.

import SwiftUI

struct ScanIntroView: View {
    let user: User
    var onBack: (() -> Void)? = nil
    let onBeginScan: () -> Void
    let onManual: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(onBack: onBack)

            ScreenTitle(
                title: "Pindai Tubuh",
                subtitle: "Kenakan pakaian ketat (atau pakaian dalam yang pas) agar siluet tubuh terlihat jelas, dan berdirilah di depan dinding polos dengan pencahayaan baik. Foto Anda tetap di perangkat — kami tidak akan membagikan privasi Anda ;)"
            )
            .padding(.top, 20)

            illustration
                .padding(.horizontal, 20)
                .padding(.top, 28)

            Spacer()

            VStack(spacing: 12) {
                PrimaryButton(title: "Mulai memindai", action: onBeginScan)
                SecondaryButton(title: "Masukkan ukuran manual", action: onManual)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var illustration: some View {
        HStack(spacing: 16) {
            figureCard(symbol: frontSymbol, label: "Depan")
            figureCard(symbol: "figure.walk", label: "Samping")
        }
    }

    private var frontSymbol: String {
        user.gender == .female ? "figure.stand.dress" : "figure.stand"
    }

    private func figureCard(symbol: String, label: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 78))
                .foregroundStyle(Theme.accent)
                .frame(height: 132)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .shadow(color: Theme.cardShadow, radius: 8, y: 4)
    }
}
