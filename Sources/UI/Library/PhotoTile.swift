import SwiftUI

/// Identity for a tile's load task: the photo plus the density it is displayed
/// at. `CGSize` is `Equatable`, so a pinch that changes the target size
/// restarts the task and reloads the bitmap.
private struct TileLoadKey: Equatable {
    var photoID: String
    var size: CGSize
}

/// Shared, non-observable generation counter. `ImageCache.thumbnail` may
/// resume a cancelled caller when a shared task completes, so a load must
/// prove it is still the newest one before writing state. A class keeps the
/// counter out of SwiftUI's observation graph (no body invalidation).
private final class TileLoadToken {
    var current = 0
}

struct PhotoTile: View, Equatable {
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
    var isSelecting: Bool = false
    var isSelected: Bool = false
    var onOpen: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.viewerZoomNamespace) private var zoomNamespace
    @Environment(\.viewerZoomSourceActive) private var zoomSourceActive
    @State private var image: PlatformImage?
    @State private var isFinal = false
    @State private var imageID = 0
    @State private var loadedPhotoID: String?
    @State private var loadedSize: CGSize?
    @State private var loadToken = TileLoadToken()
    @State private var isHovering = false

    /// Library tiles are recreated on every body evaluation of the grid, but
    /// their contents only change when the photo, its badges or the selection
    /// state do. Comparing that surface (and ignoring the closure, which is
    /// rebuilt every time) lets the grid wrap tiles in `EquatableView` so a
    /// scroll never re-evaluates the body of a tile that has not changed.
    static func == (lhs: PhotoTile, rhs: PhotoTile) -> Bool {
        lhs.photo.id == rhs.photo.id
            && lhs.photo.isVideo == rhs.photo.isVideo
            && lhs.photo.isFavorite == rhs.photo.isFavorite
            && lhs.photo.duration == rhs.photo.duration
            && lhs.photo.takenAt == rhs.photo.takenAt
            && lhs.photo.faces.count == rhs.photo.faces.count
            && lhs.columns == rhs.columns
            && lhs.side == rhs.side
            && lhs.aspectRatio == rhs.aspectRatio
            && lhs.targetSize == rhs.targetSize
            && lhs.backupState == rhs.backupState
            && lhs.dateText == rhs.dateText
            && lhs.cornerRadius == rhs.cornerRadius
            && lhs.isSelecting == rhs.isSelecting
            && lhs.isSelected == rhs.isSelected
    }

    private var resolvedTargetSize: CGSize {
        if let targetSize { return targetSize }
        let width: CGFloat = 700 / CGFloat(max(columns, 1))
        return CGSize(width: width, height: width / max(aspectRatio ?? 1, 0.1))
    }

    private var resolvedBackupState: AppModel.BackupState {
        backupState ?? app.photoBackupState(photo)
    }

    var body: some View {
        // A synchronous cache lookup in `body` is what makes a returning or
        // prefetched tile paint its picture in the first frame. Without it the
        // tile always painted its placeholder until the `.task` below ran,
        // which is the blank flash a fast fling exposes.
        let cached = cachedEntry
        let shown = image ?? cached?.image
        let isReady = isFinal || (image == nil && (cached?.isFinal ?? false))

        Button(action: onOpen) {
            ZStack {
                Color.clear
                if let shown {
                    TileImage(image: shown, imageID: imageID)
                } else {
                    TilePlaceholder()
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
                if isSelecting {
                    selectionMark
                } else {
                    HStack(spacing: 4) {
                        if photo.isFavorite {
                            Image(systemName: "heart.fill")
                                .scaledFont(9, weight: .bold)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(.black.opacity(0.35)))
                        }
                        if resolvedBackupState == .needsUpdate {
                            Image(systemName: "arrow.triangle.2.circlepath.icloud")
                                .scaledFont(10, weight: .bold)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(.orange))
                        }
                    }
                    .padding(4)
                }
            }
            .overlay {
                if isSelecting {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 3)
                        .allowsHitTesting(false)
                }
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
        .background {
            if isSelecting {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TileFramePreferenceKey.self,
                        value: [photo.id: proxy.frame(in: .named("libraryGrid"))]
                    )
                }
            }
        }
        .zoomTransitionSource(id: photo.id, in: zoomSourceActive ? zoomNamespace : nil)
        .onHover { isHovering = $0 }
        // The id includes the target size: pinching to a new density must
        // restart the load, otherwise the old bitmap stays upscaled in the new
        // (much larger) slot forever.
        .task(id: TileLoadKey(photoID: photo.id, size: resolvedTargetSize)) { await load() }
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
                app.showSearch = true
            } label: {
                Label("Find Similar", systemImage: "magnifyingglass")
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            isSelecting
                ? (isSelected ? "Selected" : "Not selected")
                : (isReady ? "Ready" : "Loading")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("library.tile")
        #if DEBUG
        .onAppear { TileLoadProbe.shared.appeared(photo.id, blank: shown == nil, final: isReady) }
        .onDisappear { TileLoadProbe.shared.disappeared(photo.id) }
        .onChange(of: shown == nil) { _, isBlank in
            if !isBlank { TileLoadProbe.shared.painted(photo.id) }
        }
        .onChange(of: isReady) { _, ready in
            if ready { TileLoadProbe.shared.finished(photo.id) }
        }
        #endif
    }

    /// Best already-decoded image for this photo, at this density or at the
    /// last density it was decoded for. NSCache lookups only: no request is
    /// created, so it is safe to call from `body`.
    private var cachedEntry: ImageCache.CachedThumbnail? {
        app.images.cachedThumbnailEntry(for: photo, size: resolvedTargetSize)
    }

    /// Already-decoded thumbnails paint in the same transaction; PhotoKit's
    /// degraded pass then swaps in as soon as it arrives; the final image
    /// fades over it. When `body` already painted the cache, the final hit
    /// here only confirms readiness and causes no visible change.
    ///
    /// A tile can have several loads in flight across a pinch: `.task(id:)`
    /// cancels the old one, but `ImageCache.thumbnail` resumes its caller when
    /// the shared decode finishes, cancellation or not. Every path therefore
    /// proves it is still the current generation before touching `image`,
    /// `imageID` or `isFinal`, so an old density can never overwrite a newer
    /// one or claim "Ready".
    private func load() async {
        guard !Task.isCancelled else { return }
        loadToken.current += 1
        let token = loadToken.current
        let size = resolvedTargetSize
        let cached = cachedEntry
        if loadedPhotoID != photo.id {
            loadedPhotoID = photo.id
            loadedSize = size
            if cached == nil {
                image = nil
                isFinal = false
            }
        } else if loadedSize != size {
            // The grid density changed. Keep the current bitmap on screen
            // (never blank) and mark it not-final so the new size is fetched
            // and swapped in.
            loadedSize = size
            isFinal = false
        }
        guard !Task.isCancelled, loadToken.current == token, loadedSize == size else { return }
        if let final = app.images.cachedFinalThumbnail(for: photo, size: size) {
            if image == nil {
                // `body` is already drawing this exact cache entry; adopting it
                // into state needs no new image identity, so nothing is
                // re-inserted for a tile that is already correct.
                image = final
            } else if image !== final {
                image = final
                imageID += 1
            }
            isFinal = true
            #if DEBUG
            LibraryImageProbe.shared.recordFinal(final, targetSize: size)
            #endif
            return
        }
        if image == nil, let quick = cached?.image {
            // The same entry `body` fell back to, when the cache was filled
            // between the body pass and this task.
            image = quick
        }
        let loaded = await app.images.thumbnail(for: photo, size: size) { degraded in
            // This closure is invoked from ImageCache's own Task, where
            // `Task.isCancelled` would not describe this tile. The generation
            // and the shared `loadedSize` are the authority here.
            guard loadToken.current == token, loadedSize == size, !isFinal else { return }
            withRespectingReduceMotion(.easeOut(duration: 0.12), when: reduceMotion) {
                image = degraded
                imageID += 1
            }
        }
        guard let loaded else { return }
        guard !Task.isCancelled, loadToken.current == token, loadedSize == size else { return }
        withRespectingReduceMotion(.easeOut(duration: 0.2), when: reduceMotion) {
            image = loaded
            imageID += 1
            isFinal = true
        }
        #if DEBUG
        LibraryImageProbe.shared.recordFinal(loaded, targetSize: size)
        #endif
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

    private var selectionMark: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .scaledFont(22, weight: .semibold)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, isSelected ? Theme.accent : Color.black.opacity(0.25))
            .background(Circle().fill(.black.opacity(0.18)))
            .padding(6)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .accessibilityHidden(true)
    }

    private var videoBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .scaledFont(7, weight: .bold)
            if let duration = photo.duration {
                Text(shortDuration(duration))
                    .scaledFont(9, weight: .semibold, design: .rounded)
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
/// The thumbnail itself. It carries no label of its own: the tile's Button
/// describes the photo, so VoiceOver reads one element instead of two.
private struct TileImage: View {
    let image: PlatformImage
    let imageID: Int

    var body: some View {
        Image(platformImage: image)
            .resizable()
            .scaledToFill()
            .accessibilityHidden(true)
            .id(imageID)
            .transition(.opacity)
    }
}

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: PlatformImage?
    @State private var didAppear = false

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
            } else {
                Circle().fill(.quaternary)
                    .overlay {
                        Image(systemName: face.kind == .pet ? "pawprint.fill" : "person.fill")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .accessibilityHidden(true)
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
        .scaleEffect(didAppear ? 1 : 0.85)
        .opacity(didAppear ? 1 : 0)
        .onAppear {
            withRespectingReduceMotion(.backuGentle.delay(0.03), when: reduceMotion) { didAppear = true }
        }
        .task(id: face.id) {
            image = await app.images.faceImage(photo: photo, face: face)
        }
    }
}
