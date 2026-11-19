#if os(iOS)
import SwiftUI
import UIKit

/// The viewer's pager.
///
/// SwiftUI's `.page` TabView owns a page view controller whose gesture
/// recognisers compete with the per-page pinch, pan and tap handling: fast
/// flicks get dropped, and a page's own drag can block the pager. This hands
/// the whole interaction to UIKit instead — one horizontal scroll view for
/// paging, one zooming scroll view per photo for pinch/pan/taps — so each axis
/// has exactly one owner.
struct ViewerPager: UIViewControllerRepresentable {
    let photos: [PhotoItem]
    @Binding var selection: String
    let app: AppModel
    let reduceMotion: Bool
    @Binding var isZoomed: Bool
    var onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, isZoomed: $isZoomed)
    }

    func makeUIViewController(context: Context) -> ViewerPagerController {
        let controller = ViewerPagerController(app: app)
        controller.onSelectionChanged = { [weak coordinator = context.coordinator] id in
            coordinator?.select(id)
        }
        controller.onZoomChanged = { [weak coordinator = context.coordinator] zoomed in
            coordinator?.zoomed(zoomed)
        }
        controller.onSingleTap = onSingleTap
        controller.update(photos: photos, selection: selection, reduceMotion: reduceMotion)
        return controller
    }

    func updateUIViewController(_ controller: ViewerPagerController, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.isZoomed = $isZoomed
        controller.onSingleTap = onSingleTap
        controller.update(photos: photos, selection: selection, reduceMotion: reduceMotion)
    }

    @MainActor
    final class Coordinator {
        var selection: Binding<String>
        var isZoomed: Binding<Bool>

        init(selection: Binding<String>, isZoomed: Binding<Bool>) {
            self.selection = selection
            self.isZoomed = isZoomed
        }

        func select(_ id: String) {
            if selection.wrappedValue != id {
                selection.wrappedValue = id
            }
        }

        func zoomed(_ zoomed: Bool) {
            if isZoomed.wrappedValue != zoomed {
                isZoomed.wrappedValue = zoomed
            }
        }
    }
}

/// A paged, horizontally scrolling container of `ViewerZoomPageController`s.
///
/// Only a small window of page controllers exists at a time. A window of 121
/// (the viewer's maximum presentation window) meant building 121 controllers,
/// scroll views, spinners and constraint sets inside the zoom transition, then
/// laying all of them out in one commit. Pages are now created as the pager
/// approaches them and released once they are a few photos behind, so opening
/// costs the same for a 20-photo roll as for a 20,000-photo one.
@MainActor
final class ViewerPagerController: UIViewController, UIScrollViewDelegate {
    private let app: AppModel
    private let scrollView = UIScrollView()
    /// Resident page controllers keyed by photo index.
    private var pages: [Int: ViewerZoomPageController] = [:]
    /// How many photos either side of the current one keep a live controller.
    /// The pager can show at most the current photo and one neighbour mid-drag,
    /// so two either side leaves a prepared page in both directions.
    private let residentRadius = 2
    /// Hard ceiling, in case a size change or a jump leaves stragglers behind.
    private let maxResident = 9
    private var photos: [PhotoItem] = []
    private var photoIDs: [String] = []
    private var selection = ""
    private var settledIndex = 0
    private var dragStartIndex = 0
    /// The page the pager is heading toward. A new flick during the settle
    /// animation must count from here, not from the half-scrolled offset, or
    /// quick successive flicks coalesce into one page.
    private var pendingIndex = 0
    private var pageWidth: CGFloat = 1
    private var lastLayoutSize: CGSize = .zero
    private var needsInitialScroll = true
    private var reduceMotion = false

    /// Set while a zoomed page pans past its edge and hands the gesture over.
    private var edgeDragFrom: Int?
    private var edgeDragDirection = 0

    var onSelectionChanged: ((String) -> Void)?
    var onSingleTap: (() -> Void)?
    var onZoomChanged: ((Bool) -> Void)?
    private var reportedZoom = false
    private var restoredPopGesture = false
    /// Transition pop gestures disabled for the viewer's lifetime.
    private var disabledTransitionPans: [UIGestureRecognizer] = []
    /// Gates installed on the zoom transition's dismiss recogniser.
    private var dismissGates: [HorizontalDismissGate] = []

    #if DEBUG
    private var frameLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval = 0
    #endif

    init(app: AppModel) {
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.isPagingEnabled = true
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isDirectionalLockEnabled = true
        scrollView.delegate = self
        view.addSubview(scrollView)
        #if DEBUG
        startFrameLink()
        #endif
    }

    #if DEBUG
    private func startFrameLink() {
        guard ViewerInteractionProbe.shared.isEnabled, frameLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(sampleFrame))
        link.add(to: .main, forMode: .common)
        frameLink = link
        lastFrameTimestamp = 0
    }

    @objc private func sampleFrame(_ link: CADisplayLink) {
        defer { lastFrameTimestamp = link.timestamp }
        guard lastFrameTimestamp > 0 else { return }
        ViewerInteractionProbe.shared.frame(
            duration: (link.timestamp - lastFrameTimestamp) * 1000
        )
    }
    #endif

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The pager owns horizontal gestures, including a swipe that starts at
        // the screen edge. The navigation stack's edge-swipe-to-pop would
        // otherwise close the viewer instead of paging back.
        disablePopGesture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        startFrameLink()
        #endif
        // Re-assert after the zoom transition: UIKit installs the transition's
        // own pop recogniser while it finishes the push, after `viewWillAppear`.
        disablePopGesture()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if DEBUG
        frameLink?.invalidate()
        frameLink = nil
        #endif
    }

    private func disablePopGesture() {
        if let navigation = enclosingNavigationController {
            // iOS 26 adds a second, content-wide pop gesture on top of the
            // leading-edge one. A back-swipe anywhere in the photo would
            // otherwise pop the viewer instead of paging the roll.
            for gesture in [navigation.interactivePopGestureRecognizer,
                            navigation.interactiveContentPopGestureRecognizer] {
                guard let gesture, gesture.isEnabled else { continue }
                gesture.isEnabled = false
                restoredPopGesture = true
            }
        }
        disableTransitionPopGesture()
        gateHorizontalDismiss()
    }

    /// The zoom navigation transition installs a *third* interactive-pop pan on
    /// the SwiftUI hosting view itself (a sibling of the vertical
    /// `_UIContentSwipeDismiss` that owns swipe-down). That one only accepts a
    /// touch that begins in the first ~4 points of the screen and is owned by
    /// neither of the navigation controller's public pop gestures, so a swipe
    /// from the leading edge still popped the viewer while everything a few
    /// points in paged the roll. It is a distinct object from the dismiss
    /// recogniser, so disabling it hands the leading edge to the pager and
    /// leaves swipe-down alone.
    private func disableTransitionPopGesture() {
        guard let window = view.window else { return }
        var ancestor: UIView? = view
        while let current = ancestor, current !== window {
            for gesture in current.gestureRecognizers ?? [] {
                guard gesture.isEnabled,
                      String(describing: type(of: gesture)).contains("ParallaxTransitionPan") else { continue }
                gesture.isEnabled = false
                disabledTransitionPans.append(gesture)
            }
            ancestor = current.superview
        }
    }

    /// The zoom transition's swipe-down dismiss recogniser also tracks
    /// horizontal drags: dragging away from a photo's edge (which is exactly
    /// where a zoomed photo hands the gesture to the pager) ended in an
    /// interactive back that closed the viewer. The viewer never dismisses
    /// horizontally — paging and panning own that axis — so the recogniser is
    /// gated to vertical drags.
    private func gateHorizontalDismiss() {
        guard let window = view.window else { return }
        // Drop gates whose recogniser has since been re-created by the system.
        dismissGates.removeAll { $0.gesture == nil }
        var ancestor: UIView? = view
        while let current = ancestor, current !== window {
            for gesture in current.gestureRecognizers ?? [] {
                guard String(describing: type(of: gesture)).contains("ContentSwipeDismiss") else { continue }
                if let gate = dismissGates.first(where: { $0.gesture === gesture }) {
                    // UIKit can install its own delegate again; take it back.
                    if gesture.delegate !== gate {
                        gate.adopt(gesture.delegate)
                        gesture.delegate = gate
                    }
                    continue
                }
                let gate = HorizontalDismissGate(gesture: gesture, forwarding: gesture.delegate)
                gesture.delegate = gate
                dismissGates.append(gate)
            }
            ancestor = current.superview
        }
    }

    private func restorePopGesture() {
        for gesture in disabledTransitionPans {
            gesture.isEnabled = true
        }
        disabledTransitionPans.removeAll()
        for gate in dismissGates {
            gate.restore()
        }
        dismissGates.removeAll()
        guard restoredPopGesture else { return }
        let navigation = enclosingNavigationController
        navigation?.interactivePopGestureRecognizer?.isEnabled = true
        navigation?.interactiveContentPopGestureRecognizer?.isEnabled = true
        restoredPopGesture = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        restorePopGesture()
    }

    private var enclosingNavigationController: UINavigationController? {
        var controller: UIViewController? = self
        while let current = controller {
            if let navigation = current as? UINavigationController { return navigation }
            if let navigation = current.navigationController { return navigation }
            controller = current.parent
        }
        return nil
    }

    // MARK: Data

    func update(photos: [PhotoItem], selection: String, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        // Take the new selection before rebuilding. `rebuildPages` settles the
        // window on `selection`; rebuilding around the previous photo (which
        // may not even exist in the new presentation window) left the pager
        // resting on the wrong index until something else moved it.
        self.selection = selection
        let ids = photos.map(\.id)
        if ids != photoIDs {
            photoIDs = ids
            self.photos = photos
            rebuildPages()
        } else {
            self.photos = photos
            for page in pages.values {
                page.reduceMotion = reduceMotion
            }
        }
        // Initial positioning happens in viewDidLayoutSubviews, once the page
        // width is known. This method can be called inside a SwiftUI update, so
        // it must not mutate observed state synchronously.
        if !needsInitialScroll, !scrollView.isDragging, !scrollView.isDecelerating {
            let target = index(of: selection)
            if target != settledIndex {
                Task { @MainActor [weak self] in
                    self?.scrollToSelection(animated: false)
                }
            }
        }
    }

    private func index(of id: String) -> Int {
        photoIDs.firstIndex(of: id) ?? 0
    }

    // MARK: Page window

    /// Drops every controller and starts a fresh window around the selection.
    /// Called when the roll itself changes (including a new presentation, even
    /// one whose photos happen to overlap), never on a page change.
    private func rebuildPages() {
        loadViewIfNeeded()
        let started = CFAbsoluteTimeGetCurrent()
        edgeDragFrom = nil
        edgeDragDirection = 0
        for (index, page) in pages {
            release(page, at: index)
        }
        pages.removeAll()
        settledIndex = min(max(0, index(of: selection)), max(0, photoIDs.count - 1))
        pendingIndex = settledIndex
        ensurePages(around: settledIndex)
        scrollView.contentSize = .zero
        lastLayoutSize = .zero
        needsInitialScroll = true
        view.setNeedsLayout()
        #if DEBUG
        ViewerInteractionProbe.shared.pagesBuilt(
            count: pages.count,
            milliseconds: (CFAbsoluteTimeGetCurrent() - started) * 1000
        )
        #endif
        // The roll can lose the photo that is on screen (the library changed
        // underneath the viewer). Point SwiftUI at the photo that is actually
        // shown, or the chrome and the info sheet would describe a photo that
        // no longer exists.
        if !photoIDs.contains(selection), photoIDs.indices.contains(settledIndex) {
            let fallback = photoIDs[settledIndex]
            Task { @MainActor [weak self] in
                self?.onSelectionChanged?(fallback)
            }
        }
    }

    /// Creates controllers for the photos within `residentRadius` of `center`.
    /// Called on open and whenever the pager settles on a new photo, so it costs
    /// one controller per photo actually travelled to.
    private func ensurePages(around center: Int) {
        guard !photoIDs.isEmpty else { return }
        let lower = max(0, center - residentRadius)
        let upper = min(photoIDs.count - 1, center + residentRadius)
        guard lower <= upper else { return }
        for index in lower...upper {
            ensurePage(at: index)
        }
        #if DEBUG
        ViewerInteractionProbe.shared.residentPages(pages.count)
        #endif
    }

    /// Builds one page if it does not exist yet. Cheap and idempotent, so it is
    /// safe to call at the start of a gesture.
    private func ensurePage(at index: Int) {
        guard photoIDs.indices.contains(index), pages[index] == nil else { return }
        pages[index] = makePage(at: index)
    }

    private func makePage(at index: Int) -> ViewerZoomPageController {
        let page = ViewerZoomPageController(photo: photos[index], app: app)
        page.reduceMotion = reduceMotion
        page.onSingleTap = { [weak self] in self?.onSingleTap?() }
        page.onHandoffBegan = { [weak self] delta in
            self?.beginEdgePageDrag(from: index, by: delta) ?? false
        }
        page.onHandoffChanged = { [weak self] translation in
            self?.updateEdgePageDrag(translation: translation)
        }
        page.onHandoffEnded = { [weak self] translation, velocity in
            self?.endEdgePageDrag(translation: translation, velocity: velocity)
        }
        page.onZoomStateChanged = { [weak self] _ in
            guard let self, index == self.settledIndex else { return }
            self.updateOuterPaging()
        }
        page.onZoomMetrics = { [weak self] scale, centerX, centerY, overpan in
            // Every resident page reports, but only the one on screen describes
            // the viewer; a neighbour resetting its zoom used to overwrite the
            // current photo's zoom in the readout.
            guard let self, index == self.settledIndex else { return }
            #if DEBUG
            ViewerInteractionProbe.shared.zoomChanged(
                scale: scale,
                centerX: centerX,
                centerY: centerY,
                overpan: overpan
            )
            #endif
        }
        addChild(page)
        page.view.frame = CGRect(
            x: pageWidth * CGFloat(index),
            y: 0,
            width: pageWidth,
            height: view.bounds.height
        )
        scrollView.addSubview(page.view)
        page.didMove(toParent: self)
        page.setPosition(index + 1, of: photoIDs.count)
        let distance = abs(index - settledIndex)
        page.setActivation(distance == 0 ? .current : distance == 1 ? .neighbor : .idle)
        return page
    }

    /// Releases controllers that are no longer near the settled photo, unless a
    /// hand is on the screen. Evicting mid-gesture would pull a page out from
    /// under a drag that is about to settle on it.
    private func evictPages(around center: Int) {
        guard !scrollView.isDragging, !scrollView.isDecelerating else { return }
        for (index, page) in pages where abs(index - center) > residentRadius {
            release(page, at: index)
        }
        if pages.count > maxResident {
            let ordered = pages.keys.sorted { abs($0 - center) > abs($1 - center) }
            for index in ordered where pages.count > maxResident {
                if let page = pages[index] { release(page, at: index) }
            }
        }
        #if DEBUG
        ViewerInteractionProbe.shared.residentPages(pages.count)
        #endif
    }

    private func release(_ page: ViewerZoomPageController, at index: Int) {
        page.setActivation(.idle)
        page.willMove(toParent: nil)
        page.view.removeFromSuperview()
        page.removeFromParent()
        if pages[index] === page { pages.removeValue(forKey: index) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0 else { return }

        let widthChanged = abs(pageWidth - size.width) > 0.5
        pageWidth = size.width
        scrollView.frame = view.bounds
        let layoutStarted = CFAbsoluteTimeGetCurrent()
        scrollView.contentSize = CGSize(
            width: size.width * CGFloat(max(1, photoIDs.count)),
            height: size.height
        )
        for (index, page) in pages {
            page.view.frame = CGRect(
                x: size.width * CGFloat(index),
                y: 0,
                width: size.width,
                height: size.height
            )
        }
        #if DEBUG
        ViewerInteractionProbe.shared.pagesLaidOut(
            milliseconds: (CFAbsoluteTimeGetCurrent() - layoutStarted) * 1000
        )
        #endif

        if widthChanged || size != lastLayoutSize || needsInitialScroll {
            lastLayoutSize = size
            let index = needsInitialScroll ? index(of: selection) : settledIndex
            pendingIndex = index
            ensurePages(around: index)
            scrollView.setContentOffset(CGPoint(x: size.width * CGFloat(index), y: 0), animated: false)
            needsInitialScroll = false
            settle(at: index, notify: false)
        }
    }

    // MARK: Paging

    private func scrollToSelection(animated: Bool) {
        let target = index(of: selection)
        guard photoIDs.indices.contains(target), pageWidth > 0 else { return }
        ensurePages(around: target)
        pendingIndex = target
        scrollView.setContentOffset(
            CGPoint(x: pageWidth * CGFloat(target), y: 0),
            animated: animated
        )
        if !animated { settle(at: target, notify: false) }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartIndex = min(max(0, pendingIndex), max(0, photoIDs.count - 1))
        // The settled photo is about to leave: drop a full decode that has not
        // started, and build exactly the two photos this drag can reveal
        // before it reveals them. Building a whole window around each
        // neighbour (as this used to) put up to four extra controllers and
        // their image requests into the first frame of every swipe.
        pages[settledIndex]?.cancelPendingFullLoad()
        ensurePage(at: dragStartIndex - 1)
        ensurePage(at: dragStartIndex + 1)
    }

    /// Photos pages exactly one photo per flick, never several at once, and
    /// never none because a flick arrived while the previous settle was still
    /// running.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard pageWidth > 1, !photoIDs.isEmpty, edgeDragFrom == nil else { return }
        let proposed = Int((targetContentOffset.pointee.x / pageWidth).rounded())
        let target = min(max(proposed, dragStartIndex - 1), min(dragStartIndex + 1, photoIDs.count - 1))
        pendingIndex = min(max(target, 0), photoIDs.count - 1)
        targetContentOffset.pointee.x = pageWidth * CGFloat(pendingIndex)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard pageWidth > 1, !photoIDs.isEmpty else { return }
        let raw = scrollView.contentOffset.x / pageWidth
        let candidate = min(max(Int(raw.rounded()), 0), photoIDs.count - 1)
        guard candidate != settledIndex else { return }
        // Page and probe move at the halfway point so the new photo is ready,
        // but the chrome (date, favourite) only changes once the roll settles:
        // swapping it while two photos are half-visible reads as a flicker.
        settle(at: candidate, notify: false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // A drag that ends without momentum (including one that returns to the
        // same photo) still has to re-settle: it may have cancelled the current
        // photo's pending full-resolution load.
        if !decelerate { settleToNearest() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleToNearest()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settleToNearest()
    }

    private func settleToNearest() {
        guard pageWidth > 1, !photoIDs.isEmpty else { return }
        let index = min(max(Int((scrollView.contentOffset.x / pageWidth).rounded()), 0), photoIDs.count - 1)
        pendingIndex = index
        settle(at: index, notify: true)
        evictPages(around: index)
    }

    private func settle(at index: Int, notify: Bool) {
        guard !photoIDs.isEmpty else { return }
        let index = min(max(index, 0), photoIDs.count - 1)
        settledIndex = index
        selection = photoIDs.indices.contains(index) ? photoIDs[index] : selection
        disablePopGesture()
        ensurePages(around: index)
        activate(index)
        #if DEBUG
        ViewerInteractionProbe.shared.sharpen(pages[index]?.isShowingFullImage ?? false)
        ViewerInteractionProbe.shared.pageChanged(index, count: photoIDs.count)
        pages[index]?.updateProbe()
        #endif
        if notify, photoIDs.indices.contains(index) {
            onSelectionChanged?(photoIDs[index])
        }
    }

    private func activate(_ index: Int) {
        for (i, page) in pages {
            let distance = abs(i - index)
            if distance == 0 {
                page.setActivation(.current)
            } else if distance <= 1 {
                page.setActivation(.neighbor)
            } else {
                page.setActivation(.idle)
            }
            if i != index, edgeDragFrom == nil {
                page.resetZoom(animated: true)
            }
        }
        updateOuterPaging()
    }

    /// Only one scroll view may own a pan. At fit the page's zoom scroll view is
    /// inert and the pager pages; while magnified the pager's pan is off, the
    /// photo pans, and the zoom page hands an edge drag back to the pager.
    private func updateOuterPaging() {
        let currentIsZoomed = pages[settledIndex]?.isZoomed ?? false
        if reportedZoom != currentIsZoomed {
            reportedZoom = currentIsZoomed
            onZoomChanged?(currentIsZoomed)
        }
        let enabled = !currentIsZoomed && edgeDragFrom == nil
        if scrollView.panGestureRecognizer.isEnabled != enabled {
            scrollView.panGestureRecognizer.isEnabled = enabled
        }
        // If a pinch takes over while a one-finger pager drag was already under
        // way, disabling the pager's pan can cancel its settle. Recover so the
        // roll never rests between two photos.
        if !enabled, edgeDragFrom == nil, scrollView.isDragging, pageWidth > 1 {
            let nearest = CGFloat(Int((scrollView.contentOffset.x / pageWidth).rounded())) * pageWidth
            if abs(scrollView.contentOffset.x - nearest) > 1 {
                pendingIndex = Int((nearest / pageWidth).rounded())
                scrollView.setContentOffset(CGPoint(x: nearest, y: 0), animated: true)
            }
        }
    }

    // MARK: Edge hand-off from a zoomed page

    func beginEdgePageDrag(from index: Int, by delta: Int) -> Bool {
        guard delta != 0, photoIDs.indices.contains(index + delta) else { return false }
        // The neighbour must be live before the drag reveals it.
        ensurePage(at: index + delta)
        edgeDragFrom = index
        edgeDragDirection = delta
        updateOuterPaging()
        return true
    }

    func updateEdgePageDrag(translation: CGFloat) {
        guard let from = edgeDragFrom else { return }
        var travel = -translation
        let limit = pageWidth
        if abs(travel) > limit {
            travel = travel.sign == .minus
                ? -(limit + (abs(travel) - limit) * 0.12)
                : (limit + (abs(travel) - limit) * 0.12)
        }
        scrollView.setContentOffset(
            CGPoint(x: pageWidth * CGFloat(from) + travel, y: 0),
            animated: false
        )
    }

    func endEdgePageDrag(translation: CGFloat, velocity: CGFloat) {
        guard let from = edgeDragFrom else { return }
        let delta = edgeDragDirection
        let threshold = pageWidth * 0.22
        var target = from
        if delta > 0, translation < -threshold || velocity < -260 {
            target = from + 1
        } else if delta < 0, translation > threshold || velocity > 260 {
            target = from - 1
        }
        target = min(max(target, 0), max(0, photoIDs.count - 1))
        edgeDragFrom = nil
        edgeDragDirection = 0
        pendingIndex = target
        ensurePages(around: target)
        for (i, page) in pages where i != target {
            page.resetZoom(animated: true)
        }
        scrollView.setContentOffset(
            CGPoint(x: pageWidth * CGFloat(target), y: 0),
            animated: !reduceMotion
        )
        if reduceMotion {
            settle(at: target, notify: true)
        }
        updateOuterPaging()
        evictPages(around: target)
    }
}

/// One photo, with Photos-style zooming: native pinch under the fingers,
/// clamped panning, and double-tap zoom toward the tapped point.
@MainActor
final class ViewerZoomPageController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    enum Activation {
        case idle
        case neighbor
        case current
    }

    private let photo: PhotoItem
    private let app: AppModel
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var fullTask: Task<Void, Never>?
    /// Whether `fullTask` has finished waiting and is decoding.
    private var fullTaskIsDecoding = false
    private var loadGeneration = 0
    private var isLoading = false
    private var loadedFinal = false
    private var wantsFull = false
    private var activation: Activation = .idle
    private var appliedImageSize: CGSize = .zero
    private var lastBoundsSize: CGSize = .zero
    private var handoffActive = false
    private var handoffStartTranslation: CGFloat = 0
    private var didResetPanAfterHandoff = false
    /// Whether the zoom `UIScrollView` is reporting came from one of our own
    /// animated `setZoomScale`/`zoom(to:)` calls rather than a pinch.
    private var isProgrammaticZoom = false
    #if DEBUG
    /// Whether this page owns an open probe zoom run. Only a zoom this page
    /// began records samples, so a neighbour's reset can never bleed into it.
    private var zoomRunOpen = false
    #endif

    /// Time a photo has to stay current before its full-resolution image is
    /// decoded. Flicking through a roll otherwise starts a 2400px decode for
    /// every photo that passes the viewport, which is the single most expensive
    /// thing the viewer can do on the main thread. The 1200px viewer thumbnail
    /// is already one-to-one with the screen at fit, so the delay is invisible
    /// until the user zooms — and zooming skips it.
    private let fullLoadDelay: Duration = .milliseconds(200)

    private var singleTap: UITapGestureRecognizer!
    private var doubleTap: UITapGestureRecognizer!
    private var edgePan: UIPanGestureRecognizer!
    #if DEBUG
    private var lastTouchDown: CFTimeInterval = 0
    #endif

    var onSingleTap: (() -> Void)?
    var onHandoffBegan: ((_ delta: Int) -> Bool)?
    var onHandoffChanged: ((CGFloat) -> Void)?
    var onHandoffEnded: ((_ translation: CGFloat, _ velocity: CGFloat) -> Void)?
    var onZoomStateChanged: ((_ zoomed: Bool) -> Void)?
    var onZoomMetrics: ((_ scale: CGFloat, _ centerX: CGFloat, _ centerY: CGFloat, _ overpan: CGFloat) -> Void)?
    var reduceMotion = false

    var isZoomed: Bool { scrollView.zoomScale > 1.01 }

    init(photo: PhotoItem, app: AppModel) {
        self.photo = photo
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.delaysContentTouches = false
        // At rest the pager owns every pan. Pinching still works because the
        // pinch recogniser is independent of the scroll view's pan.
        scrollView.panGestureRecognizer.isEnabled = false
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        imageView.isAccessibilityElement = true
        imageView.accessibilityIdentifier = "viewer.photo"
        imageView.accessibilityTraits = .image
        scrollView.addSubview(imageView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        statusLabel.textColor = .white.withAlphaComponent(0.7)
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -80)
        ])

        singleTap = makeSingleTapRecognizer()
        singleTap.numberOfTapsRequired = 1
        doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        // Deliberately *not* `singleTap.require(toFail: doubleTap)`: that makes
        // every tap wait out the double-tap window (~350 ms) before chrome
        // moves. Apple Photos responds on the first tap and lets a double tap
        // zoom and toggle the chrome once; matching that removes the wait.
        scrollView.addGestureRecognizer(singleTap)
        scrollView.addGestureRecognizer(doubleTap)

        edgePan = UIPanGestureRecognizer(target: self, action: #selector(handleEdgePan))
        edgePan.delegate = self
        edgePan.maximumNumberOfTouches = 1
        edgePan.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(edgePan)
    }

    private func makeSingleTapRecognizer() -> UITapGestureRecognizer {
        #if DEBUG
        // The tests measure finger-down → chrome-toggle latency. Reading the
        // timestamp inside the real recogniser avoids adding a competing
        // gesture recogniser, which would block the system dismiss pan.
        let tap = TrackingTapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        tap.onTouchDown = { [weak self] in
            self?.lastTouchDown = CACurrentMediaTime()
        }
        return tap
        #else
        return UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        scrollView.frame = view.bounds
        if size != lastBoundsSize {
            lastBoundsSize = size
            layoutImage(zoom: 1)
        }
        spinner.center = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    // MARK: Activation + loading

    /// VoiceOver needs a stable description of which photo in the roll this is;
    /// the image view is the page's only accessibility element.
    func setPosition(_ position: Int, of total: Int) {
        imageView.accessibilityLabel = "Photo \(position) of \(total)"
        if let date = photo.takenAt?.dayLabel {
            imageView.accessibilityValue = date
        } else {
            imageView.accessibilityValue = photo.filename
        }
    }

    func setActivation(_ level: Activation) {
        let previous = activation
        activation = level
        #if DEBUG
        if level != .current, zoomRunOpen {
            // Paged away mid-pinch: drop the partial run rather than have it
            // published by this page's own zoom reset, or mixed into the next
            // page's gesture.
            zoomRunOpen = false
            ViewerInteractionProbe.shared.cancelZoomRun()
        }
        #endif
        switch level {
        case .idle:
            guard previous != .idle else { return }
            wantsFull = false
            cancelLoads()
            imageView.image = nil
            appliedImageSize = .zero
            spinner.stopAnimating()
            statusLabel.isHidden = true
            resetZoom(animated: false)
        case .neighbor:
            wantsFull = false
            fullTask?.cancel()
            fullTask = nil
            if previous == .idle {
                ensureLoading()
            }
        case .current:
            wantsFull = true
            ensureLoading()
        }
    }

    private func cancelLoads() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        fullTask?.cancel()
        fullTask = nil
        isLoading = false
        loadedFinal = false
    }

    /// Drops a full-resolution load that has not started yet. Called when the
    /// user starts dragging: the photo is about to become a neighbour, and
    /// decoding 2400px for it now is pure waste.
    func cancelPendingFullLoad() {
        fullTask?.cancel()
        fullTask = nil
        fullTaskIsDecoding = false
    }

    private func ensureLoading() {
        if wantsFull && loadedFinal { return }
        // Revisiting a photo whose full image is still cached should be sharp
        // immediately, not after a 1200px placeholder and the full-load delay.
        if wantsFull, let full = app.images.cachedFullImage(for: photo) {
            show(full, final: true)
            return
        }
        guard !isLoading else { return }
        isLoading = true
        let generation = loadGeneration

        let mediumSize = CGSize(width: 1200, height: 1200)
        if imageView.image == nil {
            if let sharp = app.images.cachedViewerThumbnail(for: photo, size: mediumSize) {
                show(sharp, final: false)
            } else if let quick = app.images.cachedPreview(for: photo) {
                show(quick, final: false)
            }
        }
        if imageView.image == nil, photo.isRemoteOnly {
            statusLabel.text = "Downloading from \(serverName)"
            statusLabel.isHidden = false
        }
        if imageView.image == nil {
            spinner.startAnimating()
        }

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if let medium = await self.app.images.viewerThumbnail(
                for: self.photo,
                size: mediumSize
            ) {
                if Task.isCancelled || generation != self.loadGeneration { return }
                self.show(medium, final: false)
            }
            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            self.isLoading = false
            self.loadTask = nil
            if self.wantsFull && !self.loadedFinal, self.activation == .current {
                self.scheduleFullLoad(immediately: self.isZoomed)
            }
        }
    }

    /// Only a photo that has been on screen for a moment gets the expensive
    /// full image. Leaving the page cancels the wait; an already-running decode
    /// still finishes and lands in the cache for the next visit.
    ///
    /// Zooming skips the wait. The 1200px viewer thumbnail is one-to-one with
    /// the screen at fit but visibly soft at 2.5x, and pinching is the user
    /// asking for detail — waiting 200 ms first made an immediate zoom sit
    /// blurred for half a second.
    private func scheduleFullLoad(immediately: Bool = false) {
        guard wantsFull, !loadedFinal, activation == .current else { return }
        if let pending = fullTask {
            // Promote a waiting task; never restart a decode that is already
            // running (that would do the work twice).
            guard immediately, !fullTaskIsDecoding else { return }
            pending.cancel()
            fullTask = nil
        }
        let generation = loadGeneration
        let delay = fullLoadDelay
        fullTaskIsDecoding = false
        fullTask = Task { @MainActor [weak self] in
            if !immediately {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            guard !Task.isCancelled,
                  generation == self.loadGeneration,
                  self.wantsFull,
                  !self.loadedFinal,
                  self.activation == .current else { return }
            self.fullTaskIsDecoding = true
            if let full = await self.app.images.fullImage(for: self.photo) {
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                self.show(full, final: true)
            } else if self.imageView.image == nil {
                self.showFailure()
            }
            self.fullTask = nil
            self.fullTaskIsDecoding = false
        }
    }

    private func show(_ image: PlatformImage, final: Bool) {
        spinner.stopAnimating()
        statusLabel.isHidden = true
        let hadImage = imageView.image != nil
        let previousAspect = Self.aspect(of: appliedImageSize)
        let newAspect = Self.aspect(of: image.size)
        // Aspect-fit means the laid-out frame depends only on the aspect ratio,
        // not the pixel size. A sharper image of the same photo can therefore
        // replace the pixels underneath an existing zoom without moving or
        // rescaling anything — no jump, and no resetting a pinch in progress.
        let aspectMatches = hadImage
            && !imageView.bounds.isEmpty
            && previousAspect > 0
            && abs(previousAspect - newAspect) <= newAspect * 0.01

        if aspectMatches {
            if scrollView.zoomScale > 1.01 {
                imageView.image = image
            } else {
                UIView.transition(
                    with: imageView,
                    duration: 0.16,
                    options: [.transitionCrossDissolve, .allowUserInteraction]
                ) {
                    self.imageView.image = image
                }
            }
            appliedImageSize = image.size
        } else {
            imageView.image = image
            appliedImageSize = image.size
            // Keep a pinch in progress; the first image always starts at fit.
            layoutImage(zoom: hadImage ? max(scrollView.zoomScale, 1) : 1)
        }
        if final {
            loadedFinal = true
            #if DEBUG
            if activation == .current {
                ViewerInteractionProbe.shared.sharpen(true)
            }
            #endif
        }
        updateProbe()
    }

    private static func aspect(of size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 0 }
        return size.width / size.height
    }

    private func showFailure() {
        spinner.stopAnimating()
        statusLabel.text = photo.isRemoteOnly
            ? "Could not download this photo from \(serverName)."
            : "This photo is not available on this device."
        statusLabel.isHidden = false
    }

    private var serverName: String {
        app.servers.server(id: photo.copies.first?.serverID ?? photo.serverID)?.name ?? "storage"
    }

    // MARK: Layout

    private func layoutImage(zoom: CGFloat) {
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            imageView.frame = .zero
            scrollView.contentSize = bounds
            return
        }
        let fit = Self.aspectFit(image.size, in: bounds)
        scrollView.setZoomScale(1, animated: false)
        imageView.transform = .identity
        imageView.frame = CGRect(origin: .zero, size: fit)
        scrollView.contentSize = fit
        if zoom > 1.001 {
            scrollView.setZoomScale(zoom, animated: false)
        }
        centerZoomingView()
        scrollView.contentOffset = clampedOffset(scrollView.contentOffset)
        updatePanAvailability()
    }

    private func clampedOffset(_ offset: CGPoint) -> CGPoint {
        let bounds = scrollView.bounds.size
        let inset = scrollView.adjustedContentInset
        let minX = -inset.left
        let maxX = max(minX, scrollView.contentSize.width - bounds.width + inset.right)
        let minY = -inset.top
        let maxY = max(minY, scrollView.contentSize.height - bounds.height + inset.bottom)
        return CGPoint(
            x: min(max(offset.x, minX), maxX),
            y: min(max(offset.y, minY), maxY)
        )
    }

    private static func aspectFit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Keeps the photo centred without ever touching `contentInset`.
    ///
    /// Reassigning the inset on every zoom tick rewrites the content offset
    /// underneath the pinch, which made a zoom-out move in visible steps (and
    /// fought the pinch anchor on the way in). Moving the zooming view's centre
    /// leaves the offset alone: while the scaled photo is smaller than the
    /// viewport the centre is the viewport's, at the moment it fills the
    /// viewport the two coincide, and once it is larger the centre is the
    /// content's, so panning still clamps to the photo's edges.
    private func centerZoomingView() {
        guard imageView.bounds.width > 0, imageView.bounds.height > 0 else { return }
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        let offsetX = max(0, (bounds.width - content.width) / 2)
        let offsetY = max(0, (bounds.height - content.height) / 2)
        let center = CGPoint(
            x: content.width / 2 + offsetX,
            y: content.height / 2 + offsetY
        )
        if imageView.center != center {
            imageView.center = center
        }
    }

    private func updatePanAvailability() {
        let zoomed = scrollView.zoomScale > 1.01
        // Never yank the pan recogniser out from under a live hand-off.
        if !handoffActive {
            scrollView.panGestureRecognizer.isEnabled = zoomed
        }
        onZoomStateChanged?(zoomed)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    /// Whether the photo on screen is the full-resolution one (as opposed to
    /// the 1200px viewer thumbnail). The UI tests use this to prove a photo
    /// sharpens after a pause and sharpens *at once* when zoomed.
    var isShowingFullImage: Bool { loadedFinal }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        #if DEBUG
        if !isProgrammaticZoom, activation == .current {
            zoomRunOpen = true
            ViewerInteractionProbe.shared.beginZoomRun(
                from: scrollView.zoomScale,
                centre: viewportFocus(),
                inset: viewportInset(),
                limits: scrollView.minimumZoomScale...scrollView.maximumZoomScale
            )
        }
        #endif
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerZoomingView()
        updatePanAvailability()
        #if DEBUG
        // Only the photo on screen, and only a zoom this page started,
        // describes the run. A neighbour resetting its zoom must not append to
        // (or close) the gesture under the fingers.
        if zoomRunOpen, activation == .current {
            ViewerInteractionProbe.shared.zoomSample(
                scrollView.zoomScale,
                centre: viewportFocus(),
                inset: viewportInset()
            )
        }
        #endif
        // A pinch asks for detail now: start the full decode without waiting
        // out the delay that exists to protect flicking through the roll.
        if scrollView.zoomScale > 1.01 {
            scheduleFullLoad(immediately: true)
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale <= 1.01 {
            setZoomScale(1, animated: false)
        }
        centerZoomingView()
        // A pinch that ends inside the rubber band leaves the content offset
        // past the edge until the next touch. Settle it here (at fit this puts
        // the photo back at zero) so the viewer never rests out of bounds.
        scrollView.contentOffset = clampedOffset(scrollView.contentOffset)
        updatePanAvailability()
        #if DEBUG
        if zoomRunOpen {
            zoomRunOpen = false
            ViewerInteractionProbe.shared.endZoomRun()
        }
        #endif
        isProgrammaticZoom = false
        updateProbe()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updateProbe() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateProbe()
    }

    func resetZoom(animated: Bool) {
        let needsReset = scrollView.zoomScale > 1.01
            || abs(scrollView.contentOffset.x) > 0.5
            || abs(scrollView.contentOffset.y) > 0.5
        guard needsReset else { return }
        if animated {
            setZoomScale(1, animated: true)
        } else {
            setZoomScale(1, animated: false)
            centerZoomingView()
            scrollView.contentOffset = .zero
        }
        updatePanAvailability()
        updateProbe()
    }

    /// `UIScrollView` reports a programmatic animated zoom through the same
    /// `willBeginZooming`/`didEndZooming` callbacks as a pinch. Marking those
    /// keeps them out of the probe's pinch runs, so a double-tap reset cannot
    /// replace (or add to) the summary of the pinch that came before it.
    private func setZoomScale(_ scale: CGFloat, animated: Bool) {
        if animated { isProgrammaticZoom = true }
        scrollView.setZoomScale(scale, animated: animated)
    }

    private func zoom(to rect: CGRect, animated: Bool) {
        if animated { isProgrammaticZoom = true }
        scrollView.zoom(to: rect, animated: animated)
    }

    // MARK: Gestures

    @objc private func handleSingleTap() {
        #if DEBUG
        if lastTouchDown > 0 {
            ViewerInteractionProbe.shared.tapLatency(
                milliseconds: (CACurrentMediaTime() - lastTouchDown) * 1000
            )
            lastTouchDown = 0
        }
        #endif
        onSingleTap?()
    }

    @objc private func handleDoubleTap() {
        guard imageView.image != nil else { return }
        if scrollView.zoomScale > 1.01 {
            setZoomScale(1, animated: !reduceMotion)
            return
        }
        let target: CGFloat = 2.5
        let point = doubleTap.location(in: imageView)
        let size = CGSize(
            width: scrollView.bounds.width / target,
            height: scrollView.bounds.height / target
        )
        let rect = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        zoom(to: rect, animated: !reduceMotion)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === edgePan {
            return scrollView.zoomScale > 1.01 && imageView.image != nil
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === edgePan || otherGestureRecognizer === edgePan {
            return true
        }
        return false
    }

    @objc private func handleEdgePan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: scrollView)
        let velocity = pan.velocity(in: scrollView)

        switch pan.state {
        case .began:
            handoffActive = false
            handoffStartTranslation = translation.x
        case .changed:
            if handoffActive {
                onHandoffChanged?(translation.x - handoffStartTranslation)
                return
            }
            guard scrollView.zoomScale > 1.01 else { return }
            // A vertical pan belongs to the photo (or the dismiss transition),
            // never to paging.
            guard abs(translation.x) > abs(translation.y) * 1.2 else { return }
            let direction = edgeDirection(for: translation)
            guard direction != 0 else { return }
            guard onHandoffBegan?(direction) == true else { return }
            handoffActive = true
            handoffStartTranslation = translation.x
            // Keep this scroll view's own pan recogniser live. It owns the
            // gesture, and the zoom transition's swipe-dismiss recogniser waits
            // for every other pan to fail: disabling this one mid-drag handed
            // the rest of the gesture to the system, which popped the viewer
            // with a horizontal interactive back instead of paging the roll.
            // Stopping the bounce is enough to hold the photo still at its
            // edge while the pager slides the page away.
            scrollView.bounces = false
            scrollView.contentOffset = clampedOffset(scrollView.contentOffset)
        case .ended, .cancelled, .failed:
            if handoffActive {
                let travel = pan.state == .ended
                    ? translation.x - handoffStartTranslation
                    : 0
                onHandoffEnded?(travel, velocity.x)
                handoffActive = false
                scrollView.bounces = true
                didResetPanAfterHandoff = true
                schedulePanReset()
            }
        default:
            break
        }
    }

    private func edgeDirection(for translation: CGPoint) -> Int {
        let bounds = scrollView.bounds.size
        let inset = scrollView.adjustedContentInset
        let minX = -inset.left
        let maxX = max(minX, scrollView.contentSize.width - bounds.width + inset.right)
        let slop: CGFloat = 1.5
        if scrollView.contentOffset.x <= minX + slop, translation.x > 8 {
            return -1
        }
        if scrollView.contentOffset.x >= maxX - slop, translation.x < -8 {
            return 1
        }
        return 0
    }

    private func schedulePanReset() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard let self, self.didResetPanAfterHandoff else { return }
            self.didResetPanAfterHandoff = false
            self.scrollView.panGestureRecognizer.isEnabled = self.scrollView.zoomScale > 1.01
        }
    }

    // MARK: Probe

    /// Reports live zoom, centre and over-pan to the pager, which forwards them
    /// for the photo on screen only.
    func updateProbe() {
        #if DEBUG
        guard ViewerInteractionProbe.shared.isEnabled else { return }
        let bounds = scrollView.bounds
        let focus = viewportFocus()
        let minX = -scrollView.adjustedContentInset.left
        let maxX = max(minX, scrollView.contentSize.width - bounds.width + scrollView.adjustedContentInset.right)
        let overpan = max(0, minX - scrollView.contentOffset.x)
            + max(0, scrollView.contentOffset.x - maxX)
        onZoomMetrics?(scrollView.zoomScale, focus.x, focus.y, overpan)
        #endif
    }

    #if DEBUG
    /// The scroll view's insets as a size, so a pinch run can prove the zoom
    /// layout never rewrites them mid-gesture (the churn that made a zoom-out
    /// move in steps).
    private func viewportInset() -> CGSize {
        CGSize(
            width: scrollView.contentInset.left + scrollView.contentInset.right,
            height: scrollView.contentInset.top + scrollView.contentInset.bottom
        )
    }

    /// Where the point at the centre of the viewport falls in the photo, as a
    /// fraction of the photo's size — (0.5, 0.5) when the photo is centred.
    /// The photo is centred by moving the zooming view rather than by insetting
    /// the scroll view, so translate the point instead of reading
    /// `contentOffset`, which no longer carries any centring.
    private func viewportFocus() -> CGPoint {
        guard imageView.bounds.width > 0, imageView.bounds.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let bounds = scrollView.bounds
        let point = scrollView.convert(
            CGPoint(x: bounds.midX, y: bounds.midY),
            to: imageView
        )
        return CGPoint(
            x: point.x / imageView.bounds.width,
            y: point.y / imageView.bounds.height
        )
    }
    #endif
}

#if DEBUG
/// A single-tap recogniser that reports when the finger lands, so the probe can
/// measure the real finger-down to chrome-toggle latency without adding a
/// second gesture recogniser that would compete with scrolling.
private final class TrackingTapGestureRecognizer: UITapGestureRecognizer {
    var onTouchDown: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onTouchDown?()
    }
}
#endif

/// Refuses to let the zoom transition's dismiss recogniser begin on a mostly
/// horizontal drag, while forwarding everything else to the delegate the system
/// installed. A vertical pull still dismisses the viewer.
@MainActor
final class HorizontalDismissGate: NSObject, UIGestureRecognizerDelegate {
    private(set) weak var gesture: UIGestureRecognizer?
    private weak var forwarding: UIGestureRecognizerDelegate?

    init(gesture: UIGestureRecognizer, forwarding: UIGestureRecognizerDelegate?) {
        self.gesture = gesture
        self.forwarding = forwarding
    }

    func restore() {
        // Only take the delegate back if it is still ours; UIKit may have
        // replaced it while the transition ran.
        if gesture?.delegate === self {
            gesture?.delegate = forwarding
        }
    }

    /// Remembers a delegate UIKit installed in place of this gate.
    func adopt(_ delegate: UIGestureRecognizerDelegate?) {
        guard delegate !== self else { return }
        forwarding = delegate
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: pan.view)
            if abs(velocity.x) > abs(velocity.y) { return false }
        }
        return forwarding?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        forwarding?.gestureRecognizer?(gestureRecognizer, shouldReceive: touch) ?? true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // UIKit's default without a delegate is no simultaneous recognition;
        // keep that unless the system's own delegate said otherwise.
        forwarding?.gestureRecognizer?(gestureRecognizer, shouldRecognizeSimultaneouslyWith: other) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        forwarding?.gestureRecognizer?(gestureRecognizer, shouldBeRequiredToFailBy: other) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        forwarding?.gestureRecognizer?(gestureRecognizer, shouldRequireFailureOf: other) ?? false
    }
}
#endif
