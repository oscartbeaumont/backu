import SwiftUI

/// A subtle blurred wash behind the floating title and status bar. Photos uses
/// a tall, soft background-coloured gradient rather than a hard material bar;
/// this keeps the title readable while the grid bleeds underneath.
struct StatusBarScrim: View {
    var topInset: CGFloat
    var isVisible: Bool

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Theme.systemBackground.opacity(0.84), location: 0),
                .init(color: Theme.systemBackground.opacity(0.42), location: 0.55),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: max(topInset, 8) + 60)
        .ignoresSafeArea(edges: .top)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Photos' three-level library switch: Years, Months, All.
///
/// The control is a glass capsule with a matched-geometry selection pill. It
/// lives inside the bottom bar, so every timeline element shares the same
/// 56 pt height.
struct LibraryLevelSwitcher: View {
    @Binding var level: LibraryLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    private var selected: LibraryLevel { level }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(LibraryLevel.allCases) { option in
                Button {
                    guard level != option else { return }
                    level = option
                } label: {
                    Text(option.rawValue)
                        .font(.subheadline.weight(level == option ? .semibold : .medium))
                        .foregroundStyle(level == option ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background {
                            if level == option {
                                Capsule()
                                    .fill(Color.primary.opacity(0.14))
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
                                    .matchedGeometryEffect(id: "library.level", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(level == option ? .isSelected : [])
                .accessibilityIdentifier("library.level.\(option.rawValue.lowercased())")
            }
        }
        .padding(3)
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 240, minHeight: 56, maxHeight: 56)
        .glassCapsule(interactive: true)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .animation(
            reduceMotion ? .easeInOut(duration: 0.16) : .snappy(duration: 0.28, extraBounce: 0.02),
            value: selected
        )
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library zoom level")
        .accessibilityValue(level.rawValue)
        .accessibilityIdentifier("library.levelSwitcher")
    }
}

/// Floating Photos-style header: a large title on the left and the filter and
/// Select controls on the right, all over the photo grid. Backup controls live
/// in Settings; the photo view stays as quiet as Photos.
struct LibraryTopBar: View {
    var title: String
    var isSelecting: Bool
    var isFiltered: Bool
    var filterSymbol: String
    var onFilter: () -> Void
    var onToggleSelection: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            if isSelecting {
                #if os(iOS)
                Button("Done", action: onToggleSelection)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("library.done")
                #endif
            } else {
                Button(action: onFilter) {
                    Image(systemName: isFiltered ? filterSymbol : "line.3.horizontal.decrease")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isFiltered ? Theme.accent : Color.primary)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(isFiltered ? "Filter applied" : "Filter and sort")
                .accessibilityIdentifier("library.filter")

                #if os(iOS)
                Button(action: onToggleSelection) {
                    Text("Select")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Select photos")
                .accessibilityIdentifier("library.select")
                #endif
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// Photos' selection action bar: share on the left, a Select All control in
/// the middle and delete on the right, floating where the level switcher sits.
struct LibrarySelectionBar: View {
    var selectedCount: Int
    var allSelected: Bool
    var isPreparingShare: Bool
    var onShare: () -> Void
    var onToggleAll: () -> Void
    var onDelete: () -> Void

    private var isEmpty: Bool { selectedCount == 0 }

    var body: some View {
        HStack(spacing: 3) {
            Button(action: onShare) {
                Group {
                    if isPreparingShare {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .frame(width: 64, height: 42)
                .contentShape(Rectangle())
            }
            .frame(width: 64, height: 42)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(isEmpty || isPreparingShare)
            .opacity(isEmpty ? 0.35 : 1)
            .accessibilityLabel("Share selected photos")
            .accessibilityIdentifier("library.selection.share")

            Button(action: onToggleAll) {
                Text(allSelected ? "Deselect All" : "Select All")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(allSelected ? "Deselect all photos" : "Select all photos")
            .accessibilityIdentifier("library.selection.all")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 64, height: 42)
                    .contentShape(Rectangle())
            }
            .frame(width: 64, height: 42)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .opacity(isEmpty ? 0.35 : 1)
            .accessibilityLabel("Delete selected photos")
            .accessibilityIdentifier("library.selection.delete")
        }
        .padding(3)
        .frame(width: 270, height: 48)
        .glassCapsule(interactive: true)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}
