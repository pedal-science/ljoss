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

/// How far the reading pass has got.
///
/// `total` is what the listing pass counted as needing to be opened, so it is known
/// before the first file is read: a scan that finds ten files and has to read four of
/// them reports `0/4`, then `1/4`, and so on.
struct AssetScanProgress: Equatable, Sendable {
    var read: Int
    var total: Int
}

/// One file the listing pass decided has to be opened — new, or changed since last time.
struct ScanCandidate: Hashable, Sendable {
    var rootID: UUID
    var relative: String
    var url: URL
    var size: Int
    var modified: Date
    var addedAt: Date
    /// New since the previous listing, as opposed to an existing file that changed.
    var isNew: Bool

    var id: String { "\(rootID.uuidString)/\(relative)" }
}

/// What walking the folders found, before any file has been opened.
struct ScanListing: Sendable {
    /// Files that must be opened: new, or changed since the previous listing.
    var candidates: [ScanCandidate] = []
    /// Entries the previous listing already described, carried over unread.
    var carried: [AssetEntry] = []
    var issues: [AssetRootIssue] = []
    /// Entries whose file is no longer in any folder.
    var removed = 0
    /// Symlinks, non-regular files, and anything the filesystem refused.
    var skipped = 0

    /// How many files have to be opened. This is the progress bar's maximum.
    var toRead: Int { candidates.count }
    var added: Int { candidates.filter(\.isNew).count }
    var updated: Int { candidates.count - added }
}

/// Walking the folders, and reading the files that have to be opened.
///
/// Two passes, on purpose. The first is a directory walk that reads only metadata, and
/// it is what answers "how many files need opening" — the number a progress bar needs
/// before the first byte is read. The second opens exactly those files, several at a
/// time, and reports each one as it lands.
enum AssetScan {

    /// The extensions a folder is read for. A `.wav` is an impulse response; a `.nam`
    /// can be either, so its own architecture decides (`NAMSniff`).
    private static let extensions: Set<String> = ["nam", "wav"]

    /// How many files are opened at once.
    ///
    /// Reading a header is a little I/O and a little JSON, so the machine's own width is
    /// the useful number: at least two, so a one-core machine still overlaps a read with
    /// the next open, and at most eight, past which the extra concurrent opens buy file
    /// descriptors rather than throughput.
    static var parallelism: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8)
    }

    // MARK: - Pass one: the folders

    /// Walk the folders and work out what has to be opened, without opening anything.
    static func listing(roots: [ScanRoot], previous: [AssetEntry], now: Date) -> ScanListing {
        let scopes = startAccess(roots)
        defer { stopAccess(scopes) }
        return walk(roots: roots, previous: previous, now: now)
    }

    /// The walk itself, for a caller that already holds the folders' security scopes.
    private static func walk(roots: [ScanRoot], previous: [AssetEntry], now: Date) -> ScanListing {
        var listing = ScanListing()
        var previousByID: [String: AssetEntry] = [:]
        for entry in previous { previousByID[entry.id] = entry }

        var seenPaths = Set<String>()
        var foundIDs = Set<String>()
        var refused = 0

        for root in roots {
            let rootPath = path(of: root.url)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory) else {
                listing.issues.append(AssetRootIssue(rootID: root.id, message: "Folder not found"))
                continue
            }
            guard isDirectory.boolValue else {
                listing.issues.append(AssetRootIssue(rootID: root.id, message: "This is a file, not a folder"))
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
                listing.issues.append(AssetRootIssue(rootID: root.id, message: "Folder could not be read"))
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

                // Size and modification date are the whole cache key: a file that matches
                // is carried over unread, which is what makes a second scan of an
                // unchanged library have nothing at all to open.
                if let cached = previousByID[id], cached.size == size, cached.modified == modified {
                    listing.carried.append(cached)
                    continue
                }

                listing.candidates.append(ScanCandidate(
                    rootID: root.id, relative: relative, url: file,
                    size: size, modified: modified,
                    addedAt: previousByID[id]?.addedAt ?? now,
                    isNew: previousByID[id] == nil
                ))
            }
        }

        // The order the files have to be read in should not be the order the filesystem
        // happened to hand them over in.
        listing.candidates.sort { $0.id < $1.id }
        listing.removed = previous.filter { !foundIDs.contains($0.id) }.count
        listing.skipped = refused
        return listing
    }

    // MARK: - Pass two: the files

    /// Read one file's own description. Pure, so it can run on any thread.
    static func read(_ candidate: ScanCandidate) -> AssetEntry {
        describe(url: candidate.url, relative: candidate.relative, rootID: candidate.rootID,
                 size: candidate.size, modified: candidate.modified, addedAt: candidate.addedAt)
    }

    /// Put a listing and the entries read from it back together.
    static func outcome(listing: ScanListing, read: [AssetEntry]) -> AssetScanOutcome {
        var outcome = AssetScanOutcome()
        outcome.entries = listing.carried + read
        outcome.entries.sort { $0.id < $1.id }
        outcome.issues = listing.issues
        outcome.stats.files = outcome.entries.count
        outcome.stats.models = outcome.entries.filter(\.isModel).count
        outcome.stats.irs = outcome.entries.count - outcome.stats.models
        outcome.stats.added = listing.added
        outcome.stats.updated = listing.updated
        outcome.stats.removed = listing.removed
        outcome.stats.parsed = read.count
        outcome.stats.skipped = listing.skipped
        return outcome
    }

    // MARK: - Both passes

    /// List the folders, then read what has to be read, one file at a time.
    ///
    /// The whole scan on a single thread. The parallel form below gives the same answer;
    /// this is the one the assertions use, where determinism is worth more than speed.
    static func run(roots: [ScanRoot], previous: [AssetEntry], now: Date) -> AssetScanOutcome {
        let scopes = startAccess(roots)
        defer { stopAccess(scopes) }
        let listing = walk(roots: roots, previous: previous, now: now)
        return outcome(listing: listing, read: listing.candidates.map { read($0) })
    }

    /// List the folders, then read what has to be read several files at once, reporting
    /// progress as each one lands.
    ///
    /// Separate from `run` rather than an overload of it: a three-argument call would
    /// resolve to this one from inside an async context, so the two are named apart to
    /// keep the single-threaded form reachable.
    ///
    /// - Parameters:
    ///   - parallelism: how many files may be open at once. Defaults to what the machine
    ///     can usefully do.
    ///   - onProgress: called once with `0/total` as soon as the listing has said how
    ///     many files have to be opened, then once per file read.
    static func runConcurrently(roots: [ScanRoot],
                                previous: [AssetEntry],
                                now: Date,
                                parallelism: Int = AssetScan.parallelism,
                                onProgress: @Sendable (AssetScanProgress) async -> Void = { _ in }) async -> AssetScanOutcome {
        let scopes = startAccess(roots)
        defer { stopAccess(scopes) }

        // Pass one opens nothing, so it is cheap next to what follows — and it is what
        // turns "some files" into "this many have to be read".
        let listing = walk(roots: roots, previous: previous, now: now)
        let total = listing.toRead
        await onProgress(AssetScanProgress(read: 0, total: total))
        guard total > 0 else { return outcome(listing: listing, read: []) }

        let candidates = listing.candidates
        let width = min(max(parallelism, 1), total)
        var read = [AssetEntry?](repeating: nil, count: total)
        var done = 0

        // A sliding window rather than one task per file: at most `width` files are open
        // at any moment, and a new one starts as each finishes.
        await withTaskGroup(of: (Int, AssetEntry).self) { group in
            var next = 0
            while next < width {
                let index = next
                group.addTask { (index, AssetScan.read(candidates[index])) }
                next += 1
            }
            while let (index, entry) = await group.next() {
                read[index] = entry
                done += 1
                await onProgress(AssetScanProgress(read: done, total: total))
                if next < total {
                    let index = next
                    group.addTask { (index, AssetScan.read(candidates[index])) }
                    next += 1
                }
            }
        }

        return outcome(listing: listing, read: read.compactMap { $0 })
    }

    // MARK: - Folder access

    /// Open the security scope of every folder, and return the ones that have to be
    /// closed again.
    ///
    /// Held across both passes rather than around each file: on iOS a file is only
    /// readable while its folder's scope is open, and pass two reads on many threads.
    private static func startAccess(_ roots: [ScanRoot]) -> [URL] {
        var started: [URL] = []
        for root in roots where root.url.startAccessingSecurityScopedResource() {
            started.append(root.url)
        }
        return started
    }

    private static func stopAccess(_ urls: [URL]) {
        for url in urls { url.stopAccessingSecurityScopedResource() }
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
                          gearType: info.gearType,
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
