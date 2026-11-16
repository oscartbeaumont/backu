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
}

struct LibraryScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var filter: LibraryFilter = .all
    @State private var showAddServer = false
    @State private var scrollTop: CGFloat = 0
    @State private var index = TimelineIndex()
    @State private var metrics = TimelineMetrics()
    @State private var label = TimelineLabelState()

    private let calendar = Calendar(identifier: .gregorian)

    private var photos: [PhotoItem] {
        var photos = app.catalog.photos
        if !app.settings.showRemoteOnlyPhotos {
            photos = photos.filter { $0.isLocal }
        }
        switch filter {
        case .all: break
        case .favorites: photos = photos.filter(\.isFavorite)
        case .videos: photos = photos.filter(\.isVideo)
        case .pending: photos = photos.filter { !$0.isBackedUp }
        }
        return photos
    }

    private var columns: Int {
        let base = app.settings.gridColumns
        #if os(macOS)
        return min(8, base + 3)
        #else
        return sizeClass == .compact ? base : min(8, base + 2)
        #endif
    }

    var body: some View {
        #if os(iOS)
        GeometryReader { proxy in
            timeline(topInset: proxy.safeAreaInsets.top, availableHeight: proxy.size.height)
        }
        #else
        timeline(topInset: 0, availableHeight: 900)
        #endif
    }

    private func timeline(topInset: CGFloat, availableHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("library.top")

                    header(topInset: topInset)
                    filterBar(proxy: proxy)

                    if app.backup.isRunning {
                        BackupBanner()
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                    if app.remoteSyncMessage != nil {
                        remoteBanner
                    }

                    if photos.isEmpty {
                        emptyState
                    } else {
                        photoGrid
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
                scrollTop = value
                updateTimeline()
            }
            .overlay(alignment: .top) {
                LibraryTopBar(
                    label: label,
                    pendingCount: pendingCount
                ) {
                    showAddServer = true
                }
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
        }
        .task {
            rebuildTimeline()
            label.touch()
        }
        .onChange(of: app.settings.showRemoteOnlyPhotos) { _, _ in rebuildTimeline() }
        .onChange(of: app.catalog.photos.count) { _, _ in rebuildTimeline() }
        .onChange(of: app.backup.lastRunAt) { _, _ in
            if filter == .pending { rebuildTimeline() }
        }
        .onDisappear { label.cancel() }
        .sheet(isPresented: $showAddServer) {
            AddServerFlow()
                .environment(app)
        }
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
        guard !photos.isEmpty else { return "No \(filter.rawValue.lowercased()) photos" }
        let backedUp = photos.filter(\.isBackedUp).count
        let noun = filter == .all ? "item" : filter.rawValue.lowercased()
        return "\(photos.count) \(noun)\(photos.count == 1 ? "" : "s") · \(backedUp) backed up"
    }

    private var pendingCount: Int {
        app.catalog.photos.filter { !$0.isBackedUp || $0.sidecarDirtyAt != nil }.count
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
                            rebuildTimeline()
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
                app.remoteSyncMessage = nil
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

    private var photoGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columns),
            spacing: gridSpacing
        ) {
            ForEach(photos) { photo in
                PhotoTile(photo: photo, columns: columns, cornerRadius: 0) {
                    app.viewer = app.photosForViewer(startingAt: photo.id, within: photos)
                }
                .id(photo.id)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGRect.self) { view in
            view.frame(in: .global)
        } action: { frame in
            metrics.frame = frame
            updateTimeline()
            label.touch()
        }
    }

    private var gridSpacing: CGFloat { 2 }

    // MARK: Timeline labels

    private func rebuildTimeline() {
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
        index = TimelineIndex(dates: dates, anchors: anchors)
        updateTimeline()
    }

    private func updateTimeline() {
        let frame = metrics.frame
        guard frame.width > 0, !index.dates.isEmpty else {
            label.update(month: nil, year: nil)
            label.isCollapsed = false
            return
        }

        let tile = (frame.width - gridSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rowHeight = max(tile + gridSpacing, 1)
        let travelled = scrollTop - frame.minY
        let row = max(0, Int(floor(travelled / rowHeight)))
        let position = min(row * columns, index.dates.count - 1)

        label.isCollapsed = travelled >= 0

        guard let date = index.dates[position] else { return }
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let month = calendar.date(from: parts) else { return }
        label.update(month: month, year: parts.year)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: app.backup.isRunning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.backup.status)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(app.backup.completedCount) of \(app.backup.totalCount) · \(formattedBytes(app.backup.transferredBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(app.backup.progress * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .contentTransition(.numericText())
            }
            ProgressBar(value: app.backup.progress)
        }
        .padding(14)
        .contentCard(radius: 16)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
