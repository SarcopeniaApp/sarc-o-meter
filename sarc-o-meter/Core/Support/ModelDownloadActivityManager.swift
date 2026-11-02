//  ModelDownloadActivityManager.swift
//
//  Manager untuk mengontrol iOS Live Activity (ActivityKit) saat pengunduhan model AI (Qwen 3B)
//  berlangsung di latar belakang / Lock Screen / Dynamic Island.

import Foundation
import ActivityKit
import SwiftUI

@MainActor
final class ModelDownloadActivityManager {
    static let shared = ModelDownloadActivityManager()

    private var currentActivity: Activity<ModelDownloadActivityAttributes>?

    /// Bersihkan semua Live Activity yang masih tertinggal dari sesi sebelumnya.
    /// Panggil ini saat app launch atau saat app kembali ke foreground.
    func cleanupStaleActivities() {
        let activities = Activity<ModelDownloadActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        print("[LiveActivity] 🧹 Membersihkan \(activities.count) activity lama…")
        for activity in activities {
            let state = ModelDownloadActivityAttributes.ContentState(
                progress: 1.0, percent: 100, progressText: "Selesai"
            )
            Task {
                await activity.end(
                    ActivityContent(state: state, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            }
        }
        currentActivity = nil
    }

    func startActivity(modelName: String) {
        // End semua activity lama yang masih tertinggal dari sesi sebelumnya
        // dan tunggu sampai selesai agar tidak race dengan activity baru.
        let staleActivities = Activity<ModelDownloadActivityAttributes>.activities
        if !staleActivities.isEmpty {
            Task {
                for activity in staleActivities {
                    let state = ModelDownloadActivityAttributes.ContentState(
                        progress: 1.0, percent: 100, progressText: "Selesai"
                    )
                    await activity.end(
                        ActivityContent(state: state, staleDate: nil),
                        dismissalPolicy: .immediate
                    )
                }
                // Setelah cleanup selesai, mulai activity baru
                beginActivity(modelName: modelName)
            }
        } else {
            beginActivity(modelName: modelName)
        }
    }

    private func beginActivity(modelName: String) {
        let authInfo = ActivityAuthorizationInfo()

        if authInfo.areActivitiesEnabled {
            // Permission sudah diberikan → langsung mulai
            requestLiveActivity(modelName: modelName)
        } else {
            // Fresh install: permission belum diberikan.
            // Tunggu sampai user menekan "Allow" (dengan timeout 8 detik)
            print("[LiveActivity] ⏳ Menunggu izin Live Activity dari pengguna…")
            Task {
                await waitForAuthorizationAndStart(modelName: modelName, authInfo: authInfo)
            }
        }
    }

    /// Menunggu user memberikan izin Live Activity, lalu memulai activity.
    /// Timeout 8 detik agar tidak menunggu selamanya jika user menolak.
    private func waitForAuthorizationAndStart(
        modelName: String,
        authInfo: ActivityAuthorizationInfo
    ) async {
        // Buat task yang menunggu perubahan izin
        let waitTask = Task {
            for await enabled in authInfo.activityEnablementUpdates {
                if enabled {
                    return true
                }
            }
            return false
        }

        // Buat task timeout 8 detik
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            waitTask.cancel()
        }

        let granted = await waitTask.value
        timeoutTask.cancel()

        if granted {
            print("[LiveActivity] ✅ Izin diberikan oleh pengguna!")
            requestLiveActivity(modelName: modelName)
        } else {
            print("[LiveActivity] ❌ Live Activities tidak diizinkan atau timeout.")
        }
    }

    /// Request Live Activity ke sistem
    private func requestLiveActivity(modelName: String) {
        let attributes = ModelDownloadActivityAttributes(modelName: modelName)
        let initialState = ModelDownloadActivityAttributes.ContentState(
            progress: 0.0,
            percent: 0,
            progressText: "Menyiapkan unduhan model AI…"
        )

        do {
            // staleDate 30 detik ke depan — jika app mati dan tidak update,
            // iOS akan menandai activity sebagai stale.
            let content = ActivityContent(
                state: initialState,
                staleDate: Date().addingTimeInterval(30)
            )
            currentActivity = try Activity<ModelDownloadActivityAttributes>.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            print("[LiveActivity] ✅ Berhasil dimulai: \(modelName)")
            print("[LiveActivity] Activity ID: \(currentActivity?.id ?? "nil")")
            print("[LiveActivity] Jumlah activities aktif: \(Activity<ModelDownloadActivityAttributes>.activities.count)")
        } catch {
            print("[LiveActivity] ❌ Gagal memulai: \(error)")
        }
    }

    func updateProgress(percent: Int, progressValue: Double, text: String) {
        guard let currentActivity else {
            print("[LiveActivity] ⚠️ updateProgress dipanggil tapi currentActivity nil")
            return
        }

        let updatedState = ModelDownloadActivityAttributes.ContentState(
            progress: progressValue,
            percent: percent,
            progressText: text
        )

        Task {
            // Perpanjang staleDate setiap update, sehingga iOS tahu activity masih aktif
            let content = ActivityContent(
                state: updatedState,
                staleDate: Date().addingTimeInterval(30)
            )
            await currentActivity.update(content)
        }
    }

    func stopActivity() {
        guard let currentActivity else { return }
        let finalState = ModelDownloadActivityAttributes.ContentState(
            progress: 1.0,
            percent: 100,
            progressText: "Model AI Siap Digunakan!"
        )

        Task {
            let content = ActivityContent(state: finalState, staleDate: nil)
            await currentActivity.end(content, dismissalPolicy: .immediate)
            print("[LiveActivity] ✅ Berhasil dihentikan")
        }
        self.currentActivity = nil
    }

    /// Hentikan semua Live Activity yang sedang aktif.
    /// Gunakan saat app masuk ke background/terminated saat download berlangsung.
    func endAllActivities() {
        let activities = Activity<ModelDownloadActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        print("[LiveActivity] 🛑 App going background — ending \(activities.count) activities")
        for activity in activities {
            let state = ModelDownloadActivityAttributes.ContentState(
                progress: activity.content.state.progress,
                percent: activity.content.state.percent,
                progressText: "Unduhan dijeda — buka app untuk melanjutkan"
            )
            Task {
                await activity.end(
                    ActivityContent(state: state, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            }
        }
        currentActivity = nil
    }
}
