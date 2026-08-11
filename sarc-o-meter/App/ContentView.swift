//  ContentView.swift
//
//  The app shell + launch router.
//   • If a screening has already been completed (ScreeningStore has a record) →
//     go straight to the Tracker.
//   • Otherwise run the screening: gender → age → height → weight → body scan
//     (auto or manual) → result → questionnaire → exercise test → analysis, then
//     save the record and drop into the Tracker.
//
//  It owns only the CORE journey (personal info + the scan) and hands off to the
//  feature entry views: ScreeningFlowView and TrackerView.

import SwiftUI
import UIKit

struct ContentView: View {

    private enum Step {
        case gender, age, height, weight, instructions, manual, measuring, result, screening
    }

    // Loaded once on first creation. Non-nil ⇒ screening done ⇒ show the tracker.
    @State private var record: ScreeningRecord? = ScreeningStore.load()

    @State private var step: Step = .gender
    @State private var gender: Gender?
    @State private var ageYears = 0
    @State private var heightCm = 0
    @State private var weightKg = 0
    @State private var measurements: BodyMeasurements?
    @State private var errorText: String?
    @State private var showCapture = false

    // Manual-entry sub-flow state.
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
            if let record {
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
        .task { if record == nil { await llm.loadModel() } }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .gender:
            GenderScreen(selection: $gender, debugServer: $debugServer) {
                step = .age
            }

        case .age:
            NumericPadScreen(
                title: "Tentang Anda",
                subtitle: "Berapa usia Anda? Usia membantu kami menyesuaikan skrining.",
                unit: "tahun", value: $ageYears,
                onBack: { step = .gender }
            ) { step = .height }

        case .height:
            NumericPadScreen(
                subtitle: "Berapa tinggi badan Anda?",
                unit: "cm", value: $heightCm,
                onBack: { step = .age }
            ) { step = .weight }

        case .weight:
            NumericPadScreen(
                subtitle: "Bagus — sekarang, berapa berat badan Anda?",
                unit: "kg", value: $weightKg,
                onBack: { step = .height }
            ) { step = .instructions }

        case .instructions:
            ScanIntroView(
                gender: gender,
                onBack: { step = .weight },
                onBeginScan: { startCapture() },
                onManual: { beginManual() }
            )

        case .manual:
            manualScreen

        case .measuring:
            MeasuringView()

        case .result:
            if let measurements {
                ResultScreen(
                    measurements: measurements,
                    gender: gender,
                    onRescan: { step = .instructions },
                    onFinish: { step = .screening }
                )
            }

        case .screening:
            // ── Screening feature: questionnaire → exercise test → analysis ──
            ScreeningFlowView(
                input: screeningInput,
                llm: llm,
                onExit: { step = .result },
                onFinished: { rec in
                    ScreeningStore.save(rec)
                    record = rec            // flips the shell over to the tracker
                }
            )
        }
    }

    /// The Core → Screening hand-off, in Core types only.
    private var screeningInput: ScreeningInput {
        ScreeningInput(
            gender: gender ?? .male,
            ageYears: ageYears > 0 ? ageYears : nil,
            heightCm: heightCm > 0 ? Double(heightCm) : nil,
            weightKg: weightKg > 0 ? Double(weightKg) : nil,
            measurements: measurements
        )
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
        var vals = manualValues
        vals["height"] = Double(heightCm)
        measurements = BodyMeasurements(values: vals)
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
        ScreeningStore.clear()
        record = nil
        gender = nil
        ageYears = 0
        heightCm = 0
        weightKg = 0
        measurements = nil
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
              heightCm > 0, weightKg > 0 else {
            errorText = "Data kurang — silakan masukkan kembali tinggi dan berat badan Anda."
            step = .weight
            return
        }
        let h = Double(heightCm)
        let w = Double(weightKg)

        let dbg = DebugLog.shared
        dbg.serverBase = debugServer.isEmpty ? nil : debugServer
        dbg.startRun()
        dbg.text("input", "height=\(h)cm weight=\(w)kg gender=\(gender?.rawValue ?? "?")")
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

                let ordered = BodyMeasurements.names.map {
                    "\($0)=\(String(format: "%.1f", result[$0] ?? 0))"
                }
                dbg.text("04_measurements", ordered.joined(separator: ", "))
                dbg.text("timing", String(format: "%.2fs total", elapsed))
                for wmsg in warns { dbg.text("warning", wmsg) }

                DispatchQueue.main.async {
                    measurements = result
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
