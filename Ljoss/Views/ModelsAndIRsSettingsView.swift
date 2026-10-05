import SwiftUI
import UniformTypeIdentifiers

// The folders the user's captures are kept in, and what was found in them.
//
// The library is this app's own listing of files on disk. It is not the device's library
// — a rig still names its model by the id `engine.assets` gave it — and nothing here is
// sent anywhere. What it is for is telling the user what they have (`docs/ASSETS.md`).

struct ModelsAndIRsSettingsView: View {
    @Environment(AssetLibrary.self) private var assets

    @State private var showingImporter = false
    @State private var complaint: String?

    // Viewing preferences, not library data: shared across launches by `@AppStorage`, the
    // same treatment the canvas's wrap toggle gets.
    @AppStorage("assets.groupBy") private var groupBy: AssetGroupKey = .type
    @AppStorage("assets.groupThenBy") private var groupThenBy: AssetGroupKey = .make
    @AppStorage("assets.sortBy") private var sortBy: AssetSortKey = .make
    @AppStorage("assets.sortThenBy") private var sortThenBy: AssetSortKey = .updated

    private var grouping: AssetGrouping {
        AssetGrouping(groupBy: groupBy, thenBy: groupThenBy, sortBy: sortBy, thenSortBy: sortThenBy)
    }

    private var sections: [AssetSection] {
        AssetOrdering.sections(assets.entries, rootLabels: assets.rootLabels, grouping: grouping)
    }

    var body: some View {
        VStack {
            Form {
                folders
                if let complaint { complaintRow(complaint) }
                if let error = assets.lastError { complaintRow(error) }
                
                Section {
                    Picker("Group by", selection: $groupBy) {
                        ForEach(AssetGroupKey.allCases) { key in Text(key.displayName).tag(key) }
                    }
                    Picker("Then by", selection: $groupThenBy) {
                        ForEach(AssetGroupKey.allCases) { key in Text(key.displayName).tag(key) }
                    }
                } header: {
                    Text("Group")
                } footer: {
                    Text("A second level equal to the first adds nothing, and None is one list.")
                }
                
                Section {
                    Picker("Sort by", selection: $sortBy) {
                        ForEach(AssetSortKey.allCases) { key in Text(key.displayName).tag(key) }
                    }
                    Picker("Then by", selection: $sortThenBy) {
                        ForEach(AssetSortKey.allCases) { key in Text(key.displayName).tag(key) }
                    }
                } header: {
                    Text("Sort")
                } footer: {
                    Text("Names read A–Z and dates read newest first. Unknown is always last.")
                }
                
                Section {
                    ScanStatusRow(state: assets.state, unavailableFolders: assets.issues.count)
                }
                
            }
            .formStyle(.grouped)
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: true) { result in
                add(result)
            }
                          .onAppear { assets.scanIfNeeded() }
            ScrollView {
                results
            }
        }.padding()
    }

    // MARK: - Folders

    private var folders: some View {
        Section {
            ForEach(assets.roots) { root in
                folderRow(root)
            }

            HStack(spacing: 10) {
                Button {
                    showingImporter = true
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .disabled(assets.state.isScanning)

                Spacer()

                Button {
                    assets.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(assets.roots.isEmpty || assets.state.isScanning)
            }
            .frame(minHeight: Metrics.minTouchTarget)
        } header: {
            Text("Folders")
        } footer: {
            Text(foldersFooter)
        }
    }

    private func folderRow(_ root: AssetRoot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(root.label)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(root.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let issue = assets.issue(for: root) {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)

            Button(role: .destructive) {
                assets.removeFolder(root)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop scanning this folder")
            .accessibilityLabel(Text("Remove \(root.label)"))
        }
        .frame(minHeight: Metrics.minTouchTarget)
        .contextMenu {
            Button(role: .destructive) { assets.removeFolder(root) } label: {
                Label("Remove Folder", systemImage: "trash")
            }
        }
    }

    private var foldersFooter: String {
        guard !assets.roots.isEmpty else {
            return "Add the folders your .nam models and impulse responses are kept in."
        }
        let folders = assets.roots.count
        let files = assets.entries.count
        return "\(folders) folder\(folders == 1 ? "" : "s") · "
             + "\(files) file\(files == 1 ? "" : "s") · "
             + "\(assets.modelCount) model\(assets.modelCount == 1 ? "" : "s"), "
             + "\(assets.irCount) impulse response\(assets.irCount == 1 ? "" : "s")"
    }

    private func complaintRow(_ text: String) -> some View {
        Section {
            Label(text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            // One complaint is enough: they are all the same shape, and a list of them
            // would push the folders off the page.
            complaint = urls.compactMap { assets.addFolder($0) }.first
        case .failure(let error):
            complaint = "That folder could not be opened: \(error.localizedDescription)"
        }
    }

    // MARK: - What was found

    @ViewBuilder
    private var results: some View {
        if assets.roots.isEmpty {
            Section {
                Text("No folders yet. Add the folders that hold your .nam models and impulse responses.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if sections.isEmpty {
            // While the first scan runs the indicator is saying what is happening, so
            // "nothing found" would be a claim about a scan that has not finished.
            if !assets.state.isScanning {
                Section {
                    Text("No models or impulse responses were found in these folders.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Group {
                ForEach(sections) { section in
                    if let title = section.title {
                        Section(title) { rows(section) }
                    } else {
                        Section { rows(section) }
                    }
                }
            }
            // The list can change under the pointer while a scan publishes, so it is not
            // interactive until the scan is done. The folders and the display choices
            // above stay live: they are what starts the next scan, and changing one
            // mid-scan simply supersedes it.
            .disabled(assets.state.isScanning)
            .opacity(assets.state.isScanning ? 0.5 : 1)
        }
    }

    private func rows(_ section: AssetSection) -> some View {
        ForEach(section.entries) { entry in
            AssetRow(entry: entry)
        }
    }
}

// MARK: - The indicator

/// What the folders are doing, in a row that keeps its size whether or not it has
/// anything to say.
///
/// The fixed height is the point: a scan starting or finishing must not move the list
/// under the pointer, so the row is always here and only its contents come and go.
struct ScanStatusRow: View {
    var state: AssetLibrary.ScanState
    /// Folders that could not be read, which is worth saying next to the count.
    var unavailableFolders: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .idle:
                EmptyView()
            case .scanning:
                ProgressView()
                    .controlSize(.small)
                Text("Scanning folders…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .finished(let stats):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(finished(stats))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .opacity(state == .idle ? 0 : 1)
        .animation(.easeInOut(duration: 0.2), value: state)
        .accessibilityHidden(state == .idle)
    }

    private func finished(_ stats: AssetScanStats) -> String {
        var text = "Scan finished — \(stats.summary)"
        if unavailableFolders > 0 {
            text += " · \(unavailableFolders) folder\(unavailableFolders == 1 ? "" : "s") unavailable"
        }
        return text
    }
}

// MARK: - One row

struct AssetRow: View {
    var entry: AssetEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isModel ? "waveform" : "hifispeaker.2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(entry.isModel ? ComponentCategory.amp.accent : ComponentCategory.cab.accent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(entry.relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.isModel ? "Model" : "IR")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
                Text(entry.modified.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: Metrics.minTouchTarget)
        .help(help)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts: [String] = [entry.make]
        if let model = entry.model { parts.append(model) }
        if let rate = entry.sampleRate { parts.append(Self.rate(rate)) }
        if let frames = entry.frames { parts.append("\(frames) frames") }
        parts.append(Int64(entry.size).formatted(.byteCount(style: .file)))
        return parts.joined(separator: " · ")
    }

    private var help: String {
        let added = entry.addedAt.formatted(date: .abbreviated, time: .omitted)
        let updated = entry.modified.formatted(date: .abbreviated, time: .omitted)
        var text = "\(entry.fileName) · added \(added) · updated \(updated)"
        if let architecture = entry.architecture { text += " · \(architecture)" }
        return text
    }

    private static func rate(_ value: Double) -> String {
        guard value >= 1000 else { return String(format: "%.0f Hz", value) }
        let kHz = value / 1000
        return kHz == kHz.rounded()
            ? String(format: "%.0f kHz", kHz)
            : String(format: "%.1f kHz", kHz)
    }
}
