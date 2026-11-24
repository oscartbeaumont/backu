import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All Items"
    case favorites = "Favourites"
    case videos = "Videos"
    case photos = "Photos"
    case pending = "Not Backed Up"
    case people = "With People"
    case located = "With Location"
    case local = "On This Device"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "heart"
        case .videos: return "play.rectangle"
        case .photos: return "photo"
        case .pending: return "icloud.slash"
        case .people: return "person.2"
        case .located: return "location"
        case .local: return "iphone"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case added = "Added"
    case captured = "Captured"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .added: return "clock"
        case .captured: return "camera"
        }
    }
}

/// One month of the timeline. Sections are built once per catalog/filter change
/// so scrolling only lays out views; it never regroups the library.
struct LibraryMonthSection: Identifiable {
    var id: String
    var monthStart: Date
    var title: String
    var items: [LibraryItem]
    /// Mirrors `items.map(\.photo)`, built once so a card body never allocates.
    var photos: [PhotoItem]
    var cover: LibraryItem
    var dayText: String
}

/// One year of the timeline.
struct LibraryYearSection: Identifiable {
    var id: Int
    var year: Int
    var items: [LibraryItem]
    var photos: [PhotoItem]
    var cover: LibraryItem
    var firstMonthID: String?
}

/// A mutable box that does not invalidate the view: the grid's frame changes on
/// every scroll tick, and only the derived labels should cause updates.
@MainActor
final class TimelineMetrics {
    var frame: CGRect = .zero
    var scrollTop: CGFloat = 0
    /// Last scroll distance, used to tell a forward fling from a reversal.
    var travelled: CGFloat = 0
    var direction: ScrollDirection = .forward
    var phase: ScrollPhase = .idle
    /// Mean aspect ratio of the library, used to estimate row height at the
    /// full-width level (where every row is a different height).
    var averageAspect: CGFloat = 1
}

/// One row of the cached grid. Built once per catalog/filter change so a tile
/// never has to ask the catalog for its backup state or format a date.
struct LibraryItem: Identifiable {
    var photo: PhotoItem
    var backupState: AppModel.BackupState
    var dateText: String?

    var id: String { photo.id }
}

struct LibrarySummary: Equatable {
    var count = 0
    var backedUp = 0
    var pending = 0
}

/// Throttles prefetch-window changes. Scrolling is reported per tick, and the
/// prefetcher re-arms at most every ~50 ms while idle, so a settled grid stays
/// cheap. During a drag or fling the window is applied immediately instead
/// (see `LibraryScreen.timeline`), so the lead screens are warmed from the
/// first tick rather than 80 ms later.
@MainActor
final class ScrollWindow {
    private var applied: Range<Int>?
    private var pending: Range<Int>?
    private var task: Task<Void, Never>?
    private var lastAppliedAt = Date.distantPast
    private let interval: TimeInterval = 0.05

    func request(
        _ range: Range<Int>,
        immediate: Bool = false,
        apply: @escaping @MainActor (Range<Int>) -> Void
    ) {
        if applied == range { return }
        if immediate || Date().timeIntervalSince(lastAppliedAt) >= interval {
            applyNow(range, apply)
            return
        }
        pending = range
        guard task == nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled, let next = self.pending else { return }
            self.applyNow(next, apply)
        }
    }

    private func applyNow(_ range: Range<Int>, _ apply: @MainActor (Range<Int>) -> Void) {
        task?.cancel()
        task = nil
        pending = nil
        applied = range
        lastAppliedAt = Date()
        apply(range)
    }

    func invalidate() {
        applied = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}

struct LibraryScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var filter: LibraryFilter = .all
    @State private var sort: LibrarySort = .captured
    @State private var showFilterPanel = false
    @State private var pendingLevelScroll: (target: String, anchor: UnitPoint)?
    @State private var isSelecting = false
    @State private var selectedPhotoIDs: Set<String> = []
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var dragSelectionBase: Set<String>?
    @State private var dragAnchorID: String?
    @State private var dragDeselecting = false
    @State private var selectionHaptic = 0
    @State private var isPreparingShare = false
    @State private var shareURLs: [URL] = []
    @State private var showShareSheet = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var items: [LibraryItem] = []
    @State private var photos: [PhotoItem] = []
    @State private var monthSections: [LibraryMonthSection] = []
    @State private var yearSections: [LibraryYearSection] = []
    @State private var summary = LibrarySummary()
    @State private var metrics = TimelineMetrics()
    @State private var window = ScrollWindow()
    @State private var prefetcher = ThumbnailPrefetcher()
    @State private var viewWidth: CGFloat = 0
    @State private var viewHeight: CGFloat = 0
    @State private var pinchBaseColumns: Int?
    @State private var pinchPreviewColumns: Int?
    @State private var pinchHaptic = 0
    #if DEBUG
    @State private var monthPillHeight: CGFloat = 0
    #endif

    private let calendar = Calendar(identifier: .gregorian)

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter
    }()

    #if DEBUG
    /// Test seam for the date-pill overflow case: a full month name is wider
    /// than a phone screen at large Dynamic Type, while the shipped "MMM yyyy"
    /// form is not. Enabled with `BACKU_MONTH_TITLE_STYLE=long`.
    private static let longMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private var monthTitleFormatter: DateFormatter {
        ProcessInfo.processInfo.environment["BACKU_MONTH_TITLE_STYLE"] == "long"
            ? Self.longMonthFormatter
            : Self.monthFormatter
    }
    #else
    private var monthTitleFormatter: DateFormatter { Self.monthFormatter }
    #endif

    /// Columns added on top of the stored preference for roomier layouts.
    private var columnExtra: Int {
        #if os(macOS)
        return 3
        #else
        return sizeClass == .compact ? 0 : 2
        #endif
    }

    private var columns: Int {
        let base = app.settings.gridColumns
        // Full width is a deliberate level, not a density that gains extra
        // columns on a roomier screen.
        if base <= 1 { return 1 }
        #if os(macOS)
        return min(8, base + columnExtra)
        #else
        return sizeClass == .compact ? base : min(8, base + columnExtra)
        #endif
    }

    private var level: LibraryLevel { app.libraryLevel }

    private var gridSpacing: CGFloat { 2 }

    var body: some View {
        GeometryReader { proxy in
            timeline(
                width: proxy.size.width,
                topInset: proxy.safeAreaInsets.top,
                availableHeight: proxy.size.height
            )
        }
        #if DEBUG
        .modifier(DebugTextSizeModifier())
        #endif
    }

    private func timeline(width: CGFloat, topInset: CGFloat, availableHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // One lazy container per level: a LazyVGrid for All, a
                // LazyVStack for Months/Years. The wrappers are plain VStacks,
                // so no lazy container is nested inside another; headers are
                // ordinary siblings and never consume a grid cell.
                timelineContent(width: width, topInset: topInset)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.pageBackground)
            .coordinateSpace(name: "libraryGrid")
            .onPreferenceChange(TileFramePreferenceKey.self) { frames in
                if isSelecting, tileFrames != frames { tileFrames = frames }
            }
            #if DEBUG
            // Measured on the ScrollView, outside the scroll content, so the
            // probe element can never participate in a card's layout or its
            // accessibility frame.
            .onPreferenceChange(MonthPillHeightKey.self) { monthPillHeight = $0 }
            #endif
            .safeAreaInset(edge: .top, spacing: 0) {
                if level != .all {
                    Color.clear.frame(height: topInset + 54)
                }
            }
            #if os(iOS)
            .ignoresSafeArea(edges: .top)
            #endif
            .onScrollPhaseChange { _, phase in
                metrics.phase = phase
                // A drag or fling has begun: re-arm the prefetch window now
                // rather than waiting out the idle throttle. This is the
                // difference between the lead screens being warm and the fling
                // outrunning the prefetcher.
                if phase != .idle { updateTimeline() }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { old, new in
                guard abs(new - old) > 0.5 else { return }
                let direction: ScrollDirection = new > old ? .forward : .backward
                if direction != metrics.direction {
                    metrics.direction = direction
                    // Reversing direction moves the lead to the other side of
                    // the viewport; apply that at once too.
                    updateTimeline()
                }
            }
            .onGeometryChange(for: CGFloat.self) { view in
                view.frame(in: .global).minY
            } action: { value in
                metrics.scrollTop = value
                updateTimeline()
            }
            .overlay(alignment: .top) {
                StatusBarScrim(topInset: topInset, isVisible: true)
            }
            .overlay(alignment: .top) {
                LibraryTopBar(
                    title: isSelecting
                        ? (selectedPhotoIDs.isEmpty ? "Select Photos" : "\(selectedPhotoIDs.count) Selected")
                        : "Library",
                    isSelecting: isSelecting,
                    isFiltered: filter != .all,
                    filterSymbol: filter.symbol,
                    onFilter: {
                        withAnimation(.backuSnappy) { showFilterPanel.toggle() }
                    },
                    onToggleSelection: toggleSelectionMode
                )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                #if os(iOS)
                if isSelecting {
                    LibrarySelectionBar(
                        selectedCount: selectedPhotoIDs.count,
                        allSelected: !items.isEmpty && selectedPhotoIDs.count == items.count,
                        isPreparingShare: isPreparingShare,
                        onShare: { Task { await shareSelected() } },
                        onToggleAll: toggleAllSelection,
                        onDelete: { showDeleteConfirm = true }
                    )
                    .padding(.top, 6)
                    .padding(.bottom, 8 + bottomBarClearance)
                }
                #endif
            }
            .overlay {
                if showFilterPanel {
                    filterPanelOverlay(topInset: topInset)
                }
            }
            .overlay {
                if isDeleting {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView("Deleting…")
                            .padding(18)
                            .glassSurface(18)
                    }
                    .transition(.opacity)
                }
            }
            #if DEBUG
            .overlay(alignment: .bottomTrailing) { TileLoadProbeView() }
            .overlay(alignment: .topTrailing) {
                LibraryRuntimeProbeView(monthPillHeight: monthPillHeight)
            }
            #endif
            .onAppear {
                self.viewWidth = width
                self.viewHeight = availableHeight
            }
            .onChange(of: width) { _, value in
                viewWidth = value
                window.invalidate()
                requestWindow(immediate: true)
            }
            .onChange(of: availableHeight) { _, value in
                viewHeight = value
                requestWindow()
            }
            .animation(.backuGentle, value: app.remoteSyncMessage)
            .onChange(of: filter) { _, _ in
                withAnimation(.backuSnappy) {
                    proxy.scrollTo("library.top", anchor: .top)
                }
            }
            .onChange(of: app.libraryLevel) { _, newLevel in
                if newLevel != .all {
                    prefetcher.stop()
                    window.cancel()
                }
                let pending = pendingLevelScroll
                pendingLevelScroll = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(90))
                    proxy.scrollTo(pending?.target ?? "library.top", anchor: pending?.anchor ?? .top)
                    if newLevel == .all {
                        window.invalidate()
                        requestWindow(immediate: true)
                    }
                }
            }
        }
        .task {
            rebuildContent()
        }
        .onChange(of: app.catalog.version) { _, _ in rebuildContent() }
        .onChange(of: filter) { _, _ in rebuildContent() }
        .onChange(of: sort) { _, _ in rebuildContent() }
        .onChange(of: app.settings.showRemoteOnlyPhotos) { _, _ in rebuildContent() }
        .onChange(of: app.settings.backupServerIDs) { _, _ in rebuildContent() }
        .onChange(of: app.settings.gridColumns) { _, _ in
            window.invalidate()
            requestWindow(immediate: true)
        }
        .onChange(of: app.backup.lastRunAt) { _, _ in
            if filter == .pending { rebuildContent() } else { rebuildItems() }
        }
        .onDisappear {
            window.cancel()
            prefetcher.stop()
        }
        #if os(iOS)
        .sheet(isPresented: $showShareSheet, onDismiss: { shareURLs = [] }) {
            ActivityView(items: shareURLs)
        }
        #endif
        .alert(
            "Delete \(selectedPhotoIDs.count) Photo\(selectedPhotoIDs.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                Task { await deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will be removed from this device's photo library. Copies already in your buckets are kept. Remote-only photos are skipped.")
        }
        .simultaneousGesture(pinchToResize)
        .simultaneousGesture(selectionDragGesture)
        .sensoryFeedback(.selection, trigger: pinchHaptic)
        .sensoryFeedback(.selection, trigger: app.settings.gridColumns)
        .sensoryFeedback(.selection, trigger: selectionHaptic)
    }

    // MARK: Floating header and filter panel

    private var hasTopBanner: Bool {
        app.authorization == .limited
            || (!app.hasPhotoAccess && !app.catalog.photos.isEmpty)
            || app.backup.isRunning
            || app.backup.lastError != nil
            || app.remoteSyncMessage != nil
    }

    private var bottomBarClearance: CGFloat {
        #if os(iOS)
        // The custom bottom bar is a root safe-area inset; the library's own
        // floating controls need to sit above it rather than overlap it.
        return 66
        #else
        return 0
        #endif
    }

    private func filterPanelOverlay(topInset: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.backuSnappy) { showFilterPanel = false }
                }

            LibraryFilterPanel(
                sort: $sort,
                filter: $filter,
                onDismiss: {
                    withAnimation(.backuSnappy) { showFilterPanel = false }
                }
            )
            .frame(maxWidth: 360)
            .padding(.horizontal, 20)
            .padding(.top, topInset + 58)
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
        .transition(.opacity)
        .zIndex(20)
    }

    // MARK: Banners and empty state

    private var remoteBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(Theme.accent)
            Text(app.remoteSyncMessage ?? "")
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                app.dismissRemoteSyncMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .contentCard(radius: 16)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        Group {
            if app.authorization == .limited && app.catalog.photos.isEmpty {
                EmptyStateView(
                    symbol: "photo.badge.plus",
                    title: "No photos shared",
                    message: "You've given Backu access to an empty selection. Choose the photos you want to see and back up — everything else stays private.",
                    actionTitle: "Select More Photos"
                ) {
                    Task { await app.requestMorePhotos() }
                }
            } else if !app.hasPhotoAccess {
                let restricted = app.authorization == .restricted
                let denied = app.authorization == .denied
                EmptyStateView(
                    symbol: "photo.on.rectangle.angled",
                    title: restricted
                        ? "Photo access is restricted"
                        : (denied ? "Photo access is off" : "Your library is private"),
                    message: restricted
                        ? "Photo access is restricted on this device. Ask the person who manages it to allow Backu."
                        : (denied
                           ? "iOS will not ask again. Allow photo access for Backu in Settings to show your library and back up new photos."
                           : "Backu needs access to show your photos, build the search index and back them up. Nothing leaves the device until you add a server."),
                    actionTitle: restricted ? nil : (denied ? "Open Settings" : "Allow Photo Access")
                ) {
                    if denied {
                        PhotoAccess.openSystemSettings()
                    } else if !restricted {
                        Task { await app.requestPhotoAccess() }
                    }
                }
            } else if app.catalog.photos.isEmpty {
                EmptyStateView(
                    symbol: "sparkles",
                    title: "Nothing here yet",
                    message: "Add photos to this \(DeviceInfo.model) and Backu will index them automatically, on-device.",
                    actionTitle: "Scan Again"
                ) {
                    Task { await app.scanLibrary(force: true) }
                }
            } else {
                EmptyStateView(
                    symbol: filter.symbol,
                    title: "No \(filter.rawValue.lowercased()) photos",
                    message: "Try a different filter, or add more photos to your library."
                )
            }
        }
        .padding(.top, 40)
    }

    // MARK: Continuous grid

    private func tileSide(width: CGFloat) -> CGFloat {
        guard width > 1 else { return 1 }
        let count = CGFloat(max(columns, 1))
        return max(1, (width - gridSpacing * (count - 1)) / count)
    }

    private func thumbnailPixels(side: CGFloat) -> CGSize {
        let scale = max(displayScale, 1)
        return CGSize(width: side * scale, height: side * scale)
    }

    // MARK: Timeline levels

    /// Years and Months use the dense PhotoKit collage from Photos: a handful
    /// of square thumbnails per row with the date floating over the photos.
    /// Tapping anywhere in a year drills into its months; tapping a month opens
    /// the All grid at that period.
    private func calendarColumns(for count: Int) -> Int {
        switch count {
        case ...1: return 1
        case ...4: return 2
        case ...9: return 3
        case ...24: return 4
        default: return 6
        }
    }

    private var calendarMaxItems: Int { 42 }

    // MARK: Scroll content

    /// The scroll content holds exactly one *lazy* container: a `LazyVGrid` for
    /// the All grid, or the card `LazyVStack` for Months/Years. The wrappers
    /// around them are plain `VStack`s, so nothing lazy is nested inside
    /// anything lazy (the old All layout was a `LazyVGrid` inside a
    /// `LazyVStack`, which made each grid row pay two layout passes). Headers
    /// are ordinary siblings above the grid rather than grid cells, so they
    /// can never consume a column and leave a blank first cell.
    @ViewBuilder
    private func timelineContent(width: CGFloat, topInset: CGFloat) -> some View {
        Group {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    topAnchor
                    // The floating title replaces the in-flow header. On All
                    // the grid runs under it; the empty state starts below it.
                    if level == .all {
                        Color.clear.frame(height: topInset + 54)
                    }
                    banners
                    emptyState
                    Color.clear.frame(height: 10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                switch level {
                case .all:
                    allGrid(width: width, topInset: topInset)
                case .months:
                    timelineScaffold {
                        monthsTimeline(width: width)
                    }
                case .years:
                    timelineScaffold {
                        yearsTimeline(width: width)
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private var topAnchor: some View {
        Color.clear
            .frame(height: 0)
            .id("library.top")
    }

    /// Banner rows shared by every level. They sit above the grid so a banner
    /// always spans the full width.
    @ViewBuilder
    private var banners: some View {
        if app.authorization == .limited {
            PhotoAccessBanner(
                isLimited: true,
                onAction: { Task { await app.requestMorePhotos() } }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } else if !app.hasPhotoAccess && !app.catalog.photos.isEmpty {
            PhotoAccessBanner(
                isLimited: false,
                onAction: { PhotoAccess.openSystemSettings() }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        if app.backup.isRunning || app.backup.lastError != nil {
            BackupBanner()
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        if app.remoteSyncMessage != nil {
            remoteBanner
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Plain wrapper for the Months/Years levels. It is deliberately *not* a
    /// `LazyVStack`: the cards themselves own the only lazy container.
    private func timelineScaffold<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            topAnchor
            banners
            content()
            Color.clear.frame(height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The All level: header views, then a single `LazyVGrid`, then the footer.
    /// `metrics.frame` is measured on the grid itself, so
    /// `travelled = scrollTop - grid.minY` starts at the first photo and the
    /// prefetch row math is not shifted by banner height.
    private func allGrid(width: CGFloat, topInset: CGFloat) -> some View {
        let count = max(columns, 1)
        let side = tileSide(width: width)
        let pixels = thumbnailPixels(side: side)
        let scale = max(displayScale, 1)
        return VStack(alignment: .leading, spacing: 0) {
            topAnchor
            if hasTopBanner {
                Color.clear.frame(height: topInset + 54)
                banners
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(side), spacing: gridSpacing), count: count),
                spacing: gridSpacing
            ) {
                ForEach(items) { item in
                    PhotoTile(
                        photo: item.photo,
                        columns: count,
                        side: count <= 1 ? nil : side,
                        aspectRatio: count <= 1 ? max(0.2, item.photo.aspectRatio) : nil,
                        targetSize: count <= 1
                            ? fullWidthTargetSize(item, width: width, scale: scale)
                            : pixels,
                        backupState: item.backupState,
                        dateText: item.dateText,
                        cornerRadius: 0,
                        isSelecting: isSelecting,
                        isSelected: selectedPhotoIDs.contains(item.id),
                        onDetails: {
                            var presentation = app.photosForViewer(startingAt: item.photo.id, within: photos)
                            presentation.panel = .info
                            app.viewer = presentation
                        }
                    ) {
                        handleTileTap(item)
                    }
                    .equatable()
                    .id(item.photo.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGRect.self) { view in
                view.frame(in: .global)
            } action: { frame in
                metrics.frame = frame
                updateTimeline()
            }
            Color.clear.frame(height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Photos' full-width level keeps each photo's own shape, so the request
    /// matches the width and that photo's height (the prefetcher uses the
    /// library mean, since a caching manager needs one size per window).
    private func fullWidthTargetSize(_ item: LibraryItem, width: CGFloat, scale: CGFloat) -> CGSize {
        let aspect = max(0.2, item.photo.aspectRatio)
        return CGSize(width: width * scale, height: width / aspect * scale)
    }

    // MARK: Timeline levels

    private func monthsTimeline(width: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(monthSections) { section in
                Button {
                    changeLevel(
                        .all,
                        target: section.cover.id,
                        anchor: UnitPoint(x: 0.5, y: 0.18)
                    )
                } label: {
                    timelineCard(
                        photos: section.photos,
                        title: section.title,
                        columns: calendarColumns(for: section.photos.count),
                        width: width
                    )
                }
                .buttonStyle(.plain)
                .id("month-\(section.id)")
                .accessibilityLabel("\(section.title), \(section.items.count) photo\(section.items.count == 1 ? "" : "s")")
                .accessibilityHint("Shows this month in the photo grid")
                .accessibilityIdentifier("library.monthCard")
            }
        }
        .padding(.vertical, 2)
    }

    private func yearsTimeline(width: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(yearSections) { section in
                Button {
                    let target = section.firstMonthID.map { "month-\($0)" }
                    changeLevel(
                        .months,
                        target: target,
                        anchor: UnitPoint(x: 0.5, y: 0.16)
                    )
                } label: {
                    timelineCard(
                        photos: section.photos,
                        title: String(section.year),
                        columns: calendarColumns(for: section.photos.count),
                        width: width
                    )
                }
                .buttonStyle(.plain)
                .id("year-\(section.year)")
                .accessibilityLabel("\(section.year), \(section.items.count) photo\(section.items.count == 1 ? "" : "s")")
                .accessibilityHint("Shows the months in this year")
                .accessibilityIdentifier("library.yearCard")
            }
        }
        .padding(.vertical, 2)
    }

    /// One collage card, pinned to the viewport width.
    ///
    /// The date pill is an `overlay`, so its intrinsic text width can never
    /// size the card. Previously the pill was a layout sibling in a `ZStack`:
    /// a label wider than the screen (a long month name at a large Dynamic
    /// Type size) grew the card past the viewport, and the enclosing centred
    /// `LazyVStack` then placed the card at a negative x — clipping the pill's
    /// leading cap. The card now fills the scroll content width and the stack
    /// is leading-aligned, so its content can never be centred off-screen.
    private func timelineCard(
        photos: [PhotoItem],
        title: String,
        columns: Int,
        width: CGFloat
    ) -> some View {
        TimelineMosaic(
            photos: photos,
            columns: columns,
            maxItems: calendarMaxItems,
            width: width
        )
        .frame(width: max(1, width), alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            TimelineDateLabel(title: title)
                .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            if photos.count > calendarMaxItems {
                TimelineCountBadge(remaining: photos.count - calendarMaxItems)
                    .padding(10)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Pinch to resize

    /// Photos' two-finger resize. The column count is previewed with a haptic
    /// while pinching and committed once on release, so the lazy grid only
    /// reflows one time instead of on every frame.
    private var pinchToResize: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                guard level == .all, !isSelecting else { return }
                if pinchBaseColumns == nil { pinchBaseColumns = columns }
                guard let base = pinchBaseColumns, base > 0 else { return }
                let target = min(8, max(1, Int((CGFloat(base) / max(value.magnification, 0.2)).rounded())))
                if target != pinchPreviewColumns {
                    pinchPreviewColumns = target
                    pinchHaptic += 1
                }
            }
            .onEnded { value in
                guard level == .all, !isSelecting else { return }
                let base = pinchBaseColumns ?? columns
                pinchBaseColumns = nil
                pinchPreviewColumns = nil
                guard base > 0 else { return }
                let target = min(8, max(1, Int((CGFloat(base) / max(value.magnification, 0.2)).rounded())))
                guard target != base else { return }
                applyColumns(target)
            }
    }

    private func applyColumns(_ target: Int) {
        let base = min(8, max(1, target - columnExtra))
        withAnimation(reduceMotion ? .easeInOut(duration: 0.16) : .smooth(duration: 0.3)) {
            app.settings.gridColumns = base
        }
    }

    // MARK: Bulk selection

    private func toggleSelectionMode() {
        withAnimation(.backuSnappy) {
            if isSelecting {
                endSelection()
            } else {
                showFilterPanel = false
                if app.libraryLevel != .all {
                    pendingLevelScroll = ("library.top", .top)
                    app.libraryLevel = .all
                }
                selectedPhotoIDs = []
                isSelecting = true
            }
        }
    }

    private func endSelection() {
        isSelecting = false
        selectedPhotoIDs = []
        tileFrames = [:]
        resetDragSelection()
    }

    private func toggleAllSelection() {
        let all = Set(items.map(\.id))
        withAnimation(.backuSnappy) {
            if selectedPhotoIDs.count == items.count {
                selectedPhotoIDs = []
            } else {
                selectedPhotoIDs = all
            }
        }
        selectionHaptic += 1
    }

    private func handleTileTap(_ item: LibraryItem) {
        if isSelecting {
            withAnimation(.backuSnappy) {
                if selectedPhotoIDs.contains(item.id) {
                    selectedPhotoIDs.remove(item.id)
                } else {
                    selectedPhotoIDs.insert(item.id)
                }
            }
            selectionHaptic += 1
        } else {
            app.viewer = app.photosForViewer(startingAt: item.photo.id, within: photos)
        }
    }

    private func shareSelected() async {
        guard !selectedPhotoIDs.isEmpty, !isPreparingShare else { return }
        isPreparingShare = true
        let urls = await app.shareURLs(for: selectedPhotoIDs)
        isPreparingShare = false
        guard !urls.isEmpty else {
            app.errorMessage = "Could not prepare those photos for sharing."
            return
        }
        shareURLs = urls
        showShareSheet = true
    }

    private func deleteSelected() async {
        guard !selectedPhotoIDs.isEmpty else { return }
        isDeleting = true
        let result = await app.deletePhotos(selectedPhotoIDs)
        isDeleting = false
        if result.skipped > 0 {
            app.errorMessage = "Deleted \(result.deleted) photo\(result.deleted == 1 ? "" : "s"). \(result.skipped) remote-only item\(result.skipped == 1 ? "" : "s") stayed in your buckets."
        }
        withAnimation(.backuSnappy) { endSelection() }
    }

    private var selectionDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("libraryGrid"))
            .onChanged { value in
                guard isSelecting else { return }
                if dragAnchorID == nil {
                    guard let anchor = hitTest(value.startLocation) else { return }
                    dragAnchorID = anchor
                    dragSelectionBase = selectedPhotoIDs
                    dragDeselecting = selectedPhotoIDs.contains(anchor)
                    applySelectionRange(anchor: anchor, target: anchor)
                } else if let anchor = dragAnchorID,
                          let target = hitTest(value.location) {
                    applySelectionRange(anchor: anchor, target: target)
                }
            }
            .onEnded { _ in resetDragSelection() }
    }

    private func hitTest(_ point: CGPoint) -> String? {
        tileFrames.first { $0.value.contains(point) }?.key
    }

    private func applySelectionRange(anchor: String, target: String) {
        guard let start = items.firstIndex(where: { $0.id == anchor }),
              let end = items.firstIndex(where: { $0.id == target }) else { return }
        let range = min(start, end)...max(start, end)
        let ids = items[range].map(\.id)
        var next = dragSelectionBase ?? selectedPhotoIDs
        if dragDeselecting {
            next.subtract(ids)
        } else {
            next.formUnion(ids)
        }
        guard next != selectedPhotoIDs else { return }
        selectedPhotoIDs = next
        selectionHaptic += 1
    }

    private func resetDragSelection() {
        dragAnchorID = nil
        dragSelectionBase = nil
        dragDeselecting = false
    }

    // MARK: Content

    /// Filtering and the timeline index are derived state: build them once per
    /// catalog revision instead of on every body evaluation.
    private func rebuildContent() {
        var filtered = app.catalog.photos
        if !app.settings.showRemoteOnlyPhotos {
            filtered.removeAll { !$0.isLocal }
        }
        switch filter {
        case .all:
            break
        case .favorites:
            filtered.removeAll { !$0.isFavorite }
        case .videos:
            filtered.removeAll { !$0.isVideo }
        case .photos:
            filtered.removeAll { $0.isVideo }
        case .pending:
            filtered.removeAll { app.photoBackupState($0) == .backedUp }
        case .people:
            filtered.removeAll { $0.faces.isEmpty }
        case .located:
            filtered.removeAll { !$0.metadata.hasLocation }
        case .local:
            filtered.removeAll { !$0.isLocal }
        }
        filtered.sort { (libraryDate($0) ?? .distantPast) > (libraryDate($1) ?? .distantPast) }

        photos = filtered
        rebuildItems()
        updateTimeline()
        if level == .all {
            window.invalidate()
            requestWindow(immediate: true)
        } else {
            window.cancel()
            prefetcher.stop()
        }
    }

    private func libraryDate(_ photo: PhotoItem) -> Date? {
        switch sort {
        case .captured: return photo.takenAt ?? photo.addedAt
        case .added: return photo.addedAt ?? photo.takenAt
        }
    }

    /// Re-reads backup state without recomputing the filter or the timeline.
    private func rebuildItems() {
        var backedUp = 0
        var pending = 0
        var built: [LibraryItem] = []
        built.reserveCapacity(photos.count)
        var aspectTotal: CGFloat = 0
        for photo in photos {
            let state = app.photoBackupState(photo)
            if state == .backedUp { backedUp += 1 }
            if state != .backedUp { pending += 1 }
            aspectTotal += max(0.2, photo.aspectRatio)
            built.append(LibraryItem(
                photo: photo,
                backupState: state,
                dateText: libraryDate(photo).map { Self.dayFormatter.string(from: $0) }
            ))
        }
        metrics.averageAspect = built.isEmpty ? 1 : aspectTotal / CGFloat(built.count)
        var pendingTotal = 0
        for photo in app.catalog.photos where app.photoBackupState(photo) != .backedUp {
            pendingTotal += 1
        }
        items = built
        summary = LibrarySummary(count: photos.count, backedUp: backedUp, pending: pendingTotal)
        if isSelecting {
            selectedPhotoIDs.formIntersection(Set(built.map(\.id)))
        }
        rebuildSections()
    }

    /// The All grid is chronological, so one pass over `items` gives both
    /// timelines. Sections are built here, not in `body`, so a scroll never
    /// regroups or re-sorts the library.
    private func rebuildSections() {
        var months: [LibraryMonthSection] = []
        var years: [LibraryYearSection] = []

        for item in items {
            let date = libraryDate(item.photo) ?? .distantPast
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            let year = parts.year ?? 0
            let month = parts.month ?? 0
            let monthID = String(format: "%04d-%02d", year, month)
            let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? date

            if months.last?.id != monthID {
                months.append(LibraryMonthSection(
                    id: monthID,
                    monthStart: monthStart,
                    title: year > 0 ? monthTitleFormatter.string(from: monthStart) : "Undated",
                    items: [],
                    photos: [],
                    cover: item,
                    dayText: String(parts.day ?? 0)
                ))
            }
            months[months.count - 1].items.append(item)
            months[months.count - 1].photos.append(item.photo)

            if years.last?.year != year {
                years.append(LibraryYearSection(
                    id: year,
                    year: year,
                    items: [],
                    photos: [],
                    cover: item,
                    firstMonthID: nil
                ))
            }
            years[years.count - 1].items.append(item)
            years[years.count - 1].photos.append(item.photo)
        }

        for index in years.indices {
            let year = years[index].year
            years[index].firstMonthID = months.first { $0.id.hasPrefix(String(format: "%04d-", year)) }?.id
        }

        monthSections = months
        yearSections = years
    }

    // MARK: Scroll pipeline

    /// The height of one grid row, in points. The full-width level has a
    /// different height per photo, so it uses the library's mean aspect ratio
    /// to keep the row estimate — and therefore the prefetch window — sane.
    private func gridRowHeight(width: CGFloat) -> CGFloat {
        if columns <= 1 {
            let aspect = max(0.2, metrics.averageAspect)
            return max(1, width / aspect + gridSpacing)
        }
        return max(tileSide(width: width) + gridSpacing, 1)
    }

    /// Called on every scroll tick. It only does arithmetic: derive the scroll
    /// direction and row, then move the prefetch window.
    private func updateTimeline() {
        guard level == .all else { return }
        let frame = metrics.frame
        guard frame.width > 0, viewHeight > 0 else { return }
        let rowHeight = gridRowHeight(width: frame.width)
        let travelled = metrics.scrollTop - frame.minY
        let delta = travelled - metrics.travelled
        if abs(delta) > 1 {
            metrics.direction = delta > 0 ? .forward : .backward
        }
        metrics.travelled = travelled
        let row = max(0, Int(floor(travelled / rowHeight)))
        // While a finger or the deceleration is moving the grid, apply the
        // window on the tick instead of waiting out the idle throttle.
        requestWindow(
            firstRow: row,
            rowHeight: rowHeight,
            immediate: metrics.phase != .idle
        )
    }

    private func requestWindow(firstRow: Int? = nil, rowHeight: CGFloat? = nil, immediate: Bool = false) {
        guard !photos.isEmpty, viewWidth > 1, viewHeight > 1 else { return }
        let frame = metrics.frame
        guard frame.width > 0 else { return }
        let height = max(rowHeight ?? gridRowHeight(width: viewWidth), 1)
        let row: Int
        if let firstRow {
            row = firstRow
        } else {
            let travelled = max(0, metrics.scrollTop - frame.minY)
            row = max(0, Int(floor(travelled / height)))
        }
        let visibleRows = max(1, Int(ceil(viewHeight / height)) + 1)
        let totalRows = max(1, (photos.count + columns - 1) / columns)
        let lowerRow = max(0, min(totalRows - 1, row))
        let upperRow = min(totalRows, lowerRow + visibleRows)
        let lower = min(photos.count, lowerRow * columns)
        let upper = min(photos.count, upperRow * columns)
        guard lower < upper else { return }

        // The prefetcher and the tiles must agree on the pixel size for the
        // caching manager to serve preheated images. Tiles get this exact
        // `thumbnailPixels(side:)` value. At the full-width level every tile
        // has its own height, so the decode pump is given the same per-photo
        // size the tile will request (the caching manager still warms the
        // mean size, since it needs one box per window).
        let pixels: CGSize
        let perPhotoPixelSize: ((PhotoItem) -> CGSize)?
        if columns <= 1 {
            let scale = max(displayScale, 1)
            let aspect = max(0.2, metrics.averageAspect)
            let width = viewWidth
            pixels = CGSize(width: width * scale, height: width / aspect * scale)
            perPhotoPixelSize = { photo in
                let aspect = max(0.2, photo.aspectRatio)
                return CGSize(width: width * scale, height: width / aspect * scale)
            }
        } else {
            pixels = thumbnailPixels(side: tileSide(width: viewWidth))
            perPhotoPixelSize = nil
        }
        let snapshot = photos
        let rowCount = columns
        let direction = metrics.direction
        window.request(lower..<upper, immediate: immediate) { range in
            prefetcher.update(
                photos: snapshot,
                visibleRange: range,
                itemsPerRow: rowCount,
                visibleRows: visibleRows,
                targetPixelSize: pixels,
                images: app.images,
                direction: direction,
                perPhotoPixelSize: perPhotoPixelSize
            )
        }
    }

    /// Switches timeline level and scrolls to the requested section, once the
    /// new level has been laid out. Photos animates the level change; keeping
    /// the delay short makes the destination feel like part of the same zoom.
    private func changeLevel(
        _ newLevel: LibraryLevel,
        target: String? = nil,
        anchor: UnitPoint = .top
    ) {
        guard app.libraryLevel != newLevel || target != nil else { return }
        pendingLevelScroll = (target ?? "library.top", anchor)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .smooth(duration: 0.28)) {
            app.libraryLevel = newLevel
        }
    }
}

struct PhotoAccessBanner: View {
    var isLimited: Bool
    var onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isLimited ? "photo.badge.checkmark" : "lock.shield")
                .scaledFont(14, weight: .semibold)
                .foregroundStyle(isLimited ? Theme.mint : .orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(isLimited ? "You're seeing selected photos" : "Photo access is off")
                    .font(.footnote.weight(.semibold))
                Text(isLimited
                     ? "Backu can only see the photos you shared. Add more at any time."
                     : "New photos can't be shown or backed up until you allow access in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(isLimited ? "Select More" : "Settings", action: onAction)
                .font(.caption.weight(.semibold))
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(12)
        .contentCard(radius: 16)
        .accessibilityElement(children: .contain)
    }
}

struct BackupBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let error = app.backup.lastError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.footnote)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if app.backup.isRunning {
                    Text("\(Int(app.backup.progress * 100))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .contentCard(radius: 14)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.backupBanner")
        }
    }
}
