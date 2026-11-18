import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var columnVisibilityBeforeViewer: NavigationSplitViewVisibility?
    @State private var libraryShowsTabs = false
    @Namespace private var viewerNamespace

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
                    compactRoot
                } else {
                    splitRoot
                }
                #endif
            }
        }
        .environment(\.viewerZoomNamespace, viewerNamespace)
        .background(Theme.pageBackground)
        .animation(.backuSnappy, value: app.showOnboarding)
        .onChange(of: app.settings.autoBackupEnabled) { _, _ in app.scheduleBackgroundBackup() }
        .onChange(of: app.settings.backupServerIDs) { _, _ in app.scheduleBackgroundBackup() }
        #if os(macOS)
        .sheet(item: $app.viewer) { presentation in
            ViewerScreen(presentation: presentation)
                .environment(app)
                .frame(minWidth: 940, minHeight: 720)
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
        #if os(iOS)
        .fullScreenCover(isPresented: $app.showSearch, onDismiss: { app.viewer = nil }) {
            searchCover
        }
        #else
        .sheet(isPresented: $app.showSearch, onDismiss: { app.viewer = nil }) {
            searchCover
                .frame(minWidth: 760, minHeight: 640)
        }
        #endif
    }

    private var searchCover: some View {
        @Bindable var app = app
        return NavigationStack {
            SearchScreen()
                .environment(app)
                .environment(\.viewerZoomSourceActive, true)
                .environment(\.viewerZoomNamespace, viewerNamespace)
                #if os(iOS)
                .navigationDestination(item: $app.viewer) { presentation in
                    ViewerScreen(presentation: presentation)
                        .environment(app)
                }
                #endif
        }
    }

    /// The viewer is pushed above the tab bar so it covers the whole screen and
    /// the tab bar needs no visibility juggling on the way back.
    #if os(iOS)
    private var compactRoot: some View {
        @Bindable var app = app
        return NavigationStack {
            tabRoot
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(item: $app.viewer) { presentation in
                    ViewerScreen(presentation: presentation)
                        .environment(app)
                }
        }
    }

    private var tabRoot: some View {
        @Bindable var app = app
        return TabView(selection: $app.activeTab) {
            Tab(AppTab.library.title, systemImage: AppTab.library.symbol, value: .library) {
                NavigationStack { LibraryScreen() }
                    .toolbar(.hidden, for: .tabBar)
                    .environment(\.viewerZoomSourceActive, app.activeTab == .library)
            }
            Tab(AppTab.people.title, systemImage: AppTab.people.symbol, value: .people) {
                NavigationStack { PeopleScreen() }
                    .toolbar(.hidden, for: .tabBar)
                    .environment(\.viewerZoomSourceActive, app.activeTab == .people)
            }
            Tab(AppTab.settings.title, systemImage: AppTab.settings.symbol, value: .settings) {
                NavigationStack { SettingsScreen() }
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .tint(Theme.accent)
        .toolbar(.hidden, for: .tabBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if app.viewer == nil {
                AppBottomBar(
                    selection: $app.activeTab,
                    level: $app.libraryLevel,
                    showsLibraryTabs: $libraryShowsTabs,
                    onSearch: { app.showSearch = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.backuSnappy, value: app.viewer == nil)
    }
    #endif

    private var splitRoot: some View {
        @Bindable var app = app
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $app.activeTab)
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 280)
        } detail: {
            NavigationStack {
                Group {
                    switch app.activeTab {
                    case .library: LibraryScreen()
                    case .people: PeopleScreen()
                    case .settings: SettingsScreen()
                    }
                }
                .navigationDestination(item: $app.viewer) { presentation in
                    ViewerScreen(presentation: presentation)
                        .environment(app)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
        #if os(iOS)
        // Photos gives the viewer the whole screen on iPad. Collapsing to the
        // detail column when a photo opens keeps the zoom transition full-bleed.
        .onChange(of: app.viewer == nil) { _, isClosed in
            if isClosed {
                columnVisibility = columnVisibilityBeforeViewer ?? .all
                columnVisibilityBeforeViewer = nil
            } else {
                columnVisibilityBeforeViewer = columnVisibility
                columnVisibility = .detailOnly
            }
        }
        #endif
    }
}

/// Photos-style bottom bar. On the Library tab it becomes the timeline
/// switcher (Library circle · Years/Months/All · Search). Tapping the Library
/// circle reveals the normal tab bar again so People and Settings stay
/// reachable. The two states cross-fade with a short slide.
struct AppBottomBar: View {
    @Binding var selection: AppTab
    @Binding var level: LibraryLevel
    @Binding var showsLibraryTabs: Bool
    var onSearch: () -> Void
    @Namespace private var namespace

    private var isTimeline: Bool {
        selection == .library && !showsLibraryTabs
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if isTimeline {
                    timelineChrome
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    tabsChrome
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: isTimeline)

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .scaledFont(20, weight: .semibold)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Search")
            .accessibilityIdentifier("search.open")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var timelineChrome: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                    showsLibraryTabs = true
                }
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .scaledFont(19, weight: .semibold)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Show Library tabs")
            .accessibilityIdentifier("tabs.show")

            LibraryLevelSwitcher(level: $level)
        }
    }

    private var tabsChrome: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                        selection = tab
                        if tab == .library {
                            showsLibraryTabs = false
                        }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol)
                            .scaledFont(18, weight: .semibold)
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selection == tab ? Theme.accent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background {
                        if selection == tab {
                            Capsule()
                                .fill(Theme.accent.opacity(0.12))
                                .matchedGeometryEffect(id: "bottom.tab", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab.\(tab.rawValue)")
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .glassCapsule(interactive: true)
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
                Button {
                    app.showSearch = true
                } label: {
                    Label {
                        Text("Search")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab.search")
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.clear)
                )

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
                        Text(app.backupDestinationCount > 1
                             ? "\(server.name) + \(app.backupDestinationCount - 1) more"
                             : server.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(app.backupDestinationCount > 1
                             ? "\(app.backupDestinationCount) backup destinations"
                             : server.folderDescription)
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
