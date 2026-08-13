//  NumericPadScreen.swift
//
//  The custom number-entry screen from the mockup, used for BOTH height and
//  weight (same component, different labels). A fixed three-digit display whose
//  leading zeros stay greyed until you type over them ("001" → "016" → "165"),
//  the unit in terracotta, and a 3×4 pad whose bottom-right key is the terracotta
//  "next" arrow (disabled until you've entered something).

import SwiftUI

struct NumericPadScreen: View {
    @Binding var value: Int
    
    var title: String   // manual-entry screens override with the measurement name
    let subtitle: String
    let unit: String        // e.g. "cm" / "kg"
    var onBack: (() -> Void)? = nil
    let onNext: () -> Void
    
    init(title: String = "Pindai Tubuh", subtitle: String = "", unit: String = "cm", value: Binding<Int> = Binding.constant(0), onBack: (() -> Void)? = nil, onNext: @escaping () -> Void) {
        self._value = value
        self.onBack = onBack
        self.onNext = onNext
        
        self.title = title
        self.subtitle = subtitle
        self.unit = unit
    }

    private let maxValue = 999   // three digits is plenty for cm and kg

    var body: some View {
        PageWrapper(
            title: title,
            content: {
                VStack(alignment: .leading, spacing: 0) {
                    Subtitle(subtitle)
                    
                    display
                        .padding(.top, 24)
                    
                    Spacer(minLength: 20)
                    
                    keypad
                }
            },
            scrollable: false,
            onBack: onBack
        )
    }

    // MARK: Big number + units

    private var display: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Fixed three digits: leading zeros stay greyed, typed digits go dark.
            HStack(spacing: 0) {
                ForEach(Array(digits.enumerated()), id: \.offset) { i, ch in
                    Text(String(ch))
                        .foregroundStyle(i < greyCount ? Theme.faint : Theme.ink)
                }
            }
            .monospaced(true)
            .font(.system(size: 68, weight: .bold, design: .rounded))
            .animation(.snappy(duration: 0.15), value: value)

            Text(unit)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
    }

    private var digits: String { String(format: "%03d", value) }
    private var greyCount: Int { value == 0 ? 3 : 3 - String(value).count }

    // MARK: Keypad

    private enum Key: Equatable { case digit(Int), clear, next }

    private let rows: [[Key]] = [
        [.digit(7), .digit(8), .digit(9)],
        [.digit(4), .digit(5), .digit(6)],
        [.digit(1), .digit(2), .digit(3)],
        [.clear,    .digit(0), .next],
    ]

    private var keypad: some View {
        VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 12) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in
                        keyView(key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: Key) -> some View {
        switch key {
        case .digit(let n):
            padButton { press(n) } label: {
                Text("\(n)")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.ink)
            }
        case .clear:
            padButton { value = 0 } label: {
                Text("C")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        case .next:
            Button {
                if value > 0 { onNext() }
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 74)
                    .background(value > 0 ? Theme.accent : Theme.faint,
                                in: RoundedRectangle(cornerRadius: 20))
            }
            .disabled(value == 0)
        }
    }

    private func padButton<Content: View>(
        _ action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: 74)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
                .shadow(color: Theme.keyShadow, radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    private func press(_ n: Int) {
        let next = value * 10 + n
        if next <= maxValue { value = next }
    }
}
