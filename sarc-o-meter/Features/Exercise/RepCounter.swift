import Foundation
import MediaPipeTasksVision
import Combine

// Mode latihan
enum ExerciseMode: String, CaseIterable, Identifiable {
    case sitToStand = "Sit to Stand"
    case stepUp     = "Step Up"
    case calfRaise  = "Calf Raise"
    var id: String { rawValue }
}

// Status sesi latihan
enum SessionState: Equatable {
    case idle           // belum mulai
    case countdown(Int) // hitung mundur, sisa detik
    case running(Int)   // sedang menghitung, sisa detik
    case finished       // selesai, skor beku
}

// Fase gerakan untuk state machine
private enum RepPhase { case down, up }

final class RepCounter: ObservableObject {
    @Published var repCount: Int = 0
    @Published var isReady: Bool = false        // true bila rentang gerak sudah cukup terkalibrasi
    @Published var mode: ExerciseMode = .sitToStand {
        didSet { reset() }
    }

    // ── OUR ADDITION (not in the colleague's reference) ──
    /// Movement intensity 0…1. 1.0 = a rep needs the full range of motion; lower
    /// values count a rep with less ROM (e.g. 0.5 = a shallower squat still
    /// counts). The tracker sets this from the prescribed plan; the screening
    /// test leaves it at the default 1.0 so behavior matches the reference.
    var intensity: Double = 1.0

    @Published var debugMetric: Double = 0
    @Published var debugRange: Double = 0

    @Published var session: SessionState = .idle

        private var timer: Timer?
        private let countdownSeconds = 5
        private let runningSeconds = 10

        // Mulai sesi: hitung mundur -> menghitung -> selesai
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
                        self.repCount = 0            // mulai hitung dari 0, kalibrasi tetap terbawa
                        self.session = .running(remaining)
                    }
                case .running(let s):
                    remaining = s - 1
                    if remaining > 0 {
                        self.session = .running(remaining)
                    } else {
                        self.session = .finished
                        t.invalidate()
                    }
                default:
                    t.invalidate()
                }
            }
        }

        func stopSession() {
            timer?.invalidate()
            timer = nil
            session = .idle
        }

    // --- Kalibrasi adaptif per sesi ---
    private var observedMin: Double =  .greatestFiniteMagnitude
    private var observedMax: Double = -.greatestFiniteMagnitude
    private var calibrated = false
    private var phase: RepPhase = .down
    private var lastRepTime: TimeInterval = 0

    // --- Parameter yang bisa disetel ---
    private let visibilityThreshold: Float = 0.5   // titik dianggap valid
    private let minRepInterval: TimeInterval = 0.4 // jeda minimal antar rep (anti dobel-hitung)
    private let lowRatio  = 0.30                    // ambang bawah = 30% rentang
    private let highRatio = 0.6                     // ambang atas  = 60% rentang

    // Seberapa cepat rentang lama "menyusut" kembali ke nilai sekarang tiap frame.
    // Puncak/lembah BARU tetap ditangkap seketika; tapi lonjakan sekali (mis. saat
    // masuk frame) akan meluruh dalam ~1/calibrationRelax frame, jadi tidak
    // merusak kalibrasi sepanjang sesi. Naikkan bila kalibrasi terasa "nyangkut".
    private let calibrationRelax = 0.01

    // Floor rentang minimal per mode supaya getaran kecil tidak terhitung.
    // CATATAN: nilai step-up & calf-raise bergantung pada framing kamera
    // (seberapa penuh badan/kaki mengisi layar). Pantau overlay debug lalu setel.
    private var minRange: Double {
        switch mode {
        case .sitToStand: return 40.0    // satuan derajat
        case .stepUp:     return 0.03    // fraksi tinggi ternormalisasi
        case .calfRaise:  return 0.04    // rasio terhadap panjang betis
        }
    }

    func reset() {
        repCount = 0
        observedMin =  .greatestFiniteMagnitude
        observedMax = -.greatestFiniteMagnitude
        calibrated = false
        phase = .down
        isReady = false
        lastRepTime = 0
        debugMetric = 0
        debugRange = 0
    }

    // Panggil tiap frame dengan landmark satu orang
    func process(_ person: [NormalizedLandmark]) {
        guard let metric = metric(for: person) else { return }

        // Auto-kalibrasi dengan peluruhan: extremum baru langsung ditangkap,
        // rentang lama menyusut perlahan menuju nilai sekarang.
        if !calibrated {
            observedMin = metric
            observedMax = metric
            calibrated = true
        } else {
            let r = max(observedMax - observedMin, 1e-6)
            let relax = r * calibrationRelax
            observedMin = min(metric, observedMin + relax)
            observedMax = max(metric, observedMax - relax)
        }
        let range = observedMax - observedMin

        debugMetric = metric
        debugRange = range

        // Belum cukup bergerak untuk dihitung
        guard range >= minRange else {
            if isReady { isReady = false }
            return
        }
        if !isReady { isReady = true }

        guard case .running = session else { return }

        // Scale the "top of the rep" threshold by intensity: at 1.0 the peak must
        // reach highRatio of the range (full ROM); lower intensity needs less.
        let clamped = max(0, min(1, intensity))
        let effectiveHighRatio = lowRatio + (highRatio - lowRatio) * clamped
        let lowThresh  = observedMin + range * lowRatio
        let highThresh = observedMin + range * effectiveHighRatio

        switch phase {
        case .down:
            if metric >= highThresh {
                phase = .up
                registerRep()
            }
        case .up:
            if metric <= lowThresh {
                phase = .down
            }
        }
    }

    private func registerRep() {
        let now = Date().timeIntervalSince1970
        guard now - lastRepTime >= minRepInterval else { return }
        lastRepTime = now
        repCount += 1
    }

    // --- Metrik per mode (nilai TINGGI = posisi puncak/atas) ---
    private func metric(for p: [NormalizedLandmark]) -> Double? {
        switch mode {
        case .sitToStand:
            // Sudut lutut: berdiri ~175° (tinggi), duduk ~90° (rendah)
            return bestKneeAngle(p)
        case .stepUp:
            // Tinggi pinggul: naik platform -> y mengecil -> nilai membesar
            guard let hipY = bestVisibleY(p, left: 23, right: 24) else { return nil }
            return 1.0 - hipY
        case .calfRaise:
            // Selisih tinggi tumit vs ujung kaki, dinormalisasi panjang betis
            return calfRaiseMetric(p)
        }
    }

    // Metrik calf raise: (toeY - heelY) / panjang betis
    // Rata: tumit & toe sama tinggi -> ~0. Jinjit: tumit naik -> nilai membesar.
    private func calfRaiseMetric(_ p: [NormalizedLandmark]) -> Double? {
        let useLeft = visibility(p, 27) >= visibility(p, 28)
        let ankleI = useLeft ? 27 : 28
        let kneeI  = useLeft ? 25 : 26
        let heelI  = useLeft ? 29 : 30
        let toeI   = useLeft ? 31 : 32
        guard ankleI < p.count, kneeI < p.count, heelI < p.count, toeI < p.count else { return nil }
        // Ankle & knee harus terlihat (untuk skala).
        guard visibility(p, ankleI) >= visibilityThreshold,
              visibility(p, kneeI)  >= visibilityThreshold else { return nil }
        // Tumit/toe boleh agak samar, tapi jangan pakai kalau benar-benar hilang
        // (kalau garbage, lebih baik nil daripada mencemari kalibrasi).
        guard max(visibility(p, heelI), visibility(p, toeI)) >= 0.3 else { return nil }

        let heelY = Double(p[heelI].y)
        let toeY  = Double(p[toeI].y)
        let shank = distance(p[ankleI], p[kneeI])   // panjang tungkai bawah sebagai skala
        guard shank > 1e-4 else { return nil }
        return (toeY - heelY) / shank
    }

    // Pilih sisi (kiri/kanan) yang lebih terlihat, lalu hitung sudut lutut
    private func bestKneeAngle(_ p: [NormalizedLandmark]) -> Double? {
        let left  = kneeAngle(p, hip: 23, knee: 25, ankle: 27)
        let right = kneeAngle(p, hip: 24, knee: 26, ankle: 28)
        switch (left, right) {
        case let (l?, r?): return visibility(p, 25) >= visibility(p, 26) ? l : r
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    private func kneeAngle(_ p: [NormalizedLandmark], hip: Int, knee: Int, ankle: Int) -> Double? {
        guard hip < p.count, knee < p.count, ankle < p.count,
              visibility(p, hip)   >= visibilityThreshold,
              visibility(p, knee)  >= visibilityThreshold,
              visibility(p, ankle) >= visibilityThreshold else { return nil }
        let a = p[hip], b = p[knee], c = p[ankle]
        let a1 = atan2(Double(a.y - b.y), Double(a.x - b.x))
        let a2 = atan2(Double(c.y - b.y), Double(c.x - b.x))
        var deg = abs(a1 - a2) * 180 / .pi
        if deg > 180 { deg = 360 - deg }
        return deg
    }

    // Ambil koordinat y dari sisi yang lebih terlihat
    private func bestVisibleY(_ p: [NormalizedLandmark], left: Int, right: Int) -> Double? {
        guard left < p.count, right < p.count else { return nil }
        let vl = visibility(p, left), vr = visibility(p, right)
        if max(vl, vr) < visibilityThreshold { return nil }
        return Double(vl >= vr ? p[left].y : p[right].y)
    }

    private func distance(_ a: NormalizedLandmark, _ b: NormalizedLandmark) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func visibility(_ p: [NormalizedLandmark], _ i: Int) -> Float {
        guard i < p.count else { return 0 }
        return p[i].visibility?.floatValue ?? 1
    }
}
