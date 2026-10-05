import Foundation
import Observation

/// The user's own models and impulse responses: which folders hold them, what was found
/// in them, and what the last scan did.
///
/// It is **not** the device's library. A rig still names its model and impulse response
/// by the id `engine.assets` gave it; this is a listing of the user's own files, and
/// nothing here is sent anywhere — see `docs/ASSETS.md`.
///
/// What it holds is stored in SwiftData (`AssetStore`) and read back when the app starts,
/// which is also the scan's cache: a file whose size and modification date match what was
/// stored is carried over without being read again.
@MainActor
@Observable
final class AssetLibrary {

    /// What the folders are doing, which is what the indicator shows.
    enum ScanState: Equatable, Sendable {
        case idle
        case scanning
        case finished(AssetScanStats)

        var isScanning: Bool { self == .scanning }
    }

    private(set) var roots: [AssetRoot] = []
    private(set) var entries: [AssetEntry] = []
    /// Folders that contributed nothing, and why.
    private(set) var issues: [AssetRootIssue] = []
    private(set) var state: ScanState = .idle
    /// Where a load, a save or a folder went wrong, so the page can say so rather than
    /// fail silently.
    private(set) var lastError: String?

    /// How long the finished message stays before clearing. The row keeps its size
    /// throughout, so nothing moves when it goes.
    private static let finishedLinger = Duration.seconds(5)

    private let directory: URL
    /// The library between launches: the store holds it, the value types above are what
    /// everything reads — the scan is handed them as its cache, and they are what comes
    /// back when the app starts (`docs/ASSETS.md`).
    private let store: AssetStore
    private var scanTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    /// Bumped for every scan, so a superseded scan's result is dropped rather than
    /// published over a newer one.
    private var generation = 0
    private var hasScanned = false

    /// What an older build wrote the library to, before the store existed.
    private static let legacyFileName = "AssetLibrary.json"

    // MARK: - Setup

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            // Sibling of the rigs, and moved out of the folder's old name with them —
            // whichever of the two is built first does the move, and the second is a no-op.
            AppDirectories.migrateLegacyFolder()
            self.directory = AppDirectories.support()
        }

        // A store whose file cannot be opened is worth saying so about, and not worth
        // failing over: the library still works for this session, out of memory, and the
        // complaint below is shown where the page can see it.
        let opened = AssetStore.open(directory: self.directory)
        store = opened.store
        load()
        if let failure = opened.failure {
            lastError = "Your model folders could not be opened: \(failure.localizedDescription)"
        }
    }

    // MARK: - Bookmarks

    /// macOS wants the scope spelled out on a bookmark it will resolve later. iOS has no
    /// such option: a URL from the picker carries its scope implicitly, and asking for
    /// one is a compile error rather than a runtime one — which is how this was found.
    private static var scopedCreation: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        #else
        []
        #endif
    }

    private static var scopedResolution: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope, .withoutUI]
        #else
        [.withoutUI]
        #endif
    }

    /// Write the folders, and what was found in them, into the store.
    ///
    /// Only the rows that differ are touched, so this is safe to call from every path
    /// that changes either list, and saving the same library twice writes nothing at all
    /// (`AssetSync`).
    func save() {
        do {
            try store.write(roots: roots, entries: entries)
            // A write that went somewhere answers whatever went wrong before it. A write
            // to the in-memory fallback has saved nothing, so a complaint about that stays
            // where the user can see it.
            if store.isPersistent { lastError = nil }
        } catch {
            lastError = "Your model folders could not be saved: \(error.localizedDescription)"
        }
    }

    func load() {
        do {
            // A library an older build wrote as JSON is brought across once, into a store
            // that has never held anything, and the file is deleted afterwards: leaving it
            // would resurrect the folders of a user who has deliberately emptied the
            // library, and a folder list is the one thing a rescan cannot rebuild.
            try store.importLegacyJSON(at: directory.appending(path: Self.legacyFileName))
            roots = try store.roots()
            entries = try store.entries()
            refreshRootPaths()
            lastError = nil
        } catch {
            roots = []
            entries = []
            lastError = "Your model folders could not be read back: \(error.localizedDescription)"
        }
    }

    // MARK: - Folders

    /// Add a folder. Returns a complaint when it could not be remembered, and nil when
    /// it was added.
    @discardableResult
    func addFolder(_ url: URL) -> String? {
        let resolved = url.standardizedFileURL
        let path = resolved.path(percentEncoded: false)
        guard !roots.contains(where: { resolve($0).path(percentEncoded: false) == path }) else {
            return "That folder is already in the list."
        }

        let accessed = resolved.startAccessingSecurityScopedResource()
        defer { if accessed { resolved.stopAccessingSecurityScopedResource() } }

        var bookmark: Data?
        var isSecurityScoped = false
        if let scoped = try? resolved.bookmarkData(
            options: Self.scopedCreation,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            bookmark = scoped
            isSecurityScoped = true
        } else if let plain = try? resolved.bookmarkData() {
            bookmark = plain
        }

        #if os(iOS)
        // A path is not enough on iOS: the app's container moves between launches, so a
        // folder remembered by path is a folder that is there this session and gone the
        // next. Refusing the add is the honest failure.
        guard bookmark != nil else {
            return "That folder could not be remembered, so it would not survive a relaunch."
        }
        #endif

        roots.append(AssetRoot(path: path, bookmark: bookmark, isSecurityScoped: isSecurityScoped))
        lastError = nil
        save()
        rescan()
        return nil
    }

    /// Forget a folder. Its entries go with it — a file with no folder cannot be shown
    /// or read — and the scan that follows is about what is actually on disk.
    func removeFolder(_ root: AssetRoot) {
        roots.removeAll { $0.id == root.id }
        entries.removeAll { $0.rootID == root.id }
        issues.removeAll { $0.rootID == root.id }
        save()
        rescan()
    }

    /// The folder as it is now.
    ///
    /// The bookmark is what makes a folder survive a relaunch; the stored path is the
    /// fallback, and the whole story on macOS, which is not sandboxed.
    private func resolve(_ root: AssetRoot) -> URL {
        guard let bookmark = root.bookmark else { return root.url }
        // A bookmark made with a scope is normally resolved with one. iOS does not have
        // the option at all — a URL from the picker carries its scope implicitly — so the
        // plain attempt is the one that works there, and it is the second attempt here.
        var attempts: [URL.BookmarkResolutionOptions] = []
        if root.isSecurityScoped { attempts.append(Self.scopedResolution) }
        attempts.append([.withoutUI])

        for options in attempts {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return root.url
    }

    /// A container that moved takes every stored path with it, so the paths are
    /// re-derived from the bookmarks whenever the library is read back.
    private func refreshRootPaths() {
        var changed = false
        for index in roots.indices {
            let path = resolve(roots[index]).path(percentEncoded: false)
            if path != roots[index].path {
                roots[index].path = path
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Scanning

    /// Scan now, dropping the result of any scan still running.
    func rescan() {
        generation += 1
        let generation = generation
        scanTask?.cancel()
        scanTask = nil
        clearTask?.cancel()
        clearTask = nil

        guard !roots.isEmpty else {
            entries = []
            issues = []
            state = .idle
            save()
            return
        }

        let scanRoots = roots.map { ScanRoot(id: $0.id, url: resolve($0)) }
        let previous = entries
        let now = Date()
        state = .scanning

        scanTask = Task { [weak self] in
            // Off the main actor, in one hop: the walk is filesystem work with no
            // suspension points, which is also what makes the security-scoped access
            // start and stop inside the folders it belongs to.
            let outcome = await Task.detached(priority: .utility) {
                AssetScan.run(roots: scanRoots, previous: previous, now: now)
            }.value

            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.entries = outcome.entries
            self.issues = outcome.issues
            self.hasScanned = true
            self.save()
            self.finish(outcome.stats)
        }
    }

    /// Scan once, when the app starts, and wait for it.
    ///
    /// At launch rather than when the page is opened, and awaited rather than merely
    /// started: the local engine picks the folder it gives the daemon's model library
    /// from what the scan found, so a daemon started first would be handed yesterday's
    /// answer. The work is a walk of the folders — files that have not changed are carried
    /// over unread — so a launch costs a directory listing, not a library read.
    ///
    /// Not on a timer, and not when the page opens: a second window finds the work already
    /// done, and nothing here watches a folder — the daemon's rule, for the same reason
    /// (`docs/ASSETS.md`).
    func scanAtLaunch() async {
        if !hasScanned, !state.isScanning { rescan() }
        await scanTask?.value
    }

    private func finish(_ stats: AssetScanStats) {
        state = .finished(stats)
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.finishedLinger)
            guard let self, !Task.isCancelled, case .finished = self.state else { return }
            self.state = .idle
        }
    }

    // MARK: - What the page shows

    /// Folder names for the path grouping, disambiguated when two folders share one.
    var rootLabels: [UUID: String] {
        var used: [String: Int] = [:]
        var labels: [UUID: String] = [:]
        for root in roots {
            let base = root.label
            let count = (used[base] ?? 0) + 1
            used[base] = count
            labels[root.id] = count == 1 ? base : "\(base) (\(count))"
        }
        return labels
    }

    /// Why a folder contributed nothing, if it did.
    func issue(for root: AssetRoot) -> String? {
        issues.first { $0.rootID == root.id }?.message
    }

    var modelCount: Int { entries.filter(\.isModel).count }
    var irCount: Int { entries.count - modelCount }
}
