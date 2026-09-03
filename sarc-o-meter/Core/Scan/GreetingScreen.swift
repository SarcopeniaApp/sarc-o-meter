import SwiftUI

struct GreetingScreen: View {
    let onNext: () -> Void

    var body: some View {
        PageWrapper(
            title: "Selamat datang!",
            content: {
                VStack(alignment: .leading, spacing: 24) {
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

