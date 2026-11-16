import MapKit
import SwiftUI

struct PhotoInfoSheet: View {
    let photoID: String
    var initialPanel: ViewerPanel = .info
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""
    @State private var editingPerson: PersonTarget?

    init(photoID: String, initialPanel: ViewerPanel = .info) {
        self.photoID = photoID
        self.initialPanel = initialPanel
    }

    private var photo: PhotoItem? { app.catalog.photo(id: photoID) }

    var body: some View {
        NavigationStack {
            Group {
                if let photo {
                    content(photo)
                } else {
                    EmptyStateView(symbol: "photo", title: "Photo unavailable", message: "This photo is no longer in your library.")
                }
            }
            .background(Theme.pageBackground)
            .navigationTitle("Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .sheet(item: $editingPerson) { target in
            PersonPickerSheet(photoID: photoID, faceID: target.id)
                .environment(app)
        }
    }

    private func content(_ photo: PhotoItem) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                header(photo)

                if !photo.faces.isEmpty {
                    peopleCard(photo)
                } else if photo.analyzedAt != nil {
                    noFacesCard(photo)
                }

                tagsCard(photo)
                detailsCard(photo)
                if photo.metadata.hasLocation {
                    placeCard(photo)
                }
                backupCard(photo)
            }
            .padding(16)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Header

    private func header(_ photo: PhotoItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(photo.takenAt?.dayLabel ?? photo.filename)
                        .font(.title2.weight(.bold))
                    if photo.isVideo {
                        Label(photo.duration.map(shortDuration) ?? "Video", systemImage: "play.rectangle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(photo.filename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                backupPill(photo)
            }
            if let tags = photo.tagSummary {
                Text(tags)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .contentCard()
    }

    private func backupPill(_ photo: PhotoItem) -> some View {
        let state = app.photoBackupState(photo)
        return HStack(spacing: 5) {
            BackupBadge(state: state)
                .font(.caption)
            Text(label(for: state))
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(state == .backedUp ? Theme.mint.opacity(0.16) : Color.primary.opacity(0.08)))
    }

    private func label(for state: AppModel.BackupState) -> String {
        switch state {
        case .backedUp: return "Backed up"
        case .needsUpdate: return "Sync details"
        case .notBackedUp: return "Not backed up"
        }
    }

    // MARK: People

    private func peopleCard(_ photo: PhotoItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("People & Pets", symbol: "person.2")
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(photo.faces) { face in
                        Button {
                            editingPerson = PersonTarget(id: face.id)
                        } label: {
                            VStack(spacing: 5) {
                                FaceBubble(photo: photo, face: face, size: 58)
                                Text(personName(for: face) ?? (face.kind == .pet ? "Name pet" : "Name"))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(face.personID == nil ? Theme.accent : .secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: 70)
                            }
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            Text("Tap a face to say who it is. Names are saved with the photo and used for search.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .contentCard()
    }

    private func noFacesCard(_ photo: PhotoItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No people found")
                    .font(.subheadline.weight(.medium))
                Text("Backu looked on-device and did not find faces in this photo.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .contentCard()
    }

    private func personName(for face: PhotoFace) -> String? {
        guard let person = app.catalog.person(id: face.personID) else { return nil }
        return person.isNamed ? person.displayName : "Unnamed"
    }

    // MARK: Tags

    private func tagsCard(_ photo: PhotoItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("Tags", symbol: "tag")
            if photo.tags.isEmpty {
                Text("No tags yet. Tags are stored beside the photo in your bucket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(photo.tags, id: \.self) { tag in
                    TagChip(text: tag, isSelected: true) {
                        app.catalog.removeTag(tag, from: photo.id)
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Add a tag", text: $newTag)
                    .textFieldStyle(.plain)
                    .onSubmit { addTag(to: photo) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                Button {
                    addTag(to: photo)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(Theme.accent)
                .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Add tag")
            }
        }
        .padding(16)
        .contentCard()
    }

    private func addTag(to photo: PhotoItem) {
        let value = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        app.catalog.addTag(value, to: photo.id)
        newTag = ""
    }

    // MARK: Details

    private func detailsCard(_ photo: PhotoItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Details", symbol: "camera")
            infoRow("Captured", photo.takenAt.map { "\($0.dayLabel) · \($0.timeLabel)" } ?? "Unknown")
            if let camera = photo.metadata.cameraDescription {
                infoRow("Camera", camera)
            }
            if let lens = photo.metadata.lensModel {
                infoRow("Lens", lens)
            }
            if let exposure = photo.metadata.exposureDescription {
                infoRow("Exposure", exposure)
            }
            if photo.pixelWidth > 0 {
                infoRow("Size", "\(photo.pixelWidth) × \(photo.pixelHeight)")
            }
            if let size = photo.metadata.fileSize, size > 0 {
                infoRow("File", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
            if let place = photo.metadata.placeName {
                infoRow("Place", place)
            }
            if let sha = photo.sha256 {
                infoRow("SHA-256", String(sha.prefix(20)) + "…")
            }
        }
        .padding(16)
        .contentCard()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Place

    private func placeCard(_ photo: PhotoItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("Location", symbol: "location")
            if let coordinate = photo.metadata.coordinate {
                Map(initialPosition: .region(
                    MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    )
                )) {
                    Marker("", coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
                        .tint(Theme.accent)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .allowsHitTesting(false)
                Text(String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .contentCard()
    }

    // MARK: Backup

    private func backupCard(_ photo: PhotoItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("Storage", symbol: "externaldrive")
            if photo.copies.isEmpty {
                Text("This photo is only on this device. Turn on automatic backup, or back it up now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    app.startBackup()
                } label: {
                    Label("Back up now", systemImage: "arrow.up.to.line.compact")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(app.servers.servers.isEmpty)
            } else {
                ForEach(photo.copies, id: \.serverID) { copy in
                    if let server = app.servers.server(id: copy.serverID) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                ProviderBadge(provider: server.provider, size: 22)
                                Text(server.name)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(copy.uploadedAt.relativeShort)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(copy.objectKey)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            HStack(spacing: 10) {
                                if copy.byteCount > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: copy.byteCount, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if photo.sidecarDirtyAt != nil {
                                    Text("Details pending")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
                    }
                }
            }
        }
        .padding(16)
        .contentCard()
    }

    private func cardTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func shortDuration(_ duration: Double) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct PersonTarget: Identifiable {
    var id: UUID
}

struct PersonPickerSheet: View {
    let photoID: String
    let faceID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isPet = false

    private var face: PhotoFace? {
        app.catalog.face(photoID: photoID, faceID: faceID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let photo = app.catalog.photo(id: photoID), let face {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                FaceBubble(photo: photo, face: face, size: 92)
                                Text("Who is this?")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                }

                let people = app.catalog.people.filter { !$0.isPet && !$0.isHidden }
                if !people.isEmpty {
                    Section("People") {
                        ForEach(people) { person in
                            Button {
                                assign(person.id)
                            } label: {
                                HStack(spacing: 10) {
                                    PersonAvatar(person: person, size: 34)
                                    Text(person.displayName)
                                    Spacer()
                                    if face?.personID == person.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                let pets = app.catalog.people.filter { $0.isPet && !$0.isHidden }
                if !pets.isEmpty {
                    Section("Pets") {
                        ForEach(pets) { person in
                            Button {
                                assign(person.id)
                            } label: {
                                HStack(spacing: 10) {
                                    PersonAvatar(person: person, size: 34)
                                    Text(person.displayName)
                                    Spacer()
                                    if face?.personID == person.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Add someone new") {
                    TextField("Name", text: $name)
                    Toggle("This is a pet", isOn: $isPet)
                    Button("Create and tag") {
                        let person = app.catalog.createPerson(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            isPet: isPet,
                            coverPhotoID: photoID,
                            coverFaceID: faceID
                        )
                        assign(person.id)
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section {
                    Button("Remove this face", role: .destructive) {
                        app.catalog.removeFace(photoID: photoID, faceID: faceID)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Tag a Face")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 520)
        #endif
    }

    private func assign(_ personID: UUID) {
        app.catalog.assign(faceID: faceID, in: photoID, to: personID)
        dismiss()
    }
}

struct PersonAvatar: View {
    let person: Person
    var size: CGFloat = 40
    @Environment(AppModel.self) private var app
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let photo = app.catalog.photo(id: person.coverPhotoID ?? ""),
                      let face = photo.faces.first(where: { $0.id == person.coverFaceID }) {
                FaceBubble(photo: photo, face: face, size: size)
            } else {
                Circle()
                    .fill(Color(hex: person.isPet ? 0xC98A3D : 0x6C7A8A).gradient)
                    .overlay {
                        Image(systemName: person.isPet ? "pawprint.fill" : "person.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: size * 0.4))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: person.id) {
            guard image == nil,
                  let photo = app.catalog.photo(id: person.coverPhotoID ?? ""),
                  let face = photo.faces.first(where: { $0.id == person.coverFaceID }) else { return }
            image = await app.images.faceImage(photo: photo, face: face, size: max(300, size * 4))
        }
    }
}
