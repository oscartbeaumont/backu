#if DEBUG
import QuartzCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
/// Lightweight frame-pacing sampler for the scroll benchmark. Enabled by
/// `BACKU_PROBE=1` (the same switch as `TileLoadProbe`); it keeps a two-second
/// window so the harness can read the stats right after a fling.
@MainActor
@Observable
final class FrameTimeProbe {
    static let shared = FrameTimeProbe()

    private struct Sample {
        var at: CFTimeInterval
        var duration: Double
        var expected: Double
    }

    @MainActor
    private final class DisplayLinkTarget: NSObject {
        weak var probe: FrameTimeProbe?
        init(probe: FrameTimeProbe) { self.probe = probe }

        @objc func tick(_ link: CADisplayLink) {
            probe?.tick(link)
        }
    }

    private(set) var revision = 0
    private var samples: [Sample] = []
    private var link: CADisplayLink?
    private var target: DisplayLinkTarget?
    private var lastTimestamp: CFTimeInterval = 0
    /// Publishing at display rate would make the probe view re-evaluate ~120
    /// times/s and pollute the very frame timing it measures. Four updates a
    /// second is plenty for the test reader (which sleeps before reading).
    private var lastPublish: CFTimeInterval = 0

    var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BACKU_PROBE"] == "1"
    }

    func start() {
        guard isEnabled, link == nil else { return }
        let target = DisplayLinkTarget(probe: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.target = target
        self.link = link
        lastTimestamp = 0
        lastPublish = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
        target = nil
        lastTimestamp = 0
        lastPublish = 0
        samples.removeAll()
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let expected = max(link.targetTimestamp - link.timestamp, 0.001)
        defer { lastTimestamp = now }
        guard lastTimestamp > 0 else { return }
        samples.append(Sample(at: now, duration: now - lastTimestamp, expected: expected))
        if samples.count > 600 {
            samples.removeFirst(samples.count - 600)
        }
        if now - lastPublish >= 0.25 {
            lastPublish = now
            revision &+= 1
        }
    }

    /// `frames=120;dropped=3;worst=34.2;avg=16.9` over the trailing two
    /// seconds. A frame is "dropped" when it missed its deadline by 50 %.
    var value: String {
        _ = revision
        let now = CACurrentMediaTime()
        let recent = samples.filter { now - $0.at <= 2.0 }
        guard !recent.isEmpty else { return "frames=0;dropped=0;worst=0;avg=0" }
        let durations = recent.map(\.duration)
        let dropped = recent.filter { $0.duration > $0.expected * 1.5 }.count
        let worst = durations.max() ?? 0
        let avg = durations.reduce(0, +) / Double(durations.count)
        return String(
            format: "frames=%d;dropped=%d;worst=%.1f;avg=%.1f",
            recent.count,
            dropped,
            worst * 1000,
            avg * 1000
        )
    }
}
#else
/// macOS has no `CADisplayLink`; the scroll harness is iOS-only, so this is a
/// no-op there. Keeping the same API lets the library build on both platforms.
@MainActor
@Observable
final class FrameTimeProbe {
    static let shared = FrameTimeProbe()

    var isEnabled: Bool { false }
    func start() {}
    func stop() {}
    var value: String { "frames=0;dropped=0;worst=0;avg=0" }
}
#endif

/// Records the pixel width of final thumbnails as tiles draw them. The timeline
/// pinch test uses this to prove a density change actually reloaded the bitmap
/// (the tile's *frame* gets wider even if the old image is only upscaled).
@MainActor
@Observable
final class LibraryImageProbe {
    static let shared = LibraryImageProbe()

    private struct Sample {
        var at: CFTimeInterval
        var density: Int
        var imageWidth: Int
    }

    private(set) var revision = 0
    /// Samples and the throttling state are deliberately not observable: a
    /// final thumbnail must not invalidate the probe view on every tile.
    /// `revision` is published at most four times a second (with a trailing
    /// publish so the last load is never lost), which is ample for the test's
    /// multi-second read.
    @ObservationIgnored private var samples: [Sample] = []
    @ObservationIgnored private var lastPublish: CFTimeInterval = 0
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    /// Records the density a tile actually requested for its final image. The
    /// requested size is the meaningful signal for the pinch test: a bitmap's
    /// own width can vary with the photo's aspect ratio.
    func recordFinal(_ image: PlatformImage, targetSize: CGSize) {
        // Always on in DEBUG: the timeline pinch test needs it, and it only
        // appends one small sample per final thumbnail.
        let density = Int(targetSize.width.rounded())
        guard density > 0 else { return }
        let now = CACurrentMediaTime()
        samples.append(Sample(
            at: now,
            density: density,
            imageWidth: Self.pixelWidth(of: image)
        ))
        if samples.count > 400 {
            samples.removeFirst(samples.count - 400)
        }
        publish(at: now)
    }

    private func publish(at now: CFTimeInterval) {
        if now - lastPublish >= 0.25 {
            lastPublish = now
            revision &+= 1
            return
        }
        guard publishTask == nil else { return }
        let delay = max(0, 0.25 - (now - lastPublish))
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000) + 10))
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            self.lastPublish = CACurrentMediaTime()
            self.revision &+= 1
        }
    }

    /// `width=402;image=402;widths=402,1206;count=12;last=1206;age=0.4`
    ///
    /// `width` is the largest requested density in the trailing six seconds
    /// (which a density change raises), `last` is the most recent one and
    /// `age` is how long ago it was recorded. Exposing freshness means a
    /// caller can tell "no load happened" from "the window has expired"
    /// instead of reading a stale zero.
    var value: String {
        _ = revision
        let now = CACurrentMediaTime()
        let recent = samples.filter { now - $0.at <= 6.0 }
        let widths = Set(recent.map(\.density)).sorted().prefix(6).map(String.init).joined(separator: ",")
        let lastSample = samples.last
        let last = lastSample?.density ?? 0
        let age = lastSample.map { now - $0.at } ?? 0
        return String(
            format: "width=%d;image=%d;widths=%@;count=%d;last=%d;age=%.1f",
            recent.map(\.density).max() ?? 0,
            recent.map(\.imageWidth).max() ?? 0,
            widths,
            recent.count,
            last,
            age
        )
    }

    private static func pixelWidth(of image: PlatformImage) -> Int {
        #if canImport(UIKit)
        return Int((image.size.width * image.scale).rounded())
        #else
        if let pixels = image.representations.first?.pixelsWide, pixels > 0 { return pixels }
        return Int(image.size.width.rounded())
        #endif
    }
}

/// Hidden accessibility elements the UI tests read. Place one per screen,
/// outside any scroll content so it cannot affect layout.
struct LibraryRuntimeProbeView: View {
    var monthPillHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            probe(
                label: "Frame time probe",
                identifier: "perf.frames",
                value: FrameTimeProbe.shared.value
            )
            probe(
                label: "Image size probe",
                identifier: "perf.imageSize",
                value: LibraryImageProbe.shared.value
            )
            probe(
                label: "Month pill probe",
                identifier: "perf.monthPill",
                value: "\(Int(monthPillHeight.rounded()))"
            )
        }
        .onAppear { FrameTimeProbe.shared.start() }
        .onDisappear { FrameTimeProbe.shared.stop() }
    }

    private func probe(label: String, identifier: String, value: String) -> some View {
        Color.white.opacity(0.01)
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(false)
    }
}

/// Height of the date capsule over a timeline card, in points. A positive
/// signal for the large-type test: if the text-size override silently did not
/// apply, the height stays small and the test fails instead of passing
/// vacuously.
struct MonthPillHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// `BACKU_UI_TEXT_SIZE` applies a Dynamic Type category to the library subtree
/// from a launch environment variable. The `-UIPreferredContentSizeCategoryName`
/// launch argument is not reliably applied by the test runner, so the large-type
/// coverage must not depend on it alone.
enum LibraryDebugTextSize {
    static var value: DynamicTypeSize? {
        guard let raw = ProcessInfo.processInfo.environment["BACKU_UI_TEXT_SIZE"] else { return nil }
        switch raw.lowercased() {
        case "large": return .large
        case "xlarge": return .xLarge
        case "xxlarge": return .xxLarge
        case "xxxlarge": return .xxxLarge
        case "accessibility1": return .accessibility1
        case "accessibility2": return .accessibility2
        case "accessibility3": return .accessibility3
        case "accessibility4": return .accessibility4
        case "accessibility5": return .accessibility5
        default: return nil
        }
    }
}

struct DebugTextSizeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if let size = LibraryDebugTextSize.value {
            content.dynamicTypeSize(size)
        } else {
            content
        }
    }
}
#endif
