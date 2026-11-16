import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var app = app

        Group {
            if app.showOnboarding {
                WelcomeScreen()
            } else {
                #if os(macOS)
                splitRoot
                #else
                if horizontalSizeClass == .compact {
                    tabRoot
                } else {
                    splitRoot
                }
                #endif
            }
        }
        .background(Theme.pageBackground)
        .animation(.backuSnappy, value: app.showOnboarding)
        #if os(macOS)
        .sheet(item: $app.viewer) { presentation in
            ViewerScreen(presentation: presentation)
                .environment(app)
                .frame(minWidth: 940, minHeight: 720)
        }
        #else
        .fullScreenCover(item: $app.viewer) { presentation in
            ViewerScreen(presentation: presentation)
                .environment(app)
        }
        #endif
        .alert("Something went wrong", isPresented: Binding(
            get: { app.errorMessage != nil },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { app.errorMessage = nil }
        } message: {
            Text(app.errorMessage ?? "")
        }
    }

    private var tabRoot: some View {
        @Bindable var app = app
        return TabView(selection: $app.activeTab) {
            Tab(AppTab.library.title, systemImage: AppTab.library.symbol, value: .library) {
                NavigationStack { LibraryScreen() }
            }
            Tab(AppTab.search.title, systemImage: AppTab.search.symbol, value: .search) {
                NavigationStack { SearchScreen() }
            }
            Tab(AppTab.people.title, systemImage: AppTab.people.symbol, value: .people) {
                NavigationStack { PeopleScreen() }
            }
            Tab(AppTab.settings.title, systemImage: AppTab.settings.symbol, value: .settings) {
                NavigationStack { SettingsScreen() }
            }
        }
        .tint(Theme.accent)
    }

    private var splitRoot: some View {
        @Bindable var app = app
        return NavigationSplitView {
            SidebarView(selection: $app.activeTab)
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 280)
        } detail: {
            NavigationStack {
                switch app.activeTab {
                case .library: LibraryScreen()
                case .search: SearchScreen()
                case .people: PeopleScreen()
                case .settings: SettingsScreen()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
    }
}

struct SidebarView: View {
    @Binding var selection: AppTab
    @Environment(AppModel.self) private var app

    private var visiblePhotoCount: Int {
        let photos = app.catalog.photos
        return app.settings.showRemoteOnlyPhotos ? photos.count : photos.filter(\.isLocal).count
    }

    var body: some View {
        List {
            Section {
                ForEach(AppTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        Label {
                            HStack {
                                Text(tab.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if tab == .library, visiblePhotoCount > 0 {
                                    Text("\(visiblePhotoCount)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: tab.symbol)
                                .foregroundStyle(selection == tab ? Theme.accent : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selection == tab
                            ? RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.12))
                            : nil
                    )
                }
            } header: {
                HStack(spacing: 10) {
                    BrandMarkView(size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Backu")
                            .font(.headline)
                            .lineLimit(1)
                        Text("Private photo backup")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 8)
            }

            Section {
                BackupSidebarStatus()
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            if let server = app.backupServer {
                HStack(spacing: 8) {
                    ProviderBadge(provider: server.provider, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(server.folderDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(12)
                .glassSurface(16)
                .padding(10)
            }
        }
    }
}

struct BackupSidebarStatus: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.backup.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Text("Backing up")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(app.backup.completedCount)/\(app.backup.totalCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressBar(value: app.backup.progress)
            }
            .padding(.vertical, 4)
        } else {
            Button {
                app.activeTab = .settings
            } label: {
                Label("Automatic backup \(app.settings.autoBackupEnabled ? "on" : "off")", systemImage: app.settings.autoBackupEnabled ? "checkmark.icloud" : "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}
