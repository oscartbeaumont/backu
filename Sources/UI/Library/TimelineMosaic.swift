import SwiftUI

/// Collects the frames of visible library tiles so a drag can select the
/// contiguous run of photos between the anchor and the finger.
struct TileFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Photos' zoomed-out levels are dense collages, not one hero image. This lays
/// a section's photos into square thumbnails with the same 2 pt gutters as the
/// All grid, so the transition between levels feels continuous.
struct TimelineMosaic: View {
    let photos: [PhotoItem]
    var columns: Int = 6
    var maxItems: Int = 42

    private var shown: [PhotoItem] {
        Array(photos.prefix(maxItems))
    }

    private var rows: [[PhotoItem]] {
        guard columns > 0 else { return [] }
        return stride(from: 0, to: shown.count, by: columns).map { start in
            Array(shown[start..<min(start + columns, shown.count)])
        }
    }

    private var pixelSize: CGFloat {
        max(300, 1200 / CGFloat(max(columns, 1)))
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 2) {
                    ForEach(rows[index]) { photo in
                        TimelineThumbnail(photo: photo, pixelSize: pixelSize)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(0..<max(0, columns - rows[index].count), id: \.self) { _ in
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct TimelineThumbnail: View {
    let photo: PhotoItem
    let pixelSize: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: PlatformImage?

    private var targetSize: CGSize {
        CGSize(width: pixelSize, height: pixelSize)
    }

    var body: some View {
        ZStack {
            Color.primary.opacity(0.06)
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: photo.id) { await load() }
    }

    private func load() async {
        if let cached = app.images.cachedThumbnail(for: photo, size: targetSize) {
            image = cached
        }
        guard let loaded = await app.images.thumbnail(for: photo, size: targetSize),
              !Task.isCancelled else { return }
        withRespectingReduceMotion(.easeOut(duration: 0.18), when: reduceMotion) {
            image = loaded
        }
    }
}

/// The dark translucent date capsule Photos floats over a collage.
struct TimelineDateLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .scaledFont(20, weight: .bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.black.opacity(0.52))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
            }
            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
    }
}

struct TimelineCountBadge: View {
    let remaining: Int

    var body: some View {
        Text("+\(remaining)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(.black.opacity(0.52)))
    }
}
