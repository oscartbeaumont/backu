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
/// 56 pt height. The capsule stretches to the space the Library and Search
/// circles leave, which keeps the bar's side margins identical to the tab bar.
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
        // The bar is height-locked at 56 pt, so the labels stop at AX1: at AX5
        // an uncapped label is wider than its third of the capsule and truncates
        // to "M…", and even AX2 overflows this segment width.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(3)
        .frame(minWidth: 200, maxWidth: .infinity, minHeight: 56, maxHeight: 56)
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

/// Liquid Glass button surface drawn at the label's exact size.
///
/// `.buttonStyle(.glass)` adds its own padding and highlight around the label,
/// so a 42 pt label renders around 57 pt and a nominally 56 pt frame grows past
/// the bar it sits in. Attaching the glass to the label and keeping the button
/// plain makes circles and capsules exactly the size they are given; `hitTarget`
/// adds an invisible tap area around smaller glass so it stays easy to hit.
struct GlassSurfaceButtonStyle: ButtonStyle {
    enum Outline {
        case circle
        case capsule
    }

    var outline: Outline
    /// The smallest tappable size. The glass itself stays visually smaller.
    var hitTarget: CGFloat = 44

    private var shape: AnyShape {
        switch outline {
        case .circle: AnyShape(Circle())
        case .capsule: AnyShape(Capsule())
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(.regular.interactive(), in: shape)
            .frame(minWidth: outline == .circle ? hitTarget : nil, minHeight: hitTarget)
            .contentShape(Rectangle())
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

    /// Chrome grows with Dynamic Type only up to 56 pt. Uncapped, the metrics
    /// reached 98.67 pt at AX5 — nearly a fifth of the screen — which left the
    /// large title no room and truncated it to "Libra…". The labels below also
    /// stop at AX2, so their text always fits the capped glass. A fixed 34 pt
    /// frame would spill its text instead; a cap keeps the row readable at both
    /// ends. The button style's 44 pt hit target remains the tappable floor.
    @ScaledMetric(relativeTo: .subheadline) private var scaledControlHeight: CGFloat = 34
    @ScaledMetric(relativeTo: .subheadline) private var scaledFilterDiameter: CGFloat = 34

    private var controlHeight: CGFloat { min(scaledControlHeight, 56) }
    private var filterDiameter: CGFloat { min(scaledFilterDiameter, 56) }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(title)
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            if isSelecting {
                #if os(iOS)
                Button(action: onToggleSelection) {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .frame(height: controlHeight)
                }
                .buttonStyle(GlassSurfaceButtonStyle(outline: .capsule))
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .accessibilityIdentifier("library.done")
                #endif
            } else {
                Button(action: onFilter) {
                    Image(systemName: isFiltered ? filterSymbol : "line.3.horizontal.decrease")
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(isFiltered ? Theme.accent : Color.primary)
                        .frame(width: filterDiameter, height: filterDiameter)
                }
                .buttonStyle(GlassSurfaceButtonStyle(outline: .circle))
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .accessibilityLabel(isFiltered ? "Filter applied" : "Filter and sort")
                .accessibilityIdentifier("library.filter")

                #if os(iOS)
                Button(action: onToggleSelection) {
                    Text("Select")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .frame(height: controlHeight)
                }
                .buttonStyle(GlassSurfaceButtonStyle(outline: .capsule))
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
                            .scaledFont(17, weight: .semibold)
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
                    .scaledFont(17, weight: .semibold)
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
        // Fixed 270 × 48 pt chrome, so its type stops at AX1 like the level
        // switcher; uncapped it truncates "Select All" to "Sele…" at AX5.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(3)
        .frame(width: 270, height: 48)
        .glassCapsule(interactive: true)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}
