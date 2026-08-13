//  GenderScreen.swift
//
//  First step of the scan flow: pick a gender. It nudges the measurement model
//  the right way. Tapping a row advances straight to the next step — no separate
//  confirm button. A small, muted "developer" field for the Mac debug server
//  address lives at the bottom so it stays out of the way but is there on-device.

import SwiftUI

struct GreetingScreen: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 0) {

        }
        .padding(.horizontal, 24)
        PageWrapper(
            title: "Selamat datang!",
            content: {
                VStack(alignment: .leading, spacing: 24) {
                    Subtitle("Untuk membantu kami mendapatkan hasil screening paling akurat, kami membutuhkan beberapa informasi tentang Anda.")
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Privasi Anda terjaga", systemImage: "checkmark")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(.green)
                        HStack(alignment: .top, spacing: 8) {
                            Text("Tenang, semua informasi ini hanya akan berada di perangkat anda, dan tidak akan dikirim ke pihak lain.").font(.system(size: 13)).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.corner))
                }
            },
            footer: {
                PrimaryButton(title: "Mulai", action: onNext)
            }
        )
    }
}
