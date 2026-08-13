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
        PageWrapper(
            title: "Cek Kesehatan",
            content: {
                Subtitle("Beberapa pertanyaan keselamatan. Ini menandai kondisi yang sebaiknya diperiksa profesional sebelum berolahraga.")
                
                VStack(spacing: 12) {
                    toggleRow("Operasi atau rawat inap baru-baru ini", "Dalam 3 bulan terakhir",
                              $user.hasRecentSurgeryOrHospitalization)
                    toggleRow("Gangguan jantung", "Apakah sering berdebar-debar, atau pernah didiagnosa gangguan jantung oleh tenaga medis?",
                              $user.hasHeartCondition)
                    toggleRow("Tekanan darah tinggi tidak terkontrol", "Tekanan darah yang tidak terkelola dengan baik dapat memengaruhi keselamatan latihan",
                              $user.hasUncontrolledBP)
                    toggleRow("Sering kehilangan keseimbangan atau pusing", "Apakah akhir-akhir ini sering merasa tidak stabil saat berdiri atau berjalan?",
                              $user.hasBalanceOrDizziness)
                    toggleRow("Nyeri sendi akut atau patah tulang belum sembuh", nil,
                              $user.hasAcuteJointPainOrFracture)
                    toggleRow("Kondisi yang memengaruhi keseimbangan", "mis. stroke, Parkinson",
                              $user.hasNeurologicalCondition)
                    toggleRow("Rutin mengonsumsi obat-obatan", "mis. obat diabetes, pengencer darah, obat jantung",
                              $user.hasRoutineMedication)
                    toggleRow("Menggunakan alat bantu jalan", "mis. tongkat, walker, kursi roda",
                              $user.hasWalkingAid)
                }
                .padding(.bottom, 24)
            },
            footer: {
                PrimaryButton(title: "Lanjut", action: onNext)
            },
            onBack: onBack
        )
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
