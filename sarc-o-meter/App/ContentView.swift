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
//  It drives the ENTIRE screening flow directly — personal info, the scan, the
//  questionnaire, the 3-exercise test, and the analysis — presenting each feature
//  view (ClinicalHistoryView, ExerciseView, DiagnosisView) itself. Once done it
//  hands off to TrackerView.

import SwiftUI
import UIKit

struct ContentView: View {
    private enum Step {
        case greeting, gender, age, height, weight, instructions, manual, capturing, measuring, result
        // Screening (formerly ScreeningFlowView, now driven here):
        case questionnaire, exerciseTest, analysis
    }

    // The single source of truth. Loaded once; a saved user whose screening is
    // filled in means "returning user → show the tracker".
    @State private var user: User = UserStore.load() ?? User()

    @State private var step: Step = .greeting
    @State private var errorText: String?

    // Manual-entry sub-flow state (a transient input buffer; committed into `user`).
    @State private var manualIndex = 0
    @State private var manualEntry = 0
    @State private var manualValues: [String: Double] = [:]

    private struct ManualField { let key: String; let name: String; let subtitle: String }
    private static let manualFields: [ManualField] = [
        ManualField(key: "chest", name: "Dada",     subtitle: "Ukur bagian terlebar dada Anda."),
        ManualField(key: "waist", name: "Pinggang", subtitle: "Ukur lingkar pinggang alami Anda."),
        ManualField(key: "hip",   name: "Pinggul",  subtitle: "Ukur bagian terlebar pinggul Anda."),
        ManualField(key: "calf",  name: "Betis",    subtitle: "Ukur bagian tertebal betis Anda."),
    ]

    @AppStorage("debugServer") private var debugServer = ""
    @State private var predictor: BMNetPredictor? = try? BMNetPredictor()
    @State private var llm = LLMManager()

    // Screening flow state (moved here from the former ScreeningFlowView).
    @State private var testIndex = 0
    @State private var ruleResult: AssessmentResult?
    @State private var analysisText: String?
    @State private var plan: [Workout] = []
    @State private var weeklySchedule: String?
    @State private var isGenerating = false

    // The exercise test runs the three exercises in order.
    private static let testOrder: [(mode: ExerciseMode, name: String)] = [
        (.sitToStand, "Berdiri dari kursi"),
        (.stepUp,     "Naik step"),
        (.calfRaise,  "Jinjit (angkat tumit)"),
    ]

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
        case .greeting:
            GreetingScreen() {
                step = .gender
            }
        case .gender:
            GenderScreen(
                user: user,
                debugServer: $debugServer,
                onBack: { step = .greeting }
            ) {
                step = .age
            }
        case .age:
            NumericPadScreen(
                title: "Tentang Anda",
                subtitle: "Berapa usia Anda?",
                unit: "th", value: ageBinding,
                onBack: { step = .gender }
            ) { step = .height }

        case .height:
            NumericPadScreen(
                title: "Tentang Anda",
                subtitle: "Berapa tinggi badan Anda?",
                unit: "cm", value: heightBinding,
                onBack: { step = .age }
            ) { step = .weight }

        case .weight:
            NumericPadScreen(
                title: "Tentang Anda",
                subtitle: "Berapa berat badan Anda?",
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
                
        case .capturing:
            PoseCaptureView(
                onBack: {
                    step = .instructions
                }
            ) { front, side in
                step = .measuring
                runMeasurement(front: front, side: side)
            }

        case .measuring:
            MeasuringView()

        case .result:
            ResultScreen(
                user: user,
                onRescan: { step = .instructions },
                onFinish: { step = .questionnaire }
            )

        // ── Screening: questionnaire → exercise test → analysis ──
        case .questionnaire:
            ClinicalHistoryView(user: user, onBack: { step = .result }) {
                step = .exerciseTest
            }

        case .exerciseTest:
            exerciseTestStep

        case .analysis:
            if let ruleResult {
                DiagnosisView(
                    result: ruleResult,
                    analysis: analysisText,
                    exercises: plan,
                    weeklySchedule: weeklySchedule,
                    isGenerating: isGenerating,
                    onFinish: { finishScreening() }
                )
            }
        }
    }

    // MARK: Screening (questionnaire → 3-exercise test → on-device analysis)

    @ViewBuilder
    private var exerciseTestStep: some View {
        let item = Self.testOrder[testIndex]
        let hasNext = testIndex + 1 < Self.testOrder.count
        let nextName = hasNext ? Self.testOrder[testIndex + 1].name : nil

        // Each exercise is skippable ("can't do it" → nil reps). `.id` gives each a
        // fresh camera + rep counter so switching exercises starts clean.
        ExerciseView(
            fixedMode: item.mode,
            allowSkip: true,
            headline: item.name,
            stepIndex: testIndex,
            totalSteps: Self.testOrder.count,
            nextExerciseName: nextName
        ) { reps in
            recordTest(item.mode, reps)
        }
        .id(item.mode)
    }

    private func recordTest(_ mode: ExerciseMode, _ reps: Int?) {
        switch mode {
        case .sitToStand: user.sitToStandReps = reps
        case .stepUp:     user.stepUpReps = reps
        case .calfRaise:  user.calfRaiseReps = reps
        }
        if testIndex + 1 < Self.testOrder.count {
            testIndex += 1
        } else {
            runAnalysis()
        }
    }

    private func runAnalysis() {
        // Everything the rule engine needs (gender, height, calf, waist, clinical
        // history, the reps just recorded) already lives on `user`.
        let result = RuleEngine.evaluate(user)
        ruleResult = result
        analysisText = nil
        weeklySchedule = nil
        isGenerating = true
        step = .analysis

        Task {
            await llm.loadModel()   // no-op if the shell already loaded it at launch
            llm.appendSystemMessage(OnDeviceRAG.getSystemPrompt())
            let prompt = OnDeviceRAG.buildPrompt(
                question: "Buat rencana latihan yang aman dan detail berdasarkan profil saya.",
                result: result,
                user: user,
                maxChunks: 3
            )
            let raw = await llm.sendMessage(prompt) ?? ""

            if let parsed = OnDeviceRAG.parse(raw, result: result) {
                analysisText = parsed.analysis
                plan = parsed.plan
                weeklySchedule = parsed.weeklySchedule
            } else {
                analysisText = OnDeviceRAG.extractInsight(from: raw)
                plan = ExercisePlan.derive(from: result)
                weeklySchedule = ExercisePlan.weeklySchedule(for: result)
            }

            // Safety override: mobility-only restriction or severe risk always forces
            // the deterministic single-exercise plan, regardless of LLM output.
            if result.workoutRestriction == .mobilityOnly || result.overallRisk == .severe {
                plan = ExercisePlan.derive(from: result)
                weeklySchedule = ExercisePlan.weeklySchedule(for: result)
            }

            isGenerating = false
        }
    }

    private func finishScreening() {
        guard let ruleResult else { return }
        user.screening = ScreeningRecord(
            completedAt: Date(),
            overallRisk: ruleResult.overallRisk.rawValue,
            workoutRestriction: ruleResult.workoutRestriction.rawValue,
            analysis: analysisText ?? "",
            plan: plan.isEmpty ? ExercisePlan.derive(from: ruleResult) : plan,
            weeklySchedule: weeklySchedule ?? ExercisePlan.weeklySchedule(for: ruleResult)
        )
        UserStore.save(user)   // user.screening is set → shell flips to the tracker
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
        step = .capturing
    }

    private func restartScreening() {
        UserStore.clear()
        user = User()               // fresh source of truth
        manualIndex = 0
        manualEntry = 0
        manualValues = [:]
        testIndex = 0
        ruleResult = nil
        analysisText = nil
        plan = []
        weeklySchedule = nil
        isGenerating = false
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
