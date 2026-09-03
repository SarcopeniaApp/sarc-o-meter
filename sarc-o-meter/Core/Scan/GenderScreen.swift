//  GenderScreen.swift
//
//  First step of the scan flow: pick a gender. It nudges the measurement model
//  the right way. Tapping a row advances straight to the next step — no separate
//  confirm button. A small, muted "developer" field for the Mac debug server
//  address lives at the bottom so it stays out of the way but is there on-device.

import SwiftUI

struct GenderScreen: View {
    let user: User
    @Binding var debugServer: String
    var onBack: (() -> Void)? = nil
    let onNext: () -> Void

    var body: some View {
        PageWrapper(
            title: "Jenis Kelamin",
            content: {
                VStack(alignment: .leading, spacing: 24) {
                    Subtitle("Apa jenis kelamin Anda saat lahir?")

                    VStack(spacing: 14) {
                        genderRow(.female, glyph: "\u{2640}", label: "Saya terlahir perempuan") // ♀
                        genderRow(.male,   glyph: "\u{2642}", label: "Saya terlahir laki-laki") // ♂
                    }
                    serverField(icon: "ladybug", placeholder: "Server debug (opsional) — http://<ip-mac>:8000", text: $debugServer)
                }
            },
            onBack: onBack
        )
    }

    private func serverField(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .frame(width: 16)
            TextField(placeholder, text: text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .keyboardType(.URL)
        }
    }

    // Tapping selects AND advances — the whole row is the control. The gender
    // glyphs are the Unicode ♀/♂ characters (SF Symbols has no `mars`/`venus`),
    // so they render reliably on any device.
    private func genderRow(_ g: UserGender, glyph: String, label: String) -> some View {
        Button {
            user.gender = g
            onNext()
        } label: {
            HStack(spacing: 16) {
                Text(glyph)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40)
                Text(label)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.vertical, 26)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
            .shadow(color: Theme.cardShadow, radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}
