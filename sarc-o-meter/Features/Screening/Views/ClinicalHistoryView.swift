//  ClinicalHistoryView.swift
//
//  Step of the sarcopenia screen: a short safety checklist. Any "yes" becomes a
//  red flag in the rule engine and can restrict the workout plan to supervised
//  mobility/balance work — so these gate everything downstream.

import SwiftUI

struct ClinicalHistoryView: View {
    @Bindable var user: User
    var onBack: (() -> Void)? = nil
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(onBack: onBack)

            ScreenTitle(
                title: "Cek Kesehatan",
                subtitle: "Beberapa pertanyaan keselamatan. Ini menandai kondisi yang sebaiknya diperiksa profesional sebelum berolahraga."
            )
            .padding(.top, 20)

            ScrollView {
                VStack(spacing: 12) {
                    toggleRow("Operasi atau rawat inap baru-baru ini", "Dalam 3 bulan terakhir",
                              $user.hasRecentSurgeryOrHospitalization)
                    toggleRow("Kondisi jantung tidak stabil", "mis. nyeri dada, tekanan darah tidak terkontrol",
                              $user.hasUnstableCardio)
                    toggleRow("Sering terjatuh", "Dalam 12 bulan terakhir",
                              $user.hasRecentFalls)
                    toggleRow("Nyeri sendi akut atau patah tulang belum sembuh", nil,
                              $user.hasAcuteJointPainOrFracture)
                    toggleRow("Kondisi yang memengaruhi keseimbangan", "mis. stroke, Parkinson",
                              $user.hasNeurologicalCondition)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 8)
            }

            PrimaryButton(title: "Lanjut", action: onNext)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private func toggleRow(_ title: String, _ subtitle: String?, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .shadow(color: Theme.cardShadow, radius: 8, y: 4)
    }
}
