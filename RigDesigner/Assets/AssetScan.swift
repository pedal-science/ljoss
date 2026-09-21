import Foundation

/// One folder, resolved to somewhere the filesystem can read.
///
/// The library keeps `AssetRoot`s with bookmarks; this is what a scan actually needs,
/// so the scan itself stays a pure function of URLs and can run off the main actor.
struct ScanRoot: Hashable, Sendable {
    var id: UUID
    var url: URL
}

/// What one pass over the folders did.
struct AssetScanStats: Equatable, Sendable {
    /// Files found now.
    var files = 0
    var models = 0
    var irs = 0
    /// Files that were not in the list before.
    var added = 0
    /// Files whose size or modification date changed, so their info was read again.
    var updated = 0
    /// Entries whose file is no longer in any folder.
    var removed = 0
    /// Files whose headers were actually read by this pass. `0` is a scan that read
    /// nothing, which is what makes "only re-read what changed" assertable rather than
    /// a claim in a comment.
    var parsed = 0
    /// Symlinks, non-regular files, and anything the filesystem refused.
    var skipped = 0

    static let none = AssetScanStats()

    var isEmpty: Bool {
        files == 0 && added == 0 && updated == 0 && removed == 0
    }

    /// One line, for the indicator.
    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if updated > 0 { parts.append("\(updated) updated") }
        if removed > 0 { parts.append("\(removed) removed") }
        let changed = parts.isEmpty ? "nothing changed" : parts.joined(separator: ", ")
        return "\(files) file\(files == 1 ? "" : "s") · \(changed)"
    }
}

/// Why a configured folder contributed nothing. A folder that is missing, unreadable,
/// or a file rather than a directory is **not** a scan failure — it is an empty library
/// with an explanation, the same distinction `docs/assets.md` draws for the daemon.
struct AssetRootIssue: Identifiable, Equatable, Sendable {
    var rootID: UUID
    var message: String
    var id: UUID { rootID }
}

/// The library after one pass.
struct AssetScanOutcome: Sendable {
    var entries: [AssetEntry] = []
    var stats = AssetScanStats()
    var issues: [AssetRootIssue] = []
}

/// Walking the folders, and reconciling what is there against what was there.
///
/// Synchronous on purpose: it runs inside one detached task, where security-scoped
/// access can be started and stopped around each folder without an await in between.
enum AssetScan {

    /// The extensions a folder is read for. A `.wav` is an impulse response; a `.nam`
    /// can be either, so its own architecture decides (`NAMSniff`).
    private static let extensions: Set<String> = ["nam", "wav"]

    /// Reconcile the folders with the previous listing.
    ///
    /// - Parameters:
    ///   - previous: what the last pass saw. A file that matches it — same size, same
    ///     modification date — is carried over unread, which is what makes a second
    ///     scan of an unchanged library cost nothing.
    ///   - now: what a newly found file's `addedAt` becomes.
    static func run(roots: [ScanRoot], previous: [AssetEntry], now: Date) -> AssetScanOutcome {
        var outcome = AssetScanOutcome()
        var previousByID: [String: AssetEntry] = [:]
        for entry in previous { previousByID[entry.id] = entry }

        var seenPaths = Set<String>()
        var foundIDs = Set<String>()
        var refused = 0

        for root in roots {
            let accessed = root.url.startAccessingSecurityScopedResource()
            defer { if accessed { root.url.stopAccessingSecurityScopedResource() } }

            let rootPath = path(of: root.url)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) else {
                outcome.issues.append(AssetRootIssue(rootID: root.id, message: "Folder not found"))
                continue
            }
            guard isDirectory.boolValue else {
                outcome.issues.append(AssetRootIssue(rootID: root.id, message: "This is a file, not a folder"))
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: root.url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                             .fileSizeKey, .contentModificationDateKey],
                // Hidden names and bundles: the daemon's scan skips the first, and a
                // bundle's contents are nobody's model library.
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    refused += 1
                    return true
                }
            ) else {
                outcome.issues.append(AssetRootIssue(rootID: root.id, message: "Folder could not be read"))
                continue
            }

            for case let file as URL in enumerator {
                guard let relative = relativePath(of: file, under: rootPath) else { continue }
                guard extensions.contains(extensionOf(relative)) else { continue }

                // Two configured folders where one is inside the other would otherwise
                // list the same file twice. The first folder in the list keeps it.
                let filePath = path(of: file)
                guard seenPaths.insert(filePath).inserted else { continue }

                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                                     .fileSizeKey, .contentModificationDateKey]),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true else {
                    // A link out of the folder makes "a file in this library" a promise
                    // the list cannot keep, which is the rule the daemon's scan keeps too.
                    refused += 1
                    continue
                }

                let size = values.fileSize ?? 0
                let modified = values.contentModificationDate ?? now
                let id = "\(root.id.uuidString)/\(relative)"
                foundIDs.insert(id)

                if let cached = previousByID[id], cached.size == size, cached.modified == modified {
                    outcome.entries.append(cached)
                    continue
                }

                outcome.entries.append(describe(url: file, relative: relative, rootID: root.id,
                                                size: size, modified: modified,
                                                addedAt: previousByID[id]?.addedAt ?? now))
                outcome.stats.parsed += 1
                if previousByID[id] == nil { outcome.stats.added += 1 } else { outcome.stats.updated += 1 }
            }
        }

        outcome.entries.sort { $0.id < $1.id }
        outcome.stats.files = outcome.entries.count
        outcome.stats.models = outcome.entries.filter(\.isModel).count
        outcome.stats.irs = outcome.entries.filter { !$0.isModel }.count
        outcome.stats.removed = previous.filter { !foundIDs.contains($0.id) }.count
        outcome.stats.skipped = refused
        return outcome
    }

    // MARK: - One file

    /// Read what a file says about itself, and guess the rest.
    private static func describe(url: URL, relative: String, rootID: UUID,
                                 size: Int, modified: Date, addedAt: Date) -> AssetEntry {
        let stem = stem(of: relative)
        let directories = directoryComponents(of: relative)

        if extensionOf(relative) == "wav" {
            let info = NAMSniff.wav(at: url)
            return AssetEntry(rootID: rootID, relative: relative, kind: .ir,
                              name: stem,
                              make: MakeHeuristics.make(claimed: nil, fileStem: stem, directories: directories),
                              model: nil, architecture: nil,
                              sampleRate: info?.sampleRate, channels: info?.channels, frames: info?.frames,
                              size: size, modified: modified, addedAt: addedAt)
        }

        let info = NAMSniff.nam(at: url)
        return AssetEntry(rootID: rootID, relative: relative,
                          kind: info.architecture == NAMSniff.irArchitecture ? .ir : .model,
                          name: info.name ?? stem,
                          make: MakeHeuristics.make(claimed: info.make, fileStem: stem, directories: directories),
                          model: info.model, architecture: info.architecture,
                          sampleRate: info.sampleRate, channels: nil, frames: nil,
                          size: size, modified: modified, addedAt: addedAt)
    }

    // MARK: - Paths

    private static func path(of url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }

    private static func relativePath(of file: URL, under root: String) -> String? {
        let filePath = path(of: file)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard filePath.hasPrefix(prefix) else { return nil }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func extensionOf(_ relative: String) -> String {
        guard let dot = relative.lastIndex(of: ".") else { return "" }
        return String(relative[relative.index(after: dot)...]).lowercased()
    }

    private static func stem(of relative: String) -> String {
        let name = relative.split(separator: "/").last.map(String.init) ?? relative
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    private static func directoryComponents(of relative: String) -> [String] {
        relative.split(separator: "/").dropLast().map(String.init)
    }
}
