import SwiftUI

struct MonthGroup: Identifiable {
    var id: String
    var date: Date
    var photos: [PhotoItem]
}

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

struct LibraryScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var filter: LibraryFilter = .all

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

    private var months: [MonthGroup] {
        let calendar = Calendar(identifier: .gregorian)
        var groups: [String: [PhotoItem]] = [:]
        var dates: [String: Date] = [:]
        for photo in photos {
            let date = photo.takenAt ?? Date.distantPast
            let components = calendar.dateComponents([.year, .month], from: date)
            let key = String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
            groups[key, default: []].append(photo)
            dates[key] = date
        }
        return groups.keys.sorted(by: >).compactMap { key in
            guard let items = groups[key], let date = dates[key] else { return nil }
            return MonthGroup(id: key, date: date, photos: items)
        }
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
        @Bindable var app = app
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                header
                filterBar
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
                    ForEach(months) { month in
                        Section {
                            grid(month.photos)
                                .padding(.bottom, 18)
                        } header: {
                            monthHeader(month)
                        }
                    }
                }
            }
            .padding(.bottom, 90)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.pageBackground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var header: some View {
        ScreenTitle("Library", subtitle: subtitle) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Grid size", selection: Binding(
                        get: { app.settings.gridColumns },
                        set: { app.settings.gridColumns = $0 }
                    )) {
                        Label("Large", systemImage: "square.grid.2x2").tag(2)
                        Label("Medium", systemImage: "square.grid.3x3").tag(3)
                        Label("Small", systemImage: "square.grid.4x4").tag(4)
                        Label("Tiny", systemImage: "square.grid.2x2.fill").tag(6)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Grid size")

                if app.backup.isRunning {
                    Button {
                        app.backup.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .tint(.red)
                    .accessibilityLabel("Stop backup")
                } else if app.servers.servers.isEmpty {
                    Button {
                        app.activeTab = .servers
                    } label: {
                        Label("Add storage", systemImage: "externaldrive.badge.plus")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                } else if pendingCount == 0 {
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.mint)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("All \(app.catalog.photos.count) photos backed up")
                } else {
                    Button {
                        app.startBackup()
                    } label: {
                        Image(systemName: "arrow.up.to.line.compact")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Back up \(pendingCount) photos to \(app.backupServer?.name ?? "storage")")
                }
            }
        }
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

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { option in
                    FilterChip(title: option.rawValue, isSelected: filter == option) {
                        withAnimation(.backuSnappy) { filter = option }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

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
        }
        .padding(12)
        .glassSurface(16)
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

    private func monthHeader(_ month: MonthGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(month.date.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Text("\(month.photos.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background {
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .horizontal)
        }
    }

    private func grid(_ items: [PhotoItem]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns),
            spacing: 2
        ) {
            ForEach(items) { photo in
                PhotoTile(photo: photo, columns: columns) {
                    app.viewer = app.photosForViewer(startingAt: photo.id, within: photos)
                }
            }
        }
        .frame(maxWidth: .infinity)
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
        .glassSurface(18)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
