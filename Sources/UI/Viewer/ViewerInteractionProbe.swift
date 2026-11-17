#if DEBUG
import Observation
import SwiftUI

/// Debug-only readout of the viewer's live gesture state. The UI tests use it
/// to assert that a page actually advanced, that a double-tap zoomed toward the
/// tap point, and that panning never left the image bounds. Enabled by
/// `BACKU_PROBE=1`; release builds do not contain it.
@MainActor
@Observable
final class ViewerInteractionProbe {
    static let shared = ViewerInteractionProbe()

    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    private(set) var scale: CGFloat = 1
    private(set) var centerX: CGFloat = 0.5
    private(set) var centerY: CGFloat = 0.5
    private(set) var overpan: CGFloat = 0
    private(set) var revision = 0

    var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BACKU_PROBE"] == "1"
    }

    func pageChanged(_ index: Int, count: Int) {
        pageIndex = index
        pageCount = count
        revision &+= 1
    }

    func zoomChanged(scale: CGFloat, centerX: CGFloat, centerY: CGFloat, overpan: CGFloat) {
        self.scale = scale
        self.centerX = centerX
        self.centerY = centerY
        self.overpan = overpan
        revision &+= 1
    }

    /// `page=4/27;scale=2.50;cx=0.79;cy=0.45;over=0.0`
    var value: String {
        _ = revision
        return String(
            format: "page=%d/%d;scale=%.2f;cx=%.3f;cy=%.3f;over=%.1f",
            pageIndex + 1,
            pageCount,
            scale,
            centerX,
            centerY,
            overpan
        )
    }
}

struct ViewerInteractionProbeView: View {
    private var probe = ViewerInteractionProbe.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Viewer interaction probe")
            .accessibilityValue(probe.value)
            .accessibilityIdentifier("viewer.probe")
            .allowsHitTesting(false)
    }
}
#endif
