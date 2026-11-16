import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum Theme {
    static let accent = Color(hex: 0x2F6BF6)
    static let accentDeep = Color(hex: 0x0A47C9)
    static let mint = Color(hex: 0x34C6A5)
    static let cardRadius: CGFloat = 22
    static let tileRadius: CGFloat = 4

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x3E7BFF), Color(hex: 0x2F6BF6), Color(hex: 0x0A47C9)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var systemBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var cardFill: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var pageBackground: some View {
        ZStack {
            systemBackground
            LinearGradient(
                colors: [accent.opacity(0.10), .clear, mint.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension View {
    /// Liquid Glass surface with a consistent corner radius.
    @ViewBuilder
    func glassSurface(
        _ radius: CGFloat = Theme.cardRadius,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        let glass = tint.map { Glass.regular.tint($0) } ?? .regular
        self.glassEffect(glass.interactive(interactive), in: .rect(cornerRadius: radius))
    }

    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        let glass = tint.map { Glass.regular.tint($0) } ?? .regular
        self.glassEffect(glass.interactive(interactive), in: .capsule)
    }

    /// A solid content surface. Liquid Glass belongs to the floating chrome,
    /// not to stacked content cards.
    func contentCard(radius: CGFloat = 18) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    func cardShadow() -> some View {
        shadow(color: .black.opacity(0.06), radius: 18, y: 6)
    }

    @ViewBuilder
    func hideListBackground() -> some View {
        #if os(iOS)
        self.scrollContentBackground(.hidden)
        #else
        self
        #endif
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

extension Animation {
    static var backuSnappy: Animation { .snappy(duration: 0.28, extraBounce: 0.02) }
    static var backuGentle: Animation { .smooth(duration: 0.35) }
}
