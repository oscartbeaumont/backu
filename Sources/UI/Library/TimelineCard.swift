import SwiftUI

/// A large image card used by the Years and Months levels of the library.
///
/// It deliberately mirrors the calm, rounded PhotoKit cards in Photos: one
/// fitted image per section, a soft placeholder, and no per-card chrome beyond
/// whatever the timeline overlays (a year, a day number, a count).
struct TimelineCard<Overlay: View>: View {
    let photo: PhotoItem
    let width: CGFloat
    /// Width divided by height.
    let aspectRatio: CGFloat
    let cornerRadius: CGFloat
    private let overlay: Overlay

    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    @State private var image: PlatformImage?

    init(
        photo: PhotoItem,
        width: CGFloat,
        aspectRatio: CGFloat,
        cornerRadius: CGFloat,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.photo = photo
        self.width = width
        self.aspectRatio = aspectRatio
        self.cornerRadius = cornerRadius
        self.overlay = overlay()
    }

    private var height: CGFloat {
        width / max(aspectRatio, 0.1)
    }

    private var targetSize: CGSize {
        let scale = max(displayScale, 1)
        return CGSize(width: width * scale, height: height * scale)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.065))
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .overlay {
            overlay
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: photo.id) { await load() }
        .accessibilityHidden(true)
    }

    private func load() async {
        let size = targetSize
        if let cached = app.images.cachedViewerThumbnail(for: photo, size: size) {
            image = cached
        }
        guard let loaded = await app.images.viewerThumbnail(for: photo, size: size),
              !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            image = loaded
        }
    }
}
