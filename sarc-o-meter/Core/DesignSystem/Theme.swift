//  Theme.swift
//
//  The visual language for the whole scan flow: a warm off-white canvas, a single
//  terracotta accent, soft white cards, and a few reusable building blocks (nav
//  header, primary/secondary buttons) so every screen looks like one product.

import SwiftUI

extension UIApplication {
    var currentWindow: UIWindow? {
        connectedScenes
            .compactMap {
                $0 as? UIWindowScene
            }
            .flatMap {
                $0.windows
            }
            .first {
                $0.isKeyWindow
            }
    }
}

extension EnvironmentValues {
    var safeAreaInsets: EdgeInsets {
        self[SafeAreaInsetsKey.self]
    }
}

private extension UIEdgeInsets {
    var swiftUiInsets: EdgeInsets {
        EdgeInsets(top: top, leading: left, bottom: bottom, trailing: right)
    }
}

private struct SafeAreaInsetsKey: EnvironmentKey {
    static var defaultValue: EdgeInsets {
        UIApplication.shared.currentWindow?.safeAreaInsets.swiftUiInsets ?? EdgeInsets()
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint = .zero
    
    static func reduce(value: inout CGPoint, nextValue: () -> CGPoint) {}
}


enum Theme {
    static let bg      = Color(red: 0.961, green: 0.949, blue: 0.937)   // warm off-white
    static let card    = Color.white
    static let accent  = Color(red: 0.737, green: 0.486, blue: 0.373)   // terracotta
    static let ink     = Color(red: 0.122, green: 0.114, blue: 0.106)   // near-black text
    static let muted   = Color(red: 0.545, green: 0.525, blue: 0.506)   // subtitles
    static let faint   = Color(red: 0.835, green: 0.820, blue: 0.800)   // the "000" gray

    static var accentSoft: Color { accent.opacity(0.12) }

    static let corner: CGFloat = 20
    static let cardShadow = Color.black.opacity(0.05)
    static let keyShadow  = Color.black.opacity(0.04)
}

// MARK: - Nav header (back button + optional centered title)

struct NavHeader: View {
    var title: String? = nil
    var onBack: (() -> Void)? = nil

    var body: some View {
        ZStack {
            if let title {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 46, height: 46)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                            .shadow(color: Theme.cardShadow, radius: 8, y: 4)
                    }
                }
                Spacer()
            }
        }
        .frame(height: 46)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}

// MARK: - Buttons

/// Filled terracotta call-to-action.
struct PrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 15, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(enabled ? Theme.accent : Theme.faint,
                            in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(!enabled)
    }
}

/// Outlined secondary action (e.g. "Rescan").
struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 15, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
                )
        }
    }
}

// MARK: - Screen title block (big heading + subtitle)

struct ScreenTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Subtitle: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PageWrapper<Content: View, Footer: View>: View {
    @Environment(\.safeAreaInsets) private var safeAreaInsets
    
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer?
    
    private let onBack: (() -> Void)?
    private let title: String
    private let scrollable: Bool
    
    @State private var scrollState = (CGFloat(0.0), CGFloat(0.95))
    @State private var scroll: CGPoint = .zero
    
    private let VPW = UIScreen.main.bounds.size.width
    private let VPH = UIScreen.main.bounds.size.height
    
    init(
        title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer,
        onBack: (() -> Void)? = nil
    ) {
        self.content = content()
        self.footer = footer()
        self.onBack = onBack
        self.scrollable = true
        self.title = title
    }
    
    init(
        title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer = { EmptyView() },
        scrollable: Bool = true,
        onBack: (() -> Void)? = nil
    ) {
        self.content = content()
        self.footer = nil
        self.scrollable = scrollable
        self.onBack = onBack
        self.title = title
    }
    
    var scrollPassed: Bool {
        if scroll.y <= -24 {
            return true
        } else {
            return false
        }
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            if self.scrollable {
                ScrollView {
                    LazyVStack(spacing: 24) {
                        HStack {
                            Text(title)
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Spacer()
                        }
                        .zIndex(2)
                        
                        self.content
                    }
                    .padding(EdgeInsets(top: 84, leading: 24, bottom: footer != nil ? 96 : 24, trailing: 24))
                    .background(GeometryReader { geometry in
                        Color.clear
                            .preference(key: ScrollOffsetPreferenceKey.self, value: geometry.frame(in: .named("scroll")).origin)
                    })
                    .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                        self.scroll = value
                    }
                }
                .frame(alignment: .topLeading)
                .background(Theme.bg.ignoresSafeArea())
                .coordinateSpace(name: "scroll")
            } else {
                VStack(spacing: 24) {
                    HStack {
                        Text(title)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer()
                    }
                    .zIndex(2)
                    
                    self.content
                }
                .padding(EdgeInsets(top: 84, leading: 24, bottom: 24, trailing: 24))
                .frame(alignment: .topLeading)
                .background(Theme.bg.ignoresSafeArea())
                .coordinateSpace(name: "scroll")
            }
            
            ZStack {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .opacity(scrollState.0)
                    .scaleEffect(scrollState.1)
                HStack {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 48, height: 48)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                                .shadow(color: Theme.cardShadow, radius: 8, y: 4)
                        }
                    }
                    Spacer()
                }
            }
            .padding(EdgeInsets(top: safeAreaInsets.top + 12, leading: 24, bottom: 24, trailing: 24))
            .frame(width: self.VPW)
            .background(
                Rectangle()
                    .fill(Theme.card)
                    .opacity(scrollState.0)
            )
            .ignoresSafeArea()
            
            if let footer = self.footer {
                VStack(spacing: 0) {
                    Spacer()
                    ZStack {
                        VStack(alignment: .leading, spacing: 12) {
                            footer
                        }
                        .frame(height: 48)
                    }
                    .padding(EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24))
                    .background(
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(Theme.card)
                                .opacity(scrollState.0)
                        }
                        .ignoresSafeArea()
                    )
                }
            }
        }
        .frame(width: VPW, alignment: .topLeading)
        .navigationBarBackButtonHidden(true)
        .onChange(of: self.scrollPassed) {
            if self.scrollPassed {
                withAnimation(.spring(duration: 0.25)) {
                    self.scrollState = (CGFloat(1), CGFloat(1))
                }
            } else {
                withAnimation(.spring(duration: 0.25)) {
                    self.scrollState = (CGFloat(0), CGFloat(0.95))
                }
            }
        }
    }
}
