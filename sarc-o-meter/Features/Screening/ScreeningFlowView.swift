//  ScreeningFlowView.swift
//
//  ══════════════════════ SCREENING FEATURE — ENTRY POINT ══════════════════════
//  Runs the second half of the screening: questionnaire → exercise test
//  (MediaPipe sit-to-stand, skippable) → on-device analysis. On finish it hands a
//  fully-built ScreeningRecord (result + LLM analysis + adjustable workout plan)
//  back to the shell, which persists it and moves into the tracker.
//
//  CONTRACT: `ScreeningInput`, and `ScreeningFlowView(input:llm:onExit:onFinished:)`.
//  ═════════════════════════════════════════════════════════════════════════════

import SwiftUI

/// Everything the screening needs from the rest of the app — Core types only.
struct ScreeningInput {
    let gender: Gender
    let ageYears: Int?
    let heightCm: Double?
    let weightKg: Double?
    let measurements: BodyMeasurements?
}

struct ScreeningFlowView: View {
    let input: ScreeningInput
    let llm: LLMManager
    var onExit: () -> Void                        // back out to the scan result
    var onFinished: (ScreeningRecord) -> Void     // shell saves + opens the tracker

    private enum Step { case questionnaire, exerciseTest, analysis }
    @State private var step: Step = .questionnaire
    @State private var assessment = AssessmentData()
    @State private var ruleResult: AssessmentResult?
    @State private var analysisText: String?
    @State private var plan: [WorkoutItem] = []
    @State private var isGenerating = false

    // The exercise test runs the three exercises in order.
    @State private var testIndex = 0
    private static let testOrder: [(mode: ExerciseMode, name: String)] = [
        (.sitToStand, "Berdiri dari kursi"),
        (.stepUp,     "Naik step"),
        (.calfRaise,  "Jinjit (angkat tumit)"),
    ]

    var body: some View {
        switch step {
        case .questionnaire:
            ClinicalHistoryView(history: $assessment.clinicalHistory, onBack: onExit) {
                step = .exerciseTest
            }

        case .exerciseTest:
            exerciseTestStep

        case .analysis:
            if let ruleResult {
                DiagnosisView(
                    result: ruleResult,
                    analysis: analysisText,
                    isGenerating: isGenerating,
                    onFinish: { finish() }
                )
            }
        }
    }

    // MARK: The 3-exercise test

    @ViewBuilder
    private var exerciseTestStep: some View {
        let item = Self.testOrder[testIndex]
        // Each exercise is skippable ("can't do it" → nil reps). `.id` gives each
        // a fresh camera + rep counter so switching exercises starts clean.
        ExerciseView(
            fixedMode: item.mode,
            allowSkip: true,
            headline: "Tes \(testIndex + 1)/3: \(item.name)"
        ) { reps in
            recordTest(item.mode, reps)
        }
        .id(item.mode)
    }

    private func recordTest(_ mode: ExerciseMode, _ reps: Int?) {
        switch mode {
        case .sitToStand: assessment.physicalTest.sitToStandReps = reps
        case .stepUp:     assessment.physicalTest.stepUpReps = reps
        case .calfRaise:  assessment.physicalTest.calfRaiseReps = reps
        }
        if testIndex + 1 < Self.testOrder.count {
            testIndex += 1
        } else {
            runAnalysis()
        }
    }

    // MARK: Rule engine + on-device RAG analysis

    private func runAnalysis() {
        assessment.personalData = PersonalData(
            age: input.ageYears,
            gender: input.gender,
            heightCm: input.heightCm,
            weightKg: input.weightKg
        )
        assessment.bodyMeasurement = BodyMeasurement(
            waistCircumferenceCm: input.measurements?["waist"],
            calfCircumferenceCm: input.measurements?["calf"],
            armCircumferenceCm: input.measurements?["bicep"]
        )

        let result = RuleEngine.evaluate(data: assessment)
        ruleResult = result
        analysisText = nil
        isGenerating = true
        step = .analysis

        Task {
            await llm.loadModel()   // no-op if the shell already loaded it at launch
            llm.appendSystemMessage(OnDeviceRAG.getSystemPrompt())
            let prompt = OnDeviceRAG.buildPrompt(
                question: "Jelaskan hasil skrining saya secara singkat dan beri satu saran latihan yang aman untuk memulai.",
                result: result,
                maxChunks: 3
            )
            let raw = await llm.sendMessage(prompt) ?? ""
            if let parsed = OnDeviceRAG.parse(raw) {
                analysisText = parsed.analysis
                plan = parsed.plan
            } else {
                // Model didn't return usable JSON → show whatever text came back
                // (if any) and fall back to the deterministic plan.
                analysisText = raw.isEmpty ? nil : raw
                plan = ExercisePlan.derive(from: result)
            }
            isGenerating = false
        }
    }

    private func finish() {
        guard let ruleResult else { return }
        let record = ScreeningRecord(
            completedAt: Date(),
            overallRisk: ruleResult.overallRisk.rawValue,
            workoutRestriction: ruleResult.workoutRestriction.rawValue,
            analysis: analysisText ?? "",
            plan: plan.isEmpty ? ExercisePlan.derive(from: ruleResult) : plan
        )
        onFinished(record)
    }
}
