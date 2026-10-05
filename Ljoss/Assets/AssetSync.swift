import Foundation

/// What a scan's result means for the store: the rows it has to touch, and nothing else.
///
/// This is the write-side twin of `AssetScanStats.parsed`. A scan that found nothing new
/// produces an empty change, which is what makes "an unchanged library is not rewritten"
/// something a test can assert rather than a claim in a comment — and what keeps a launch
/// scan of a real library from writing thousands of rows it already had
/// (`docs/ASSETS.md`).
struct AssetChange: Equatable, Sendable {
    /// Files the store has never held.
    var inserted: [AssetEntry] = []
    /// Files whose row differs from the found entry in at least one field.
    var updated: [AssetEntry] = []
    /// Rows whose file is no longer in any folder, by `AssetEntry.id`.
    var removedIDs: [String] = []

    var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && removedIDs.isEmpty }
}

/// Reconciling what a scan found against what is stored.
enum AssetSync {

    /// What has to change for the store to hold exactly `scanned`.
    ///
    /// Identity is `AssetEntry.id` — the folder's id and the path under it — so a
    /// container that moved does not make the whole library look new, the same rule the
    /// scan's own cache keeps. The comparison is the whole entry: every field is either
    /// something the file said about itself or the size and date that decide whether it
    /// was read again, and a row that differs in any of them is worth writing.
    static func changes(from stored: [AssetEntry], to scanned: [AssetEntry]) -> AssetChange {
        var byID: [String: AssetEntry] = [:]
        for entry in stored { byID[entry.id] = entry }

        var change = AssetChange()
        var found = Set<String>()
        for entry in scanned {
            found.insert(entry.id)
            guard let stored = byID[entry.id] else {
                change.inserted.append(entry)
                continue
            }
            if stored != entry { change.updated.append(entry) }
        }

        // Sorted rather than in fetch order: the same library reconciled twice deletes the
        // same rows in the same order.
        change.removedIDs = stored.map(\.id).filter { !found.contains($0) }.sorted()
        return change
    }
}
