import SwiftUI

/// The floating filter panel from Photos: sort at the top, a checkmarked list of
/// library filters, media-type choices and view options. It is presented as a
/// glass card over the library rather than a full sheet, so the grid stays
/// visible while the filter changes.
struct LibraryFilterPanel: View {
    @Environment(AppModel.self) private var app
    @Binding var sort: LibrarySort
    @Binding var filter: LibraryFilter
    var onDismiss: () -> Void

    @State private var mediaExpanded = false
    @State private var viewExpanded = false

    private let baseFilters: [LibraryFilter] = [
        .all, .favorites, .pending, .people, .located, .local
    ]

    var body: some View {
        VStack(spacing: 0) {
            sortControl
                .padding(12)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Filter:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 4)

                    ForEach(baseFilters) { option in
                        filterRow(option)
                    }

                    mediaTypesRow
                    if mediaExpanded {
                        filterRow(.photos)
                            .padding(.leading, 30)
                        filterRow(.videos)
                            .padding(.leading, 30)
                    }

                    viewOptionsRow
                    if viewExpanded {
                        viewOptions
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 470)

            Divider().opacity(0.5)

            Button("Done", action: onDismiss)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .accessibilityIdentifier("filter.done")
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.18), radius: 26, y: 12)
    }

    private var sortControl: some View {
        HStack(spacing: 2) {
            ForEach(LibrarySort.allCases) { option in
                Button {
                    withAnimation(.backuSnappy) { sort = option }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 15, weight: .semibold))
                        Text(option.rawValue)
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(sort == option ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background {
                        if sort == option {
                            Capsule().fill(Color.primary.opacity(0.12))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sort == option ? .isSelected : [])
                .accessibilityIdentifier("filter.sort.\(option.rawValue.lowercased())")
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    private func filterRow(_ option: LibraryFilter) -> some View {
        Button {
            withAnimation(.backuSnappy) { filter = option }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: option.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 24)
                Text(option.rawValue)
                    .font(.body)
                Spacer(minLength: 8)
                if filter == option {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == option ? .isSelected : [])
        .accessibilityIdentifier("filter.option.\(option.id.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    private var mediaTypesRow: some View {
        Button {
            withAnimation(.backuSnappy) { mediaExpanded.toggle() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 24)
                Text("Media Types")
                    .font(.body)
                Spacer(minLength: 8)
                if filter == .photos || filter == .videos {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(mediaExpanded ? 90 : 0))
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.mediaTypes")
    }

    private var viewOptionsRow: some View {
        Button {
            withAnimation(.backuSnappy) { viewExpanded.toggle() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.grid.2x2")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 24)
                Text("View Options")
                    .font(.body)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(viewExpanded ? 90 : 0))
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.viewOptions")
    }

    @ViewBuilder
    private var viewOptions: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $settings.showRemoteOnlyPhotos) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Photos from servers")
                        .font(.subheadline)
                    Text("Include photos backed up from other devices.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accent)

            HStack {
                Text("Grid size")
                    .font(.subheadline)
                Spacer()
                Picker("Grid size", selection: $settings.gridColumns) {
                    Text("Full width").tag(1)
                    Text("Large").tag(2)
                    Text("Medium").tag(3)
                    Text("Small").tag(4)
                    Text("Tiny").tag(6)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
