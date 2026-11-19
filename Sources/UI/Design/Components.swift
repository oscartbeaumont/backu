import SwiftUI

struct BrandMarkView: View {
    var size: CGFloat = 44
    var showBackground = false

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: showBackground ? size * 0.24 : 0, style: .continuous))
    }
}

struct ScreenTitle: View {
    var title: String
    var subtitle: String?
    var trailing: AnyView?

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> some View = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.largeTitle.bold())
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

struct GlassIconButton: View {
    var symbol: String
    var label: String
    var isActive: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(16, weight: .semibold)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(isActive ? Theme.accent : nil)
        .accessibilityLabel(label)
    }
}

struct ProviderBadge: View {
    var provider: StorageProvider
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(hex: provider.tint).gradient)
            Image(systemName: provider.symbol)
                .scaledFont(size * 0.42, weight: .semibold)
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct FilterChip: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(PressableButtonStyle())
        .glassSurface(22, tint: isSelected ? Theme.accent : nil, interactive: true)
        .animation(.backuSnappy, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct TagChip: View {
    var text: String
    var isSelected: Bool = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .scaledFont(9, weight: .bold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(text)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background {
            if isSelected {
                Capsule().fill(Theme.accent)
            } else {
                Capsule().fill(.thinMaterial)
            }
        }
        .overlay {
            if !isSelected {
                Capsule().strokeBorder(.black.opacity(0.06))
            }
        }
    }
}

struct StatTile: View {
    var value: String
    var label: String
    var symbol: String
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(16, weight: .semibold)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassSurface(18)
    }
}

struct BackupBadge: View {
    var state: AppModel.BackupState

    var body: some View {
        switch state {
        case .backedUp:
            Image(systemName: "checkmark.icloud.fill")
                .foregroundStyle(.white, Theme.mint)
                .accessibilityLabel("Backed up")
        case .needsUpdate:
            Image(systemName: "arrow.triangle.2.circlepath.icloud")
                .foregroundStyle(.white, .orange)
                .accessibilityLabel("Details need an update")
        case .notBackedUp:
            Image(systemName: "icloud.slash")
                .foregroundStyle(.white, .gray)
                .accessibilityLabel("Not backed up")
        }
    }
}

struct ProgressBar: View {
    var value: Double
    var tint: Color = Theme.accent

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(6, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 7)
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .scaledFont(38, weight: .light)
                .foregroundStyle(Theme.accent)
                .padding(18)
                .glassSurface(24, tint: Theme.accent.opacity(0.12))
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(36)
    }
}

/// Wrapping layout for chips and filters.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Shared formatters. `DateFormatter` is expensive to build (locale data,
/// ICU state) and was previously constructed on every access, inside body
/// evaluation for grid and viewer labels. DateFormatter is safe to read from
/// multiple threads on Apple platforms, so one instance per format is enough.
private enum DateFormatters {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    static let monthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

extension Date {
    var monthYearLabel: String {
        DateFormatters.monthYear.string(from: self)
    }

    var dayLabel: String {
        DateFormatters.day.string(from: self)
    }

    var timeLabel: String {
        DateFormatters.time.string(from: self)
    }

    var relativeShort: String {
        DateFormatters.relative.localizedString(for: self, relativeTo: Date())
    }
}
