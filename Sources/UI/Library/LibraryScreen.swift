import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case favorites = "Favorites"
    case videos = "Videos"
    case pending = "Not backed up"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .favorites: return "heart.fill"
        case .videos: return "play.rectangle.fill"
        case .pending: return "icloud.slash"
        }
    }
}

/// One entry of the year rail. The first photo of a year doubles as the
/// scroll anchor for that year.
struct YearAnchor: Identifiable, Equatable {
    var year: Int
    var photoID: String
    var id: Int { year }
}

/// Cheap lookup table for the timeline labels. Kept in sync with the visible
/// photos so scrolling never has to filter the catalog.
struct TimelineIndex {
    var dates: [Date?] = []
    var anchors: [YearAnchor] = []
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
    @State private var showAddServer = false
    @State private var showBackupActivity = false
    @State private var items: [LibraryItem] = []
    @State private var photos: [PhotoItem] = []
    @State private var summary = LibrarySummary()
    @State private var index = TimelineIndex()
    @State private var metrics = TimelineMetrics()
    @State private var label = TimelineLabelState()
    @State private var window = ScrollWindow()
    @State private var prefetcher = ThumbnailPrefetcher()
    @State private var lastRow = -1
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

                    header(topInset: topInset)
                    filterBar(proxy: proxy)

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
                        photoGrid(width: width)
                    }

                    Color.clear.frame(height: 10)
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.pageBackground)
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
                StatusBarScrim(topInset: topInset, isVisible: label.isCollapsed)
            }
            .overlay(alignment: .top) {
                LibraryTopBar(
                    label: label,
                    pendingCount: summary.pending,
                    onShowActivity: { showBackupActivity = true },
                    onAddServer: { showAddServer = true }
                )
            }
            .overlay(alignment: .trailing) {
                YearRail(
                    anchors: index.anchors,
                    availableHeight: availableHeight,
                    label: label
                ) { year in
                    jump(to: year, using: proxy)
                }
                .padding(.trailing, 6)
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
        }
        .task {
            rebuildContent()
            label.touch()
        }
        .onChange(of: app.catalog.version) { _, _ in rebuildContent() }
        .onChange(of: filter) { _, _ in rebuildContent() }
        .onChange(of: app.settings.showRemoteOnlyPhotos) { _, _ in rebuildContent() }
        .onChange(of: app.settings.gridColumns) { _, _ in
            window.invalidate()
            requestWindow(immediate: true)
        }
        .onChange(of: app.backup.lastRunAt) { _, _ in
            if filter == .pending { rebuildContent() } else { rebuildItems() }
        }
        .onDisappear {
            label.cancel()
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
        .simultaneousGesture(pinchToResize)
        .sensoryFeedback(.selection, trigger: pinchHaptic)
        .sensoryFeedback(.selection, trigger: app.settings.gridColumns)
    }

    // MARK: Header

    private func header(topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Library")
                .font(.largeTitle.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.trailing, 104)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, topInset + 10)
        .padding(.bottom, 4)
    }

    private var subtitle: String {
        if app.isScanning { return "Scanning your photo library…" }
        if !app.hasPhotoAccess { return "Photo access is off" }
        guard !app.catalog.photos.isEmpty else { return "No photos yet" }
        guard summary.count > 0 else { return "No \(filter.rawValue.lowercased()) photos" }
        let noun = filter == .all ? "item" : filter.rawValue.lowercased()
        return "\(summary.count) \(noun)\(summary.count == 1 ? "" : "s") · \(summary.backedUp) backed up"
    }

    // MARK: Filters

    private func filterBar(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(LibraryFilter.allCases) { option in
                        FilterChip(title: option.rawValue, isSelected: filter == option) {
                            guard filter != option else { return }
                            withAnimation(.backuSnappy) {
                                filter = option
                                proxy.scrollTo("library.top", anchor: .top)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 6)
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
            if !app.hasPhotoAccess {
                EmptyStateView(
                    symbol: "photo.on.rectangle.angled",
                    title: "Your library is private",
                    message: "Backu needs access to show your photos, build the search index and back them up. Nothing leaves the device until you add a server.",
                    actionTitle: "Allow Photo Access"
                ) {
                    Task { await app.requestPhotoAccess() }
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

    private func photoGrid(width: CGFloat) -> some View {
        let side = tileSide(width: width)
        let pixels = thumbnailPixels(side: side)
        return LazyVGrid(
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
                    cornerRadius: 0
                ) {
                    app.viewer = app.photosForViewer(startingAt: item.photo.id, within: photos)
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
            label.touch()
        }
    }

    // MARK: Pinch to resize

    /// Photos' two-finger resize. The column count is previewed with a haptic
    /// while pinching and committed once on release, so the lazy grid only
    /// reflows one time instead of on every frame.
    private var pinchToResize: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if pinchBaseColumns == nil { pinchBaseColumns = columns }
                guard let base = pinchBaseColumns, base > 0 else { return }
                let target = min(8, max(2, Int((CGFloat(base) / max(value.magnification, 0.2)).rounded())))
                if target != pinchPreviewColumns {
                    pinchPreviewColumns = target
                    pinchHaptic += 1
                }
            }
            .onEnded { value in
                let base = pinchBaseColumns ?? columns
                pinchBaseColumns = nil
                pinchPreviewColumns = nil
                guard base > 0 else { return }
                let target = min(8, max(2, Int((CGFloat(base) / max(value.magnification, 0.2)).rounded())))
                guard target != base else { return }
                applyColumns(target)
            }
    }

    private func applyColumns(_ target: Int) {
        let base = min(8, max(2, target - columnExtra))
        withAnimation(reduceMotion ? .easeInOut(duration: 0.16) : .smooth(duration: 0.3)) {
            app.settings.gridColumns = base
        }
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
        case .all: break
        case .favorites: filtered.removeAll { !$0.isFavorite }
        case .videos: filtered.removeAll { !$0.isVideo }
        case .pending: filtered.removeAll { $0.isBackedUp && $0.sidecarDirtyAt == nil }
        }

        photos = filtered
        index = timelineIndex(for: filtered)
        rebuildItems()
        lastRow = -1
        updateTimeline()
        window.invalidate()
        requestWindow(immediate: true)
    }

    /// Re-reads backup state without recomputing the filter or the timeline.
    private func rebuildItems() {
        var backedUp = 0
        var pending = 0
        var built: [LibraryItem] = []
        built.reserveCapacity(photos.count)
        for photo in photos {
            let state = app.photoBackupState(photo)
            if photo.isBackedUp { backedUp += 1 }
            if !photo.isBackedUp || photo.sidecarDirtyAt != nil { pending += 1 }
            built.append(LibraryItem(
                photo: photo,
                backupState: state,
                dateText: photo.takenAt.map { Self.dayFormatter.string(from: $0) }
            ))
        }
        var pendingTotal = 0
        for photo in app.catalog.photos where !photo.isBackedUp || photo.sidecarDirtyAt != nil {
            pendingTotal += 1
        }
        items = built
        summary = LibrarySummary(count: photos.count, backedUp: backedUp, pending: pendingTotal)
    }

    private func timelineIndex(for photos: [PhotoItem]) -> TimelineIndex {
        var dates: [Date?] = []
        var anchors: [YearAnchor] = []
        dates.reserveCapacity(photos.count)
        var previousYear: Int?
        for photo in photos {
            let date = photo.takenAt ?? photo.addedAt
            dates.append(date)
            guard let date else { continue }
            let year = calendar.component(.year, from: date)
            if year != previousYear {
                anchors.append(YearAnchor(year: year, photoID: photo.id))
                previousYear = year
            }
        }
        return TimelineIndex(dates: dates, anchors: anchors)
    }

    // MARK: Scroll pipeline

    /// Called on every scroll tick. It only does arithmetic and, when the row
    /// changes, updates the small label state — never the grid.
    private func updateTimeline() {
        let frame = metrics.frame
        guard frame.width > 0, !index.dates.isEmpty, viewHeight > 0 else { return }
        let side = tileSide(width: frame.width)
        let rowHeight = max(side + gridSpacing, 1)
        let travelled = metrics.scrollTop - frame.minY
        let row = max(0, Int(floor(travelled / rowHeight)))

        label.setCollapsed(travelled >= 0)
        requestWindow(firstRow: row, rowHeight: rowHeight)

        guard row != lastRow else { return }
        lastRow = row
        guard row * columns < index.dates.count else { return }
        let position = min(row * columns, index.dates.count - 1)
        guard let date = index.dates[position] else { return }
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let month = calendar.date(from: parts) else { return }
        label.update(month: month, year: parts.year)
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

    private func jump(to year: Int, using proxy: ScrollViewProxy) {
        guard let anchor = index.anchors.first(where: { $0.year == year }) else { return }
        withAnimation(.smooth(duration: 0.32)) {
            proxy.scrollTo(anchor.photoID, anchor: .top)
        }
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
