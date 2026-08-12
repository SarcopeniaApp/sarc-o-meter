import Foundation
import MediaPipeTasksVision
import Combine

// MARK: - Exercise Mode

enum ExerciseMode: String, CaseIterable, Identifiable {
    case sitToStand = "Sit to Stand"
    case stepUp     = "Step Up"
    case calfRaise  = "Calf Raise"
    var id: String { rawValue }
}

// MARK: - Session State

enum SessionState: Equatable {
    case idle
    case countdown(Int)
    case running(Int)
    case finished
}

// MARK: - Exercise Level (dari iOSMediaPipe ExerciseTypes)

/// Level kesulitan latihan — ditentukan dari parameter objektif per latihan,
/// BUKAN langsung dari usia/BMI.
enum ExerciseLevel: String {
    case beginner = "Beginner"
    case moderate = "Moderate"
    case advanced = "Advanced"
}

// MARK: - Form Score (dari iOSMediaPipe ExerciseTypes)

/// Skor kualitas gerakan 0.0–1.0 per repetisi.
struct FormScore {
    let value: Double
    let components: [String: Double]

    static let perfect = FormScore(value: 1.0, components: [:])
    static let zero    = FormScore(value: 0.0, components: [:])

    static func average(_ pairs: [(key: String, score: Double)]) -> FormScore {
        guard !pairs.isEmpty else { return .zero }
        let avg  = pairs.map(\.score).reduce(0, +) / Double(pairs.count)
        let dict = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.score) })
        return FormScore(value: avg.clamped(to: 0...1), components: dict)
    }
}

// MARK: - Feedback (dari iOSMediaPipe ExerciseTypes)

enum FeedbackSeverity { case good, info, warning }

struct ExerciseFeedback: Identifiable {
    let id       = UUID()
    let message:  String
    let severity: FeedbackSeverity
}

// MARK: - Rep Analysis (output gabungan level + form + feedback)

struct RepAnalysis {
    let exercise:  ExerciseMode
    let level:     ExerciseLevel
    let repCount:  Int
    let formScore: FormScore
    let feedback:  [ExerciseFeedback]
    let kneeAngle: Double?    // sudut lutut terakhir (debug/display)
    let heelRise:  Double?    // CalfRaise: normalizedHeelRise puncak
    let minKnee:   Double?    // SitToStand: knee angle terdalam selama rep
}

// MARK: - Thresholds (dari iOSMediaPipe ExerciseConfiguration)

private struct SitToStandThreshold {
    let beginner: ClosedRange<Double>;  let moderate: ClosedRange<Double>
    let advanced: ClosedRange<Double>;  let tooDeepAngle: Double
    let maxTrunkLean: Double
    static let `default` = SitToStandThreshold(
        beginner: 100...120, moderate: 80...100, advanced: 60...80,
        tooDeepAngle: 65,    maxTrunkLean: 45
    )
}

private struct StepUpThreshold {
    let beginnerHeightCm: ClosedRange<Double>;  let moderateHeightCm: ClosedRange<Double>
    let advancedHeightCm: ClosedRange<Double>;  let acceptableKneeRange: ClosedRange<Double>
    let targetHipAngleAtTop: ClosedRange<Double>
    static let `default` = StepUpThreshold(
        beginnerHeightCm: 5...10,  moderateHeightCm: 10...15, advancedHeightCm: 15...20,
        acceptableKneeRange: 70...120,  targetHipAngleAtTop: 160...180
    )
}

private struct CalfRaiseThreshold {
    let beginnerNormRise: ClosedRange<Double>; let moderateNormRise: ClosedRange<Double>
    let advancedNormRise: ClosedRange<Double>; let targetHoldSeconds: Double
    static let `default` = CalfRaiseThreshold(
        beginnerNormRise: 0.04...0.12, moderateNormRise: 0.12...0.20,
        advancedNormRise: 0.20...0.40, targetHoldSeconds: 1.0
    )
}

// MARK: - Rep Event (dari iOSMediaPipe RepetitionDetector)

private struct RepEvent {
    let repNumber: Int;          let minMetric: Double
    let maxMetric: Double;       let averageBottomMetric: Double
    let duration: TimeInterval
}

// MARK: - RepetitionDetector (dari iOSMediaPipe — generic state-machine naik/turun)

private final class RepetitionDetector {

    struct Config {
        let minRange: Double;           let lowRatioThreshold: Double
        let highRatioThreshold: Double; let minRepInterval: TimeInterval
        let calibrationRelax: Double

        static func sitToStand() -> Config {
            Config(minRange: 30,    lowRatioThreshold: 0.30, highRatioThreshold: 0.65,
                   minRepInterval: 0.5, calibrationRelax: 0.01)
        }
        static func stepUp() -> Config {
            Config(minRange: 0.025, lowRatioThreshold: 0.30, highRatioThreshold: 0.65,
                   minRepInterval: 0.5, calibrationRelax: 0.01)
        }
        static func calfRaise() -> Config {
            Config(minRange: 0.04,  lowRatioThreshold: 0.30, highRatioThreshold: 0.65,
                   minRepInterval: 0.4, calibrationRelax: 0.01)
        }
    }

    let config: Config
    var onRepCompleted: ((RepEvent) -> Void)?

    private(set) var repCount: Int  = 0
    private(set) var isReady:  Bool = false
    private(set) var debugMin: Double = 0
    private(set) var debugMax: Double = 0

    private var observedMin: Double =  .greatestFiniteMagnitude
    private var observedMax: Double = -.greatestFiniteMagnitude
    private var calibrated = false

    private enum Phase { case atBottom, atTop }
    private var phase: Phase = .atBottom

    private var repStartTime:    TimeInterval = 0
    private var lastRepTime:     TimeInterval = 0
    private var metricDuringRep: [Double]    = []

    init(config: Config) { self.config = config }

    func reset() {
        repCount = 0
        observedMin =  .greatestFiniteMagnitude
        observedMax = -.greatestFiniteMagnitude
        calibrated  = false
        isReady     = false
        phase       = .atBottom
        lastRepTime = 0
        metricDuringRep = []
        debugMin = 0; debugMax = 0
    }

    func process(metric: Double, timestamp: TimeInterval) {
        updateCalibration(metric)
        let range = observedMax - observedMin
        isReady   = range >= config.minRange
        debugMin  = observedMin; debugMax = observedMax
        guard isReady else { return }

        metricDuringRep.append(metric)
        let lowThresh  = observedMin + range * config.lowRatioThreshold
        let highThresh = observedMin + range * config.highRatioThreshold

        switch phase {
        case .atBottom:
            if metric >= highThresh { phase = .atTop; repStartTime = timestamp }
        case .atTop:
            if metric <= lowThresh  { completeRep(timestamp: timestamp); phase = .atBottom }
        }
    }

    private func updateCalibration(_ metric: Double) {
        guard calibrated else { observedMin = metric; observedMax = metric; calibrated = true; return }
        let r = max(observedMax - observedMin, 1e-6)
        let relax = r * config.calibrationRelax
        observedMin = min(metric, observedMin + relax)
        observedMax = max(metric, observedMax - relax)
    }

    private func completeRep(timestamp: TimeInterval) {
        guard timestamp - lastRepTime >= config.minRepInterval else { return }
        lastRepTime = timestamp
        repCount   += 1

        let minM    = metricDuringRep.min() ?? observedMin
        let maxM    = metricDuringRep.max() ?? observedMax
        let dur     = timestamp - repStartTime
        let rangeM  = maxM - minM
        let bThresh = minM + max(rangeM * 0.20, 5.0)
        let bot     = metricDuringRep.filter { $0 <= bThresh }
        let avgBot  = bot.isEmpty ? minM : bot.reduce(0, +) / Double(bot.count)
        metricDuringRep.removeAll()

        onRepCompleted?(RepEvent(repNumber: repCount, minMetric: minM,
                                 maxMetric: maxM, averageBottomMetric: avgBot, duration: dur))
    }
}

// MARK: - RepCounter

final class RepCounter: ObservableObject {

    // ── Published (dipakai ExerciseView — interface tidak berubah) ─────────────
    @Published var repCount:  Int          = 0
    @Published var isReady:   Bool         = false
    @Published var session:   SessionState = .idle
    @Published var mode:      ExerciseMode = .sitToStand { didSet { reset() } }

    /// Hasil analisis repetisi terakhir: level + form score + feedback
    @Published var lastRepAnalysis: RepAnalysis?

    /// Metrik mentah & rentang kalibrasi (untuk overlay debug)
    @Published var debugMetric: Double = 0
    @Published var debugRange:  Double = 0

    // ── Intensity (dari sarc-o-meter, dipertahankan untuk Tracker) ─────────────
    /// 1.0 = ROM penuh wajib; < 1.0 = ROM lebih sedikit sudah cukup per rep.
    var intensity: Double = 1.0

    // ── Step height untuk Step Up (cm). Nil = default beginner. ───────────────
    var configuredStepHeightCm: Double?

    // ── Thresholds (dari iOSMediaPipe) ────────────────────────────────────────
    private let sts = SitToStandThreshold.default
    private let su  = StepUpThreshold.default
    private let cr  = CalfRaiseThreshold.default

    // ── Timer sesi ─────────────────────────────────────────────────────────────
    private var timer: Timer?
    private let countdownSeconds = 5
    private let runningSeconds   = 10

    // ── RepetitionDetector ─────────────────────────────────────────────────────
    private var detector: RepetitionDetector!

    // ── Buffer per-rep ─────────────────────────────────────────────────────────
    private var repKneeAngles:  [Double] = []
    private var repHipAtTop:    [Double] = []
    private var repTrunkAngles: [Double] = []

    // Calf Raise: baseline & hold tracking
    private var heelBaselineY:       Double?
    private var baselineAccumulator: [Double] = []
    private let baselineFramesNeeded = 15
    private var peakNormHeelRise:    Double         = 0
    private var holdStartTime:       TimeInterval?
    private var peakHoldDuration:    TimeInterval   = 0

    // Snapshot sudut terakhir
    private var lastKneeAngle: Double?
    private var lastHipAngle:  Double?

    // ── MediaPipe visibility thresholds ───────────────────────────────────────
    private let visPrimary:   Float = 0.5
    private let visSecondary: Float = 0.3

    // MARK: - Init

    init() { rebuildDetector() }

    // MARK: - Session Control

    func startSession() {
        timer?.invalidate()
        reset()
        var remaining = countdownSeconds
        session = .countdown(remaining)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { return }
            switch self.session {
            case .countdown(let s):
                remaining = s - 1
                if remaining > 0 {
                    self.session = .countdown(remaining)
                } else {
                    remaining = self.runningSeconds
                    // ── Reset detektor & kalibrasi tepat saat running dimulai ──
                    // Ini memastikan:
                    // (1) rep yang terdeteksi selama countdown tidak terhitung,
                    // (2) kalibrasi baseline tumit dimulai dari posisi netral
                    //     yang benar (bukan posisi jinjit saat countdown), dan
                    // (3) RepetitionDetector melihat rentang gerak penuh sejak
                    //     awal sesi sehingga isReady cepat tercapai.
                    self.resetForRunning()
                    self.session = .running(remaining)
                }
            case .running(let s):
                remaining = s - 1
                if remaining > 0 { self.session = .running(remaining) }
                else { self.session = .finished; t.invalidate() }
            default:
                t.invalidate()
            }
        }
    }

    /// Reset state kalkulasi & detektor saat transisi countdown → running.
    /// Tidak menyentuh `session` atau timer — hanya state metrik.
    private func resetForRunning() {
        repCount = 0
        isReady  = false
        debugMetric = 0; debugRange = 0
        lastRepAnalysis = nil
        lastKneeAngle = nil; lastHipAngle = nil
        repKneeAngles.removeAll(); repHipAtTop.removeAll(); repTrunkAngles.removeAll()
        // Calf Raise: buang baseline yang terbentuk selama countdown.
        // Baseline akan direkalibrasi ulang dari posisi netral di awal running.
        heelBaselineY = nil
        baselineAccumulator.removeAll()
        peakNormHeelRise = 0; holdStartTime = nil; peakHoldDuration = 0
        // Rebuild detector agar observedMin/Max bersih — tidak ada "memori"
        // dari gerakan selama countdown yang bisa menyebabkan deteksi salah.
        rebuildDetector()
    }

    func stopSession() {
        timer?.invalidate(); timer = nil; session = .idle
    }

    // MARK: - Reset

    func reset() {
        repCount = 0; isReady = false
        debugMetric = 0; debugRange = 0
        lastRepAnalysis = nil
        lastKneeAngle = nil; lastHipAngle = nil
        repKneeAngles.removeAll(); repHipAtTop.removeAll(); repTrunkAngles.removeAll()
        heelBaselineY = nil; baselineAccumulator.removeAll()
        peakNormHeelRise = 0; holdStartTime = nil; peakHoldDuration = 0
        rebuildDetector()
    }

    // MARK: - Main Process (dipanggil tiap frame, ExerciseView tidak berubah)

    func process(_ person: [NormalizedLandmark]) {
        let now = Date().timeIntervalSince1970
        switch mode {
        case .sitToStand: processSitToStand(person, ts: now)
        case .stepUp:     processStepUp(person, ts: now)
        case .calfRaise:  processCalfRaise(person, ts: now)
        }
        // Sync debug display
        debugRange = detector.debugMax - detector.debugMin
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Sit to Stand
    // Metrik: knee angle (tinggi = berdiri ~170°, rendah = duduk ~90°)
    // ─────────────────────────────────────────────────────────────────────────

    private func processSitToStand(_ p: [NormalizedLandmark], ts: TimeInterval) {
        guard let knee = bestKneeAngle(p) else { return }
        lastKneeAngle = knee
        lastHipAngle  = bestHipAngle(p)
        repKneeAngles.append(knee)
        if let trunk = trunkInclination(p) { repTrunkAngles.append(trunk) }
        debugMetric = knee
        detector.process(metric: knee, timestamp: ts)
        isReady = detector.isReady
        if case .running = session { repCount = detector.repCount }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Step Up
    // Metrik: 1 - hipY (hip naik → y mengecil → metric membesar)
    // ─────────────────────────────────────────────────────────────────────────

    private func processStepUp(_ p: [NormalizedLandmark], ts: TimeInterval) {
        guard let hipY = bestVisibleY(p, left: 23, right: 24) else { return }
        let metric = 1.0 - hipY
        lastKneeAngle = bestKneeAngle(p)
        lastHipAngle  = bestHipAngle(p)
        if let k = lastKneeAngle { repKneeAngles.append(k) }
        if detector.isReady, let h = lastHipAngle { repHipAtTop.append(h) }
        debugMetric = metric
        detector.process(metric: metric, timestamp: ts)
        isReady = detector.isReady
        if case .running = session { repCount = detector.repCount }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Calf Raise
    // Metrik: heelDisplacement / shankLength (normalisasi terhadap panjang betis)
    // ─────────────────────────────────────────────────────────────────────────

    private func processCalfRaise(_ p: [NormalizedLandmark], ts: TimeInterval) {
        // Kalibrasi baseline tumit hanya dilakukan saat running.
        // Selama countdown, proses ini di-skip agar baseline tidak ter-set
        // dari posisi yang salah (misalnya pengguna belum siap berdiri netral).
        if heelBaselineY == nil {
            guard case .running = session else { isReady = false; return }
            calibrateCalfBaseline(p)
            isReady = false   // belum siap selama kalibrasi baseline berlangsung
            return
        }
        guard let normRise = calfNormRise(p) else { return }

        if normRise > peakNormHeelRise { peakNormHeelRise = normRise }

        // Track hold duration di puncak (normRise > 80% dari peak sesi)
        let peakThresh = (detector.isReady ? 0.8 : 0.6) * peakNormHeelRise
        if normRise >= peakThresh {
            if holdStartTime == nil { holdStartTime = ts }
            peakHoldDuration = ts - (holdStartTime ?? ts)
        } else {
            holdStartTime = nil
        }

        debugMetric = normRise
        detector.process(metric: normRise, timestamp: ts)
        isReady = detector.isReady
        if case .running = session { repCount = detector.repCount }
    }

    private func calibrateCalfBaseline(_ p: [NormalizedLandmark]) {
        let useLeft = vis(p, 27) >= vis(p, 28)
        let heelIdx = useLeft ? 29 : 30
        guard heelIdx < p.count, vis(p, heelIdx) >= visSecondary else { return }
        baselineAccumulator.append(Double(p[heelIdx].y))
        if baselineAccumulator.count >= baselineFramesNeeded {
            heelBaselineY = baselineAccumulator.reduce(0, +) / Double(baselineAccumulator.count)
            baselineAccumulator.removeAll()
        }
    }

    private func calfNormRise(_ p: [NormalizedLandmark]) -> Double? {
        guard let baseline = heelBaselineY else { return nil }
        let useLeft = vis(p, 27) >= vis(p, 28)
        let ankleI = useLeft ? 27 : 28, kneeI = useLeft ? 25 : 26, heelI = useLeft ? 29 : 30
        guard ankleI < p.count, kneeI < p.count, heelI < p.count,
              vis(p, ankleI) >= visPrimary, vis(p, kneeI) >= visPrimary,
              vis(p, heelI)  >= visSecondary else { return nil }
        let shank = dist(p[ankleI], p[kneeI])
        guard shank > 1e-4 else { return nil }
        // baseline - currentY: positif bila tumit naik (y image bertambah ke bawah)
        return (baseline - Double(p[heelI].y)) / shank
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Rep Completed → Level + Form Score + Feedback
    // ─────────────────────────────────────────────────────────────────────────

    private func rebuildDetector() {
        switch mode {
        case .sitToStand: detector = RepetitionDetector(config: .sitToStand())
        case .stepUp:     detector = RepetitionDetector(config: .stepUp())
        case .calfRaise:  detector = RepetitionDetector(config: .calfRaise())
        }
        detector.onRepCompleted = { [weak self] event in
            self?.handleRepCompleted(event)
        }
    }

    private func handleRepCompleted(_ event: RepEvent) {
        guard case .running = session else { return }

        let analysis: RepAnalysis
        switch mode {
        case .sitToStand: analysis = analyzeSTS(event)
        case .stepUp:     analysis = analyzeStepUp(event)
        case .calfRaise:  analysis = analyzeCalfRaise(event)
        }

        DispatchQueue.main.async {
            self.lastRepAnalysis = analysis
            self.repCount = self.detector.repCount
        }

        repKneeAngles.removeAll(); repHipAtTop.removeAll(); repTrunkAngles.removeAll()
    }

    // ── Sit to Stand ──────────────────────────────────────────────────────────

    private func analyzeSTS(_ event: RepEvent) -> RepAnalysis {
        // averageBottomMetric = rata-rata knee angle saat posisi duduk (bottom phase)
        let sittingKnee = event.averageBottomMetric
        let level    = classifySTS(sittingKnee)
        let score    = scoreSTS(minKneeAngle: sittingKnee, trunkAngles: repTrunkAngles,
                                duration: event.duration)
        let feedback = feedbackSTS(minKneeAngle: sittingKnee, avgTrunk: repTrunkAngles.average,
                                   score: score, level: level)
        return RepAnalysis(exercise: .sitToStand, level: level, repCount: detector.repCount,
                           formScore: score, feedback: feedback,
                           kneeAngle: lastKneeAngle, heelRise: nil, minKnee: sittingKnee)
    }

    /// Klasifikasi level berdasarkan seberapa dalam duduk (knee angle minimum).
    /// Sumber: iOSMediaPipe SitToStandAnalyzer.classifyLevel + ExerciseConfiguration.
    private func classifySTS(_ minKneeAngle: Double) -> ExerciseLevel {
        switch minKneeAngle {
        case sts.advanced.lowerBound...sts.advanced.upperBound: return .advanced
        case sts.moderate.lowerBound...sts.moderate.upperBound: return .moderate
        case sts.beginner.lowerBound...sts.beginner.upperBound: return .beginner
        default: return minKneeAngle > sts.beginner.upperBound ? .beginner : .advanced
        }
    }

    private func scoreSTS(minKneeAngle: Double, trunkAngles: [Double],
                           duration: TimeInterval) -> FormScore {
        var c: [(key: String, score: Double)] = []
        // 1. Range of Motion
        let rom: Double = minKneeAngle <= sts.beginner.upperBound
            ? 1.0
            : max(0, 1.0 - (minKneeAngle - sts.beginner.upperBound) / 30.0)
        c.append(("rangeOfMotion", rom))
        // 2. Trunk stability
        if let t = trunkAngles.average {
            c.append(("trunkStability", max(0, 1.0 - t / sts.maxTrunkLean)))
        }
        // 3. Tempo
        let tempo: Double
        switch duration {
        case 1.0...6.0:  tempo = 1.0
        case 0.5..<1.0:  tempo = 0.7
        case 6.0...10.0: tempo = 0.85
        default:         tempo = 0.5
        }
        c.append(("movementTempo", tempo))
        return FormScore.average(c)
    }

    private func feedbackSTS(minKneeAngle: Double, avgTrunk: Double?,
                              score: FormScore, level: ExerciseLevel) -> [ExerciseFeedback] {
        var f: [ExerciseFeedback] = []
        if minKneeAngle > sts.beginner.upperBound + 10 {
            f.append(.init(message: "Coba duduk lebih dalam untuk meningkatkan range of motion.", severity: .info))
        } else if minKneeAngle < sts.tooDeepAngle {
            f.append(.init(message: "Gerakan terlalu dalam — pastikan Anda merasa stabil.", severity: .warning))
        } else {
            f.append(.init(message: "Kedalaman duduk sudah bagus!", severity: .good))
        }
        if let t = avgTrunk, t > sts.maxTrunkLean {
            f.append(.init(message: "Usahakan badan lebih tegak saat berdiri.", severity: .info))
        }
        if score.components["movementTempo"] ?? 1.0 < 0.7 {
            f.append(.init(message: "Perlambat gerakan turun untuk kontrol yang lebih baik.", severity: .info))
        }
        if level == .beginner {
            f.append(.init(message: "Kursi yang lebih tinggi bisa membantu bila terasa berat.", severity: .info))
        }
        return f
    }

    // ── Step Up ───────────────────────────────────────────────────────────────

    private func analyzeStepUp(_ event: RepEvent) -> RepAnalysis {
        let level    = classifyStepUp()
        let score    = scoreStepUp(repKneeAngles: repKneeAngles, repHipAtTop: repHipAtTop,
                                   duration: event.duration)
        let feedback = feedbackStepUp(level: level, minKnee: repKneeAngles.min(),
                                      maxHipAtTop: repHipAtTop.max(), score: score)
        return RepAnalysis(exercise: .stepUp, level: level, repCount: detector.repCount,
                           formScore: score, feedback: feedback,
                           kneeAngle: lastKneeAngle, heelRise: nil, minKnee: repKneeAngles.min())
    }

    /// Level ditentukan dari tinggi step (cm) yang dimasukkan pengguna / terapis.
    /// Bila tidak dikonfigurasi, default ke beginner.
    /// Sumber: iOSMediaPipe StepUpAnalyzer.classifyLevel + ExerciseConfiguration.
    private func classifyStepUp() -> ExerciseLevel {
        guard let h = configuredStepHeightCm else { return .beginner }
        switch h {
        case su.beginnerHeightCm:  return .beginner
        case su.moderateHeightCm:  return .moderate
        case su.advancedHeightCm:  return .advanced
        default:
            if h < su.beginnerHeightCm.lowerBound { return .beginner }
            if h > su.advancedHeightCm.upperBound  { return .advanced }
            return .moderate
        }
    }

    private func scoreStepUp(repKneeAngles: [Double], repHipAtTop: [Double],
                              duration: TimeInterval) -> FormScore {
        var c: [(key: String, score: Double)] = []
        // 1. Knee alignment saat memijak step
        if let avgK = repKneeAngles.average {
            c.append(("kneeAlignment", su.acceptableKneeRange.contains(avgK) ? 1.0 : 0.6))
        }
        // 2. Hip extension di atas step (semakin lurus = lebih baik)
        if let topH = repHipAtTop.max() {
            let t = su.targetHipAngleAtTop
            let s = t.contains(topH) ? 1.0 : max(0, 1.0 - (t.lowerBound - topH) / 40.0)
            c.append(("hipExtension", s))
        }
        // 3. Tempo
        let tempo: Double
        switch duration {
        case 1.5...7.0: tempo = 1.0
        case 0.8..<1.5: tempo = 0.7
        default:        tempo = 0.6
        }
        c.append(("movementTempo", tempo))
        return FormScore.average(c)
    }

    private func feedbackStepUp(level: ExerciseLevel, minKnee: Double?,
                                 maxHipAtTop: Double?, score: FormScore) -> [ExerciseFeedback] {
        var f: [ExerciseFeedback] = []
        if let k = minKnee {
            if k < su.acceptableKneeRange.lowerBound {
                f.append(.init(message: "Hati-hati, lutut jangan terlalu jauh melewati ujung kaki.", severity: .warning))
            } else {
                f.append(.init(message: "Posisi lutut saat naik step sudah baik.", severity: .good))
            }
        }
        if let hip = maxHipAtTop, !su.targetHipAngleAtTop.contains(hip) {
            f.append(.init(message: "Luruskan pinggul sepenuhnya saat berdiri di atas step.", severity: .info))
        }
        if level == .beginner {
            f.append(.init(message: "Kalau sudah terasa ringan, coba naikkan tinggi step.", severity: .info))
        }
        if configuredStepHeightCm == nil {
            f.append(.init(message: "Atur tinggi step di pengaturan untuk pelacakan level yang lebih akurat.", severity: .info))
        }
        return f
    }

    // ── Calf Raise ────────────────────────────────────────────────────────────

    private func analyzeCalfRaise(_ event: RepEvent) -> RepAnalysis {
        let peakRise = event.maxMetric
        let level    = classifyCalfRaise(peakRise)
        let score    = scoreCalfRaise(peakRise: peakRise, holdDuration: peakHoldDuration,
                                      duration: event.duration)
        let feedback = feedbackCalfRaise(level: level, peakRise: peakRise,
                                         holdDuration: peakHoldDuration, score: score)
        // Reset state per-rep
        peakNormHeelRise = 0; peakHoldDuration = 0; holdStartTime = nil
        return RepAnalysis(exercise: .calfRaise, level: level, repCount: detector.repCount,
                           formScore: score, feedback: feedback,
                           kneeAngle: nil, heelRise: peakRise, minKnee: nil)
    }

    /// Klasifikasi level berdasarkan normalizedHeelRise puncak.
    /// Sumber: iOSMediaPipe CalfRaiseAnalyzer.classifyLevel + ExerciseConfiguration.
    private func classifyCalfRaise(_ peakNormRise: Double) -> ExerciseLevel {
        switch peakNormRise {
        case cr.advancedNormRise: return .advanced
        case cr.moderateNormRise: return .moderate
        case cr.beginnerNormRise: return .beginner
        default: return peakNormRise < cr.beginnerNormRise.lowerBound ? .beginner : .advanced
        }
    }

    private func scoreCalfRaise(peakRise: Double, holdDuration: TimeInterval,
                                 duration: TimeInterval) -> FormScore {
        var c: [(key: String, score: Double)] = []
        // 1. Heel elevation
        let minT = cr.beginnerNormRise.lowerBound
        let rise: Double
        if peakRise >= cr.moderateNormRise.lowerBound   { rise = 1.0 }
        else if peakRise >= minT                         { rise = 0.8 }
        else                                             { rise = max(0, peakRise / minT) }
        c.append(("heelElevation", rise))
        // 2. Hold duration
        c.append(("holdDuration", holdDuration >= cr.targetHoldSeconds
            ? 1.0 : max(0, holdDuration / cr.targetHoldSeconds)))
        // 3. Tempo
        c.append(("movementTempo", duration < 0.8 ? 0.6 : 1.0))
        return FormScore.average(c)
    }

    private func feedbackCalfRaise(level: ExerciseLevel, peakRise: Double,
                                    holdDuration: TimeInterval, score: FormScore) -> [ExerciseFeedback] {
        var f: [ExerciseFeedback] = []
        if peakRise < cr.beginnerNormRise.lowerBound {
            f.append(.init(message: "Coba angkat tumit lebih tinggi.", severity: .info))
        } else {
            f.append(.init(message: "Elevasi tumit bagus — pertahankan!", severity: .good))
        }
        if holdDuration < cr.targetHoldSeconds * 0.5 {
            f.append(.init(message: "Tahan posisi atas sebentar sebelum turun.", severity: .info))
        }
        if score.components["movementTempo"] ?? 1.0 < 0.7 {
            f.append(.init(message: "Turunkan tumit perlahan dan terkontrol.", severity: .info))
        }
        if heelBaselineY == nil {
            f.append(.init(message: "Berdiri diam sebentar agar sistem bisa kalibrasi.", severity: .warning))
        }
        return f
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Landmark Helpers
    // (Memakai pendekatan yang sama dengan sarc-o-meter original — langsung
    //  dari NormalizedLandmark tanpa LandmarkSmoother, agar tidak memerlukan
    //  refactor LandmarkBridge dari iOSMediaPipe.)
    // ─────────────────────────────────────────────────────────────────────────

    private func bestKneeAngle(_ p: [NormalizedLandmark]) -> Double? {
        let l = kneeAngle(p, hip: 23, knee: 25, ankle: 27)
        let r = kneeAngle(p, hip: 24, knee: 26, ankle: 28)
        switch (l, r) {
        case let (lv?, rv?): return vis(p, 25) >= vis(p, 26) ? lv : rv
        case let (lv?, nil): return lv
        case let (nil, rv?): return rv
        default: return nil
        }
    }

    private func kneeAngle(_ p: [NormalizedLandmark], hip: Int, knee: Int, ankle: Int) -> Double? {
        guard hip < p.count, knee < p.count, ankle < p.count,
              vis(p, hip) >= visPrimary, vis(p, knee) >= visPrimary,
              vis(p, ankle) >= visPrimary else { return nil }
        return angle(a: p[hip], v: p[knee], c: p[ankle])
    }

    private func bestHipAngle(_ p: [NormalizedLandmark]) -> Double? {
        let useLeft = vis(p, 23) >= vis(p, 24)
        let (s, h, k) = useLeft ? (11, 23, 25) : (12, 24, 26)
        guard s < p.count, h < p.count, k < p.count,
              vis(p, s) >= visPrimary, vis(p, h) >= visPrimary,
              vis(p, k) >= visPrimary else { return nil }
        return angle(a: p[s], v: p[h], c: p[k])
    }

    /// Kemiringan batang tubuh terhadap sumbu vertikal (derajat).
    /// Sumber: iOSMediaPipe AngleCalculator.trunkInclination.
    private func trunkInclination(_ p: [NormalizedLandmark]) -> Double? {
        guard 11 < p.count, 23 < p.count else { return nil }
        let useLeft = vis(p, 11) >= vis(p, 12)
        let shIdx   = useLeft ? 11 : 12
        let hpIdx   = useLeft ? 23 : 24
        guard vis(p, shIdx) >= visPrimary, vis(p, hpIdx) >= visPrimary else { return nil }
        let sx = Double(p[shIdx].x), sy = Double(p[shIdx].y)
        let hx = Double(p[hpIdx].x), hy = Double(p[hpIdx].y)
        let dx = hx - sx, dy = hy - sy
        return atan2(abs(dx), abs(dy)) * 180 / .pi
    }

    private func bestVisibleY(_ p: [NormalizedLandmark], left: Int, right: Int) -> Double? {
        guard left < p.count, right < p.count else { return nil }
        let vl = vis(p, left), vr = vis(p, right)
        guard max(vl, vr) >= visPrimary else { return nil }
        return Double(vl >= vr ? p[left].y : p[right].y)
    }

    /// Sudut di titik `v`, dibentuk oleh ruas v→a dan v→c. Selalu [0°, 180°].
    /// Sumber: iOSMediaPipe AngleCalculator.angle.
    private func angle(a: NormalizedLandmark, v: NormalizedLandmark,
                       c: NormalizedLandmark) -> Double {
        let v1x = Double(a.x - v.x), v1y = Double(a.y - v.y)
        let v2x = Double(c.x - v.x), v2y = Double(c.y - v.y)
        let dot  = v1x*v2x + v1y*v2y
        let mag1 = (v1x*v1x + v1y*v1y).squareRoot()
        let mag2 = (v2x*v2x + v2y*v2y).squareRoot()
        guard mag1 > 1e-6, mag2 > 1e-6 else { return 0 }
        return acos((dot / (mag1 * mag2)).clamped(to: -1...1)) * 180 / .pi
    }

    private func dist(_ a: NormalizedLandmark, _ b: NormalizedLandmark) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx*dx + dy*dy).squareRoot()
    }

    private func vis(_ p: [NormalizedLandmark], _ i: Int) -> Float {
        guard i < p.count else { return 0 }
        return p[i].visibility?.floatValue ?? 1.0
    }
}

// MARK: - Extensions

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Array where Element == Double {
    var average: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }
}
