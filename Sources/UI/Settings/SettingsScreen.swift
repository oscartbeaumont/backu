import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var showAddServer = false
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ScreenTitle("Settings", subtitle: "Backup, library and privacy")

                backupCard()
                libraryCard()
                peopleCard()
                storageCard()
                supportCard
                aboutCard
            }
            .padding(.bottom, 90)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground)
        .topScrollScrim()
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .sheet(isPresented: $showAddServer) {
            AddServerFlow().environment(app)
        }
        .confirmationDialog("Reset Backu?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Library and Servers", role: .destructive) {
                app.settings.hasCompletedOnboarding = false
                app.resetLibrary()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the local index, face groups and server credentials. Photos in your buckets are untouched.")
        }
    }

    // MARK: Backup

    @ViewBuilder
    private func backupCard() -> some View {
        @Bindable var settings = app.settings
        SettingsCard(title: "Backup", symbol: "arrow.up.circle") {
            SettingsToggle(
                title: "Automatic backup",
                subtitle: "Upload new photos whenever Backu runs.",
                symbol: "wand.and.stars",
                isOn: $settings.autoBackupEnabled
            )
            Divider().opacity(0.4)
            HStack(spacing: 12) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                Text("Destination")
                    .font(.subheadline)
                Spacer()
                Menu {
                    ForEach(app.servers.servers) { server in
                        Button(server.name) {
                            app.settings.backupServerID = server.id
                        }
                    }
                    Divider()
                    Button("Add a server…") { showAddServer = true }
                } label: {
                    Text(app.backupServer?.name ?? "None")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Folder in bucket")
                        .font(.subheadline)
                    Text(app.backupServer.map { "\($0.bucket)/\($0.folderDescription)" } ?? "Not configured")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            Divider().opacity(0.4)
            SettingsToggle(
                title: "Use mobile data",
                subtitle: "Back up over cellular as well as Wi-Fi.",
                symbol: "antenna.radiowaves.left.and.right",
                isOn: $settings.backupOnCellular
            )
            SettingsToggle(
                title: "Include videos",
                subtitle: "Videos can be much larger than photos.",
                symbol: "video",
                isOn: $settings.includeVideos
            )
            SettingsToggle(
                title: "Include screenshots",
                subtitle: "Screenshots are skipped by default.",
                symbol: "rectangle.dashed",
                isOn: $settings.includeScreenshots
            )
            Divider().opacity(0.4)
            backupActions
        }
    }

    @ViewBuilder
    private var backupActions: some View {
        if app.backup.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(app.backup.status)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(app.backup.completedCount)/\(app.backup.totalCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressBar(value: app.backup.progress)
                Button("Stop Backup") { app.backup.cancel() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.glass)
                    .tint(.red)
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    app.startBackup()
                } label: {
                    Label("Back Up Now", systemImage: "arrow.up.to.line.compact")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(app.servers.servers.isEmpty)

                if let last = app.backup.lastRunAt {
                    Text(last.relativeShort)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = app.backup.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Library

    @ViewBuilder
    private func libraryCard() -> some View {
        @Bindable var settings = app.settings
        SettingsCard(title: "Library", symbol: "photo.on.rectangle") {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Photo access")
                        .font(.subheadline)
                    Text(app.photoAccessDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(app.hasPhotoAccess ? "Refresh" : "Allow") {
                    Task { await app.requestPhotoAccess() }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scan library")
                        .font(.subheadline)
                    Text(app.isScanning ? "Scanning…" : app.lastScanMessage ?? "\(app.catalog.photos.count) items indexed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan") {
                    Task { await app.scanLibrary(force: true) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(app.isScanning)
            }

            Divider().opacity(0.4)
            SettingsToggle(
                title: "Show photos from servers",
                subtitle: "Browse photos backed up from your other devices.",
                symbol: "icloud",
                isOn: $settings.showRemoteOnlyPhotos
            )
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26)
                Text("Grid size")
                    .font(.subheadline)
                Spacer()
                Picker("Grid size", selection: $settings.gridColumns) {
                    Text("Large").tag(2)
                    Text("Medium").tag(3)
                    Text("Small").tag(4)
                    Text("Tiny").tag(6)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Theme.accent)
            }
        }
    }

    // MARK: People

    @ViewBuilder
    private func peopleCard() -> some View {
        @Bindable var settings = app.settings
        SettingsCard(title: "People & Pets", symbol: "person.2") {
            SettingsToggle(
                title: "Face recognition",
                subtitle: "Finds and groups faces entirely on-device.",
                symbol: "face.smiling",
                isOn: $settings.faceRecognitionEnabled
            )
            Divider().opacity(0.4)
            if app.analyzer.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    Text(app.analyzer.status)
                        .font(.caption)
                        .lineLimit(1)
                    ProgressBar(value: app.analyzer.progress)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Index faces")
                            .font(.subheadline)
                        Text(app.analyzer.lastRunAt.map { "Last run \($0.relativeShort)" } ?? "Not run yet")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Index") {
                        Task {
                            await app.analyzer.analyzeMissing(
                                catalog: app.catalog,
                                settings: app.settings,
                                faceStore: app.faceStore,
                                places: app.places
                            )
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            Text("Face vectors stay on this device. Names and tags sync to your bucket inside each photo's sidecar.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Storage

    private func storageCard() -> some View {
        SettingsCard(title: "Storage", symbol: "externaldrive") {
            ForEach(app.servers.servers) { server in
                HStack(spacing: 12) {
                    ProviderBadge(provider: server.provider, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.name)
                            .font(.subheadline)
                        Text(server.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if app.settings.backupServerID == server.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            Button {
                showAddServer = true
            } label: {
                Label("Add a server", systemImage: "plus.circle")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)

            Divider().opacity(0.4)
            Button(role: .destructive) {
                confirmReset = true
            } label: {
                Label("Reset library index", systemImage: "trash")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Support

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.pink)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.pink.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Support Backu")
                        .font(.subheadline.weight(.semibold))
                    Text("Free, open source, no subscription.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("MIT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
            }

            Text("If Backu earns a place in your workflow, sponsoring keeps the App Store fee paid and the project moving. Every contribution goes straight to development.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    openURL(ProjectLinks.sponsors)
                } label: {
                    Label("Sponsor on GitHub", systemImage: "heart.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .accessibilityLabel("Sponsor Backu on GitHub")

                Button {
                    openURL(ProjectLinks.repository)
                } label: {
                    Label("Star", systemImage: "star")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Star Backu on GitHub")
            }

            HStack(spacing: 6) {
                Button("View source") {
                    openURL(ProjectLinks.repository)
                }
                Text("·")
                Button("Report an issue") {
                    openURL(ProjectLinks.issues)
                }
                Spacer()
                Text("No ads, no tracking")
            }
            .font(.caption2)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .contentCard()
        .padding(.horizontal, 16)
    }

    // MARK: About

    private var aboutCard: some View {
        VStack(spacing: 14) {
            BrandMarkView(size: 66)
            VStack(spacing: 3) {
                Text("Backu")
                    .font(.headline)
                Text("Version 1.0 · MIT licensed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Your photos live in your own bucket. Backu stores the original file, a readable JSON sidecar with tags and people, and a small search index beside your photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Label("No account", systemImage: "person.crop.circle.badge.xmark")
                Label("No tracking", systemImage: "hand.raised")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .contentCard()
        .padding(.horizontal, 16)
    }
}

struct SettingsCard<Content: View>: View {
    var title: String
    var symbol: String
    var content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
        .padding(.horizontal, 16)
    }
}

struct SettingsToggle: View {
    var title: String
    var subtitle: String
    var symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.accent)
        }
    }
}
