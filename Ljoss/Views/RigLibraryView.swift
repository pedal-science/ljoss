import SwiftUI

struct RigLibraryView: View {
    @Environment(RigLibrary.self) private var library
    @Binding var selection: UUID?
    @State private var renaming: Rig?
    @State private var draftName: String = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(library.rigs) { rig in
                    RigRow(rig: rig)
                        .tag(rig.id)
                        .contextMenu {
                            Button { beginRename(rig) } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button { selection = library.duplicate(rig).id } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            Divider()
                            Button(role: .destructive) { delete(rig) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(rig) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { selection = library.duplicate(rig).id } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            .tint(.indigo)
                        }
                }
            } header: {
                Text("\(library.rigs.count) rigs")
            }

            if let error = library.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Rigs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(RigLayout.allCases) { layout in
                        Button {
                            selection = library.createRig(layout: layout).id
                        } label: {
                            Label(layout.displayName,
                                  systemImage: layout == .single ? "rectangle" : "rectangle.split.1x2")
                        }
                    }
                } label: {
                    Label("New Rig", systemImage: "plus")
                } primaryAction: {
                    selection = library.createRig(layout: .single).id
                }
            }
        }
        .alert("Rename Rig", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let rig = renaming { library.rename(rig, to: draftName) }
                renaming = nil
            }
        }
    }

    private func beginRename(_ rig: Rig) {
        draftName = rig.name
        renaming = rig
    }

    private func delete(_ rig: Rig) {
        if selection == rig.id {
            selection = library.rigs.first(where: { $0.id != rig.id })?.id
        }
        library.delete(rig)
    }
}

struct RigRow: View {
    let rig: Rig

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rig.layout == .single ? "rectangle" : "rectangle.split.1x2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(rig.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(minHeight: Metrics.minTouchTarget)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let chains = rig.activeChains.map(\.name).joined(separator: " + ")
        let blocks = rig.blockCount
        return "\(chains) · \(blocks) block\(blocks == 1 ? "" : "s")"
    }
}
