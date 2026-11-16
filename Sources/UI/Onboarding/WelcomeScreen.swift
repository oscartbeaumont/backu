import SwiftUI

struct WelcomeScreen: View {
    @Environment(AppModel.self) private var app
    @State private var showAdd = false
    @State private var step = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 30)

                BrandMarkView(size: 104)
                    .cardShadow()
                    .scaleEffect(step >= 1 ? 1 : 0.8)
                    .opacity(step >= 1 ? 1 : 0)

                VStack(spacing: 10) {
                    Text("Your photos.\nYour bucket.")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .opacity(step >= 2 ? 1 : 0)
                        .offset(y: step >= 2 ? 0 : 12)

                    Text("Back up, browse and search your library on storage you already own. Nothing sits between you and your photos.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .opacity(step >= 2 ? 1 : 0)
                        .offset(y: step >= 2 ? 0 : 12)
                }
                .padding(.top, 26)

                VStack(spacing: 12) {
                    WelcomeFeature(symbol: "externaldrive.connected.to.line.below", title: "Any S3 bucket", message: "AWS, Backblaze, Cloudflare R2 or a server you run yourself.")
                    WelcomeFeature(symbol: "person.2.crop.square.stack", title: "People and pets", message: "Faces are found and grouped on-device. You give them names.")
                    WelcomeFeature(symbol: "magnifyingglass", title: "Instant search", message: "A local index means results appear before you finish typing.")
                    WelcomeFeature(symbol: "arrow.up.circle", title: "Automatic backup", message: "New photos upload in the background, on Wi-Fi only if you prefer.")
                }
                .padding(.top, 30)
                .opacity(step >= 3 ? 1 : 0)
                .offset(y: step >= 3 ? 0 : 14)

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
                        withAnimation(.backuSnappy) { app.showOnboarding = false }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 34)
                .padding(.bottom, 30)
                .opacity(step >= 4 ? 1 : 0)

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
            for index in 1...4 {
                try? await Task.sleep(for: .milliseconds(90))
                withAnimation(.spring(duration: 0.55, bounce: 0.12)) { step = index }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddServerFlow().environment(app)
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
                .font(.system(size: 17, weight: .semibold))
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
