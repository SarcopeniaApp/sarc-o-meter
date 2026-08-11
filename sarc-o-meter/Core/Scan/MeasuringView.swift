//  MeasuringView.swift
//
//  The in-between spinner shown while segmentation + the Core ML model run.

import SwiftUI

struct MeasuringView: View {
    var body: some View {
        VStack(spacing: 22) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
            Text("Menganalisis pindaian Anda…")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }
}
