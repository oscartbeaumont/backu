import SwiftUI

struct PeopleScreen: View {
    @Environment(AppModel.self) private var app
    @State private var filter: PeopleFilter = .all
    @State private var personTarget: Person?

    enum PeopleFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case people = "People"
        case pets = "Pets"
        case unnamed = "To name"
        var id: String { rawValue }
    }

    private var people: [Person] {
        let all = app.catalog.people.filter { !$0.isHidden }
        switch filter {
        case .all:
            return all.sorted { lhs, rhs in
                if lhs.isNamed != rhs.isNamed { return lhs.isNamed }
                return lhs.faceCount > rhs.faceCount
            }
        case .people:
            return all.filter { !$0.isPet }.sorted { $0.faceCount > $1.faceCount }
        case .pets:
            return all.filter(\.isPet).sorted { $0.faceCount > $1.faceCount }
        case .unnamed:
            return all.filter { !$0.isNamed }.sorted { $0.faceCount > $1.faceCount }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 18, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ScreenTitle("People & Pets", subtitle: subtitle) {
                    GlassIconButton(symbol: "sparkle.magnifyingglass", label: "Scan for faces") {
                        Task {
                            await app.analyzer.analyzeMissing(
                                catalog: app.catalog,
                                settings: app.settings,
                                faceStore: app.faceStore,
                                places: app.places
                            )
                        }
                    }
                }

                if app.analyzer.isRunning {
                    analyzingBanner
                }

                if app.catalog.people.isEmpty {
                    emptyState
                } else {
                    filterBar
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(people) { person in
                            PersonGridCell(person: person) {
                                personTarget = person
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 120)
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .navigationDestination(item: $personTarget) { person in
            PersonDetailScreen(personID: person.id)
        }
    }

    private var subtitle: String {
        let faces = app.catalog.stats().faces
        let named = app.catalog.people.filter(\.isNamed).count
        if faces == 0 { return "Faces are found on-device" }
        return "\(faces) face\(faces == 1 ? "" : "s") · \(named) named"
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(PeopleFilter.allCases) { option in
                    FilterChip(title: option.rawValue, isSelected: filter == option) {
                        withAnimation(.backuSnappy) { filter = option }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private var analyzingBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "face.smiling.inverse")
                    .foregroundStyle(Theme.accent)
                Text(app.analyzer.status)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(app.analyzer.completed)/\(app.analyzer.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressBar(value: app.analyzer.progress)
        }
        .padding(14)
        .glassSurface(18)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: "person.2.crop.square.stack",
            title: "Find the people in your photos",
            message: "Backu finds faces on-device, groups them by person, and lets you give them names. Nothing is uploaded to recognise a face.",
            actionTitle: "Scan for Faces"
        ) {
            Task {
                await app.analyzer.analyzeMissing(
                    catalog: app.catalog,
                    settings: app.settings,
                    faceStore: app.faceStore,
                    places: app.places
                )
            }
        }
        .padding(.top, 40)
    }
}

struct PersonGridCell: View {
    let person: Person
    var onOpen: () -> Void
    @Environment(AppModel.self) private var app
    @State private var naming = false
    @State private var draftName = ""

    var body: some View {
        Button {
            if person.isNamed {
                onOpen()
            } else {
                draftName = ""
                naming = true
            }
        } label: {
            VStack(spacing: 8) {
                PersonAvatar(person: person, size: 104)
                    .overlay(alignment: .bottomTrailing) {
                        if person.isPet {
                            Image(systemName: "pawprint.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Circle().fill(Color(hex: 0xC98A3D)))
                                .offset(x: 2, y: 2)
                        }
                    }
                Text(person.isNamed ? person.displayName : "Add name")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(person.isNamed ? Color.primary : .secondary)
                    .lineLimit(1)
                Text("\(person.faceCount) photo\(person.faceCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(person.isNamed ? person.displayName : "Unnamed \(person.isPet ? "pet" : "person")"), \(person.faceCount) photos")
        .accessibilityIdentifier(person.isNamed ? "people.cell" : "people.name")
        .alert("Name this \(person.isPet ? "pet" : "person")", isPresented: $naming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { app.catalog.renamePerson(person.id, to: trimmed) }
            }
        } message: {
            Text("The name is saved beside every photo they appear in, so it syncs to your other devices.")
        }
    }
}

struct PersonDetailScreen: View {
    let personID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isPet = false
    @State private var didLoad = false
    @State private var mergeTarget: Person?
    @State private var confirmDelete = false

    private var person: Person? { app.catalog.person(id: personID) }

    private var photos: [PhotoItem] {
        app.catalog.photos(of: personID)
    }

    var body: some View {
        ScrollView {
            if let person {
                VStack(spacing: 18) {
                    header(person)
                    photoGrid
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground)
        .navigationTitle(person?.displayName ?? "Person")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        confirmDelete = true
                    } label: {
                        Label("Delete \(person?.isPet == true ? "pet" : "person")", systemImage: "trash")
                    }
                    if app.catalog.people.count > 1 {
                        Button {
                            mergeTarget = app.catalog.people.first { $0.id != personID }
                        } label: {
                            Label("Merge into another", systemImage: "arrow.triangle.merge")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            guard let person, !didLoad else { return }
            name = person.name ?? ""
            isPet = person.isPet
            didLoad = true
        }
        .confirmationDialog(
            "Delete this \(person?.isPet == true ? "pet" : "person")?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                app.catalog.deletePerson(personID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The face tags are removed from your photos. Your photos are not deleted.")
        }
        .sheet(item: $mergeTarget) { target in
            MergePersonSheet(sourceID: personID, initialTargetID: target.id)
                .environment(app)
        }
    }

    private func header(_ person: Person) -> some View {
        VStack(spacing: 12) {
            PersonAvatar(person: person, size: 132)
                .glassSurface(70, tint: Theme.accent.opacity(0.08))
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .onSubmit(save)
                    .frame(maxWidth: 240)
                Button {
                    save()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(name == (person.name ?? ""))
                .accessibilityLabel("Save name")
            }
            HStack(spacing: 14) {
                Label("\(photos.count) photos", systemImage: "photo.on.rectangle")
                Toggle(isOn: Binding(
                    get: { person.isPet },
                    set: { value in
                        isPet = value
                        app.catalog.setPet(person.id, isPet: value)
                    }
                )) {
                    Label("Pet", systemImage: "pawprint")
                }
                .toggleStyle(.button)
                .buttonStyle(.glass)
            }
            .font(.caption)
        }
        .padding(.top, 8)
    }

    private var photoGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(photos) { photo in
                PhotoTile(photo: photo, columns: 3) {
                    app.viewer = app.photosForViewer(startingAt: photo.id, within: photos)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        app.catalog.renamePerson(personID, to: trimmed)
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

struct MergePersonSheet: View {
    let sourceID: UUID
    var initialTargetID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var targetID: UUID

    init(sourceID: UUID, initialTargetID: UUID) {
        self.sourceID = sourceID
        self.initialTargetID = initialTargetID
        _targetID = State(initialValue: initialTargetID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Merge into") {
                    ForEach(app.catalog.people.filter { $0.id != sourceID }) { person in
                        Button {
                            targetID = person.id
                        } label: {
                            HStack(spacing: 10) {
                                PersonAvatar(person: person, size: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.displayName)
                                    Text("\(person.faceCount) faces")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if targetID == person.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Merge")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") {
                        app.catalog.mergePeople(sourceID, into: targetID)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 460)
        #endif
    }
}
