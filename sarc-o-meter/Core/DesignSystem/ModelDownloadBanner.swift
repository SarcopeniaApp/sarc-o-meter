//  ModelDownloadBanner.swift
//
//  In-app floating banner yang menampilkan progress download model AI.
//  Muncul di dalam app saat model sedang diunduh, melengkapi Live Activity
//  yang hanya terlihat di luar app (Lock Screen / Dynamic Island).

import SwiftUI

struct ModelDownloadBanner: View {
    let progress: Double
    let progressText: String

    private var percent: Int { Int(progress * 100) }

    var body: some View {
        HStack(spacing: 14) {
            // Icon sparkles dengan animasi berputar
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Mengunduh Model AI")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\(percent)%")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accent)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3), value: percent)
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.faint.opacity(0.5))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.accent, Theme.accent.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * CGFloat(progress), height: 6)
                            .animation(.easeInOut(duration: 0.3), value: progress)
                    }
                }
                .frame(height: 6)

                Text(progressText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
        )
    }
}
