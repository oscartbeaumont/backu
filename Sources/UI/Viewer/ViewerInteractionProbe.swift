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
        // The live readout only. Run summaries are recorded from the page's
        // `scrollViewDidZoom`, so an `updateProbe` (page settle, image sharpen,
        // layout) can never append to or close a pinch run.
        self.scale = scale
        self.centerX = centerX
        self.centerY = centerY
        self.overpan = overpan
        revision &+= 1
    }

    /// One tick of a pinch: what the zoom read, where the photo's centre sat in
    /// the viewport (0.5, 0.5 is centred) and what insets the scroll view had.
    private struct ZoomSample {
        var scale: CGFloat
        var centre: CGPoint
        var inset: CGSize
    }

    /// Every tick a single pinch reported, plus the shape of that run: how many
    /// ticks sampled, how far the scale travelled, the largest jump between two
    /// ticks, how many ticks moved against the pinch's direction, how many
    /// ticks rewrote the scroll view's inset, and how far the photo's centre
    /// wandered from the middle of the viewport.
    ///
    /// A zoom that travels in visible steps (the old layout reassigned
    /// `contentInset` on every tick, which rewrote the content offset under the
    /// fingers) shows up here as a large tick step, a reversal, or inset
    /// writes; a pinch that is read continuously is a monotonic ramp with small
    /// steps and no inset changes. Only DEBUG builds record this, and only
    /// while a pinch is running, so it never touches the observable graph
    /// during normal scrolling.
    private(set) var zoomSampleCount = 0
    private(set) var zoomSpan: CGFloat = 0
    private(set) var zoomLargestStep: CGFloat = 0
    private(set) var zoomBackSteps = 0
    private(set) var zoomRuns = 0
    private(set) var zoomFirst: CGFloat = 0
    private(set) var zoomLast: CGFloat = 0
    private(set) var zoomLow: CGFloat = 0
    private(set) var zoomHigh: CGFloat = 0
    private(set) var zoomInsetWrites = 0
    private(set) var zoomCentreDrift: CGFloat = 0
    private(set) var zoomCentreStep: CGFloat = 0
    private var zoomRunSamples: [ZoomSample] = []
    private var zoomRunLimits: ClosedRange<CGFloat> = 1...1
    private var zoomRunActive = false

    /// A pinch reports a tick per display frame; a *programmatic* zoom (the
    /// double-tap reset, a page reset when the roll moves on) opens and closes
    /// a run with only its endpoints. Those must not replace the pinch summary
    /// the tests read, or a reset after a pinch would publish a 2-sample run
    /// whose "step" is the whole zoom range.
    private let zoomRunMinimumSamples = 4

    /// Starts a fresh run: the accumulated samples and the zoom range are reset
    /// here, so nothing from a previous (or unfinished) gesture can leak into
    /// this one. The published summary is replaced by `endZoomRun` only when the
    /// run reported enough ticks (see `zoomRunMinimumSamples`), so a
    /// programmatic zoom cannot hide the pinch a test has just measured.
    /// `limits` are the scroll view's zoom range: a bounce past them is the
    /// intended rubber band, not a reversal of the gesture.
    func beginZoomRun(
        from scale: CGFloat,
        centre: CGPoint,
        inset: CGSize,
        limits: ClosedRange<CGFloat>
    ) {
        zoomRunLimits = limits
        zoomRunSamples = [ZoomSample(scale: clamped(scale), centre: centre, inset: inset)]
        zoomRunActive = true
    }

    func zoomSample(_ scale: CGFloat, centre: CGPoint, inset: CGSize) {
        guard zoomRunActive else { return }
        let sample = ZoomSample(scale: clamped(scale), centre: centre, inset: inset)
        let last = zoomRunSamples[zoomRunSamples.count - 1]
        guard last.scale != sample.scale || last.centre != sample.centre || last.inset != sample.inset else {
            return
        }
        zoomRunSamples.append(sample)
    }

    func endZoomRun() {
        guard zoomRunActive else { return }
        zoomRunActive = false
        defer { zoomRunSamples = [] }
        guard zoomRunSamples.count >= zoomRunMinimumSamples else { return }
        let first = zoomRunSamples[0].scale
        let direction: CGFloat = (zoomRunSamples[zoomRunSamples.count - 1].scale < first) ? -1 : 1
        var low = first
        var high = first
        var largest: CGFloat = 0
        var back = 0
        var insetWrites = 0
        var centreStep: CGFloat = 0
        for (previous, current) in zip(zoomRunSamples, zoomRunSamples.dropFirst()) {
            low = min(low, current.scale)
            high = max(high, current.scale)
            largest = max(largest, abs(current.scale - previous.scale))
            if (current.scale - previous.scale) * direction < -0.001 { back += 1 }
            if current.inset != previous.inset { insetWrites += 1 }
            centreStep = max(centreStep, hypot(current.centre.x - previous.centre.x, current.centre.y - previous.centre.y))
        }
        var drift: CGFloat = 0
        for sample in zoomRunSamples {
            drift = max(drift, hypot(sample.centre.x - 0.5, sample.centre.y - 0.5))
        }
        zoomSampleCount = zoomRunSamples.count
        zoomSpan = high - low
        zoomLargestStep = largest
        zoomBackSteps = back
        zoomRuns += 1
        zoomFirst = first
        zoomLast = zoomRunSamples[zoomRunSamples.count - 1].scale
        zoomLow = low
        zoomHigh = high
        zoomInsetWrites = insetWrites
        zoomCentreDrift = drift
        zoomCentreStep = centreStep
        revision &+= 1
    }

    private func clamped(_ scale: CGFloat) -> CGFloat {
        min(max(scale, zoomRunLimits.lowerBound), zoomRunLimits.upperBound)
    }

    /// Drops an unfinished run — the page it belonged to was paged away or
    /// evicted mid-gesture — without publishing a partial summary, so the next
    /// gesture starts from a clean slate.
    func cancelZoomRun() {
        guard zoomRunActive else { return }
        zoomRunActive = false
        zoomRunSamples = []
    }

    /// Whether the current photo is showing its full-resolution image rather
    /// than the viewer-size thumbnail, so a test can prove a photo sharpens
    /// after a pause and sharpens straight away when zoomed.
    private(set) var sharp = false

    func sharpen(_ value: Bool) {
        if sharp != value {
            sharp = value
            revision &+= 1
        }
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

    /// `page=4/27;scale=2.50;cx=0.79;cy=0.45;over=0.0;live=5;setup=3.1ms;layout=0.4ms;worst=16.7ms;drops=0;tap=83ms;mem=142.3MB;sharp=1;zoomRuns=0;zoomN=0;zoomFirst=0.00;zoomLast=0.00;zoomMin=0.00;zoomMax=0.00;zoomSpan=0.00;zoomStep=0.00;zoomBack=0;zoomInset=0;zoomDrift=0.000;zoomCentreStep=0.000`
    var value: String {
        _ = revision
        return String(
            format: "page=%d/%d;scale=%.2f;cx=%.3f;cy=%.3f;over=%.1f;live=%d;setup=%.1fms;layout=%.1fms;worst=%.1fms;drops=%d;tap=%.0fms;mem=%.1fMB;sharp=%d;zoomRuns=%d;zoomN=%d;zoomFirst=%.2f;zoomLast=%.2f;zoomMin=%.2f;zoomMax=%.2f;zoomSpan=%.2f;zoomStep=%.2f;zoomBack=%d;zoomInset=%d;zoomDrift=%.3f;zoomCentreStep=%.3f",
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
            footprintMB,
            sharp ? 1 : 0,
            zoomRuns,
            zoomSampleCount,
            zoomFirst,
            zoomLast,
            zoomLow,
            zoomHigh,
            zoomSpan,
            zoomLargestStep,
            zoomBackSteps,
            zoomInsetWrites,
            zoomCentreDrift,
            zoomCentreStep
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
