import Foundation
import SwiftData

// The library on disk, as SwiftData.
//
// The value types in `AssetEntry.swift` are what the app works with: they cross into the
// scan's detached task, they are what the ordering sorts and what the local engine reads
// to pick the daemon's model folder. The two records here exist to be stored, and the
// conversion happens at this boundary — see `docs/ASSETS.md`.

// MARK: - One folder, stored

/// One configured folder, as SwiftData holds it.
@Model
final class AssetRootRecord {
    @Attribute(.unique) var id: UUID
    var path: String
    var bookmark: Data?
    var isSecurityScoped: Bool
    var addedAt: Date

    init(_ root: AssetRoot) {
        id = root.id
        path = root.path
        bookmark = root.bookmark
        isSecurityScoped = root.isSecurityScoped
        addedAt = root.addedAt
    }

    var value: AssetRoot {
        AssetRoot(id: id, path: path, bookmark: bookmark,
                  isSecurityScoped: isSecurityScoped, addedAt: addedAt)
    }

    /// Take everything but the identity from `root`. A folder keeps its row, and so keeps
    /// the entries that name it, when only its path has moved.
    func write(_ root: AssetRoot) {
        path = root.path
        bookmark = root.bookmark
        isSecurityScoped = root.isSecurityScoped
        addedAt = root.addedAt
    }
}

// MARK: - One file, stored

/// One model or impulse response, as SwiftData holds it.
@Model
final class AssetEntryRecord {
    @Attribute(.unique) var id: String
    var rootID: UUID
    /// The path under its root, extension included: `tweed/deluxe.nam`.
    var relative: String
    /// `AssetKind.rawValue`.
    ///
    /// Stored as a string rather than as the enum so that a kind written by a build that
    /// knows one this one does not reads back as a model, rather than costing the user
    /// their library — the rule the JSON store kept, for the same reason
    /// (`docs/ARCHITECTURE.md` makes the same argument for `Block.componentID`).
    var kindRaw: String
    var name: String
    var make: String
    var model: String?
    var architecture: String?
    var sampleRate: Double?
    var channels: Int?
    var frames: Int?
    var size: Int
    var modified: Date
    var addedAt: Date

    init(_ entry: AssetEntry) {
        id = entry.id
        rootID = entry.rootID
        relative = entry.relative
        kindRaw = entry.kind.rawValue
        name = entry.name
        make = entry.make
        model = entry.model
        architecture = entry.architecture
        sampleRate = entry.sampleRate
        channels = entry.channels
        frames = entry.frames
        size = entry.size
        modified = entry.modified
        addedAt = entry.addedAt
    }

    var value: AssetEntry {
        AssetEntry(rootID: rootID, relative: relative,
                   kind: AssetKind(rawValue: kindRaw) ?? .model,
                   name: name, make: make, model: model, architecture: architecture,
                   sampleRate: sampleRate, channels: channels, frames: frames,
                   size: size, modified: modified, addedAt: addedAt)
    }

    /// Take everything but the identity from `entry`.
    func write(_ entry: AssetEntry) {
        kindRaw = entry.kind.rawValue
        name = entry.name
        make = entry.make
        model = entry.model
        architecture = entry.architecture
        sampleRate = entry.sampleRate
        channels = entry.channels
        frames = entry.frames
        size = entry.size
        modified = entry.modified
        addedAt = entry.addedAt
    }
}

// MARK: - The store

/// The folders and what the last scan found in them, held in SwiftData.
///
/// Main-actor only, because SwiftData's `mainContext` is: the walk runs off the actor on
/// `AssetEntry` values, and what comes back is a handful of rows that differ.
@MainActor
final class AssetStore {

    /// What the store file is called, beside the rigs.
    static let fileName = "AssetLibrary.store"

    private let container: ModelContainer

    /// Whether anything written here survives the session. False for the in-memory store,
    /// which is what stops a library that could not be opened from deleting a file it
    /// cannot take the place of.
    let isPersistent: Bool

    /// Open the store in `directory`, creating the file if it is not there yet; or, with
    /// no directory, one that is not written anywhere.
    ///
    /// Throws rather than starting empty: whether a library that cannot be read is worth
    /// saying so about is the caller's decision, and `open(directory:)` is what it does
    /// about it.
    init(directory: URL?) throws {
        let schema = Schema([AssetRootRecord.self, AssetEntryRecord.self])
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: Self.fileName)
            container = try ModelContainer(for: schema, configurations: ModelConfiguration(url: url))
            isPersistent = true
        } else {
            container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            isPersistent = false
        }
    }

    /// The store for a library in `directory`, and what went wrong if its file could not
    /// be opened.
    ///
    /// An in-memory store as the fallback, so a library that cannot be remembered is still
    /// one the user can use this session — and so the page can say what is wrong rather
    /// than the app failing to start.
    static func open(directory: URL) -> (store: AssetStore, failure: Error?) {
        do {
            return (try AssetStore(directory: directory), nil)
        } catch {
            return (inMemory(), error)
        }
    }

    /// A store that is not written anywhere.
    ///
    /// `try!` is deliberate: an in-memory container has no file to be missing, corrupt or
    /// read-only, so the only thing that can fail here is the schema above — a mistake in
    /// this file rather than a state the app should carry on through.
    static func inMemory() -> AssetStore { try! AssetStore(directory: nil) }

    private var context: ModelContext { container.mainContext }

    // MARK: - Reading it back

    /// The folders, in the order the user added them.
    ///
    /// Sorted rather than left in fetch order, which SwiftData does not promise: the list on
    /// the page is the user's, and `localEngineModelsRoot` hands the daemon the *first*
    /// folder that holds a model, so an order that changed between launches would change
    /// which folder the daemon is given. The id breaks a tie that two folders added in the
    /// same instant would otherwise leave to chance.
    func roots() throws -> [AssetRoot] {
        try context.fetch(FetchDescriptor<AssetRootRecord>())
            .map(\.value)
            .sorted { ($0.addedAt, $0.id.uuidString) < ($1.addedAt, $1.id.uuidString) }
    }

    /// The files, by id — the order `AssetScan` leaves a scan's result in, so what comes
    /// back here and what comes back from a walk are the same list in the same order.
    func entries() throws -> [AssetEntry] {
        try context.fetch(FetchDescriptor<AssetEntryRecord>())
            .map(\.value)
            .sorted { $0.id < $1.id }
    }

    // MARK: - Writing it out

    /// Hold what the app now has. Only the rows that differ are touched.
    ///
    /// The baseline is what the store itself holds rather than what the caller last saw,
    /// so a write that failed earlier is corrected by the next one instead of being
    /// remembered as done. One save for both, because the folders and the files in them
    /// belong together — and no save at all when nothing differs, so a launch scan of an
    /// unchanged library leaves the file alone.
    func write(roots newRoots: [AssetRoot], entries newEntries: [AssetEntry]) throws {
        try syncRoots(newRoots)
        try syncEntries(newEntries)
        guard context.hasChanges else { return }
        try context.save()
    }

    private func syncRoots(_ newRoots: [AssetRoot]) throws {
        let records = try context.fetch(FetchDescriptor<AssetRootRecord>())
        var byID: [UUID: AssetRootRecord] = [:]
        for record in records { byID[record.id] = record }

        let kept = Set(newRoots.map(\.id))
        for record in records where !kept.contains(record.id) { context.delete(record) }

        for root in newRoots {
            if let record = byID[root.id] {
                // Compared before writing, like the entries: assigning a field marks the row
                // dirty whether or not the value actually changed, and a folder that has
                // not moved is most of them.
                if record.value != root { record.write(root) }
            } else {
                context.insert(AssetRootRecord(root))
            }
        }
    }

    private func syncEntries(_ newEntries: [AssetEntry]) throws {
        let records = try context.fetch(FetchDescriptor<AssetEntryRecord>())
        var byID: [String: AssetEntryRecord] = [:]
        for record in records { byID[record.id] = record }

        let change = AssetSync.changes(from: records.map(\.value), to: newEntries)
        for id in change.removedIDs {
            if let record = byID[id] { context.delete(record) }
        }
        for entry in change.updated { byID[entry.id]?.write(entry) }
        for entry in change.inserted { context.insert(AssetEntryRecord(entry)) }
    }

    // MARK: - What an older build left behind

    /// Bring the JSON an older build wrote into this store, once, and delete it.
    ///
    /// - Returns: how many files were brought across; `0` when there was nothing to do.
    ///
    /// Three guards, each of which has to hold for the file to be removed:
    ///
    /// - The store has to be one that keeps what it is given. Importing into the in-memory
    ///   fallback and deleting the file would be losing the user's folder list to a store
    ///   that was only ever a stand-in for it.
    /// - The store has to have never held anything. Otherwise a library the user emptied
    ///   deliberately would come back on the next launch, which is the one outcome worse
    ///   than an empty list.
    /// - The file has to be there at all, and has to decode: a corrupt one is left in
    ///   place, and the message is `AssetLibrary`'s to show.
    @discardableResult
    func importLegacyJSON(at url: URL) throws -> Int {
        guard isPersistent else { return 0 }
        guard try context.fetchCount(FetchDescriptor<AssetRootRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<AssetEntryRecord>()) == 0 else { return 0 }
        guard let data = try? Data(contentsOf: url) else { return 0 }

        let snapshot = try AssetSnapshot.decodeLegacy(data)
        try write(roots: snapshot.roots, entries: snapshot.entries)
        try? FileManager.default.removeItem(at: url)
        return snapshot.entries.count
    }
}
