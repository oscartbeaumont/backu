import SwiftUI

struct PhotoTile: View {
    let photo: PhotoItem
    var columns: Int = 3
    /// Fixed side in points for the edge-to-edge Library grid. Search and
    /// People leave it nil and keep their intrinsic square tiles.
    var side: CGFloat?
    /// Natural width / height when the tile is full-width (Photos' one-column
    /// zoom level). Ignored when `side` is set.
    var aspectRatio: CGFloat?
    /// Exact thumbnail size in pixels for the current density.
    var targetSize: CGSize?
    var backupState: AppModel.BackupState?
    var dateText: String?
    var cornerRadius: CGFloat = Theme.tileRadius
    var onOpen: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.viewerZoomNamespace) private var zoomNamespace
    @Environment(\.viewerZoomSourceActive) private var zoomSourceActive
    @State private var image: PlatformImage?
    @State private var isFinal = false
    @State private var imageID = 0
    @State private var loadedPhotoID: String?
    @State private var isHovering = false

    private var resolvedTargetSize: CGSize {
        if let targetSize { return targetSize }
        let width: CGFloat = 700 / CGFloat(max(columns, 1))
        return CGSize(width: width, height: width / max(aspectRatio ?? 1, 0.1))
    }

    private var resolvedBackupState: AppModel.BackupState {
        backupState ?? app.photoBackupState(photo)
    }

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                Color.clear
                TilePlaceholder()
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .id(imageID)
                        .transition(.opacity)
                }
            }
            .modifier(TileSizing(side: side, aspectRatio: aspectRatio))
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                if photo.isVideo {
                    videoBadge
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if photo.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    if resolvedBackupState == .needsUpdate {
                        Image(systemName: "arrow.triangle.2.circlepath.icloud")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(.orange))
                    }
                }
                .padding(4)
            }
            .overlay {
                if isHovering {
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Circle().fill(.black.opacity(0.3)))
                                .padding(5)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .zoomTransitionSource(id: photo.id, in: zoomSourceActive ? zoomNamespace : nil)
        .onHover { isHovering = $0 }
        .task(id: photo.id) { await load() }
        .contextMenu {
            Button {
                app.toggleFavorite(photo.id)
            } label: {
                Label(photo.isFavorite ? "Remove from Favorites" : "Favorite", systemImage: photo.isFavorite ? "heart.slash" : "heart")
            }
            Button {
                var presentation = app.photosForViewer(startingAt: photo.id, within: app.catalog.photos)
                presentation.panel = .info
                app.viewer = presentation
            } label: {
                Label("Details", systemImage: "info.circle")
            }
            Button {
                app.activeTab = .search
            } label: {
                Label("Find Similar", systemImage: "magnifyingglass")
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isFinal ? "Ready" : "Loading")
        .accessibilityIdentifier("library.tile")
        #if DEBUG
        .onAppear { TileLoadProbe.shared.appeared(photo.id, blank: image == nil, final: isFinal) }
        .onDisappear { TileLoadProbe.shared.disappeared(photo.id) }
        .onChange(of: image == nil) { _, isBlank in
            if !isBlank { TileLoadProbe.shared.painted(photo.id) }
        }
        .onChange(of: isFinal) { _, ready in
            if ready { TileLoadProbe.shared.finished(photo.id) }
        }
        #endif
    }

    /// Already-decoded thumbnails paint in the same transaction, so a tile
    /// returning into view never flashes its placeholder. PhotoKit's degraded
    /// pass then swaps in as soon as it arrives; the final image fades over it.
    private func load() async {
        let size = resolvedTargetSize
        if loadedPhotoID != photo.id {
            loadedPhotoID = photo.id
            image = nil
            isFinal = false
        }
        if let final = app.images.cachedFinalThumbnail(for: photo, size: size) {
            image = final
            isFinal = true
            return
        }
        if image == nil, let quick = app.images.cachedThumbnail(for: photo, size: size) {
            image = quick
            imageID += 1
        }
        let loaded = await app.images.thumbnail(for: photo, size: size) { degraded in
            guard !isFinal else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                image = degraded
                imageID += 1
            }
        }
        guard let loaded else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            image = loaded
            imageID += 1
            isFinal = true
        }
    }

    private var accessibilityLabel: String {
        var parts = [photo.isVideo ? "Video" : "Photo"]
        if let dateText {
            parts.append(dateText)
        } else if let date = photo.takenAt {
            parts.append(date.dayLabel)
        }
        if !photo.faces.isEmpty { parts.append("\(photo.faces.count) people") }
        return parts.joined(separator: ", ")
    }

    private var videoBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 7, weight: .bold))
            if let duration = photo.duration {
                Text(shortDuration(duration))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.42)))
        .padding(4)
    }

    private func shortDuration(_ duration: Double) -> String {
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        return "0:\(String(format: "%02d", seconds))"
    }
}

/// The loading surface: a calm two-tone wash instead of a spinner per tile.
/// It stays still while scrolling — no flashing, no repeating animation.
private struct TilePlaceholder: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.055))
            .overlay {
                LinearGradient(
                    colors: [.white.opacity(0.14), .clear, .black.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}

private struct TileSizing: ViewModifier {
    var side: CGFloat?
    var aspectRatio: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let side {
            content.frame(width: side, height: side)
        } else if let aspectRatio {
            content
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            content.aspectRatio(1, contentMode: .fit)
        }
    }
}

struct FaceBubble: View {
    let photo: PhotoItem
    let face: PhotoFace
    var size: CGFloat = 56
    @Environment(AppModel.self) private var app
    @State private var image: PlatformImage?
    @State private var didAppear = false

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(.quaternary)
                    .overlay {
                        Image(systemName: face.kind == .pet ? "pawprint.fill" : "person.fill")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
        .scaleEffect(didAppear ? 1 : 0.85)
        .opacity(didAppear ? 1 : 0)
        .onAppear {
            withAnimation(.backuGentle.delay(0.03)) { didAppear = true }
        }
        .task(id: face.id) {
            image = await app.images.faceImage(photo: photo, face: face)
        }
    }
}
