import SwiftUI

struct ServersScreen: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false
    @State private var selectedServer: ServerConfig?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if app.servers.servers.isEmpty {
                    EmptyStateView(
                        symbol: "externaldrive.badge.plus",
                        title: "Bring your own storage",
                        message: "Connect Amazon S3, Backblaze B2, Cloudflare R2 or any S3-compatible server. Your photos stay in a bucket you control.",
                        actionTitle: "Add a Server"
                    ) {
                        showAdd = true
                    }
                    .padding(.top, 24)
                } else {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                    overview
                    ForEach(app.servers.servers) { server in
                        ServerCard(server: server) {
                            selectedServer = server
                        }
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground)
        .navigationTitle("Servers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAdd = true
                } label: {
                    Label("Add server", systemImage: "plus")
                }
                .accessibilityIdentifier("servers.add")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddServerFlow()
                .environment(app)
        }
        .navigationDestination(item: $selectedServer) { server in
            ServerDetailScreen(serverID: server.id)
        }
    }

    private var subtitle: String {
        if app.servers.servers.isEmpty { return "No storage connected" }
        let backedUp = app.catalog.photos.filter(\.isBackedUp).count
        return "\(app.servers.servers.count) server\(app.servers.servers.count == 1 ? "" : "s") · \(backedUp) photos stored"
    }

    private var overview: some View {
        let stats = app.catalog.stats()
        return HStack(spacing: 10) {
            StatTile(value: "\(stats.backedUp)", label: "Backed up", symbol: "checkmark.icloud", tint: Theme.mint)
            StatTile(value: "\(stats.localPhotos - stats.backedUp > 0 ? stats.localPhotos - stats.backedUp : 0)", label: "On device only", symbol: "iphone", tint: .orange)
            StatTile(value: "\(app.servers.servers.count)", label: "Servers", symbol: "externaldrive", tint: Theme.accent)
        }
        .padding(.horizontal, 16)
    }
}

struct ServerCard: View {
    let server: ServerConfig
    var onOpen: () -> Void
    @Environment(AppModel.self) private var app

    private var photoCount: Int {
        app.catalog.photos.filter { $0.copy(on: server.id) != nil }.count
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProviderBadge(provider: server.provider)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(server.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    Label(server.folderDescription, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Label("\(photoCount) photos", systemImage: "photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(server.lastVerifiedAt == nil ? Color.orange : Theme.mint)
                        .frame(width: 6, height: 6)
                    Text(server.lastVerifiedAt == nil
                         ? "Not verified yet"
                         : "Verified \(server.lastVerifiedAt!.relativeShort)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if app.isBackupDestination(server) {
                        Spacer()
                        Label(app.backupDestinationCount > 1 ? "Backup destination" : "Auto-backup destination",
                              systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .contentCard()
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .contextMenu {
            Button {
                onOpen()
            } label: {
                Label("Open", systemImage: "arrow.up.right")
            }
            Button {
                app.toggleBackupDestination(server)
            } label: {
                Label(
                    app.isBackupDestination(server)
                        ? "Remove from automatic backup"
                        : "Add to automatic backup",
                    systemImage: app.isBackupDestination(server) ? "minus.circle" : "plus.circle"
                )
            }
        }
        .padding(.horizontal, 16)
    }

}

struct ServerDetailScreen: View {
    let serverID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var verification: S3Client.Verification?
    @State private var verifyError: String?
    @State private var confirmRemove = false

    private var server: ServerConfig? { app.servers.server(id: serverID) }

    var body: some View {
        ScrollView {
            if let server {
                VStack(spacing: 14) {
                    header(server)
                    connectionCard(server)
                    usageCard(server)
                    actionsCard(server)
                    dangerCard(server)
                }
                .padding(16)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground)
        .navigationTitle(server?.name ?? "Server")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Remove \(server?.name ?? "server")?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Server", role: .destructive) {
                if let server { app.removeServer(server) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your photos stay in the bucket. Backu forgets the credentials and stops backing up here.")
        }
    }

    private func header(_ server: ServerConfig) -> some View {
        HStack(spacing: 14) {
            ProviderBadge(provider: server.provider, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.title2.weight(.bold))
                Text(server.provider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface()
    }

    private func connectionCard(_ server: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connection", systemImage: "network")
                .font(.subheadline.weight(.semibold))
            infoRow("Bucket", server.bucket)
            infoRow("Endpoint", server.resolvedEndpoint?.absoluteString ?? "Not set")
            infoRow("Region", server.region)
            infoRow("Folder", server.folderDescription)
            infoRow("Access key", mask(server.accessKeyID))
            infoRow("Addressing", server.pathStyle ? "Path style" : "Virtual host")

            if let verification {
                VStack(alignment: .leading, spacing: 6) {
                    checkRow("List folder", verification.canList)
                    checkRow("Write object", verification.canWrite)
                    checkRow("Read object", verification.canRead)
                    Text("\(Int(verification.latency * 1000)) ms")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
            }
            if let verifyError {
                Text(verifyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await check(server) }
            } label: {
                HStack(spacing: 8) {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.shield")
                    }
                    Text(checking ? "Testing…" : "Test Connection")
                        .font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .buttonStyle(.glass)
            .disabled(checking)
        }
        .padding(16)
        .glassSurface()
    }

    private func usageCard(_ server: ServerConfig) -> some View {
        let photos = app.catalog.photos.filter { $0.copy(on: server.id) != nil }
        let bytes = photos.compactMap { $0.copy(on: server.id)?.byteCount }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 12) {
            Label("Library on this server", systemImage: "photo.stack")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                StatTile(value: "\(photos.count)", label: "Photos", symbol: "photo", tint: Theme.accent)
                StatTile(value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), label: "Uploaded", symbol: "arrow.up.circle", tint: Theme.mint)
            }
            if let last = app.backup.lastRunAt,
               app.backup.destinationStatuses.contains(where: { $0.id == server.id }) {
                Text("Last backup \(last.relativeShort)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassSurface()
    }

    private func actionsCard(_ server: ServerConfig) -> some View {
        VStack(spacing: 10) {
            Button {
                app.toggleBackupDestination(server)
            } label: {
                HStack {
                    Label(
                        app.isBackupDestination(server)
                            ? "Included in automatic backup"
                            : "Use for automatic backup",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    Spacer()
                    if app.isBackupDestination(server) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .font(.footnote.weight(.medium))
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
            }
            .buttonStyle(.glass)

            Button {
                app.addBackupDestination(server)
                app.startBackup()
                dismiss()
            } label: {
                Label("Back Up Now", systemImage: "arrow.up.to.line.compact")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
        }
        .padding(14)
        .glassSurface()
    }

    private func dangerCard(_ server: ServerConfig) -> some View {
        Button(role: .destructive) {
            confirmRemove = true
        } label: {
            Label("Remove Server", systemImage: "trash")
                .font(.footnote.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.glass)
        .tint(.red)
        .padding(14)
        .glassSurface()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func checkRow(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Theme.mint : .red)
            Text(label)
                .font(.caption)
            Spacer()
        }
    }

    private func mask(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "•", count: max(value.count, 4)) }
        return String(value.prefix(4)) + String(repeating: "•", count: 6) + String(value.suffix(4))
    }

    private func check(_ server: ServerConfig) async {
        checking = true
        verification = nil
        verifyError = nil
        let result = await app.verify(server: server)
        verification = result
        if result == nil { verifyError = app.errorMessage }
        app.errorMessage = nil
        checking = false
    }
}
