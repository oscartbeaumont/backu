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

/// Photos' three library zoom levels. Months is the date timeline: each month
/// is a section with a header and a large card, so scrolling moves through time
/// without needing a separate scrubber.
enum LibraryLevel: String, CaseIterable, Identifiable {
    case years = "Years"
    case months = "Months"
    case all = "All"

    var id: String { rawValue }
}

/// One month of the timeline. Sections are built once per catalog/filter change
/// so scrolling only lays out views; it never regroups the library.
struct LibraryMonthSection: Identifiable {
    var id: String
    var monthStart: Date
    var title: String
    var items: [LibraryItem]
    var cover: LibraryItem
    var dayText: String
}

/// One year of the timeline.
struct LibraryYearSection: Identifiable {
    var id: Int
    var year: Int
    var items: [LibraryItem]
    var cover: LibraryItem
    var firstMonthID: String?
}

/// A mutable box that does not invalidate the view: the grid's frame changes on
/// every scroll tick, and only the derived labels should cause updates.
@MainActor
final class TimelineMetrics {
    var frame: CGRect = .zero
    var scrollTop: CGFloat = 0
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

/// Throttles prefetch-window changes. Scrolling is reported per tick, but the
/// prefetcher re-arms at most every ~80 ms, so a fling stays cheap while a slow
/// scroll still keeps the next screens warm.
@MainActor
final class ScrollWindow {
    private var applied: Range<Int>?
    private var pending: Range<Int>?
    private var task: Task<Void, Never>?
    private var lastAppliedAt = Date.distantPast
    private let interval: TimeInterval = 0.08

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
            try? await Task.sleep(for: .milliseconds(80))
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
    @State private var level: LibraryLevel = .all
    @State private var showFilterPanel = false
    @State private var showAddServer = false
    @State private var showBackupActivity = false
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

    private var gridSpacing: CGFloat { 2 }

    var body: some View {
        GeometryReader { proxy in
            timeline(
                width: proxy.size.width,
                topInset: proxy.safeAreaInsets.top,
                availableHeight: proxy.size.height
            )
        }
    }

    private func timeline(width: CGFloat, topInset: CGFloat, availableHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("library.top")

                    // The floating title replaces the old in-flow header. On All
                    // the grid runs under it; banners and the empty state start
                    // below it. Years/Months reserve the title height through a
                    // top safe-area inset so their date labels never sit under
                    // the clock during a programmatic jump.
                    if level == .all && (items.isEmpty || hasTopBanner) {
                        Color.clear.frame(height: topInset + 54)
                    }

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

                    if items.isEmpty {
                        emptyState
                    } else {
                        Group {
                            switch level {
                            case .years:
                                yearsTimeline(width: width, proxy: proxy)
                            case .months:
                                monthsTimeline(width: width, proxy: proxy)
                            case .all:
                                photoGrid(width: width)
                            }
                        }
                        .transition(.opacity)
                    }

                    Color.clear.frame(height: 10)
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.pageBackground)
            .coordinateSpace(name: "libraryGrid")
            .onPreferenceChange(TileFramePreferenceKey.self) { frames in
                if isSelecting, tileFrames != frames { tileFrames = frames }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if level != .all {
                    Color.clear.frame(height: topInset + 54)
                }
            }
            #if os(iOS)
            .ignoresSafeArea(edges: .top)
            #endif
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
                    onToggleSelection: toggleSelectionMode,
                    pendingCount: summary.pending,
                    onShowActivity: { showBackupActivity = true },
                    onAddServer: { showAddServer = true }
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
                    .padding(.bottom, 8)
                } else {
                    levelSwitcher(proxy: proxy)
                }
                #else
                levelSwitcher(proxy: proxy)
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
        .sheet(isPresented: $showAddServer) {
            AddServerFlow()
                .environment(app)
        }
        .sheet(isPresented: $showBackupActivity) {
            BackupActivityView()
                .environment(app)
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

    private func levelSwitcher(proxy: ScrollViewProxy) -> some View {
        LibraryLevelSwitcher(
            level: Binding(
                get: { level },
                set: { changeLevel($0, proxy: proxy) }
            )
        )
        .padding(.top, 6)
        .padding(.bottom, 8)
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

    private func monthsTimeline(width: CGFloat, proxy: ScrollViewProxy) -> some View {
        LazyVStack(spacing: 4) {
            ForEach(monthSections) { section in
                Button {
                    changeLevel(
                        .all,
                        target: section.cover.id,
                        anchor: UnitPoint(x: 0.5, y: 0.18),
                        proxy: proxy
                    )
                } label: {
                    ZStack(alignment: .topLeading) {
                        TimelineMosaic(
                            photos: section.items.map(\.photo),
                            columns: calendarColumns(for: section.items.count),
                            maxItems: calendarMaxItems
                        )
                        TimelineDateLabel(title: section.title)
                            .padding(10)
                        if section.items.count > calendarMaxItems {
                            TimelineCountBadge(remaining: section.items.count - calendarMaxItems)
                                .padding(10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }
                    }
                    .contentShape(Rectangle())
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

    private func yearsTimeline(width: CGFloat, proxy: ScrollViewProxy) -> some View {
        LazyVStack(spacing: 4) {
            ForEach(yearSections) { section in
                Button {
                    let target = section.firstMonthID.map { "month-\($0)" }
                    changeLevel(
                        .months,
                        target: target,
                        anchor: UnitPoint(x: 0.5, y: 0.16),
                        proxy: proxy
                    )
                } label: {
                    ZStack(alignment: .topLeading) {
                        TimelineMosaic(
                            photos: section.items.map(\.photo),
                            columns: calendarColumns(for: section.items.count),
                            maxItems: calendarMaxItems
                        )
                        TimelineDateLabel(title: String(section.year))
                            .padding(10)
                        if section.items.count > calendarMaxItems {
                            TimelineCountBadge(remaining: section.items.count - calendarMaxItems)
                                .padding(10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }
                    }
                    .contentShape(Rectangle())
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

    @ViewBuilder
    private func photoGrid(width: CGFloat) -> some View {
        if columns <= 1 {
            let scale = max(displayScale, 1)
            LazyVStack(spacing: gridSpacing) {
                ForEach(items) { item in
                    let aspect = max(0.2, item.photo.aspectRatio)
                    PhotoTile(
                        photo: item.photo,
                        columns: 1,
                        side: nil,
                        aspectRatio: aspect,
                        targetSize: CGSize(width: width * scale, height: width / aspect * scale),
                        backupState: item.backupState,
                        dateText: item.dateText,
                        cornerRadius: 0,
                        isSelecting: isSelecting,
                        isSelected: selectedPhotoIDs.contains(item.id)
                    ) {
                        handleTileTap(item)
                    }
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
        } else {
            let side = tileSide(width: width)
            let pixels = thumbnailPixels(side: side)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(side), spacing: gridSpacing), count: columns),
                spacing: gridSpacing
            ) {
                ForEach(items) { item in
                    PhotoTile(
                        photo: item.photo,
                        columns: columns,
                        side: side,
                        targetSize: pixels,
                        backupState: item.backupState,
                        dateText: item.dateText,
                        cornerRadius: 0,
                        isSelecting: isSelecting,
                        isSelected: selectedPhotoIDs.contains(item.id)
                    ) {
                        handleTileTap(item)
                    }
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
        }
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
                level = .all
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
        window.invalidate()
        requestWindow(immediate: true)
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
        for photo in photos {
            let state = app.photoBackupState(photo)
            if state == .backedUp { backedUp += 1 }
            if state != .backedUp { pending += 1 }
            built.append(LibraryItem(
                photo: photo,
                backupState: state,
                dateText: libraryDate(photo).map { Self.dayFormatter.string(from: $0) }
            ))
        }
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
                    title: year > 0 ? Self.monthFormatter.string(from: monthStart) : "Undated",
                    items: [],
                    cover: item,
                    dayText: String(parts.day ?? 0)
                ))
            }
            months[months.count - 1].items.append(item)

            if years.last?.year != year {
                years.append(LibraryYearSection(
                    id: year,
                    year: year,
                    items: [],
                    cover: item,
                    firstMonthID: nil
                ))
            }
            years[years.count - 1].items.append(item)
        }

        for index in years.indices {
            let year = years[index].year
            years[index].firstMonthID = months.first { $0.id.hasPrefix(String(format: "%04d-", year)) }?.id
        }

        monthSections = months
        yearSections = years
    }

    // MARK: Scroll pipeline

    /// Called on every scroll tick. It only does arithmetic: collapse the
    /// large title and, in the All grid, keep the prefetch window moving.
    private func updateTimeline() {
        let frame = metrics.frame
        guard frame.width > 0, viewHeight > 0 else { return }
        let side = tileSide(width: frame.width)
        let rowHeight = max(side + gridSpacing, 1)
        let travelled = metrics.scrollTop - frame.minY

        guard level == .all else { return }
        let row = max(0, Int(floor(travelled / rowHeight)))
        requestWindow(firstRow: row, rowHeight: rowHeight)
    }

    private func requestWindow(firstRow: Int? = nil, rowHeight: CGFloat? = nil, immediate: Bool = false) {
        guard !photos.isEmpty, viewWidth > 1, viewHeight > 1 else { return }
        let frame = metrics.frame
        guard frame.width > 0 else { return }
        let side = tileSide(width: viewWidth)
        let height = max(rowHeight ?? (side + gridSpacing), 1)
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

        let pixels = thumbnailPixels(side: side)
        let snapshot = photos
        let rowCount = columns
        window.request(lower..<upper, immediate: immediate) { range in
            prefetcher.update(
                photos: snapshot,
                visibleRange: range,
                itemsPerRow: rowCount,
                visibleRows: visibleRows,
                targetPixelSize: pixels,
                images: app.images
            )
        }
    }

    /// Switches timeline level and scrolls to the requested section, once the
    /// new level has been laid out. Photos animates the level change; keeping
    /// the delay short makes the destination feel like part of the same zoom.
    private func changeLevel(
        _ newLevel: LibraryLevel,
        target: String? = nil,
        anchor: UnitPoint = .top,
        proxy: ScrollViewProxy
    ) {
        guard level != newLevel || target != nil else { return }
        if newLevel != .all {
            prefetcher.stop()
            window.cancel()
        }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .smooth(duration: 0.28)) {
            level = newLevel
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            if let target {
                proxy.scrollTo(target, anchor: anchor)
            } else {
                proxy.scrollTo("library.top", anchor: .top)
            }
            if newLevel == .all {
                window.invalidate()
                requestWindow(immediate: true)
            }
        }
    }
}

struct PhotoAccessBanner: View {
    var isLimited: Bool
    var onAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isLimited ? "photo.badge.checkmark" : "lock.shield")
                .font(.system(size: 14, weight: .semibold))
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
        }
    }
}
