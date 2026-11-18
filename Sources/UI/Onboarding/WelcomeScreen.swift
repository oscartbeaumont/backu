import Photos
import SwiftUI

struct WelcomeScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAdd = false
    @State private var stage: Stage?
    @State private var appearStep = 0
    @State private var didChooseStage = false

    private enum Stage {
        case photoAccess
        case intro
    }

    var body: some View {
        Group {
            switch stage {
            case .photoAccess:
                PhotoAccessOnboardingView {
                    withRespectingReduceMotion(.backuSnappy, when: reduceMotion) { stage = .intro }
                }
                .transition(.opacity)
            case .intro:
                intro
                    .transition(.opacity)
            case nil:
                // One frame while the launch state is read; avoids flashing the
                // welcome before the permission explanation on a first run.
                Color.clear
            }
        }
        .background {
            ZStack {
                Theme.pageBackground
                Circle()
                    .fill(Theme.accent.opacity(0.16))
                    .frame(width: 520, height: 520)
                    .blur(radius: 90)
                    .offset(x: -160, y: -300)
                Circle()
                    .fill(Theme.mint.opacity(0.12))
                    .frame(width: 420, height: 420)
                    .blur(radius: 80)
                    .offset(x: 180, y: 220)
            }
            .ignoresSafeArea()
        }
        .task {
            // The system prompt is only shown after this explanation. If iOS
            // has already been asked, go straight to the welcome instead.
            guard !didChooseStage else { return }
            didChooseStage = true
            stage = app.authorization == .notDetermined ? .photoAccess : .intro
        }
        .sheet(isPresented: $showAdd) {
            AddServerFlow().environment(app)
        }
    }

    private var intro: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 30)

                BrandMarkView(size: 104)
                    .cardShadow()
                    .scaleEffect(appearStep >= 1 ? 1 : 0.8)
                    .opacity(appearStep >= 1 ? 1 : 0)

                VStack(spacing: 10) {
                    Text("Your photos.\nYour bucket.")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .opacity(appearStep >= 2 ? 1 : 0)
                        .offset(y: appearStep >= 2 ? 0 : 12)

                    Text("Back up, browse and search your library on storage you already own. Nothing sits between you and your photos.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .opacity(appearStep >= 2 ? 1 : 0)
                        .offset(y: appearStep >= 2 ? 0 : 12)
                }
                .padding(.top, 26)

                VStack(spacing: 12) {
                    WelcomeFeature(symbol: "externaldrive.connected.to.line.below", title: "Any S3 bucket", message: "AWS, Backblaze, Cloudflare R2 or a server you run yourself.")
                    WelcomeFeature(symbol: "person.2.crop.square.stack", title: "People and pets", message: "Faces are found and grouped on-device. You give them names.")
                    WelcomeFeature(symbol: "magnifyingglass", title: "Instant search", message: "A local index means results appear before you finish typing.")
                    WelcomeFeature(symbol: "arrow.up.circle", title: "Automatic backup", message: "New photos upload in the background, on Wi-Fi only if you prefer.")
                }
                .padding(.top, 30)
                .opacity(appearStep >= 3 ? 1 : 0)
                .offset(y: appearStep >= 3 ? 0 : 14)

                VStack(spacing: 10) {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Storage", systemImage: "plus")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: 420)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)

                    Button("Look around first") {
                        app.settings.hasCompletedOnboarding = true
                        withRespectingReduceMotion(.backuSnappy, when: reduceMotion) { app.showOnboarding = false }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 34)
                .padding(.bottom, 30)
                .opacity(appearStep >= 4 ? 1 : 0)

                HStack(spacing: 16) {
                    Label("No account", systemImage: "person.crop.circle.badge.xmark")
                    Label("On-device AI", systemImage: "cpu")
                    Label("Keys in Keychain", systemImage: "key.horizontal")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 26)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
        .task {
            for index in 1...4 {
                try? await Task.sleep(for: .milliseconds(90))
                withRespectingReduceMotion(.spring(duration: 0.55, bounce: 0.12), when: reduceMotion) {
                    appearStep = index
                }
            }
        }
    }
}

/// The pre-permission page. iOS only shows its own prompt once, so it is worth
/// explaining what Backu needs the library for before asking. The same page
/// handles limited and refused states, since those need different routes: a
/// limited grant can be widened with the system picker, while a refusal can
/// only be undone in Settings.
struct PhotoAccessOnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false
    @State private var didAppear = false
    var onContinue: () -> Void

    private var status: PHAuthorizationStatus { app.authorization }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 40)

                BrandMarkView(size: 92)
                    .cardShadow()
                    .scaleEffect(didAppear ? 1 : 0.82)
                    .opacity(didAppear ? 1 : 0)

                VStack(spacing: 10) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .opacity(didAppear ? 1 : 0)
                        .offset(y: didAppear ? 0 : 12)

                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 430)
                        .opacity(didAppear ? 1 : 0)
                        .offset(y: didAppear ? 0 : 12)
                }
                .padding(.top, 26)

                if status == .notDetermined {
                    VStack(spacing: 12) {
                        WelcomeFeature(symbol: "photo.on.rectangle.angled", title: "Browse everything", message: "Your library appears here, with the same grid and viewer as Photos.")
                        WelcomeFeature(symbol: "arrow.up.circle", title: "Back up originals", message: "Uploads use the untouched file, with its metadata and checksum.")
                        WelcomeFeature(symbol: "magnifyingglass", title: "Search on device", message: "Names, places, tags and faces are indexed locally. Nothing is uploaded.")
                    }
                    .padding(.top, 26)
                    .opacity(didAppear ? 1 : 0)
                    .offset(y: didAppear ? 0 : 14)
                } else {
                    accessStateCard
                        .padding(.top, 26)
                        .opacity(didAppear ? 1 : 0)
                }

                privacyNote
                    .padding(.top, 22)
                    .opacity(didAppear ? 1 : 0)

                VStack(spacing: 10) {
                    primaryAction
                    Button(secondaryTitle) { onContinue() }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 30)
                .padding(.bottom, 26)
                .opacity(didAppear ? 1 : 0)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
        .task {
            withRespectingReduceMotion(.spring(duration: 0.55, bounce: 0.12), when: reduceMotion) {
                didAppear = true
            }
        }
        .onChange(of: app.authorization) { _, newValue in
            // Choosing full access in the system prompt (or coming back from
            // Settings) moves the flow on without an extra tap.
            if newValue == .authorized { onContinue() }
        }
    }

    private var title: String {
        switch status {
        case .notDetermined: return "A private view of\nyour photo library."
        case .limited: return "You've shared\nsome photos."
        case .denied, .restricted: return "Backu can't see\nyour photos."
        case .authorized: return "You're all set."
        @unknown default: return "Photo access"
        }
    }

    private var message: String {
        switch status {
        case .notDetermined:
            return "Backu needs to read your photo library to show your photos, back up the original files and build an on-device search index. You choose what it can see."
        case .limited:
            return "Backu can only see the photos you selected. You can add more at any time — the rest of your library stays private."
        case .denied:
            return "Access was turned off. iOS will not ask again, so allow photo access for Backu in Settings to show and back up your library."
        case .restricted:
            return "Photo access is restricted on this device. Ask the person who manages it to allow Backu's access."
        case .authorized:
            return "Backu can read your photo library and back up the original files."
        @unknown default:
            return "Manage photo access to continue."
        }
    }

    private var accessStateCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .limited ? "photo.badge.checkmark" : "lock.shield")
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(status == .limited ? Theme.mint : .orange)
                .frame(width: 40, height: 40)
                .background(
                    Circle().fill((status == .limited ? Theme.mint : .orange).opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(status.photoAccessTitle)
                    .font(.subheadline.weight(.semibold))
                Text(status.photoAccessDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassSurface(18)
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 1)
                Text("Faces, places and search are processed on this device. Photos only leave it once you connect a bucket and backup runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Read the privacy policy") {
                openURL(ProjectLinks.privacyPolicy)
            }
            .font(.caption2.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .padding(.leading, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .contentCard(radius: 16)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch status {
        case .notDetermined:
            Button {
                Task { await askForAccess() }
            } label: {
                actionLabel(
                    title: isRequesting ? "Asking…" : "Allow Photo Access",
                    symbol: "photo.on.rectangle"
                )
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(isRequesting)

        case .limited:
            #if os(iOS)
            Button {
                Task { await app.requestMorePhotos() }
            } label: {
                actionLabel(title: "Select More Photos", symbol: "photo.badge.plus")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            #else
            EmptyView()
            #endif

        case .denied:
            Button {
                PhotoAccess.openSystemSettings()
            } label: {
                actionLabel(title: "Open Settings", symbol: "gearshape")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .controlSize(.large)

        case .restricted, .authorized:
            EmptyView()

        @unknown default:
            EmptyView()
        }
    }

    private var secondaryTitle: String {
        switch status {
        case .limited: return "Continue with selected photos"
        case .denied, .restricted: return "Continue without photos"
        default: return "Not Now"
        }
    }

    private func actionLabel(title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            if isRequesting {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: symbol)
            }
            Text(title)
        }
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
    }

    private func askForAccess() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        let result = await app.requestPhotoAccess()
        if result == .authorized {
            onContinue()
        }
    }
}

struct WelcomeFeature: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(Theme.accent)
                .frame(width: 42, height: 42)
                .glassSurface(14, tint: Theme.accent.opacity(0.10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }
}
