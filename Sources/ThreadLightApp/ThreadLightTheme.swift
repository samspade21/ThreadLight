import AppKit
import SwiftUI

enum ThreadLightTheme {
    static let aubergine = Color(red: 0.26, green: 0.10, blue: 0.34)
    static let violet = Color(red: 0.49, green: 0.28, blue: 0.96)
    static let coral = Color(red: 0.98, green: 0.42, blue: 0.43)
    static let teal = Color(red: 0.12, green: 0.67, blue: 0.65)
    static let ivory = Color(red: 0.98, green: 0.96, blue: 0.92)

    // Brand colors used as foregrounds must adapt: the fixed palette is intended
    // for fills and does not maintain WCAG contrast in both appearances.
    static let accentForeground = adaptiveColor(
        name: "ThreadLightAccentForeground",
        light: NSColor(srgbRed: 0.38, green: 0.16, blue: 0.78, alpha: 1),
        dark: NSColor(srgbRed: 0.66, green: 0.52, blue: 1.00, alpha: 1)
    )
    static let successForeground = adaptiveColor(
        name: "ThreadLightSuccessForeground",
        light: NSColor(srgbRed: 0.02, green: 0.42, blue: 0.40, alpha: 1),
        dark: teal
    )
    static let dangerForeground = adaptiveColor(
        name: "ThreadLightDangerForeground",
        light: NSColor(srgbRed: 0.72, green: 0.14, blue: 0.18, alpha: 1),
        dark: coral
    )

    static let threadGradient = LinearGradient(
        colors: [violet, coral],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let ambientGradient = LinearGradient(
        colors: [aubergine.opacity(0.10), violet.opacity(0.035), .clear],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func avatarColor(for seed: String) -> Color {
        let palette = [violet, coral, teal, .indigo, .pink, .orange]
        let scalar = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(scalar) % palette.count]
    }

    private static func adaptiveColor(name: String, light: NSColor, dark: Color) -> Color {
        adaptiveColor(name: name, light: light, dark: NSColor(dark))
    }

    private static func adaptiveColor(name: String, light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct ThreadLightAppIcon: View {
    var size: CGFloat = 44

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct AmbientBackdrop: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            ThreadLightTheme.ambientGradient
            Circle()
                .fill(ThreadLightTheme.violet.opacity(0.06))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: 320, y: -260)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct ThreadLightCardModifier: ViewModifier {
    var emphasis = false

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(emphasis ? ThreadLightTheme.violet.opacity(0.32) : Color.primary.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(emphasis ? 0.10 : 0.04), radius: emphasis ? 16 : 8, y: 4)
    }
}

extension View {
    func threadLightCard(emphasis: Bool = false) -> some View {
        modifier(ThreadLightCardModifier(emphasis: emphasis))
    }
}

struct StatusOrb: View {
    let color: Color
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(color.opacity(0.28), lineWidth: 4))
            .accessibilityHidden(true)
    }
}

struct ThreadPathGlyph: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
            Capsule().fill(ThreadLightTheme.threadGradient).frame(width: 34, height: 3)
            Image(systemName: "checkmark.shield.fill").foregroundStyle(ThreadLightTheme.successForeground)
        }
        .foregroundStyle(ThreadLightTheme.accentForeground)
        .accessibilityHidden(true)
    }
}
