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
    /// The exact card width in points, supplied by the timeline. Cells are
    /// sized from this rather than from flexible proposals: a thumbnail's
    /// `Image` has an intrinsic size, and if a lazy container ever measures the
    /// card without a width proposal ("maxWidth: .infinity" does not force
    /// one), those intrinsic sizes leak out and the card grows past the screen.
    var width: CGFloat

    private var rows: [[PhotoItem]] {
        guard columns > 0, !photos.isEmpty else { return [] }
        let shown = Array(photos.prefix(maxItems))
        return stride(from: 0, to: shown.count, by: columns).map { start in
            Array(shown[start..<min(start + columns, shown.count)])
        }
    }

    private var pixelSize: CGFloat {
        max(300, 1200 / CGFloat(max(columns, 1)))
    }

    private var cellSide: CGFloat {
        let count = CGFloat(max(columns, 1))
        guard width > 0 else { return 0 }
        return max(1, (width - 2 * (count - 1)) / count)
    }

    var body: some View {
        // Build the rows once per body pass: `rows` is read for every row and
        // for the filler count, and recomputing it each time was pure scroll
        // cost.
        let rows = self.rows
        let cell = cellSide
        VStack(spacing: 2) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: 2) {
                    ForEach(row) { photo in
                        TimelineThumbnail(photo: photo, pixelSize: pixelSize)
                            .frame(width: cell, height: cell)
                    }
                    ForEach(0..<max(0, columns - row.count), id: \.self) { _ in
                        // Match the "no thumbnail yet" tone so an incomplete
                        // final row reads as part of the collage instead of a
                        // stark white hole.
                        Color.primary.opacity(0.06)
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
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
        // Same first-frame rule as the All grid: paint a decoded thumbnail
        // synchronously so a collage never flashes grey.
        let shown = image ?? app.images.cachedThumbnail(for: photo, size: targetSize)
        ZStack {
            if let shown {
                Image(platformImage: shown)
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .clipped()
        .task(id: photo.id) { await load() }
    }

    private func load() async {
        if image == nil,
           let cached = app.images.cachedFinalThumbnail(for: photo, size: targetSize) {
            image = cached
            return
        }
        if image == nil, let cached = app.images.cachedThumbnail(for: photo, size: targetSize) {
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
///
/// It is an overlay, not a layout sibling: its intrinsic width must never be
/// allowed to size the card. A long month name at a large Dynamic Type setting
/// is wider than the screen, and when that fed back into the card's width the
/// enclosing centred `LazyVStack` placed the card at a negative x — clipping
/// the capsule's leading cap. Constraining it to one line that shrinks keeps
/// the pill inside the card at every size.
struct TimelineDateLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .scaledFont(20, weight: .bold)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .allowsTightening(true)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.black.opacity(0.52))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
            }
            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
            #if DEBUG
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: MonthPillHeightKey.self, value: proxy.size.height)
                }
            }
            #endif
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
