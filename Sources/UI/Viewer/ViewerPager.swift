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
    var onSingleTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeUIViewController(context: Context) -> ViewerPagerController {
        let controller = ViewerPagerController(app: app)
        controller.onSelectionChanged = { [weak coordinator = context.coordinator] id in
            coordinator?.select(id)
        }
        controller.onSingleTap = onSingleTap
        controller.update(photos: photos, selection: selection, reduceMotion: reduceMotion)
        return controller
    }

    func updateUIViewController(_ controller: ViewerPagerController, context: Context) {
        context.coordinator.selection = $selection
        controller.onSingleTap = onSingleTap
        controller.update(photos: photos, selection: selection, reduceMotion: reduceMotion)
    }

    @MainActor
    final class Coordinator {
        var selection: Binding<String>

        init(selection: Binding<String>) {
            self.selection = selection
        }

        func select(_ id: String) {
            if selection.wrappedValue != id {
                selection.wrappedValue = id
            }
        }
    }
}

/// A paged, horizontally scrolling container of `ViewerZoomPageController`s.
@MainActor
final class ViewerPagerController: UIViewController, UIScrollViewDelegate {
    private let app: AppModel
    private let scrollView = UIScrollView()
    private var pages: [ViewerZoomPageController] = []
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
    }

    // MARK: Data

    func update(photos: [PhotoItem], selection: String, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        let ids = photos.map(\.id)
        if ids != photoIDs {
            photoIDs = ids
            self.photos = photos
            rebuildPages()
        } else {
            self.photos = photos
            for page in pages {
                page.reduceMotion = reduceMotion
            }
        }
        self.selection = selection
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

    /// One zoom page per photo. Pages are cheap until they become visible: they
    /// only load an image once the pager activates them.
    private func rebuildPages() {
        loadViewIfNeeded()
        for page in pages {
            page.willMove(toParent: nil)
            page.view.removeFromSuperview()
            page.removeFromParent()
        }
        pages = photos.enumerated().map { index, photo in
            let page = ViewerZoomPageController(photo: photo, app: app)
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
            addChild(page)
            page.view.frame = view.bounds
            scrollView.addSubview(page.view)
            page.didMove(toParent: self)
            return page
        }
        settledIndex = min(max(0, index(of: selection)), max(0, pages.count - 1))
        pendingIndex = settledIndex
        scrollView.contentSize = .zero
        lastLayoutSize = .zero
        needsInitialScroll = true
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0 else { return }

        let widthChanged = abs(pageWidth - size.width) > 0.5
        pageWidth = size.width
        scrollView.frame = view.bounds
        scrollView.contentSize = CGSize(
            width: size.width * CGFloat(max(1, pages.count)),
            height: size.height
        )
        for (i, page) in pages.enumerated() {
            page.view.frame = CGRect(x: size.width * CGFloat(i), y: 0, width: size.width, height: size.height)
        }

        if widthChanged || size != lastLayoutSize || needsInitialScroll {
            lastLayoutSize = size
            let index = needsInitialScroll ? index(of: selection) : settledIndex
            pendingIndex = index
            scrollView.setContentOffset(CGPoint(x: size.width * CGFloat(index), y: 0), animated: false)
            needsInitialScroll = false
            settle(at: index, notify: false)
        }
    }

    // MARK: Paging

    private func scrollToSelection(animated: Bool) {
        guard pages.indices.contains(index(of: selection)), pageWidth > 0 else { return }
        let target = index(of: selection)
        pendingIndex = target
        scrollView.setContentOffset(
            CGPoint(x: pageWidth * CGFloat(target), y: 0),
            animated: animated
        )
        if !animated { settle(at: target, notify: false) }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartIndex = min(max(0, pendingIndex), max(0, pages.count - 1))
    }

    /// Photos pages exactly one photo per flick, never several at once, and
    /// never none because a flick arrived while the previous settle was still
    /// running.
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard pageWidth > 1, !pages.isEmpty, edgeDragFrom == nil else { return }
        let proposed = Int((targetContentOffset.pointee.x / pageWidth).rounded())
        let target = min(max(proposed, dragStartIndex - 1), min(dragStartIndex + 1, pages.count - 1))
        pendingIndex = min(max(target, 0), pages.count - 1)
        targetContentOffset.pointee.x = pageWidth * CGFloat(pendingIndex)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard pageWidth > 1, !pages.isEmpty else { return }
        let raw = scrollView.contentOffset.x / pageWidth
        let candidate = min(max(Int(raw.rounded()), 0), pages.count - 1)
        guard candidate != settledIndex else { return }
        settle(at: candidate, notify: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleToNearest()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settleToNearest()
    }

    private func settleToNearest() {
        guard pageWidth > 1, !pages.isEmpty else { return }
        let index = min(max(Int((scrollView.contentOffset.x / pageWidth).rounded()), 0), pages.count - 1)
        pendingIndex = index
        settle(at: index, notify: true)
    }

    private func settle(at index: Int, notify: Bool) {
        let index = min(max(index, 0), max(0, pages.count - 1))
        settledIndex = index
        selection = photoIDs.indices.contains(index) ? photoIDs[index] : selection
        activate(index)
        #if DEBUG
        ViewerInteractionProbe.shared.pageChanged(index, count: pages.count)
        #endif
        if notify, let id = photoIDs[safe: index] {
            onSelectionChanged?(id)
        }
    }

    private func activate(_ index: Int) {
        for (i, page) in pages.enumerated() {
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
        let currentIsZoomed = pages[safe: settledIndex]?.isZoomed ?? false
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
        guard delta != 0, pages.indices.contains(index + delta) else { return false }
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
        target = min(max(target, 0), max(0, pages.count - 1))
        edgeDragFrom = nil
        edgeDragDirection = 0
        pendingIndex = target
        for (i, page) in pages.enumerated() where i != target {
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
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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

    private var singleTap: UITapGestureRecognizer!
    private var doubleTap: UITapGestureRecognizer!
    private var edgePan: UIPanGestureRecognizer!

    var onSingleTap: (() -> Void)?
    var onHandoffBegan: ((_ delta: Int) -> Bool)?
    var onHandoffChanged: ((CGFloat) -> Void)?
    var onHandoffEnded: ((_ translation: CGFloat, _ velocity: CGFloat) -> Void)?
    var onZoomStateChanged: ((_ zoomed: Bool) -> Void)?
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

        singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        scrollView.addGestureRecognizer(doubleTap)

        edgePan = UIPanGestureRecognizer(target: self, action: #selector(handleEdgePan))
        edgePan.delegate = self
        edgePan.maximumNumberOfTouches = 1
        edgePan.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(edgePan)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        scrollView.frame = view.bounds
        if size != lastBoundsSize {
            lastBoundsSize = size
            layoutImage(resetZoom: true)
        }
        spinner.center = CGPoint(x: size.width / 2, y: size.height / 2)
    }

    // MARK: Activation + loading

    func setActivation(_ level: Activation) {
        let previous = activation
        activation = level
        switch level {
        case .idle:
            guard previous != .idle else { return }
            wantsFull = false
            loadGeneration &+= 1
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
            loadedFinal = false
            imageView.image = nil
            appliedImageSize = .zero
            spinner.stopAnimating()
            statusLabel.isHidden = true
            resetZoom(animated: false)
        case .neighbor:
            wantsFull = false
            if previous == .idle {
                ensureLoading()
            }
        case .current:
            wantsFull = true
            ensureLoading()
        }
    }

    private func ensureLoading() {
        if wantsFull && loadedFinal { return }
        guard !isLoading else { return }
        isLoading = true
        let generation = loadGeneration

        if imageView.image == nil, let quick = app.images.cachedPreview(for: photo) {
            show(quick, final: false)
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
            if let medium = await self.app.images.thumbnail(
                for: self.photo,
                size: CGSize(width: 1200, height: 1200)
            ) {
                if Task.isCancelled || generation != self.loadGeneration { return }
                self.show(medium, final: false)
            }
            if self.wantsFull && !self.loadedFinal {
                if let full = await self.app.images.fullImage(for: self.photo) {
                    if Task.isCancelled || generation != self.loadGeneration { return }
                    self.show(full, final: true)
                } else if self.imageView.image == nil {
                    self.showFailure()
                }
            }
            guard !Task.isCancelled, generation == self.loadGeneration else { return }
            self.isLoading = false
            self.loadTask = nil
            if self.wantsFull && !self.loadedFinal, self.activation == .current {
                self.ensureLoading()
            }
        }
    }

    private func show(_ image: PlatformImage, final: Bool) {
        spinner.stopAnimating()
        statusLabel.isHidden = true
        let hadImage = imageView.image != nil
        let sizeChanged = appliedImageSize != image.size
        if hadImage && !sizeChanged && scrollView.zoomScale <= 1.01 {
            UIView.transition(
                with: imageView,
                duration: 0.16,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                self.imageView.image = image
            }
        } else {
            imageView.image = image
        }
        appliedImageSize = image.size
        if sizeChanged || imageView.bounds.isEmpty {
            layoutImage(resetZoom: scrollView.zoomScale <= 1.01)
        }
        if final { loadedFinal = true }
        updateProbe()
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

    private func layoutImage(resetZoom: Bool) {
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            imageView.frame = .zero
            scrollView.contentSize = bounds
            scrollView.contentInset = .zero
            return
        }
        let fit = Self.aspectFit(image.size, in: bounds)
        if resetZoom {
            scrollView.setZoomScale(1, animated: false)
            imageView.transform = .identity
            imageView.frame = CGRect(origin: .zero, size: fit)
            scrollView.contentSize = fit
            centerContent()
        } else if imageView.bounds.size != fit {
            // A different aspect ratio arrived while zoomed; settle back to 1x
            // rather than leaving the old offset pointing at empty space.
            scrollView.setZoomScale(1, animated: false)
            imageView.transform = .identity
            imageView.frame = CGRect(origin: .zero, size: fit)
            scrollView.contentSize = fit
            centerContent()
        }
        updatePanAvailability()
    }

    private static func aspectFit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func centerContent() {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        let insets = UIEdgeInsets(
            top: max(0, (bounds.height - content.height) / 2),
            left: max(0, (bounds.width - content.width) / 2),
            bottom: max(0, (bounds.height - content.height) / 2),
            right: max(0, (bounds.width - content.width) / 2)
        )
        if scrollView.contentInset != insets {
            scrollView.contentInset = insets
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

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updatePanAvailability()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale <= 1.01 {
            scrollView.setZoomScale(1, animated: false)
            centerContent()
        }
        updatePanAvailability()
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
            scrollView.setZoomScale(1, animated: true)
        } else {
            scrollView.setZoomScale(1, animated: false)
            centerContent()
            scrollView.contentOffset = .zero
        }
        updatePanAvailability()
        updateProbe()
    }

    // MARK: Gestures

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap() {
        guard imageView.image != nil else { return }
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: !reduceMotion)
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
        scrollView.zoom(to: rect, animated: !reduceMotion)
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
            // The image is at its edge: stop its own rubber-band so the pager
            // gets the whole gesture.
            scrollView.panGestureRecognizer.isEnabled = false
        case .ended, .cancelled, .failed:
            if handoffActive {
                let travel = pan.state == .ended
                    ? translation.x - handoffStartTranslation
                    : 0
                onHandoffEnded?(travel, velocity.x)
                didResetPanAfterHandoff = true
                handoffActive = false
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

    private func updateProbe() {
        #if DEBUG
        guard ViewerInteractionProbe.shared.isEnabled else { return }
        let bounds = scrollView.bounds
        let inset = scrollView.adjustedContentInset
        let zoom = max(scrollView.zoomScale, 0.01)
        let imageSize = imageView.bounds.size
        let centerX = imageSize.width > 0
            ? (scrollView.contentOffset.x + bounds.width / 2 - inset.left) / zoom / imageSize.width
            : 0.5
        let centerY = imageSize.height > 0
            ? (scrollView.contentOffset.y + bounds.height / 2 - inset.top) / zoom / imageSize.height
            : 0.5
        let minX = -inset.left
        let maxX = max(minX, scrollView.contentSize.width - bounds.width + inset.right)
        let overpan = max(0, minX - scrollView.contentOffset.x)
            + max(0, scrollView.contentOffset.x - maxX)
        ViewerInteractionProbe.shared.zoomChanged(
            scale: scrollView.zoomScale,
            centerX: centerX,
            centerY: centerY,
            overpan: overpan
        )
        #endif
    }
}
#endif
