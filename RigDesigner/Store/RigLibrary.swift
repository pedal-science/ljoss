import Foundation
import Observation

/// The user's saved rigs.
///
/// One JSON file per rig rather than a single library file: a rig that fails to
/// decode then costs the user that rig, not their whole library, and duplicate
/// and delete become single file operations.
@MainActor
@Observable
final class RigLibrary: RigProviding {

    private(set) var rigs: [Rig] = []
    /// Set when a load or save fails, so the UI can say so rather than fail silently.
    private(set) var lastError: String?

    private let directory: URL
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    // MARK: - Setup

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL.temporaryDirectory
            self.directory = base
                .appending(path: "RigDesigner", directoryHint: .isDirectory)
                .appending(path: "Rigs", directoryHint: .isDirectory)
        }
        load()
    }

    // The spelling of a rig file lives in `RigJSON`, not here, because the export writes one
    // too and the two must agree. See `Store/RigJSON.swift`.

    private func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).rig.json")
    }

    // MARK: - Loading

    func load() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasSuffix(".rig.json") }

            var loaded: [Rig] = []
            for file in files {
                guard let data = try? Data(contentsOf: file),
                      var rig = try? RigJSON.decode(data) else { continue }
                rig.normalize()          // tolerate anything hand-edited or written by an older build
                loaded.append(rig)
            }

            if loaded.isEmpty {
                loaded = RigFactory.starterRigs()
                for rig in loaded { writeNow(rig) }
            }
            rigs = loaded.sorted { $0.modifiedAt > $1.modifiedAt }
            lastError = nil
        } catch {
            lastError = "Could not read your rigs: \(error.localizedDescription)"
            rigs = RigFactory.starterRigs()
        }
    }

    // MARK: - Mutating the library

    func rig(id: UUID) -> Rig? { rigs.first { $0.id == id } }

    /// Replace a rig and schedule a debounced write. Called on every edit.
    func update(_ rig: Rig, touchModified: Bool = true) {
        var copy = rig
        if touchModified { copy.modifiedAt = Date() }
        if let i = rigs.firstIndex(where: { $0.id == copy.id }) {
            rigs[i] = copy
        } else {
            rigs.append(copy)
        }
        scheduleSave(copy)
    }

    @discardableResult
    func createRig(name: String? = nil, layout: RigLayout = .single) -> Rig {
        let rig = RigFactory.emptyRig(name: name ?? uniqueName(basedOn: "New Rig"), layout: layout)
        rigs.insert(rig, at: 0)
        writeNow(rig)
        return rig
    }

    @discardableResult
    func duplicate(_ rig: Rig) -> Rig {
        var copy = rig
        copy.id = UUID()
        copy.name = uniqueName(basedOn: rig.name)
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        // Fresh identity for every node, so the two rigs never share element ids.
        copy.chains = rig.chains.map { chain in
            var c = chain
            c.id = UUID()
            c.input.id = UUID()
            c.output.id = UUID()
            c.elements = Self.reidentify(chain.elements)
            return c
        }
        if let i = rigs.firstIndex(where: { $0.id == rig.id }) {
            rigs.insert(copy, at: i + 1)
        } else {
            rigs.insert(copy, at: 0)
        }
        writeNow(copy)
        return copy
    }

    private static func reidentify(_ elements: [ChainElement]) -> [ChainElement] {
        elements.map { element in
            switch element {
            case .block(var b):
                b.id = UUID()
                return .block(b)
            case .parallel(var p):
                p.id = UUID()
                p.lanes = p.lanes.map { lane in
                    var l = lane
                    l.id = UUID()
                    l.elements = reidentify(lane.elements)
                    return l
                }
                return .parallel(p)
            }
        }
    }

    func delete(_ rig: Rig) {
        pendingSaves[rig.id]?.cancel()
        pendingSaves[rig.id] = nil
        rigs.removeAll { $0.id == rig.id }
        try? FileManager.default.removeItem(at: url(for: rig.id))
    }

    func rename(_ rig: Rig, to newName: String) {
        var copy = rig
        copy.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.name.isEmpty { copy.name = "Untitled Rig" }
        update(copy)
    }

    private func uniqueName(basedOn name: String) -> String {
        let existing = Set(rigs.map(\.name))
        guard existing.contains(name) else { return name }
        var n = 2
        while existing.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    // MARK: - Writing

    /// Coalesce the flurry of edits a drag produces into one write.
    private func scheduleSave(_ rig: Rig) {
        pendingSaves[rig.id]?.cancel()
        pendingSaves[rig.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.writeNow(rig)
            self?.pendingSaves[rig.id] = nil
        }
    }

    /// Write every pending change immediately — on backgrounding or quit.
    func flush() {
        for (id, task) in pendingSaves {
            task.cancel()
            if let rig = rigs.first(where: { $0.id == id }) { writeNow(rig) }
        }
        pendingSaves.removeAll()
    }

    private func writeNow(_ rig: Rig) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try RigJSON.encode(rig)
            // .atomic keeps a half-written file from ever replacing a good one.
            try data.write(to: url(for: rig.id), options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not save “\(rig.name)”: \(error.localizedDescription)"
        }
    }
}
