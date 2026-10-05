import Foundation

// Assertions for the SwiftData store the library lives in: that what it holds is what was
// put into it, that reading it back is what keeps a launch from re-reading a library that
// has not changed, and that the JSON an older build wrote is brought across exactly once.
//
// These need a real `ModelContainer`, which is why they are separate from the pure ones:
// what is being asserted is a file on disk rather than a rule. Everything is written into
// a temporary directory, so nothing here goes near the app's own library.

// MARK: - Files to scan

private func storeTempDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "asset-store-tests-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func storeWrite(_ data: Data, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? data.write(to: url)
}

private func storeWrite(_ text: String, to url: URL) {
    storeWrite(Data(text.utf8), to: url)
}

/// A `.nam` shaped enough like the reference writer's to be read: metadata at the front,
/// the rate after the weights.
private func storeNam(_ name: String, architecture: String = "WaveNet") -> String {
    """
    {"version": "0.5.4", "metadata": {"name": "\(name)"}, "architecture": "\(architecture)",
     "config": {"input_size": 1}, "weights": [0.5, 0.5], "sample_rate": 48000}
    """
}

// MARK: - The store

@MainActor
func testAssetStoreRoundTrip() {
    print("storing the library")
    let directory = storeTempDirectory("round-trip")
    defer { try? FileManager.default.removeItem(at: directory) }

    let added = Date(timeIntervalSince1970: 1_700_000_000)
    // Sub-second precision here on purpose: `modified` is half of the key a scan decides
    // "unchanged" with, so a store that rounded it would make every file look edited on
    // every launch.
    let modified = Date(timeIntervalSince1970: 1_700_000_123.456789)
    let root = AssetRoot(path: "/Users/someone/models", bookmark: Data([1, 2, 3]),
                         isSecurityScoped: true, addedAt: added)
    // Added second, but written first: the order the folders come back in is the order they
    // were added in, not the order they happened to be handed over in.
    let laterRoot = AssetRoot(path: "/Users/someone/irs", bookmark: Data([4, 5, 6]),
                              isSecurityScoped: true, addedAt: added.addingTimeInterval(60))
    let entries = [
        AssetEntry(rootID: root.id, relative: "tweed/deluxe.nam", kind: .model, name: "Deluxe",
                   make: "Fender", model: "Deluxe Reverb", architecture: "WaveNet",
                   sampleRate: 48000, channels: nil, frames: nil, size: 1234,
                   modified: modified, addedAt: added),
        AssetEntry(rootID: root.id, relative: "cabs/v30.nam", kind: .ir, name: "V30",
                   make: "Celestion", model: nil, architecture: "Linear",
                   sampleRate: 48000, channels: nil, frames: nil, size: 4096,
                   modified: modified, addedAt: added),
    ]

    do {
        let store = try AssetStore(directory: directory)
        check(store.isPersistent, "the store beside the rigs is one that keeps what it is given")
        try store.write(roots: [laterRoot, root], entries: entries)
    } catch {
        check(false, "the library is writable: \(error)")
    }

    // A second store on the same file, which is what a relaunch opens: everything below
    // is read from disk rather than remembered from above.
    do {
        let store = try AssetStore(directory: directory)
        let roots = try store.roots()
        let stored = try store.entries()
        check(roots == [root, laterRoot], "the folders come back in the order they were added")
        check(roots.first?.bookmark == Data([1, 2, 3]) && roots.first?.isSecurityScoped == true,
              "a folder comes back with its path, its bookmark and its scope")

        // Compared by id rather than as two arrays: a fetch has no order of its own, and
        // what the list is sorted into is the ordering below rather than the fetch.
        let byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        check(byID.count == entries.count && entries.allSatisfy { byID[$0.id] == $0 },
              "a file comes back with every field the scan worked out")
        check(stored.map(\.id) == stored.map(\.id).sorted(),
              "…in the order a scan leaves its own result in")
        check(byID[entries[0].id]?.modified == modified,
              "…including the sub-second date a scan compares")
        check(AssetSync.changes(from: stored, to: entries).isEmpty,
              "so a launch that scans with them writes nothing back")
    } catch {
        check(false, "the library is readable back: \(error)")
    }

    // A kind written by a build that knows one this one does not.
    let record = AssetEntryRecord(entries[0])
    record.kindRaw = "neural"
    check(record.value.kind == .model,
          "a kind this build does not know reads as a model rather than costing the library")
    check(record.value.name == "Deluxe" && record.value.modified == modified,
          "…and the rest of the row is still the file's own")
}

@MainActor
func testAssetStoreIsTheScanCacheAcrossLaunches() {
    print("a launch re-reads nothing that has not changed")
    let directory = storeTempDirectory("cache-store")
    let models = storeTempDirectory("cache-models")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: models)
    }

    storeWrite(storeNam("Deluxe"), to: models.appending(path: "tweed/deluxe.nam"))
    storeWrite(storeNam("V30", architecture: "Linear"), to: models.appending(path: "cabs/v30.nam"))

    let root = AssetRoot(path: models.path(percentEncoded: false))
    let scanRoots = [ScanRoot(id: root.id, url: models)]

    let first = AssetScan.run(roots: scanRoots, previous: [], now: Date())
    check(first.stats.parsed == 2, "a first scan reads every file it finds")

    do {
        let store = try AssetStore(directory: directory)
        try store.write(roots: [root], entries: first.entries)
    } catch {
        check(false, "the scan's result is storable: \(error)")
    }

    // The second launch: the folders and the entries come out of the store, and that is
    // what the scan is handed as its cache — which is the whole point of storing them.
    do {
        let store = try AssetStore(directory: directory)
        let previous = try store.entries()
        check(previous.count == 2, "a second launch opens the store and finds the library in it")

        let second = AssetScan.run(roots: scanRoots, previous: previous, now: Date())
        check(second.stats.parsed == 0, "…and reads no file at all")
        check(second.stats.added == 0 && second.stats.updated == 0 && second.stats.removed == 0,
              "…because nothing in the folders changed")
        check(AssetSync.changes(from: previous, to: second.entries).isEmpty,
              "…and there is nothing to write back either")
    } catch {
        check(false, "the library is readable back: \(error)")
    }
}

@MainActor
func testAssetStoreImportsAnOlderLibraryOnce() {
    print("bringing an older build's library across")
    let directory = storeTempDirectory("import")
    defer { try? FileManager.default.removeItem(at: directory) }

    let added = Date(timeIntervalSince1970: 1_700_000_000)
    let root = AssetRoot(path: "/Users/someone/models", bookmark: Data([1, 2, 3]),
                         isSecurityScoped: true, addedAt: added)
    let entry = AssetEntry(rootID: root.id, relative: "tweed/deluxe.nam", kind: .model, name: "Deluxe",
                           make: "Fender", model: "Deluxe Reverb", architecture: "WaveNet",
                           sampleRate: 48000, channels: nil, frames: nil, size: 1234,
                           modified: added, addedAt: added)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacy = directory.appending(path: "AssetLibrary.json")
    do {
        let snapshot = AssetSnapshot(version: 1, roots: [root], entries: [entry], savedAt: added)
        storeWrite(try encoder.encode(snapshot), to: legacy)
    } catch {
        check(false, "the older build's file is writable: \(error)")
    }
    check(FileManager.default.fileExists(atPath: legacy.path), "there is a library an older build wrote")

    // A store that keeps nothing must not delete the file it cannot take the place of: the
    // folder list is the one thing in it a rescan cannot rebuild.
    do {
        let fallback = AssetStore.inMemory()
        check(!fallback.isPersistent, "the store a failed open falls back to is not one that keeps anything")
        let imported = try fallback.importLegacyJSON(at: legacy)
        check(imported == 0, "…so it does not take the import")
        check(FileManager.default.fileExists(atPath: legacy.path), "…and leaves the older build's file where it is")
    } catch {
        check(false, "the fallback store refuses the import rather than failing: \(error)")
    }

    do {
        let store = try AssetStore(directory: directory)
        let imported = try store.importLegacyJSON(at: legacy)
        check(imported == 1, "the store beside the rigs reads the file in")

        let storedRoots = try store.roots()
        let storedEntries = try store.entries()
        check(storedRoots == [root], "…with the folder list intact, path, bookmark and scope")
        check(storedEntries == [entry], "…and the files with the day each was first seen")
        check(!FileManager.default.fileExists(atPath: legacy.path),
              "…and then deletes it, so an emptied library cannot come back on the next launch")

        let again = try store.importLegacyJSON(at: legacy)
        check(again == 0, "a second launch has nothing left to import")
        check(try store.entries() == [entry], "…and leaves the library it already has alone")
    } catch {
        check(false, "the older build's library is readable: \(error)")
    }
}
