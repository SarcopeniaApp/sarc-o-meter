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
    @State private var isGenerating = false

    var body: some View {
        switch step {
        case .questionnaire:
            ClinicalHistoryView(history: $assessment.clinicalHistory, onBack: onExit) {
                step = .exerciseTest
            }

        case .exerciseTest:
            // A live sit-to-stand test (AWGS chair-stand analog). Skippable if the
            // person can't do it — that's recorded as "unable" rather than 0 reps.
            ExerciseView(
                fixedMode: .sitToStand,
                allowSkip: true,
                headline: "Tes: berdiri dari kursi (10 detik)"
            ) { reps in
                applyExerciseTest(reps)
                runAnalysis()
            }

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

    // MARK: Map the exercise test onto the rule engine's physical-test inputs

    private func applyExerciseTest(_ reps: Int?) {
        if let reps, reps > 0 {
            assessment.physicalTest.mobilityStatus = .normal
            // Reps in the 10 s window → equivalent 5-rep chair-stand time
            // (AWGS abnormal ≥ 12 s, i.e. < 5 reps in 10 s).
            assessment.physicalTest.chairStandTestSeconds = 50.0 / Double(reps)
        } else {
            // Skipped / couldn't do it → not assessable via self-test.
            assessment.physicalTest.mobilityStatus = .unable
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
            let text = await llm.sendMessage(prompt)
            analysisText = text
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
            plan: ExercisePlan.derive(from: ruleResult)
        )
        onFinished(record)
    }
}
