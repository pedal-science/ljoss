import Foundation

/// How the entries are grouped. `none` is a list with no headings at all.
enum AssetGroupKey: String, CaseIterable, Identifiable, Sendable, Codable {
    case none
    case type
    case path
    case make

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "None"
        case .type: "Type"
        case .path: "Path"
        case .make: "Make"
        }
    }
}

/// How entries are sorted inside a group.
enum AssetSortKey: String, CaseIterable, Identifiable, Sendable, Codable {
    case type
    case filename
    case make
    case name
    case added
    case updated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .type: "Type"
        case .filename: "Filename"
        case .make: "Make"
        case .name: "Name"
        case .added: "Added"
        case .updated: "Updated"
        }
    }
}

/// The four choices, as the view holds them.
struct AssetGrouping: Equatable, Sendable {
    var groupBy: AssetGroupKey = .type
    var thenBy: AssetGroupKey = .make
    var sortBy: AssetSortKey = .make
    var thenSortBy: AssetSortKey = .updated

    /// What the app opens on: grouped by type and then make, sorted by make and then by
    /// what changed most recently. One value rather than four defaults in four places.
    static let standard = AssetGrouping()

    /// The levels actually used. A second level equal to the first — or `none` — adds
    /// nothing: a heading that never varies is not a heading.
    var levels: [AssetGroupKey] {
        var keys: [AssetGroupKey] = []
        if groupBy != .none { keys.append(groupBy) }
        if thenBy != .none, thenBy != groupBy { keys.append(thenBy) }
        return keys
    }

    var sortKeys: [AssetSortKey] {
        thenSortBy == sortBy ? [sortBy] : [sortBy, thenSortBy]
    }
}

/// One heading and what is under it.
struct AssetSection: Identifiable, Equatable, Sendable {
    var id: String
    /// nil for the single untitled section a `none` grouping produces.
    var title: String?
    var entries: [AssetEntry]
}

/// Turning the library into the sections and rows the settings page shows.
///
/// A pure function of the entries, the folder names and the four choices, which is what
/// makes every combination cheap to assert — the ordering rules are the part of this
/// feature that is easiest to get subtly wrong and hardest to notice.
enum AssetOrdering {

    static func sections(_ entries: [AssetEntry], rootLabels: [UUID: String],
                         grouping: AssetGrouping = .standard) -> [AssetSection] {
        let levels = grouping.levels

        var buckets: [[GroupValue]: [AssetEntry]] = [:]
        for entry in entries {
            let key = levels.map { value(of: $0, entry: entry, rootLabels: rootLabels) }
            buckets[key, default: []].append(entry)
        }

        return buckets.keys.sorted(by: ordered).map { key in
            let rows = (buckets[key] ?? []).sorted { comesBefore($0, $1, keys: grouping.sortKeys) }
            return AssetSection(id: key.map(\.id).joined(separator: "|"),
                                title: key.isEmpty ? nil : key.map(\.text).joined(separator: " › "),
                                entries: rows)
        }
    }

    /// "Models" and "Impulse Responses": what the type grouping's headings say.
    static func typeName(_ kind: AssetKind) -> String {
        kind == .model ? "Models" : "Impulse Responses"
    }

    // MARK: - Grouping

    /// One level of a section's key: what it reads, and where it sorts.
    private struct GroupValue: Hashable {
        var text: String
        var id: String
        /// Lower first. `Unknown` is a real group, but it is the one nobody wants at
        /// the top of the list, so it sorts last however it is spelled.
        var rank: Int
    }

    private static func value(of key: AssetGroupKey, entry: AssetEntry,
                              rootLabels: [UUID: String]) -> GroupValue {
        switch key {
        case .none:
            // Never reached: `levels` drops `none`. Here so the switch is total.
            return GroupValue(text: "", id: "", rank: 0)
        case .type:
            return GroupValue(text: typeName(entry.kind), id: entry.kind.rawValue,
                              rank: entry.isModel ? 0 : 1)
        case .path:
            let root = rootLabels[entry.rootID] ?? "Unfiled"
            let text = entry.directory.isEmpty ? root : "\(root)/\(entry.directory)"
            return GroupValue(text: text, id: text.lowercased(), rank: 0)
        case .make:
            return GroupValue(text: entry.make, id: entry.make.lowercased(),
                              rank: entry.make == MakeHeuristics.unknown ? 1 : 0)
        }
    }

    private static func ordered(_ a: GroupValue, _ b: GroupValue) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        return text(a.text, isBefore: b.text)
    }

    private static func ordered(_ a: [GroupValue], _ b: [GroupValue]) -> Bool {
        for (x, y) in zip(a, b) {
            if ordered(x, y) { return true }
            if ordered(y, x) { return false }
        }
        return a.count < b.count
    }

    // MARK: - Sorting

    private static func comesBefore(_ a: AssetEntry, _ b: AssetEntry, keys: [AssetSortKey]) -> Bool {
        for key in keys {
            switch comparison(a, b, by: key) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            @unknown default: continue
            }
        }
        return tieBreak(a, b)
    }

    private static func comparison(_ a: AssetEntry, _ b: AssetEntry, by key: AssetSortKey) -> ComparisonResult {
        switch key {
        case .type:
            guard a.kind != b.kind else { return .orderedSame }
            return a.isModel ? .orderedAscending : .orderedDescending
        case .filename:
            return a.fileName.compare(b.fileName, options: textOptions)
        case .make:
            let aUnknown = a.make == MakeHeuristics.unknown
            let bUnknown = b.make == MakeHeuristics.unknown
            guard aUnknown == bUnknown else { return aUnknown ? .orderedDescending : .orderedAscending }
            return a.make.compare(b.make, options: textOptions)
        case .name:
            return a.name.compare(b.name, options: textOptions)
        case .added:
            return dateComparison(a.addedAt, b.addedAt)
        case .updated:
            return dateComparison(a.modified, b.modified)
        }
    }

    /// Newest first: "what did I add last" is the question a date column is asked.
    private static func dateComparison(_ a: Date, _ b: Date) -> ComparisonResult {
        if a == b { return .orderedSame }
        return a > b ? .orderedAscending : .orderedDescending
    }

    /// Nothing above this is a total order on its own — two files can share a name, a
    /// make and a date — so ties fall through to the path, and the list never reshuffles
    /// between two draws of the same data.
    private static func tieBreak(_ a: AssetEntry, _ b: AssetEntry) -> Bool {
        if !text(a.name, isSameAs: b.name) { return text(a.name, isBefore: b.name) }
        if a.relative != b.relative { return a.relative < b.relative }
        return a.rootID.uuidString < b.rootID.uuidString
    }

    // MARK: - Text

    private static let textOptions: String.CompareOptions = [.caseInsensitive, .numeric, .diacriticInsensitive]

    private static func text(_ a: String, isBefore b: String) -> Bool {
        switch a.compare(b, options: textOptions) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        // Equal ignoring case: fall back to the plain comparison so the order of
        // "Fender" and "fender" is the same every time.
        case .orderedSame: return a < b
        @unknown default: return a < b
        }
    }

    private static func text(_ a: String, isSameAs b: String) -> Bool {
        a.compare(b, options: textOptions) == .orderedSame
    }
}
