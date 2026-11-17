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

    /// `now=2;peak=7;finalNow=4;finalPeak=9;visible=21`
    /// `now`/`peak` are blank placeholders; `final*` still wait for full quality.
    /// Peaks are the maximum in the trailing 3 s.
    var value: String {
        _ = revision
        let now = Date()
        let recent = history.filter { now.timeIntervalSince($0.at) <= 3 }
        let blankPeak = max(recent.map(\.blank).max() ?? blank.count, blank.count)
        let finalPeak = max(recent.map(\.final).max() ?? final.count, final.count)
        return "now=\(blank.count);peak=\(blankPeak);finalNow=\(final.count);finalPeak=\(finalPeak);visible=\(visible.count)"
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
        history.append((now, blank.count, final.count))
        history.removeAll { now.timeIntervalSince($0.at) > 20 }
        revision &+= 1
    }
}

struct TileLoadProbeView: View {
    private var probe = TileLoadProbe.shared

    var body: some View {
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
