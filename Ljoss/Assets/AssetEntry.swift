import Foundation

// The local library of NAM models and impulse responses.
//
// This is *this app's* list of what is on the user's disk — the device has its own
// library, listed by `engine.assets`, and a rig names things in **that** one. The two
// are deliberately separate for now: nothing here is sent to namchain, and the
// inspector keeps picking from the device's ids (`docs/ASSETS.md`).
//
// These are the values the app works with: they cross into the scan's detached task and
// they are what the ordering sorts. What holds them between launches is `AssetStore`.

// MARK: - A folder the library is kept in

/// One configured folder to scan.
///
/// The bookmark is what makes a folder survive a relaunch: on iOS the app's container
/// path changes between launches, so a remembered path is a memory of where the folder
/// *was*. The path is still stored, because it is what a row shows and what macOS —
/// which is not sandboxed — actually needs.
struct AssetRoot: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var path: String
    var bookmark: Data?
    /// Whether `bookmark` was made with a security scope, which decides the options it
    /// has to be resolved with.
    var isSecurityScoped: Bool
    var addedAt: Date

    init(id: UUID = UUID(),
         path: String,
         bookmark: Data? = nil,
         isSecurityScoped: Bool = false,
         addedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.isSecurityScoped = isSecurityScoped
        self.addedAt = addedAt
    }

    var url: URL { URL(filePath: path, directoryHint: .isDirectory) }

    /// The folder's own name, which is what a row and the path grouping show.
    var label: String {
        let name = url.lastPathComponent
        return name.isEmpty ? path : name
    }
}

// MARK: - One file

/// One model or impulse response found in a configured folder.
///
/// Every field except the identity is what the file said about itself, or nil. A rate
/// or a frame count that could not be read is **nil rather than zero**, which is the
/// same rule the daemon's `engine.assets` keeps: a number a palette renders is worse
/// than a dash.
struct AssetEntry: Codable, Hashable, Sendable, Identifiable {
    var rootID: UUID
    /// The path under its root, extension included: `tweed/deluxe.nam`.
    var relative: String
    var kind: AssetKind
    /// `metadata.name`, or the file's own name when it did not say.
    var name: String
    /// The brand, guessed by `MakeHeuristics` when the file did not say.
    var make: String
    var model: String?
    var architecture: String?
    var sampleRate: Double?
    var channels: Int?
    var frames: Int?
    var size: Int
    /// The file's own modification date. This is what "Updated" sorts on.
    var modified: Date
    /// When this app first saw the file. Preserved across rescans and edits.
    var addedAt: Date

    /// Identity is *where the file sits in the library*, not where the filesystem
    /// happens to mount it: a container path that changes between launches would
    /// otherwise make the whole library look removed and re-added.
    var id: String { "\(rootID.uuidString)/\(relative)" }

    var fileName: String {
        guard let slash = relative.lastIndex(of: "/") else { return relative }
        return String(relative[relative.index(after: slash)...])
    }

    /// The folder this file is in, relative to its root — empty when it is at the root.
    var directory: String {
        guard let slash = relative.lastIndex(of: "/") else { return "" }
        return String(relative[..<slash])
    }

    /// The id a document would name it by, if it were the device's library: the path
    /// under the root with the extension removed (`docs/assets.md`, namchain).
    var libraryID: String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return relative }
        let ext = fileName[fileName.index(after: dot)...]
        return String(relative.dropLast(ext.count + 1))
    }

    /// Just the file's name without its extension, for the tooltip and for tests.
    var fileStem: String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        return String(fileName[..<dot])
    }

    var isModel: Bool { kind == .model }
}

// MARK: - What is on disk

/// The whole library as an older build stored it: the folders, and what was last found
/// in them.
///
/// Nothing writes this any more — SwiftData holds the library (`AssetStore`) — but a build
/// before the store wrote it to `AssetLibrary.json`, and it is read once and deleted,
/// because the folder list and the day each file was first seen are the two things a
/// rescan cannot rebuild. The `Codable` conformances above are what read it; they are kept
/// for this and for nothing else.
struct AssetSnapshot: Codable, Sendable {
    var version: Int = 1
    var roots: [AssetRoot] = []
    var entries: [AssetEntry] = []
    var savedAt: Date = .distantPast
}

extension AssetSnapshot {
    /// Read the JSON an older build wrote.
    ///
    /// Here rather than in the store so the old format is assertable without a SwiftData
    /// container (`Tests/AssetTests.swift`), and so the date strategy the writer used is
    /// stated beside the fields it applies to rather than at one call site.
    static func decodeLegacy(_ data: Data) throws -> AssetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AssetSnapshot.self, from: data)
    }
}

// MARK: - Reading a kind back

/// An unrecognised kind is read as a model rather than throwing the whole snapshot
/// away — the same forward-compatibility argument `docs/ARCHITECTURE.md` makes for
/// `Block.componentID` being a `String`: a file written by a build that knows a kind
/// this one does not must not cost the user their folder list.
///
/// Nothing on the wire depends on this: a document stores the chosen asset as a
/// `String` parameter value, not as an `AssetKind`.
extension AssetKind: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AssetKind(rawValue: raw) ?? .model
    }
}
