//
//  sarc_o_meterApp.swift
//  sarc-o-meter
//
//  Created by Kemal Dwi Heldy Muhammad on 06/08/26.
//

import SwiftUI

@main
struct sarc_o_meterApp: App {
    // Launched with `--exercise-lab` (the "ExerciseLab" scheme) → boot straight
    // into the rep-counter dev harness, skipping the whole screening flow.
    private var exerciseLab: Bool {
        ProcessInfo.processInfo.arguments.contains("--exercise-lab")
    }

    var body: some Scene {
        WindowGroup {
            if exerciseLab {
                ExerciseLabView()
            } else {
                ContentView()
            }
        }
    }
}
