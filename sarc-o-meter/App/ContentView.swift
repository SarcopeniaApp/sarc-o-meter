//  ContentView.swift
//
//  The app shell + launch router. It owns the one shared `User` (loaded from
//  UserStore) and every screen reads/writes it directly.
//   • If screening is already done (`user.screening` is set) → straight to the
//     Tracker.
//   • Otherwise run the screening: gender → age → height → weight → body scan
//     (auto or manual) → result → questionnaire → exercise test → analysis, then
//     save `user` and drop into the Tracker.
//
//  It owns only the CORE journey (personal info + the scan) and hands off to the
//  feature entry views: ScreeningFlowView and TrackerView.

import SwiftUI
import UIKit

struct ContentView: View {

    private enum Step {
        case gender, age, height, weight, instructions, manual, measuring, result, screening
    }

    // The single source of truth. Loaded once; a saved user whose screening is
    // filled in means "returning user → show the tracker".
    @State private var user: User = UserStore.load() ?? User()

    @State private var step: Step = .gender
    @State private var errorText: String?
    @State private var showCapture = false

    // Manual-entry sub-flow state (a transient input buffer; committed into `user`).
    @State private var manualIndex = 0
    @State private var manualEntry = 0
    @State private var manualValues: [String: Double] = [:]

    private struct ManualField { let key: String; let name: String; let subtitle: String }
    private static let manualFields: [ManualField] = [
        ManualField(key: "chest", name: "Dada",     subtitle: "Ukur bagian terlebar dada Anda, dalam sentimeter."),
        ManualField(key: "waist", name: "Pinggang", subtitle: "Ukur lingkar pinggang alami Anda, dalam sentimeter."),
        ManualField(key: "hip",   name: "Pinggul",  subtitle: "Ukur bagian terlebar pinggul Anda, dalam sentimeter."),
        ManualField(key: "calf",  name: "Betis",    subtitle: "Ukur bagian tertebal betis Anda, dalam sentimeter."),
    ]

    @AppStorage("debugServer") private var debugServer = ""
    @State private var predictor: BMNetPredictor? = try? BMNetPredictor()
    @State private var llm = LLMManager()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let record = user.screening {
                // ── Returning user: straight to the tracker ──
                TrackerView(record: record, onRestartScreening: { restartScreening() })
            } else {
                content
            }
        }
        .fullScreenCover(isPresented: $showCapture) {
            PoseCaptureView { front, side in
                showCapture = false
                step = .measuring
                runMeasurement(front: front, side: side)
            }
        }
        .alert("Terjadi kesalahan",
               isPresented: Binding(get: { errorText != nil },
                                    set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil; step = .weight }
        } message: {
            Text(errorText ?? "")
        }
        // Preload the on-device model during screening so it's ready by the
        // analysis step. Skipped for returning (tracker) users who don't need it.
        .task { if user.screening == nil { await llm.loadModel() } }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .gender:
            GenderScreen(user: user, debugServer: $debugServer) {
                step = .age
            }

        case .age:
            NumericPadScreen(
                title: "Tentang Anda",
                subtitle: "Berapa usia Anda? Usia membantu kami menyesuaikan skrining.",
                unit: "tahun", value: ageBinding,
                onBack: { step = .gender }
            ) { step = .height }

        case .height:
            NumericPadScreen(
                subtitle: "Berapa tinggi badan Anda?",
                unit: "cm", value: heightBinding,
                onBack: { step = .age }
            ) { step = .weight }

        case .weight:
            NumericPadScreen(
                subtitle: "Bagus — sekarang, berapa berat badan Anda?",
                unit: "kg", value: weightBinding,
                onBack: { step = .height }
            ) { step = .instructions }

        case .instructions:
            ScanIntroView(
                user: user,
                onBack: { step = .weight },
                onBeginScan: { startCapture() },
                onManual: { beginManual() }
            )

        case .manual:
            manualScreen

        case .measuring:
            MeasuringView()

        case .result:
            ResultScreen(
                user: user,
                onRescan: { step = .instructions },
                onFinish: { step = .screening }
            )

        case .screening:
            // ── Screening feature: questionnaire → exercise test → analysis ──
            ScreeningFlowView(
                user: user,
                llm: llm,
                onExit: { step = .result },
                onFinished: { UserStore.save(user) }   // user.screening is set → tracker
            )
        }
    }

    // MARK: Keypad ↔ User bindings (age is years; height/weight are whole cm/kg)

    private var ageBinding: Binding<Int> {
        Binding(get: { user.age ?? 0 }, set: { user.age = $0 > 0 ? $0 : nil })
    }
    private var heightBinding: Binding<Int> {
        Binding(get: { user.height.map { Int($0) } ?? 0 },
                set: { user.height = $0 > 0 ? Double($0) : nil })
    }
    private var weightBinding: Binding<Int> {
        Binding(get: { user.weight.map { Int($0) } ?? 0 },
                set: { user.weight = $0 > 0 ? Double($0) : nil })
    }

    // MARK: Manual entry

    @ViewBuilder
    private var manualScreen: some View {
        let field = Self.manualFields[manualIndex]
        NumericPadScreen(
            title: field.name,
            subtitle: field.subtitle,
            unit: "cm",
            value: $manualEntry,
            onBack: { manualBack() }
        ) { manualNext() }
    }

    private func beginManual() {
        manualIndex = 0
        manualEntry = 0
        manualValues = [:]
        step = .manual
    }

    private func manualNext() {
        let field = Self.manualFields[manualIndex]
        if manualEntry > 0 { manualValues[field.key] = Double(manualEntry) }
        if manualIndex + 1 < Self.manualFields.count {
            manualIndex += 1
            manualEntry = Int(manualValues[Self.manualFields[manualIndex].key] ?? 0)
        } else {
            finishManual()
        }
    }

    private func manualBack() {
        if manualIndex == 0 {
            step = .instructions
        } else {
            manualIndex -= 1
            manualEntry = Int(manualValues[Self.manualFields[manualIndex].key] ?? 0)
        }
    }

    private func finishManual() {
        user.chest = manualValues["chest"]
        user.waist = manualValues["waist"]
        user.hip   = manualValues["hip"]
        user.calf  = manualValues["calf"]
        // height/weight are already on `user` from the keypad steps.
        step = .result
    }

    // MARK: Flow control

    private func startCapture() {
        guard predictor != nil else {
            errorText = "Tidak dapat memuat model pengukuran (bmnet.mlpackage). Tambahkan ke target aplikasi."
            return
        }
        showCapture = true
    }

    private func restartScreening() {
        UserStore.clear()
        user = User()               // fresh source of truth
        manualIndex = 0
        manualEntry = 0
        manualValues = [:]
        step = .gender
    }

    // MARK: Core pipeline (segmentation + Core ML)

    private func runMeasurement(front frontUI: UIImage, side sideUI: UIImage) {
        guard let predictor,
              let front = frontUI.normalizedUp().cgImage,
              let side = sideUI.normalizedUp().cgImage,
              let h = user.height, let w = user.weight, h > 0, w > 0 else {
            errorText = "Data kurang — silakan masukkan kembali tinggi dan berat badan Anda."
            step = .weight
            return
        }

        let dbg = DebugLog.shared
        dbg.serverBase = debugServer.isEmpty ? nil : debugServer
        dbg.startRun()
        dbg.text("input", "height=\(h)cm weight=\(w)kg gender=\(user.gender?.rawValue ?? "?")")
        dbg.image("00_front", frontUI)
        dbg.image("00_side", sideUI)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let start = Date()
                let frontMask = try predictor.personMask(from: front)
                let sideMask = try predictor.personMask(from: side)
                dbg.image("01_seg_front", frontMask)
                dbg.image("01_seg_side", sideMask)
                if let sil = predictor.silhouetteImage(frontMask: frontMask, sideMask: sideMask) {
                    dbg.image("03_silhouette", sil)
                }

                let (result, warns) = try predictor.predict(
                    frontMask: frontMask, sideMask: sideMask, heightCm: h, weightKg: w)
                let elapsed = Date().timeIntervalSince(start)

                let ordered = BMNetPredictor.measurementNames.map {
                    "\($0)=\(String(format: "%.1f", result[$0] ?? 0))"
                }
                dbg.text("04_measurements", ordered.joined(separator: ", "))
                dbg.text("timing", String(format: "%.2fs total", elapsed))
                for wmsg in warns { dbg.text("warning", wmsg) }

                DispatchQueue.main.async {
                    // Fold the measurements the app uses into the shared user.
                    user.calf = result["calf"]
                    user.chest = result["chest"]
                    user.waist = result["waist"]
                    user.hip = result["hip"]
                    user.shoulderBreadth = result["shoulder-breadth"]
                    step = .result
                }
            } catch {
                dbg.text("error", String(describing: error))
                DispatchQueue.main.async {
                    errorText = "Pengukuran gagal: \(error.localizedDescription)"
                    step = .weight
                }
            }
        }
    }
}
