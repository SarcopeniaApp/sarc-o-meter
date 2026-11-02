import SwiftUI

struct GreetingScreen: View {
    var llm: LLMManager
    let onNext: () -> Void

    var body: some View {
        PageWrapper(
            title: "Selamat datang!",
            content: {
                VStack(alignment: .leading, spacing: 20) {
                    LLMDownloadCard(llm: llm)

                    Subtitle("Untuk membantu kami mendapatkan hasil screening paling akurat, kami membutuhkan beberapa informasi tentang Anda.")
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Privasi Anda terjaga", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.green)
                        
                        Text("Tenang, semua informasi ini hanya akan berada di perangkat Anda, dan tidak akan dikirim ke pihak lain.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.corner))
                }
            },
            footer: {
                PrimaryButton(title: "Mulai", action: onNext)
            }
        )
    }
}

struct LLMDownloadCard: View {
    var llm: LLMManager

    var body: some View {
        let isDone = llm.isDownloaded || llm.isLoaded
        let rawPercent = Int(round(min(1.0, max(0.0, llm.progressValue)) * 100))
        // Cap at 99% while downloading/loading weights so 100% is only shown when truly finished and green
        let percentage = isDone ? 100 : (llm.downloadedMB > 0 ? max(1, min(99, rawPercent)) : 0)

        VStack(alignment: .leading, spacing: 14) {
            // Header: Icon + Model Name + Size Badge
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isDone ? Color.green.opacity(0.12) : Theme.accent.opacity(0.12))
                        .frame(width: 40, height: 40)

                    if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.green)
                    } else if llm.isLoading {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    } else if llm.lastError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "cpu")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(llm.modelName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Text(llm.modelSize)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.faint.opacity(0.4), in: Capsule())
                    }

                    Text(isDone ? "Model AI on-device siap digunakan" : (rawPercent >= 99 ? "Memuat model ke memori…" : "Mengunduh komponen model…"))
                        .font(.system(size: 12))
                        .foregroundStyle(isDone ? .green : Theme.muted)
                }
            }

            // Progress bar and Percentage
            VStack(spacing: 6) {
                HStack {
                    if isDone {
                        Text("Selesai diunduh")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    } else if llm.downloadedMB > 0 {
                        Text(String(format: "Downloading… %.0f / %.0f MB", min(llm.downloadedMB, llm.totalMB), llm.totalMB))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    } else {
                        Text("Downloading…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                    }

                    Spacer()

                    Text("\(percentage)%")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isDone ? .green : Theme.accent)
                        .monospacedDigit()
                }

                GeometryReader { geo in
                    let totalWidth = geo.size.width
                    let activeFraction = isDone ? 1.0 : min(0.99, max(0.0, llm.progressValue))
                    let fillWidth = isDone ? totalWidth : max(0, min(totalWidth, totalWidth * CGFloat(activeFraction)))

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(red: 0.90, green: 0.89, blue: 0.88))
                            .frame(width: totalWidth, height: 6)

                        if fillWidth > 0 {
                            Capsule()
                                .fill(isDone ? Color.green : Theme.accent)
                                .frame(width: fillWidth, height: 6)
                                .animation(.linear(duration: 0.15), value: llm.progressValue)
                        }
                    }
                }
                .frame(height: 6)
            }

            if let err = llm.lastError, !isDone {
                HStack {
                    Text("Gagal: \(err)")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Coba Lagi") {
                        Task { await llm.loadModel() }
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))
        .shadow(color: Theme.cardShadow, radius: 8, y: 4)
    }
}
