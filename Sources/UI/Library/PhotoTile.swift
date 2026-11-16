import SwiftUI

struct PhotoTile: View {
    let photo: PhotoItem
    var columns: Int
    var cornerRadius: CGFloat = Theme.tileRadius
    var onOpen: () -> Void
    @Environment(AppModel.self) private var app
    @State private var image: PlatformImage?
    @State private var isHovering = false

    private var targetSize: CGSize {
        let width: CGFloat = 700 / CGFloat(max(columns, 1))
        return CGSize(width: width, height: width)
    }

    var body: some View {
        Button(action: onOpen) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        if let image {
                            Image(platformImage: image)
                                .resizable()
                                .scaledToFill()
                                .transition(.opacity)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.secondary)
                        }
                    }
                }
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
                    if app.photoBackupState(photo) == .needsUpdate {
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
        .onHover { isHovering = $0 }
        .task(id: photo.id) {
            image = await app.images.thumbnail(for: photo, size: targetSize)
        }
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
        .accessibilityIdentifier("library.tile")
    }

    private var accessibilityLabel: String {
        var parts = [photo.isVideo ? "Video" : "Photo"]
        if let date = photo.takenAt { parts.append(date.dayLabel) }
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
