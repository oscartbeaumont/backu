#if DEBUG
import Foundation
import Observation
import SwiftUI

/// Debug-only counter used by the scroll benchmark. It separates *blank* tiles
/// (nothing painted yet) from tiles still waiting for their final image, and
/// keeps a short history so the test can read a transient peak after the UI
/// settles (XCUITest queries wait for quiescence, which hides placeholders from
/// a plain count).
///
/// Enabled by `BACKU_PROBE=1`; release builds do not contain it.
@MainActor
@Observable
final class TileLoadProbe {
    static let shared = TileLoadProbe()

    private(set) var revision = 0
    private var blank: Set<String> = []
    private var final: Set<String> = []
    private var visible: Set<String> = []
    private var history: [(at: Date, blank: Int, final: Int)] = []
    /// Cumulative maxima since launch. The trailing `peak` is what the fling
    /// assertions use; these preserve the cold-start measurement, which can
    /// legitimately fall outside the 3 s window by the time a test reads it.
    private var coldBlankPeak = 0
    private var coldFinalPeak = 0

    var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BACKU_PROBE"] == "1"
    }

    func appeared(_ id: String, blank isBlank: Bool, final isFinal: Bool) {
        guard isEnabled else { return }
        visible.insert(id)
        set(id, blank: isBlank && !isFinal, final: !isFinal)
    }

    /// A degraded (or cached) image painted, but the final is still coming.
    func painted(_ id: String) {
        guard isEnabled else { return }
        set(id, blank: false, final: final.contains(id))
    }

    func finished(_ id: String) {
        guard isEnabled else { return }
        set(id, blank: false, final: false)
    }

    func disappeared(_ id: String) {
        guard isEnabled else { return }
        visible.remove(id)
        set(id, blank: false, final: false)
    }

    /// `now=2;peak=7;finalNow=4;finalPeak=9;visible=21;coldPeak=33`
    /// `now`/`peak` are blank placeholders; `final*` still wait for full quality.
    /// Peaks are the maximum in the trailing 3 s; `coldPeak` is cumulative.
    var value: String {
        _ = revision
        let now = Date()
        let recent = history.filter { now.timeIntervalSince($0.at) <= 3 }
        let blankPeak = max(recent.map(\.blank).max() ?? blank.count, blank.count)
        let finalPeak = max(recent.map(\.final).max() ?? final.count, final.count)
        return "now=\(blank.count);peak=\(blankPeak);finalNow=\(final.count);finalPeak=\(finalPeak);visible=\(visible.count);coldPeak=\(coldBlankPeak);coldFinalPeak=\(coldFinalPeak)"
    }

    private func set(_ id: String, blank isBlank: Bool, final isFinal: Bool) {
        var changed = false
        if isBlank {
            changed = blank.insert(id).inserted || changed
        } else {
            changed = blank.remove(id) != nil || changed
        }
        if isFinal {
            changed = final.insert(id).inserted || changed
        } else {
            changed = final.remove(id) != nil || changed
        }
        guard changed else { return }
        let now = Date()
        coldBlankPeak = max(coldBlankPeak, blank.count)
        coldFinalPeak = max(coldFinalPeak, final.count)
        history.append((now, blank.count, final.count))
        history.removeAll { now.timeIntervalSince($0.at) > 20 }
        revision &+= 1
    }
}

struct TileLoadProbeView: View {
    private var probe = TileLoadProbe.shared

    var body: some View {
        Group {
            if probe.isEnabled {
                // `value` is only recomputed when the view body runs. Without a
                // refresh, the trailing peak froze at its last value once every
                // tile settled (and stayed frozen through a fling that realized
                // no new tiles, as on a small library). A low-frequency
                // `TimelineView` re-evaluates the value so the 3 s window
                // genuinely decays; it only ticks while the probe is enabled.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    element
                }
            } else {
                element
            }
        }
    }

    private var element: some View {
        Color.white.opacity(0.01)
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tile loading probe")
            .accessibilityValue(probe.value)
            .accessibilityIdentifier("perf.probe")
            .allowsHitTesting(false)
    }
}
#endif
