//  ExerciseLabView.swift
//
//  Dev harness for iterating on the rep counter WITHOUT the screening flow. Boots
//  straight here when the app is launched with `--exercise-lab` (the "ExerciseLab"
//  scheme passes it). Tune each exercise's intensity with a slider, then Run it —
//  the intensities persist across relaunches so you can dial them in.
//
//  100% = a rep needs the full range of motion; lower values count a rep with less
//  ROM (RepCounter.intensity). Once you settle on good values, bake the mapping
//  into ExercisePlan.derive(...).

import SwiftUI

struct ExerciseLabView: View {
    @State private var active: ExerciseMode?

    @AppStorage("lab.intensity.sitToStand") private var sitToStand = 1.0
    @AppStorage("lab.intensity.stepUp")     private var stepUp = 1.0
    @AppStorage("lab.intensity.calfRaise")  private var calfRaise = 1.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Setel intensitas tiap latihan, lalu jalankan. 100% = rentang gerak penuh; nilai lebih rendah menghitung rep dengan ROM lebih sedikit.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(ExerciseMode.allCases) { mode in
                    Section(mode.rawValue) {
                        HStack {
                            Slider(value: binding(for: mode), in: 0...1, step: 0.05)
                            Text("\(Int(value(for: mode) * 100))%")
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                        Button {
                            active = mode
                        } label: {
                            Label("Run", systemImage: "play.fill")
                        }
                    }
                }
            }
            .navigationTitle("Exercise Lab")
        }
        .fullScreenCover(item: $active) { mode in
            ExerciseView(
                fixedMode: mode,
                intensity: value(for: mode),
                headline: "\(mode.rawValue) · \(Int(value(for: mode) * 100))%",
                showInstructions: false      // Lab: skip the how-to, go straight to the counter
            ) { _ in active = nil }
        }
    }

    private func value(for mode: ExerciseMode) -> Double {
        switch mode {
        case .sitToStand: return sitToStand
        case .stepUp:     return stepUp
        case .calfRaise:  return calfRaise
        }
    }

    private func binding(for mode: ExerciseMode) -> Binding<Double> {
        switch mode {
        case .sitToStand: return $sitToStand
        case .stepUp:     return $stepUp
        case .calfRaise:  return $calfRaise
        }
    }
}
