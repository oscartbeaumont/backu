import SwiftUI

/// Live upload status: what is uploading, what is queued, what failed, how fast
/// it is going, and whether iOS has been asked to continue in the background.
struct BackupActivityView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var backup: BackupEngine { app.backup }

    private var title: String {
        if backup.isRunning {
            return backup.totalCount == 0 ? "Checking uploads" : "Backing up"
        }
        if backup.failedCount > 0 { return "Needs attention" }
        if app.photosPendingBackup > 0 { return "Waiting for background" }
        if backup.reclaimedCount > 0 { return "Uploads recovered" }
        if backup.lastRunAt != nil { return "Up to date" }
        return "Backup ready"
    }

    private var icon: String {
        if backup.isRunning { return "arrow.up.circle.fill" }
        if backup.failedCount > 0 { return "exclamationmark.triangle.fill" }
        if backup.lastRunAt != nil { return "checkmark.icloud.fill" }
        return "arrow.up.circle"
    }

    private var iconTint: Color {
        if backup.isRunning { return Theme.accent }
        if backup.failedCount > 0 { return .orange }
        if backup.lastRunAt != nil { return Theme.mint }
        return Theme.accent
    }

    private var serverName: String {
        app.servers.server(id: backup.serverID)?.name ?? app.backupServer?.name ?? "No server"
    }

    private var subtitle: String {
        if backup.totalCount > 0, backup.isRunning {
            return "\(backup.completedCount + backup.failedCount) of \(backup.totalCount) · \(serverName)"
        }
        if let summary = backup.lastSummary, !backup.isRunning {
            return "\(summary) · \(serverName)"
        }
        return serverName
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    if !backup.failedItems.isEmpty { failuresCard }
                    if !queueItems.isEmpty { queueCard }
                    backgroundCard
                    if !backup.isRunning { actionsCard }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(Theme.pageBackground)
            .navigationTitle("Upload Activity")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .accessibilityIdentifier("backup.activity")
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .frame(minWidth: 360, minHeight: 500)
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .symbolEffect(.pulse, options: .repeating, isActive: backup.isRunning)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .contentTransition(.numericText())
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if backup.isRunning {
                    Button("Stop") { backup.cancel() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.glass)
                        .tint(.red)
                        .accessibilityIdentifier("backup.stop")
                }
            }

            if backup.isRunning {
                if backup.totalCount > 0 {
                    ProgressBar(value: backup.progress)
                    HStack {
                        Text("\(backup.completedCount) uploaded")
                        if backup.failedCount > 0 { Text("· \(backup.failedCount) failed") }
                        Spacer()
                        Text("\(Int(backup.progress * 100))%")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                if let item = backup.currentItem {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                        Text(item.filename)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if item.progress > 0 {
                            Text("\(Int(item.progress * 100))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if backup.transferredBytes > 0 || backup.isRunning {
                HStack(spacing: 16) {
                    stat(
                        "\(ByteCountFormatter.string(fromByteCount: backup.transferredBytes, countStyle: .file))",
                        label: "Transferred"
                    )
                    if backup.averageBytesPerSecond > 0 {
                        stat(
                            String(format: "%.1f MB/s", backup.averageBytesPerSecond / 1_000_000),
                            label: "Speed"
                        )
                    }
                    if app.photosPendingBackup > 0 {
                        stat("\(app.photosPendingBackup)", label: "Waiting")
                    }
                    if backup.reclaimedCount > 0 {
                        stat("\(backup.reclaimedCount)", label: "Recovered")
                    }
                }
                .padding(.top, 2)
            }

            if let error = backup.lastError, !backup.isRunning {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .contentCard()
    }

    private func stat(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Failures and queue

    private var failuresCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs attention", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(backup.failedItems.prefix(20)) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let error = item.error {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if backup.failedItems.count > 20 {
                Text("and \(backup.failedItems.count - 20) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Retry with Back Up Now; already-uploaded photos are skipped.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .contentCard()
    }

    private var queueItems: [BackupEngine.Item] {
        let pending = backup.items.filter { $0.phase != .done }
        let done = backup.items.filter { $0.phase == .done }.suffix(3)
        return pending + done
    }

    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(backup.isRunning ? "Queue" : "Last run", systemImage: "list.bullet")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(backup.items.count) item\(backup.items.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(queueItems.prefix(60)) { item in
                itemRow(item)
                if item.id != queueItems.prefix(60).last?.id {
                    Divider().opacity(0.3)
                }
            }
            if queueItems.count > 60 {
                Text("and \(queueItems.count - 60) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if backup.queuedCount > 0 && backup.isRunning {
                Text("\(backup.queuedCount) waiting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .contentCard()
    }

    private func itemRow(_ item: BackupEngine.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: item.phase))
                .font(.caption)
                .foregroundStyle(color(for: item.phase))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .font(.caption)
                    .lineLimit(1)
                if item.phase == .uploading {
                    ProgressBar(value: max(0.02, item.progress), tint: Theme.accent)
                        .frame(height: 3)
                } else {
                    Text(label(for: item.phase))
                        .font(.caption2)
                        .foregroundStyle(item.phase == .failed ? .orange : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if item.phase == .uploading {
                Text("\(Int(item.progress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func symbol(for phase: BackupEngine.Phase) -> String {
        switch phase {
        case .queued: return "clock"
        case .preparing: return "doc"
        case .analyzing: return "sparkles"
        case .uploading: return "arrow.up.circle.fill"
        case .metadata: return "text.badge.checkmark"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func color(for phase: BackupEngine.Phase) -> Color {
        switch phase {
        case .done: return Theme.mint
        case .failed: return .orange
        case .uploading: return Theme.accent
        default: return .secondary
        }
    }

    private func label(for phase: BackupEngine.Phase) -> String {
        switch phase {
        case .queued: return "Queued"
        case .preparing: return "Preparing"
        case .analyzing: return "Reading metadata"
        case .uploading: return "Uploading"
        case .metadata: return "Writing details"
        case .done: return "Uploaded"
        case .failed: return "Failed"
        }
    }

    // MARK: Background

    private var backgroundCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Background uploads", systemImage: "moon.zzz")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                Image(systemName: app.settings.autoBackupEnabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(app.settings.autoBackupEnabled ? Theme.mint : .secondary)
                Text(app.settings.autoBackupEnabled ? "Automatic backup is on." : "Automatic backup is off.")
                    .font(.caption)
                Spacer()
                if let requested = app.backgroundBackupRequestedAt {
                    Text("next check \(requested.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            Text("iOS runs automatic uploads while Backu is in the background, on Wi-Fi or mobile data as configured. Force-quitting the app stops background work until you open it again.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("Automatic uploads run while Backu is open. Uploads already in flight keep running in the background.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
            if app.photosPendingBackup > 0 {
                Text("\(app.photosPendingBackup) photo\(app.photosPendingBackup == 1 ? "" : "s") waiting for the next window.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let last = backup.lastRunAt {
                Text("Last run \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .contentCard()
    }

    // MARK: Actions

    private var actionsCard: some View {
        HStack(spacing: 10) {
            Button {
                app.startBackup()
            } label: {
                Label(backup.failedCount > 0 ? "Retry Failed" : "Back Up Now", systemImage: "arrow.up.to.line.compact")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(app.servers.servers.isEmpty)
            .accessibilityIdentifier("backup.now")

            if !app.settings.autoBackupEnabled {
                Button {
                    app.settings.autoBackupEnabled = true
                    app.scheduleBackgroundBackup()
                } label: {
                    Label("Enable Auto", systemImage: "clock.arrow.circlepath")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(14)
        .contentCard()
    }
}
