import SwiftUI

struct ViewerScreen: View {
    let presentation: ViewerPresentation

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.viewerZoomNamespace) private var zoomNamespace
    @State private var selection: String
    @State private var panel: ViewerPanel?
    @State private var chromeVisible = true
    @State private var showPanel = false
    @State private var pullDown: CGFloat = 0
    @State private var isPastDismissThreshold = false
    @State private var isDismissing = false

    init(presentation: ViewerPresentation) {
        self.presentation = presentation
        _selection = State(initialValue: presentation.startID)
        _panel = State(initialValue: presentation.panel)
        _showPanel = State(initialValue: presentation.panel != nil)
    }

    private var photo: PhotoItem? {
        app.catalog.photo(id: selection)
    }

    private var ids: [String] {
        presentation.photoIDs
    }

    private var index: Int {
        ids.firstIndex(of: selection) ?? 0
    }

    /// 0 while resting, 1 at the full dismiss distance.
    private var dismissProgress: CGFloat {
        min(1, max(0, pullDown / 340))
    }

    private var dismissThreshold: CGFloat { 140 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if os(iOS)
            TabView(selection: $selection) {
                ForEach(ids, id: \.self) { id in
                    ViewerPage(
                        photoID: id,
                        chromeVisible: $chromeVisible,
                        pullDown: $pullDown,
                        onWillDismiss: { isDismissing = true },
                        onDismiss: close
                    )
                    .tag(id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            #else
            ViewerPage(
                photoID: selection,
                chromeVisible: $chromeVisible,
                pullDown: $pullDown,
                onWillDismiss: { isDismissing = true },
                onDismiss: close
            )
                .ignoresSafeArea()
                .overlay(alignment: .leading) { pagerArrow(symbol: "chevron.left", enabled: index > 0) }
                .overlay(alignment: .trailing) { pagerArrow(symbol: "chevron.right", enabled: index < ids.count - 1) }
                .onKeyPress(.leftArrow) { move(-1); return .handled }
                .onKeyPress(.rightArrow) { move(1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
            #endif

            chrome
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden()
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        #endif
        // On iOS the zoom transition supplies Photos' interactive swipe-down
        // dismissal (a vertical drag shrinks the viewer back into its tile),
        // and the zoomed page's own pan gesture takes over while magnified.
        // macOS keeps the custom pull below.
        .viewerZoomTransition(id: selection, in: zoomNamespace, reduceMotion: reduceMotion)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.32, extraBounce: 0.02), value: chromeVisible)
        .sensoryFeedback(.impact(weight: .medium), trigger: isPastDismissThreshold)
        .sensoryFeedback(.impact(weight: .light), trigger: photo?.isFavorite ?? false)
        .onChange(of: pullDown) { _, value in
            let past = value > dismissThreshold
            if past != isPastDismissThreshold { isPastDismissThreshold = past }
        }
        .onChange(of: selection) { _, _ in
            pullDown = 0
            isPastDismissThreshold = false
        }
        .task(id: selection) { prefetchNeighbours() }
        .sheet(isPresented: $showPanel) {
            if let photo, let panel {
                PhotoInfoSheet(photoID: photo.id, initialPanel: panel)
                    .environment(app)
            }
        }
        .onChange(of: panel) { _, value in
            if value != nil { showPanel = true }
        }
        .onChange(of: showPanel) { _, value in
            if !value { panel = nil }
        }
    }

    private func close() {
        pullDown = 0
        app.viewer = nil
    }

    /// Keeps the two photos on either side warm at low priority. Changing page
    /// cancels everything outside the new window.
    private func prefetchNeighbours() {
        let lower = max(0, index - 2)
        let upper = min(ids.count, index + 3)
        guard lower < upper else { return }
        let photos = ids[lower..<upper].compactMap { app.catalog.photo(id: $0) }
        app.images.prefetchViewerPreviews(for: photos, size: CGSize(width: 1200, height: 1200))
    }

    // MARK: Chrome

    private var chrome: some View {
        ZStack {
            if chromeVisible {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(chromeTransition(edge: .top))
            }
            if chromeVisible {
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(chromeTransition(edge: .bottom))
            }
        }
        .opacity(isDismissing ? 0 : max(0, 1 - dismissProgress * 2.4))
        .allowsHitTesting(!isDismissing && dismissProgress < 0.15)
    }

    private func chromeTransition(edge: Edge) -> AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .move(edge: edge).combined(with: .opacity)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")

            VStack(alignment: .leading, spacing: 1) {
                Text(photo?.takenAt?.dayLabel ?? "Photo")
                    .font(.subheadline.weight(.semibold))
                if let taken = photo?.takenAt {
                    Text(taken.timeLabel)
                        .font(.caption2)
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassSurface(14)

            Spacer()

            if let photo {
                Button {
                    app.toggleFavorite(photo.id)
                } label: {
                    Image(systemName: photo.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(photo.isFavorite ? Theme.accent : Color.primary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(photo.isFavorite ? "Remove favorite" : "Favorite")
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            viewerAction(panel: .info, symbol: "info.circle", label: "Info")
            viewerAction(panel: .tags, symbol: "tag", label: "Tag")
            viewerAction(panel: .people, symbol: "person.2", label: "People")

            #if os(iOS)
            if let photo, photo.isRemoteOnly {
                Button {
                    Task { await saveToPhotos(photo) }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Save")
                            .font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save to photo library")
            }
            #endif
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: 420)
        .glassSurface(28)
        .padding(.bottom, 6)
    }

    private func viewerAction(panel target: ViewerPanel, symbol: String, label: String) -> some View {
        Button {
            panel = target
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityLabel(label)
    }

    #if os(macOS)
    private func pagerArrow(symbol: String, enabled: Bool) -> some View {
        Button {
            move(symbol.contains("left") ? -1 : 1)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .padding(24)
    }

    private func move(_ delta: Int) {
        let next = index + delta
        guard ids.indices.contains(next) else { return }
        selection = ids[next]
    }
    #endif

    private func saveToPhotos(_ photo: PhotoItem) async {
        guard let server = app.servers.server(id: photo.copies.first?.serverID ?? photo.serverID),
              let client = app.servers.client(for: server),
              let key = photo.copy(on: server.id)?.objectKey,
              !key.isEmpty,
              let data = try? await client.getObject(key: key) else {
            app.errorMessage = "Could not download that photo."
            return
        }
        #if os(iOS)
        do {
            try await PhotoLibraryService.shared.saveToLibrary(
                data: data,
                filename: photo.filename,
                isVideo: photo.isVideo
            )
        } catch {
            app.errorMessage = "Could not add that item to your photo library."
        }
        #endif
    }
}

struct ViewerPage: View {
    let photoID: String
    @Binding var chromeVisible: Bool
    @Binding var pullDown: CGFloat
    var onWillDismiss: () -> Void
    var onDismiss: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: PlatformImage?
    @State private var imageID = 0
    @State private var isLoading = true
    @State private var failure: String?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1
    @State private var lastOffset: CGSize = .zero

    private var photo: PhotoItem? { app.catalog.photo(id: photoID) }

    /// Distance at which releasing the swipe dismisses the viewer.
    private let dismissDistance: CGFloat = 140
    private let dismissVelocity: CGFloat = 260

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    pageImage(image)
                } else if let failure {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text(failure)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        if photo?.isRemoteOnly == true {
                            Text("Downloading from \(serverName)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .offset(y: reduceMotion ? 0 : pullDown)
            .scaleEffect(reduceMotion ? 1 : pullScale)
            .opacity(reduceMotion ? 1 - pullProgress * 0.45 : 1)
            #if os(iOS)
            // Reduce Motion removes the zoom transition (and its built-in
            // swipe-down), so the fade fallback gets its own recogniser.
            .gesture(
                VerticalDismissGesture(
                    isEnabled: reduceMotion,
                    onChanged: { translation in
                        pullDown = translation > 0 ? translation : 0
                    },
                    onEnded: { predicted in
                        finishPull(predicted: predicted)
                    }
                )
            )
            #else
            .simultaneousGesture(drag)
            #endif
            .onTapGesture {
                withAnimation(.backuGentle) { chromeVisible.toggle() }
            }
        }
        .task(id: photoID) { await load() }
    }

    private var pullProgress: CGFloat {
        min(1, max(0, pullDown / 340))
    }

    private var pullScale: CGFloat {
        guard scale <= 1 else { return 1 }
        return 1 - pullProgress * 0.26
    }

    @ViewBuilder
    private func pageImage(_ image: PlatformImage) -> some View {
        if scale > 1 {
            baseImage(image)
                .id(imageID)
                .transition(.opacity)
                .gesture(panGesture)
        } else {
            baseImage(image)
                .id(imageID)
                .transition(.opacity)
        }
    }

    private func baseImage(_ image: PlatformImage) -> some View {
        Image(platformImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnification)
            .onTapGesture(count: 2) { toggleZoom() }
            .animation(.backuSnappy, value: scale)
            .animation(.backuSnappy, value: offset)
    }

    private func finishPull(predicted: CGFloat) {
        let shouldDismiss = pullDown > dismissDistance
            || (predicted > dismissVelocity && pullDown > 40)
        if shouldDismiss {
            // macOS sheet only: bring the photo back to centre, then let the
            // sheet go, so it does not slide away with the drag offset baked in.
            onWillDismiss()
            withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.14)) {
                pullDown = 0
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(170))
                onDismiss()
            }
        } else {
            withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.34, dampingFraction: 0.82)) {
                pullDown = 0
            }
        }
    }

    private var serverName: String {
        app.servers.server(id: photo?.copies.first?.serverID ?? photo?.serverID)?.name ?? "storage"
    }

    private func load() async {
        guard let photo else {
            failure = "This photo is no longer available."
            isLoading = false
            return
        }
        isLoading = true
        failure = nil
        scale = 1
        offset = .zero
        lastScale = 1
        lastOffset = .zero

        // The grid thumbnail is already decoded: paint it in the same frame so
        // the viewer opens on the photo instead of a spinner.
        if image == nil {
            if let quick = app.images.cachedPreview(for: photo) {
                image = quick
                imageID += 1
            }
        }

        let mediumSize = CGSize(width: 1200, height: 1200)
        if let medium = await app.images.thumbnail(for: photo, size: mediumSize) {
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                image = medium
                imageID += 1
            }
        }

        let full = await app.images.fullImage(for: photo)
        guard !Task.isCancelled else { return }
        if let full {
            withAnimation(.easeOut(duration: 0.25)) {
                image = full
                imageID += 1
            }
        } else if image == nil {
            failure = photo.isRemoteOnly
                ? "Could not download this photo from \(serverName)."
                : "This photo is not available on this device."
        }
        isLoading = false
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 8)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 {
                    scale = 1
                    offset = .zero
                    lastOffset = .zero
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    /// macOS only: the sheet has no pager, so one drag handles both panning and
    /// the swipe-down.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if scale > 1 {
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                    return
                }
                // Horizontal drags belong to the pager; only lock in once the
                // finger is clearly travelling vertically.
                let isVertical = abs(value.translation.height) > abs(value.translation.width) * 1.2
                guard isVertical else {
                    if pullDown != 0 { pullDown = 0 }
                    return
                }
                let height = value.translation.height
                pullDown = height > 0 ? height : height / 4
            }
            .onEnded { value in
                if scale > 1 {
                    lastOffset = offset
                    return
                }
                finishPull(predicted: value.predictedEndTranslation.height)
            }
    }

    private func toggleZoom() {
        withAnimation(.backuSnappy) {
            if scale > 1 {
                scale = 1
                offset = .zero
                lastOffset = .zero
            } else {
                scale = 2.4
            }
            lastScale = scale
        }
    }
}



#if os(iOS)
/// A vertical-only pan used when Reduce Motion replaces the zoom transition.
/// Failing horizontal drags leaves the pager untouched.
private struct VerticalDismissGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled = true
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((CGFloat) -> Void)?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard abs(velocity.y) > 0.5 else { return false }
            return abs(velocity.y) > abs(velocity.x) * 1.2
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).y
        switch recognizer.state {
        case .began, .changed:
            context.coordinator.onChanged?(translation)
        case .ended:
            let velocity = recognizer.velocity(in: recognizer.view).y
            context.coordinator.onEnded?(translation + velocity * 0.18)
        case .cancelled, .failed:
            context.coordinator.onEnded?(0)
        default:
            break
        }
    }
}
#endif
