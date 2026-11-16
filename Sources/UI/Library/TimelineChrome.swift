import SwiftUI

/// The continuous timeline's labels, kept in their own observable object so
/// scrolling only invalidates the small chrome views that read them — never the
/// grid itself.
@MainActor
@Observable
final class TimelineLabelState {
    /// First day of the month at the top of the grid.
    var month: Date?
    /// Year at the top of the grid.
    var year: Int?
    /// Year under the finger while the rail is being dragged. It only becomes
    /// the timeline's year once the drag is committed.
    var scrubYear: Int?
    /// True once the large title has scrolled out of view.
    var isCollapsed = false
    var isRailVisible = false
    var isScrubbing = false

    var highlightedYear: Int? { scrubYear ?? year }

    private var lastTouch = Date.distantPast
    private var idleTask: Task<Void, Never>?

    func touch() {
        lastTouch = Date()
        if !isRailVisible { isRailVisible = true }
        guard idleTask == nil else { return }
        // One light poll while the rail is on screen: it hides shortly after
        // the last scroll instead of being re-armed on every frame.
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard let self else { return }
                if self.isScrubbing {
                    self.lastTouch = Date()
                    continue
                }
                if Date().timeIntervalSince(self.lastTouch) > 2.2 {
                    self.isRailVisible = false
                    self.idleTask = nil
                    return
                }
            }
        }
    }

    func update(month: Date?, year: Int?) {
        if self.month != month { self.month = month }
        if self.year != year { self.year = year }
    }

    func cancel() {
        idleTask?.cancel()
        idleTask = nil
    }
}

/// A small glass pill that names the month at the top of the grid.
struct MonthPill: View {
    var date: Date

    private var label: String {
        date.formatted(.dateTime.month(.wide).year())
    }

    var body: some View {
        Text(label)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .glassCapsule()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("library.monthPill")
    }
}

/// Trailing Liquid Glass year rail. Tapping or dragging maps the vertical
/// position to a year and asks the parent to scroll there.
struct YearRail: View {
    var anchors: [YearAnchor]
    var availableHeight: CGFloat
    @Bindable var label: TimelineLabelState
    var onSelect: (Int) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var isShown: Bool { label.isRailVisible || label.isScrubbing || voiceOverEnabled }

    private var railHeight: CGFloat {
        guard !anchors.isEmpty else { return 0 }
        let cap = max(180, min(availableHeight * 0.62, 460))
        return min(CGFloat(anchors.count) * 24, cap)
    }

    private var rowHeight: CGFloat {
        guard !anchors.isEmpty else { return 0 }
        return railHeight / CGFloat(anchors.count)
    }

    var body: some View {
        if anchors.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ForEach(anchors) { anchor in
                    Text(String(anchor.year))
                        .font(.system(
                            size: min(11, max(7, rowHeight - 8)),
                            weight: anchor.year == label.highlightedYear ? .bold : .medium,
                            design: .rounded
                        ))
                        .monospacedDigit()
                        .foregroundStyle(anchor.year == label.highlightedYear ? Theme.accent : Color.secondary)
                        .frame(width: 32, height: rowHeight)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .glassCapsule(interactive: true)
            .overlay {
                // A dedicated hit layer keeps the scrub gesture working even
                // though the glass itself draws above the scroll content.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                label.isScrubbing = true
                                highlight(at: value.location.y)
                            }
                            .onEnded { value in
                                commit(at: value.location.y)
                                label.scrubYear = nil
                                label.isScrubbing = false
                            }
                    )
                    .allowsHitTesting(isShown)
            }
            .sensoryFeedback(.selection, trigger: label.highlightedYear)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Year timeline")
            .accessibilityValue(label.highlightedYear.map(String.init) ?? "No years")
            .accessibilityHint("Adjust to jump to another year")
            .accessibilityAdjustableAction { direction in
                adjust(direction)
            }
            .accessibilityAction(named: "Jump to latest year") {
                if let newest = anchors.first { onSelect(newest.year) }
            }
            .accessibilityIdentifier("library.yearRail")
            .opacity(isShown ? 1 : 0)
            .scaleEffect(isShown ? 1 : 0.94, anchor: .trailing)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
            .animation(.easeOut(duration: 0.22), value: isShown)
        }
    }

    private func highlight(at y: CGFloat) {
        guard rowHeight > 0 else { return }
        let index = min(max(Int(y / rowHeight), 0), anchors.count - 1)
        let year = anchors[index].year
        if label.scrubYear != year { label.scrubYear = year }
    }

    private func commit(at y: CGFloat) {
        guard rowHeight > 0 else { return }
        let index = min(max(Int(y / rowHeight), 0), anchors.count - 1)
        onSelect(anchors[index].year)
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard let current = label.highlightedYear ?? anchors.first?.year,
              let index = anchors.firstIndex(where: { $0.year == current }) else { return }
        let next: Int
        switch direction {
        case .increment: next = max(0, index - 1)
        case .decrement: next = min(anchors.count - 1, index + 1)
        @unknown default: return
        }
        guard next != index else { return }
        onSelect(anchors[next].year)
    }
}

/// Floating chrome over the timeline: the month pill (once the large title is
/// gone) and the glass grid-size / backup controls.
struct LibraryTopBar: View {
    @Environment(AppModel.self) private var app
    @Bindable var label: TimelineLabelState
    var pendingCount: Int
    var onAddServer: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if label.isCollapsed, let month = label.month {
                MonthPill(date: month)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
            }

            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    gridSizeMenu
                    backupControl
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(.backuGentle, value: label.isCollapsed)
    }

    private var gridSizeMenu: some View {
        Menu {
            Picker("Grid size", selection: Binding(
                get: { app.settings.gridColumns },
                set: { app.settings.gridColumns = $0 }
            )) {
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
            Button {
                app.backup.cancel()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.red)
            .accessibilityLabel("Stop backup")
        } else if app.servers.servers.isEmpty {
            Button(action: onAddServer) {
                Label("Add storage", systemImage: "externaldrive.badge.plus")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 42)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
        } else if pendingCount == 0 {
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.mint)
                .frame(width: 42, height: 42)
                .accessibilityLabel("All \(app.catalog.photos.count) photos backed up")
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
            .accessibilityLabel("Back up \(pendingCount) photos to \(app.backupServer?.name ?? "storage")")
        }
    }
}
