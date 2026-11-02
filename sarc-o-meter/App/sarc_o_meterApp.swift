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

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if exerciseLab {
                ExerciseLabView()
            } else {
                ContentView()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // App masuk ke background — hentikan Live Activity agar tidak stuck
                // di Lock Screen / home. Download tetap berjalan (URLSession
                // background), tapi Live Activity tidak bisa di-update dari
                // background, jadi lebih baik di-dismiss daripada stuck.
                ModelDownloadActivityManager.shared.endAllActivities()
            case .active:
                // App kembali ke foreground — bersihkan activity sisa yang mungkin
                // tertinggal dari sesi/crash sebelumnya.
                ModelDownloadActivityManager.shared.cleanupStaleActivities()
            default:
                break
            }
        }
    }
}
