import SwiftUI

/// The small bit of scroll state the floating chrome needs. The grid itself
/// never observes this, so scrolling only re-renders the header wash.
@MainActor
@Observable
final class TimelineLabelState {
    /// True once the large title has scrolled out of view.
    var isCollapsed = false

    func setCollapsed(_ value: Bool) {
        if isCollapsed != value { isCollapsed = value }
    }
}

/// A subtle blurred wash behind the status bar once the large title has
/// scrolled away. Photos uses a much taller, softer gradient than a material
/// bar; this keeps the title and controls readable without cutting the grid.
struct StatusBarScrim: View {
    var topInset: CGFloat
    var isVisible: Bool

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Theme.systemBackground, location: 0),
                .init(color: Theme.systemBackground.opacity(0.88), location: 0.55),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: max(topInset, 8) + 74)
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
/// floats above the tab bar, so the content keeps the full width on every
/// level and the switch is reachable without leaving the timeline.
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
                        .frame(width: 78, height: 42)
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
        .frame(width: 240, height: 48)
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

/// Floating chrome over the timeline: filter, grid density and backup state.
/// The month pill and year scrubber are intentionally gone — Photos has no
/// scrubber, and its date readout lives in the header subtitle and the Months
/// section headers instead.
struct LibraryTopBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var filter: LibraryFilter
    var showsGridSize: Bool
    var pendingCount: Int
    var onShowActivity: () -> Void
    var onAddServer: () -> Void
    @Namespace private var backupNamespace

    private var backupMotion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.34, extraBounce: 0.03)
    }

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 8)

            filterMenu
            if showsGridSize {
                gridSizeMenu
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
            }
            GlassEffectContainer(spacing: 10) {
                backupControl
                    .glassEffectID("backup", in: backupNamespace)
            }
            .animation(backupMotion, value: app.backup.isRunning)
        }
        .sensoryFeedback(trigger: app.backup.isRunning) { _, running in
            running ? .impact(weight: .medium) : .success
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $filter) {
                ForEach(LibraryFilter.allCases) { option in
                    Label(option.rawValue, systemImage: option.symbol)
                        .tag(option)
                }
            }
        } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease" : filter.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(filter == .all ? Color.primary : Theme.accent)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(filter == .all ? "Filter photos" : "Filter: \(filter.rawValue)")
        .accessibilityIdentifier("library.filter")
    }

    private var gridSizeMenu: some View {
        Menu {
            Picker("Grid size", selection: Binding(
                get: { app.settings.gridColumns },
                set: { app.settings.gridColumns = $0 }
            )) {
                Label("Full width", systemImage: "rectangle").tag(1)
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
    }

    @ViewBuilder
    private var backupControl: some View {
        if app.backup.isRunning {
            Button(action: onShowActivity) {
                backupProgressPill
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Backup activity")
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
        } else if app.servers.servers.isEmpty {
            Button(action: onAddServer) {
                Label("Add storage", systemImage: "externaldrive.badge.plus")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 42)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
        } else if pendingCount == 0 {
            Button(action: onShowActivity) {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.mint)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All \(app.catalog.photos.count) photos backed up. Open backup activity")
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
        } else {
            Button {
                app.startBackup()
            } label: {
                Image(systemName: "arrow.up.to.line.compact")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(app.backupDestinationCount > 1
                ? "Back up \(pendingCount) photos to \(app.backupDestinationCount) buckets"
                : "Back up \(pendingCount) photos to \(app.backupServer?.name ?? "storage")")
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    /// The floating backup control grows into a live progress pill while a run
    /// is in flight, then shrinks back into its idle state.
    private var backupProgressPill: some View {
        Button {
            app.backup.cancel()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.16), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.03, app.backup.progress))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: app.backup.progress)
                }
                .frame(width: 18, height: 18)

                Text("\(app.backup.completedCount)/\(app.backup.totalCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: app.backup.completedCount)
            }
            .padding(.horizontal, 13)
            .frame(height: 42)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Backing up \(app.backup.completedCount) of \(app.backup.totalCount). Stop backup")
    }
}
