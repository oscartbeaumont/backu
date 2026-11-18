import SwiftUI

struct SearchScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var text = ""
    @State private var query = SearchQuery()
    @State private var showFilters = false
    @FocusState private var searchFocused: Bool

    private var results: [PhotoItem] {
        var query = query
        query.text = text
        return app.catalog.search(query)
    }

    private var facets: SearchIndex.Facets {
        app.catalog.facets(for: app.catalog.allIDs())
    }

    private var columns: [GridItem] {
        let count: Int
        #if os(macOS)
        count = 6
        #else
        count = sizeClass == .compact ? 3 : 5
        #endif
        return Array(repeating: GridItem(.flexible(), spacing: 2), count: count)
    }

    private var isSearching: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || !query.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ScreenTitle("Search", subtitle: "On-device index · instant results") {
                    HStack(spacing: 8) {
                        GlassIconButton(symbol: "line.3.horizontal.decrease", label: "Filters", isActive: !query.isEmpty) {
                            showFilters.toggle()
                        }
                        GlassIconButton(symbol: "xmark", label: "Close search") {
                            app.showSearch = false
                        }
                        .accessibilityIdentifier("search.close")
                    }
                }

                searchField

                if showFilters {
                    activeFilters
                }

                if isSearching {
                    resultsSection
                } else {
                    browseSection
                }
            }
            .padding(.bottom, 90)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.pageBackground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .animation(.backuSnappy, value: isSearching)
        .animation(.backuSnappy, value: showFilters)
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            searchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("People, places, cameras, tags…", text: $text)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("search.field")
                .font(.body)
                .focused($searchFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .glassSurface(22)
        .frame(maxWidth: 720)
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    private var activeFilters: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(query.personIDs), id: \.self) { id in
                if let person = app.catalog.person(id: id) {
                    TagChip(text: person.displayName, isSelected: true) {
                        query.personIDs.remove(id)
                    }
                }
            }
            ForEach(Array(query.tags), id: \.self) { tag in
                TagChip(text: "#\(tag)", isSelected: true) {
                    query.tags.remove(tag)
                }
            }
            ForEach(Array(query.cameras), id: \.self) { camera in
                TagChip(text: camera, isSelected: true) {
                    query.cameras.remove(camera)
                }
            }
            if let year = query.year {
                TagChip(text: String(year), isSelected: true) {
                    query.year = nil
                }
            }
            if query.favoritesOnly {
                TagChip(text: "Favorites", isSelected: true) { query.favoritesOnly = false }
            }
            if query.locatedOnly {
                TagChip(text: "Has location", isSelected: true) { query.locatedOnly = false }
            }
            if query.media != .all {
                TagChip(text: query.media.rawValue.capitalized, isSelected: true) { query.media = .all }
            }
            if query.activeFilterCount > 0 {
                TagChip(text: "Clear") {
                    let text = self.text
                    query = SearchQuery()
                    self.text = text
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(.subheadline.weight(.semibold))
                if !text.isEmpty {
                    Text("for “\(text)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if results.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "Nothing matched",
                    message: "Try a name, a place, or part of a camera model. Search also understands tags and years."
                )
                .padding(.top, 30)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(results) { photo in
                        PhotoTile(photo: photo, columns: columns.count) {
                            app.viewer = app.photosForViewer(startingAt: photo.id, within: results)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !app.catalog.namedPeople.isEmpty {
                peopleRow
            }

            if !facets.tags.isEmpty {
                facetSection("Tags", symbol: "tag") {
                    ForEach(facets.tags, id: \.value) { item in
                        Button {
                            query.tags.insert(item.value)
                        } label: {
                            HStack(spacing: 6) {
                                Text("#\(item.value)")
                                Text("\(item.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption2.monospacedDigit())
                            }
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .glassSurface(18, interactive: true)
                    }
                }
            }

            if !facets.cameras.isEmpty {
                facetSection("Cameras", symbol: "camera") {
                    ForEach(facets.cameras, id: \.value) { item in
                        Button {
                            query.cameras.insert(item.value)
                        } label: {
                            Text(item.value)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .glassSurface(18, interactive: true)
                    }
                }
            }

            if !facets.years.isEmpty {
                facetSection("Years", symbol: "calendar") {
                    ForEach(facets.years, id: \.year) { item in
                        Button {
                            query.year = item.year
                        } label: {
                            HStack(spacing: 6) {
                                Text(String(item.year))
                                Text("\(item.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .glassSurface(18, interactive: true)
                    }
                }
            }

            quickFilters

            if facets.tags.isEmpty && facets.cameras.isEmpty && app.catalog.namedPeople.isEmpty {
                EmptyStateView(
                    symbol: "text.magnifyingglass",
                    title: "Search your whole library",
                    message: "Backu keeps a search index on this device. Names, tags, places and camera details are ready before you finish typing."
                )
                .padding(.top, 20)
            }
        }
        .padding(.top, 22)
    }

    private func facetSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                content()
            }
            .padding(.horizontal, 18)
        }
    }

    private var peopleRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("People & Pets", systemImage: "person.2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    app.showSearch = false
                    app.activeTab = .people
                } label: {
                    Text("See all")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(app.catalog.namedPeople.prefix(12)) { person in
                        Button {
                            query.personIDs.insert(person.id)
                        } label: {
                            VStack(spacing: 6) {
                                PersonAvatar(person: person, size: 64)
                                Text(person.displayName)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .frame(maxWidth: 72)
                            }
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var quickFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Shortcuts", systemImage: "bolt")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                quickFilter("Favorites", symbol: "heart.fill") { query.favoritesOnly.toggle() }
                quickFilter("Videos", symbol: "play.rectangle.fill") { query.media = query.media == .videos ? .all : .videos }
                quickFilter("Has location", symbol: "location.fill") { query.locatedOnly.toggle() }
                quickFilter("Backed up", symbol: "checkmark.icloud") {
                    if let server = app.backupServer { query.serverID = query.serverID == nil ? server.id : nil }
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private func quickFilter(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(PressableButtonStyle())
        .glassSurface(18, interactive: true)
    }
}
