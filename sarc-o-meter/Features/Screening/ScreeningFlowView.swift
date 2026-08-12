//  ScreeningFlowView.swift
//
//  ══════════════════════ SCREENING FEATURE — ENTRY POINT ══════════════════════
//  Runs the second half of the screening: questionnaire → exercise test
//  (MediaPipe, each exercise skippable) → on-device analysis. It reads the person's
//  info + measurements straight off the shared `User`, writes the exercise-test
//  reps back onto it, and on finish stores the completed `ScreeningRecord` into
//  `user.screening` — the shell then persists `user` and moves into the tracker.
//
//  CONTRACT: `ScreeningFlowView(user:llm:onExit:onFinished:)`.
//  ═════════════════════════════════════════════════════════════════════════════

import SwiftUI

struct ScreeningFlowView: View {
    let user: User
    let llm: LLMManager
    var onExit: () -> Void            // back out to the scan result
    var onFinished: () -> Void        // shell persists `user` + opens the tracker

    private enum Step { case questionnaire, exerciseTest, analysis }
    @State private var step: Step = .questionnaire
    @State private var ruleResult: AssessmentResult?
    @State private var analysisText: String?
    @State private var plan: [Workout] = []
    @State private var weeklySchedule: String?
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
            ClinicalHistoryView(user: user, onBack: onExit) {
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
                    onFinish: { finish() }
                )
            }
        }
    }

    // MARK: The 3-exercise test

    @ViewBuilder
    private var exerciseTestStep: some View {
        let item = Self.testOrder[testIndex]
        let hasNext = testIndex + 1 < Self.testOrder.count
        let nextName = hasNext ? Self.testOrder[testIndex + 1].name : nil
        
        // Each exercise is skippable ("can't do it" → nil reps). `.id` gives each
        // a fresh camera + rep counter so switching exercises starts clean.
        ExerciseView(
            fixedMode: item.mode,
            allowSkip: true,
            headline: "Tes \(testIndex + 1)/3: \(item.name)",
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

    // MARK: Rule engine + on-device RAG analysis

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
                // Model didn't return usable JSON → try to extract just the
                // insight text; fall back to the deterministic plan.
                analysisText = OnDeviceRAG.extractInsight(from: raw)
                plan = ExercisePlan.derive(from: result)
                weeklySchedule = ExercisePlan.weeklySchedule(for: result)
            }

            // Safety override: mobility-only restriction or severe risk always
            // forces the deterministic single-exercise plan, regardless of LLM output.
            if result.workoutRestriction == .mobilityOnly || result.overallRisk == .severe {
                plan = ExercisePlan.derive(from: result)
                weeklySchedule = ExercisePlan.weeklySchedule(for: result)
            }

            isGenerating = false
        }
    }

    private func finish() {
        guard let ruleResult else { return }
        user.screening = ScreeningRecord(
            completedAt: Date(),
            overallRisk: ruleResult.overallRisk.rawValue,
            workoutRestriction: ruleResult.workoutRestriction.rawValue,
            analysis: analysisText ?? "",
            plan: plan.isEmpty ? ExercisePlan.derive(from: ruleResult) : plan,
            weeklySchedule: weeklySchedule ?? ExercisePlan.weeklySchedule(for: ruleResult)
        )
        onFinished()
    }
}

