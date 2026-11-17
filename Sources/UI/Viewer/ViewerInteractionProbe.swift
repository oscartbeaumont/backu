#if DEBUG
import Darwin
import Observation
import SwiftUI

/// Debug-only readout of the viewer's live gesture state. The UI tests use it
/// to assert that a page actually advanced, that a double-tap zoomed toward the
/// tap point, that panning never left the image bounds, and that opening the
/// viewer does not build (or keep) a controller and image for every photo in
/// the roll. Enabled by `BACKU_PROBE=1`; release builds do not contain it.
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
    /// Page controllers that currently exist, and the wall time page setup and
    /// the pager's first layout blocked the main thread for. Both are how the
    /// tests prove the viewer no longer builds a controller per photo on open.
    private(set) var livePages = 0
    private(set) var setupMilliseconds: Double = 0
    private(set) var layoutMilliseconds: Double = 0
    /// Worst main-thread frame interval while the viewer has been on screen,
    /// and how many frames took longer than two display refreshes. A display
    /// link samples these, so an expensive open or page change shows up as
    /// dropped frames rather than an opinion.
    private(set) var worstFrameMilliseconds: Double = 0
    private(set) var droppedFrames = 0
    /// Finger-down to chrome-toggle latency of the last single tap. Pins down
    /// that a tap reacts immediately instead of waiting out the double tap.
    private(set) var tapMilliseconds: Double = 0
    private(set) var revision = 0

    var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BACKU_PROBE"] == "1"
    }

    func pageChanged(_ index: Int, count: Int) {
        pageIndex = index
        pageCount = count
        sampleFootprint()
        revision &+= 1
    }

    func pagesBuilt(count: Int, milliseconds: Double) {
        livePages = count
        setupMilliseconds = milliseconds
        revision &+= 1
    }

    func frame(duration: Double) {
        // Only touch the observable graph when the readout actually changes:
        // bumping `revision` every frame would re-render the probe view 60
        // times a second and pollute the measurement it exists to take.
        var changed = false
        if duration > worstFrameMilliseconds {
            worstFrameMilliseconds = duration
            changed = true
        }
        if duration > 34 {
            droppedFrames += 1
            changed = true
        }
        if changed { revision &+= 1 }
    }

    func pagesLaidOut(milliseconds: Double) {
        layoutMilliseconds = milliseconds
        revision &+= 1
    }

    func residentPages(_ count: Int) {
        livePages = count
        revision &+= 1
    }

    func tapLatency(milliseconds: Double) {
        tapMilliseconds = milliseconds
        revision &+= 1
    }

    func zoomChanged(scale: CGFloat, centerX: CGFloat, centerY: CGFloat, overpan: CGFloat) {
        self.scale = scale
        self.centerX = centerX
        self.centerY = centerY
        self.overpan = overpan
        revision &+= 1
    }

    /// The app's physical footprint in megabytes, sampled when the page changes.
    /// Paging the whole roll must not grow it without bound.
    private(set) var footprintMB: Double = 0

    func sampleFootprint() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        footprintMB = Double(info.phys_footprint) / 1_048_576
    }

    /// `page=4/27;scale=2.50;cx=0.79;cy=0.45;over=0.0;live=5;setup=3.1ms;layout=0.4ms;worst=16.7ms;drops=0;tap=83ms;mem=142.3MB`
    var value: String {
        _ = revision
        return String(
            format: "page=%d/%d;scale=%.2f;cx=%.3f;cy=%.3f;over=%.1f;live=%d;setup=%.1fms;layout=%.1fms;worst=%.1fms;drops=%d;tap=%.0fms;mem=%.1fMB",
            pageIndex + 1,
            pageCount,
            scale,
            centerX,
            centerY,
            overpan,
            livePages,
            setupMilliseconds,
            layoutMilliseconds,
            worstFrameMilliseconds,
            droppedFrames,
            tapMilliseconds,
            footprintMB
        )
    }
}

struct ViewerInteractionProbeView: View {
    private var probe = ViewerInteractionProbe.shared

    var body: some View {
        if probe.isEnabled {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Viewer interaction probe")
                .accessibilityValue(probe.value)
                .accessibilityIdentifier("viewer.probe")
                .allowsHitTesting(false)
        }
    }
}
#endif
