import SwiftUI

struct AddServerFlow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var provider: StorageProvider?
    @State private var draft = ServerDraft()
    @State private var showAdvanced = false
    @State private var testing = false
    @State private var verification: S3Client.Verification?
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Group {
                if provider == nil {
                    providerPicker
                } else {
                    form
                }
            }
            .background(Theme.pageBackground)
            .navigationTitle(provider == nil ? "Add Storage" : "Connect \(provider?.displayName ?? "")")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if provider != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await save() }
                        } label: {
                            if saving {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Save").fontWeight(.semibold)
                            }
                        }
                        .disabled(!canSave || saving || testing)
                    }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 660)
        #endif
    }

    // MARK: Provider picker

    private var providerPicker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Where should your photos live?")
                    .font(.title2.weight(.bold))
                    .padding(.top, 8)
                Text("Backu talks to the S3 API, so any compatible bucket works. You can add more than one server.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach([StorageProvider.aws, .backblaze, .cloudflareR2, .custom]) { option in
                        ProviderCardView(provider: option) {
                            choose(option)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "key.horizontal")
                        .foregroundStyle(Theme.accent)
                    Text("S3 buckets are unlocked with an access key, not a password. Backu opens the exact page where you create one, fills in every endpoint and region for you, and keeps the key in the Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .glassSurface(16)

                Text("Credentials never pass through a Backu server — the app talks straight to your bucket.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private func choose(_ option: StorageProvider) {
        provider = option
        draft.provider = option
        draft.name = option.displayName
        draft.region = option.defaultRegion
        draft.pathStyle = option.defaultPathStyle
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let provider {
                    setupCard(provider)
                }
                connectionCard
                credentialsCard
                if let verification {
                    verificationCard(verification)
                }
                if let error {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassSurface(16)
                }
                Button {
                    Task { await test() }
                } label: {
                    HStack(spacing: 8) {
                        if testing {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "bolt.horizontal.circle")
                        }
                        Text(testing ? "Testing…" : "Test Connection")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(!canTest || testing || saving)

                Text("Keys are stored in the \(DeviceInfo.model)'s Keychain and used only to sign requests to this endpoint.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private func setupCard(_ provider: StorageProvider) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProviderBadge(provider: provider, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.headline)
                    Text(blurb(for: provider))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = provider.consoleURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            Divider().opacity(0.4)
            ForEach(Array(provider.setupSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Theme.accent))
                    Text(step)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .glassSurface()
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Bucket", systemImage: "shippingbox")
                .font(.subheadline.weight(.semibold))

            FormField(label: "Name", placeholder: "Home backup", text: $draft.name)
            FormField(label: "Bucket", placeholder: "my-photos", text: $draft.bucket)

            switch draft.provider {
            case .aws:
                Menu {
                    ForEach(ServerDraft.awsRegions, id: \.self) { region in
                        Button(region) { draft.region = region }
                    }
                } label: {
                    fieldShell(label: "Region", value: draft.region.isEmpty ? "Choose a region" : draft.region, isPlaceholder: draft.region.isEmpty)
                }
            case .backblaze:
                FormField(label: "Region", placeholder: "us-west-004", text: $draft.region)
            case .cloudflareR2:
                FormField(label: "Account ID", placeholder: "023e105f4ece…", text: $draft.accountID)
            case .custom:
                FormField(label: "Region", placeholder: "us-east-1", text: $draft.region)
            }

            if draft.provider == .custom || showAdvanced {
                FormField(label: "Endpoint", placeholder: draft.provider.endpointPlaceholder, text: $draft.endpoint)
            } else if let derived = draft.derivedEndpoint {
                HStack {
                    Text("Endpoint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(derived)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }

            FormField(label: "Prefix", placeholder: "Optional", text: $draft.prefix)
            Text("Optional. Leave empty to store photos at the bucket root; otherwise Backu uses this folder inside the bucket.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 94)

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Path-style addressing", isOn: $draft.pathStyle)
                        .font(.caption)
                    Text("Turn on for MinIO, Synology and most appliances. AWS and B2 use virtual-host style by default.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    FormField(label: "Endpoint", placeholder: draft.provider.endpointPlaceholder, text: $draft.endpoint)
                    FormField(label: "Session token", placeholder: "Optional", text: $draft.sessionToken, isSecure: true)
                }
                .padding(.top, 8)
            } label: {
                Text("Advanced")
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(16)
        .glassSurface()
    }

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Access key", systemImage: "key.horizontal")
                .font(.subheadline.weight(.semibold))
            FormField(label: "Key ID", placeholder: "Access key ID", text: $draft.accessKeyID, monospaced: true)
            FormField(label: "Secret", placeholder: "Secret access key", text: $draft.secret, isSecure: true, monospaced: true)
            Text("Create a key that can list, read and write this one bucket.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassSurface()
    }

    private func verificationCard(_ report: S3Client.Verification) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: report.canWrite && report.canList ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.canWrite && report.canList ? Theme.mint : .orange)
                Text(report.canWrite && report.canList ? "Ready to back up" : "Connected with limits")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(report.latency * 1000)) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            checkRow("List the folder", report.canList)
            checkRow("Write a test object", report.canWrite)
            checkRow("Read it back", report.canRead)
        }
        .padding(16)
        .glassSurface(tint: report.canWrite ? Theme.mint.opacity(0.10) : nil)
    }

    private func checkRow(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(ok ? Theme.mint : .red)
            Text(label)
                .font(.caption)
            Spacer()
        }
    }

    private func fieldShell(label: String, value: String, isPlaceholder: Bool) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.45)))
    }

    private func blurb(for provider: StorageProvider) -> String {
        switch provider {
        case .aws: return "Any region, any bucket. Uses an IAM access key."
        case .backblaze: return "B2 buckets through Backblaze's S3 endpoint."
        case .cloudflareR2: return "No egress fees. Needs the account ID."
        case .custom: return "MinIO, Wasabi, Synology or your own gateway."
        }
    }

    // MARK: Actions

    private var canTest: Bool {
        draft.isComplete
    }

    private var canSave: Bool {
        draft.isComplete
    }

    private func makeConfig() -> ServerConfig {
        ServerConfig(
            name: {
                let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? draft.provider.displayName : trimmed
            }(),
            provider: draft.provider,
            endpoint: draft.effectiveEndpoint,
            region: draft.effectiveRegion,
            bucket: draft.bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKeyID: draft.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
            prefix: draft.normalizedPrefix,
            pathStyle: draft.pathStyle
        )
    }

    private func makeCredentials() -> S3Credentials {
        S3Credentials(
            accessKeyID: draft.accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: draft.secret,
            sessionToken: draft.sessionToken.isEmpty ? nil : draft.sessionToken
        )
    }

    private func test() async {
        testing = true
        error = nil
        verification = nil
        defer { testing = false }
        let config = makeConfig()
        guard let endpoint = config.resolvedEndpoint, endpoint.host != nil else {
            error = "That endpoint is not a valid URL."
            return
        }
        let client = S3Client(connection: config.connection, credentials: makeCredentials())
        do {
            verification = try await client.verify(prefix: config.normalizedPrefix)
            if verification?.canWrite != true {
                error = verification?.message ?? "The key could not write to this bucket."
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        let config = makeConfig()
        let success = await app.addServer(config, credentials: makeCredentials())
        if success {
            app.showOnboarding = false
            app.settings.hasCompletedOnboarding = true
            dismiss()
        } else {
            error = app.errorMessage ?? "Could not connect to that bucket."
            app.errorMessage = nil
        }
    }
}

struct ProviderCardView: View {
    let provider: StorageProvider
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ProviderBadge(provider: provider, size: 38)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                Text(provider.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(blurb)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .padding(14)
            .glassSurface(18, interactive: true)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var blurb: String {
        switch provider {
        case .aws: return "The original. IAM key, any region."
        case .backblaze: return "Cheap storage, native S3 API."
        case .cloudflareR2: return "Zero egress fees, global."
        case .custom: return "MinIO, Wasabi, Synology…"
        }
    }
}

struct FormField: View {
    var label: String
    var placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(monospaced ? .caption.monospaced() : .callout)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(monospaced ? .asciiCapable : .default)
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.45)))
    }
}

struct ServerDraft {
    static let awsRegions = [
        "us-east-1", "us-east-2", "us-west-1", "us-west-2",
        "eu-west-1", "eu-west-2", "eu-central-1", "eu-north-1",
        "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "sa-east-1"
    ]

    var provider: StorageProvider = .custom
    var name = ""
    var bucket = ""
    var region = ""
    var endpoint = ""
    var accountID = ""
    var accessKeyID = ""
    var secret = ""
    var sessionToken = ""
    var prefix = "Backu"
    var pathStyle = false

    /// Empty means the bucket root; surrounding slashes and spaces are noise.
    var normalizedPrefix: String {
        prefix.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
    }

    var derivedEndpoint: String? {
        let override = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            return override.contains("://") ? override : "https://\(override)"
        }
        switch provider {
        case .aws:
            return "https://s3.\(region.isEmpty ? "us-east-1" : region).amazonaws.com"
        case .backblaze:
            guard !region.isEmpty else { return nil }
            return "https://s3.\(region).backblazeb2.com"
        case .cloudflareR2:
            guard !accountID.isEmpty else { return nil }
            return "https://\(accountID.trimmingCharacters(in: .whitespaces)).r2.cloudflarestorage.com"
        case .custom:
            return nil
        }
    }

    var effectiveEndpoint: String {
        derivedEndpoint ?? endpoint
    }

    var effectiveRegion: String {
        switch provider {
        case .aws: return region.isEmpty ? "us-east-1" : region
        case .backblaze: return region
        case .cloudflareR2: return "auto"
        case .custom: return region.isEmpty ? "us-east-1" : region
        }
    }

    var isComplete: Bool {
        !bucket.trimmingCharacters(in: .whitespaces).isEmpty
            && (derivedEndpoint?.isEmpty == false)
            && !accessKeyID.trimmingCharacters(in: .whitespaces).isEmpty
            && !secret.isEmpty
    }
}
