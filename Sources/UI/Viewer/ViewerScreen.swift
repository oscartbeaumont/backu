import SwiftUI

struct ViewerScreen: View {
    let presentation: ViewerPresentation
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String
    @State private var panel: ViewerPanel?
    @State private var chromeVisible = true
    @State private var showPanel = false

    init(presentation: ViewerPresentation) {
        self.presentation = presentation
        _selection = State(initialValue: presentation.startID)
        _panel = State(initialValue: presentation.panel)
        _showPanel = State(initialValue: presentation.panel != nil)
    }

    private var photo: PhotoItem? {
        app.catalog.photo(id: selection)
    }

    private var ids: [String] {
        presentation.photoIDs
    }

    private var index: Int {
        ids.firstIndex(of: selection) ?? 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if os(iOS)
            TabView(selection: $selection) {
                ForEach(ids, id: \.self) { id in
                    ViewerPage(photoID: id, chromeVisible: $chromeVisible)
                        .tag(id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            #else
            ViewerPage(photoID: selection, chromeVisible: $chromeVisible)
                .ignoresSafeArea()
                .overlay(alignment: .leading) { pagerArrow(symbol: "chevron.left", enabled: index > 0) }
                .overlay(alignment: .trailing) { pagerArrow(symbol: "chevron.right", enabled: index < ids.count - 1) }
                .onKeyPress(.leftArrow) { move(-1); return .handled }
                .onKeyPress(.rightArrow) { move(1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            #endif

            if chromeVisible {
                chrome
                    .transition(.opacity)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden()
        #endif
        .animation(.backuGentle, value: chromeVisible)
        .sheet(isPresented: $showPanel) {
            if let photo, let panel {
                PhotoInfoSheet(photoID: photo.id, initialPanel: panel)
                    .environment(app)
            }
        }
        .onChange(of: panel) { _, value in
            if value != nil { showPanel = true }
        }
        .onChange(of: showPanel) { _, value in
            if !value { panel = nil }
        }
    }

    private var chrome: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")

            VStack(alignment: .leading, spacing: 1) {
                Text(photo?.takenAt?.dayLabel ?? "Photo")
                    .font(.subheadline.weight(.semibold))
                if let taken = photo?.takenAt {
                    Text(taken.timeLabel)
                        .font(.caption2)
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassSurface(14)

            Spacer()

            if let photo {
                Button {
                    app.toggleFavorite(photo.id)
                } label: {
                    Image(systemName: photo.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(photo.isFavorite ? Theme.accent : Color.primary)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(photo.isFavorite ? "Remove favorite" : "Favorite")
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            viewerAction(panel: .info, symbol: "info.circle", label: "Info")
            viewerAction(panel: .tags, symbol: "tag", label: "Tag")
            viewerAction(panel: .people, symbol: "person.2", label: "People")

            #if os(iOS)
            if let photo, photo.isRemoteOnly {
                Button {
                    Task { await saveToPhotos(photo) }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Save")
                            .font(.caption2.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save to photo library")
            }
            #endif
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: 420)
        .glassSurface(28)
        .padding(.bottom, 6)
    }

    private func viewerAction(panel target: ViewerPanel, symbol: String, label: String) -> some View {
        Button {
            panel = target
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityLabel(label)
    }

    #if os(macOS)
    private func pagerArrow(symbol: String, enabled: Bool) -> some View {
        Button {
            move(symbol.contains("left") ? -1 : 1)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .padding(24)
    }

    private func move(_ delta: Int) {
        let next = index + delta
        guard ids.indices.contains(next) else { return }
        selection = ids[next]
    }
    #endif

    private func saveToPhotos(_ photo: PhotoItem) async {
        guard let server = app.servers.server(id: photo.copies.first?.serverID ?? photo.serverID),
              let client = app.servers.client(for: server),
              let key = photo.copy(on: server.id)?.objectKey,
              !key.isEmpty,
              let data = try? await client.getObject(key: key) else {
            app.errorMessage = "Could not download that photo."
            return
        }
        #if os(iOS)
        do {
            try await PhotoLibraryService.shared.saveToLibrary(
                data: data,
                filename: photo.filename,
                isVideo: photo.isVideo
            )
        } catch {
            app.errorMessage = "Could not add that item to your photo library."
        }
        #endif
    }
}

struct ViewerPage: View {
    let photoID: String
    @Binding var chromeVisible: Bool
    @Environment(AppModel.self) private var app
    @State private var image: PlatformImage?
    @State private var isLoading = true
    @State private var failure: String?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1
    @State private var lastOffset: CGSize = .zero

    private var photo: PhotoItem? { app.catalog.photo(id: photoID) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnification)
                        .simultaneousGesture(drag)
                        .onTapGesture(count: 2) { toggleZoom() }
                        .animation(.backuSnappy, value: scale)
                        .animation(.backuSnappy, value: offset)
                } else if let failure {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text(failure)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        if photo?.isRemoteOnly == true {
                            Text("Downloading from \(serverName)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.backuGentle) { chromeVisible.toggle() }
            }
        }
        .task(id: photoID) { await load() }
    }

    private var serverName: String {
        app.servers.server(id: photo?.copies.first?.serverID ?? photo?.serverID)?.name ?? "storage"
    }

    private func load() async {
        guard let photo else {
            failure = "This photo is no longer available."
            isLoading = false
            return
        }
        isLoading = true
        failure = nil
        image = await app.images.fullImage(for: photo)
        isLoading = false
        if image == nil {
            failure = photo.isRemoteOnly
                ? "Could not download this photo from \(serverName)."
                : "This photo is not available on this device."
        }
        scale = 1
        offset = .zero
        lastScale = 1
        lastOffset = .zero
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 8)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 {
                    scale = 1
                    offset = .zero
                    lastOffset = .zero
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1 else { return }
                lastOffset = offset
            }
    }

    private func toggleZoom() {
        withAnimation(.backuSnappy) {
            if scale > 1 {
                scale = 1
                offset = .zero
                lastOffset = .zero
            } else {
                scale = 2.4
            }
            lastScale = scale
        }
    }
}
