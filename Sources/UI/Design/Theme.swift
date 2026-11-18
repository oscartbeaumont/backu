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

    /// Keeps scrolled content from colliding with the status bar on the
    /// custom large-title screens, which hide the navigation bar.
    func topScrollScrim() -> some View {
        overlay(alignment: .top) {
            LinearGradient(
                colors: [Theme.systemBackground, Theme.systemBackground.opacity(0.92), Theme.systemBackground.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 78)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
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

// MARK: - Motion

/// `withAnimation`, but applied instantly when Reduce Motion is on, so a state
/// change still lands and only the travel between the two states is dropped.
/// Pass the view's `@Environment(\.accessibilityReduceMotion)` value.
@discardableResult
func withRespectingReduceMotion<Result>(
    _ animation: Animation,
    when reduceMotion: Bool,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(reduceMotion ? nil : animation, body)
}

// MARK: - Dynamic Type

/// A system font that keeps a design's exact point size at the default text
/// size, then grows with the user's Dynamic Type setting. A fixed-size SwiftUI
/// font pins the size, so a person who asks for larger text still gets small text.
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var points: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo textStyle: Font.TextStyle) {
        _points = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(PlatformFont.make(size: points, weight: weight, design: design))
    }
}

extension View {
    /// Use in place of a fixed-size font so custom point sizes scale with
    /// Dynamic Type. `relativeTo` chooses the text style whose growth curve
    /// applies, and body text is the right default for interface copy.
    func scaledFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design, relativeTo: textStyle))
    }
}

/// SwiftUI only offers arbitrary point sizes through the platform font types,
/// so the two are bridged here once instead of at every call site.
private enum PlatformFont {
    static func make(size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
        #if canImport(UIKit)
        var font = UIFont.systemFont(ofSize: size, weight: weight.uiWeight)
        if let design = design.uiDesign, let descriptor = font.fontDescriptor.withDesign(design) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return Font(font)
        #else
        var font = NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
        if let design = design.nsDesign, let descriptor = font.fontDescriptor.withDesign(design) {
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return Font(font)
        #endif
    }
}

private extension Font.Weight {
    #if canImport(UIKit)
    var uiWeight: UIFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
    #else
    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
    #endif
}

private extension Font.Design {
    #if canImport(UIKit)
    var uiDesign: UIFontDescriptor.SystemDesign? {
        switch self {
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        default: return nil
        }
    }
    #else
    var nsDesign: NSFontDescriptor.SystemDesign? {
        switch self {
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        default: return nil
        }
    }
    #endif
}

/// The namespace shared by every grid tile and the viewer, so whichever screen
/// pushed the viewer can zoom back into the tile it came from.
private struct ViewerZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

/// False for the tabs that are not on screen, so a photo that exists in both
/// the library and the search results only registers one transition source.
private struct ViewerZoomSourceActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var viewerZoomNamespace: Namespace.ID? {
        get { self[ViewerZoomNamespaceKey.self] }
        set { self[ViewerZoomNamespaceKey.self] = newValue }
    }

    var viewerZoomSourceActive: Bool {
        get { self[ViewerZoomSourceActiveKey.self] }
        set { self[ViewerZoomSourceActiveKey.self] = newValue }
    }
}

extension View {
    /// Marks a grid tile as the source of the viewer's zoom transition.
    @ViewBuilder
    func zoomTransitionSource(id: String, in namespace: Namespace.ID?) -> some View {
        #if os(iOS)
        if let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Expands a pushed viewer out of (and back into) the tile it came from.
    /// Reduce Motion falls back to the system's default push.
    @ViewBuilder
    func viewerZoomTransition(id: String, in namespace: Namespace.ID?, reduceMotion: Bool) -> some View {
        #if os(iOS)
        if let namespace, !reduceMotion {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
