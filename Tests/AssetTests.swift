import Foundation

// Assertions for the local model and IR library: what a file says about itself, how a
// brand is worked out, and what a scan does when a folder changes underneath it.
//
// Everything here is written into a temporary directory by the test, so these describe
// the rules rather than pinning whatever a fixture happened to contain. The two that
// matter most are silent when they break: a scan that re-reads the whole library every
// time still *works*, and an ordering that reshuffles between two draws of the same
// data still looks sorted.

// MARK: - Building files

private func tempDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "asset-tests-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
}

/// A `.nam` shaped like the reference writer's: metadata and architecture at the front,
/// the weights in the middle, the rate after them.
private func namText(name: String? = nil,
                     architecture: String = "WaveNet",
                     rate: Int = 48000,
                     make: String? = nil,
                     model: String? = nil,
                     training: String? = nil,
                     weights: Int = 0) -> String {
    var fields: [String] = []
    if let name { fields.append("\"name\": \"\(name)\"") }
    if let make { fields.append("\"gear_make\": \"\(make)\"") }
    if let model { fields.append("\"gear_model\": \"\(model)\"") }
    if let training { fields.append("\"training\": \(training)") }

    let body = (0..<weights).map { "\($0).5" }.joined(separator: ", ")
    return """
    {"version": "0.5.4",
     "metadata": {"date": {"year": 2026}, \(fields.joined(separator: ", "))},
     "architecture": "\(architecture)",
     "config": {"input_size": 1, "hidden_size": 3},
     "weights": [\(body)],
     "sample_rate": \(rate)}
    """
}

/// A RIFF header with a declared `fmt ` and `data` chunk. No samples: the header is what
/// is read, which is the whole point of a bounded probe.
private func wavData(sampleRate: Int = 48000, channels: Int = 1, bits: Int = 16, frames: Int = 2048) -> Data {
    func u32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
    func u16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
    func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

    let blockAlign = channels * bits / 8
    let dataBytes = frames * blockAlign

    var bytes: [UInt8] = []
    bytes += ascii("RIFF"); bytes += u32(36 + dataBytes); bytes += ascii("WAVE")
    bytes += ascii("fmt "); bytes += u32(16)
    bytes += u16(1); bytes += u16(channels)
    bytes += u32(sampleRate); bytes += u32(sampleRate * blockAlign)
    bytes += u16(blockAlign); bytes += u16(bits)
    bytes += ascii("data"); bytes += u32(dataBytes)
    return Data(bytes)
}

// MARK: - What a file says about itself

func testAssetSniffing() {
    print("reading a model or IR's own description")
    let root = tempDirectory("sniff")
    defer { try? FileManager.default.removeItem(at: root) }

    let model = root.appending(path: "deluxe.nam")
    write(namText(name: "Deluxe Reverb", make: "Fender", model: "Deluxe Reverb", weights: 6000), to: model)
    let info = NAMSniff.nam(at: model)
    check(info.architecture == "WaveNet", "a model's architecture is read from the front of the file")
    check(info.sampleRate == 48000, "…and its rate from the tail, after the weights have pushed it there")
    check(info.name == "Deluxe Reverb", "…and the name it was given")
    check(info.make == "Fender" && info.model == "Deluxe Reverb", "…and what it says it models")

    let linear = root.appending(path: "cab.nam")
    write(namText(name: "4x12", architecture: "Linear", weights: 4), to: linear)
    check(NAMSniff.nam(at: linear).architecture == "Linear", "an impulse response in a .nam says Linear")

    let bare = root.appending(path: "bare.nam")
    write("{\"version\": \"0.5.4\", \"architecture\": \"LSTM\", \"weights\": [], \"sample_rate\": 44100}", to: bare)
    let bareInfo = NAMSniff.nam(at: bare)
    check(bareInfo.name == nil && bareInfo.make == nil, "a file with no metadata reports nothing rather than a guess")
    check(bareInfo.sampleRate == 44100, "…and its rate is still read")

    let truncated = root.appending(path: "truncated.nam")
    write(namText(name: "Lost", training: "{\"blob\": \"\(String(repeating: "x", count: 24_000))\"}"), to: truncated)
    check(NAMSniff.nam(at: truncated).name == nil,
          "a metadata block that runs past the window is unknown, not half-read")

    let missing = root.appending(path: "nothing.nam")
    check(NAMSniff.nam(at: missing).architecture == nil, "a file that is not there reports nothing")

    let cab = root.appending(path: "cab.wav")
    try? wavData(sampleRate: 48000, channels: 2, bits: 24, frames: 4096).write(to: cab)
    let wav = NAMSniff.wav(at: cab)
    check(wav?.sampleRate == 48000 && wav?.channels == 2, "a wav's format is read from its header")
    check(wav?.frames == 4096, "…and its length in frames")

    let notes = root.appending(path: "notes.wav")
    write("this is not a RIFF file", to: notes)
    check(NAMSniff.wav(at: notes) == nil, "a file that is not a RIFF reports nothing at all")
}

// MARK: - The brand

func testMakeHeuristics() {
    print("guessing the brand")
    check(MakeHeuristics.make(claimed: "Fender", fileStem: "whatever", directories: []) == "Fender",
          "a file's own make is used as it stands")
    check(MakeHeuristics.make(claimed: "Orange Rockerverb mk3", fileStem: "x", directories: []) == "Orange",
          "a claim that names the amp as well as the brand is reduced to the brand")
    check(MakeHeuristics.make(claimed: nil, fileStem: "Marshall JCM800", directories: []) == "Marshall",
          "a brand in the filename is found")
    check(MakeHeuristics.make(claimed: nil, fileStem: "ORNG-V30-e609-Center", directories: []) == "Orange",
          "…including the spellings capture files actually use")
    check(MakeHeuristics.make(claimed: nil, fileStem: "deluxe", directories: ["Fender"]) == "Fender",
          "a folder named after the brand is a brand")
    check(MakeHeuristics.make(claimed: nil, fileStem: "SM57-cab", directories: []) == "Shure",
          "a microphone's own name implies its maker")
    check(MakeHeuristics.make(claimed: nil, fileStem: "mystery capture", directories: []) == MakeHeuristics.unknown,
          "nothing recognised is Unknown, which is an answer rather than a blank")
    check(MakeHeuristics.canonical(in: "orangewood") == nil, "matching is on whole words")
    check(MakeHeuristics.canonical(in: "MESA BOOGIE") == "Mesa/Boogie", "matching ignores case")
}

// MARK: - Scanning

func testAssetScanning() {
    print("scanning the folders")
    let root = tempDirectory("scan")
    defer { try? FileManager.default.removeItem(at: root) }

    write(namText(name: "Deluxe", make: "Fender"), to: root.appending(path: "tweed/deluxe.nam"))
    write(namText(name: "JCM800", make: "Marshall"), to: root.appending(path: "brit/jcm800.nam"))
    write(namText(name: "V30", architecture: "Linear"), to: root.appending(path: "cabs/v30.nam"))
    try? wavData().write(to: root.appending(path: "cabs/greenback.wav"))
    write("not a model", to: root.appending(path: "readme.txt"))
    write(namText(name: "Hidden"), to: root.appending(path: ".hidden.nam"))

    let scanRoot = ScanRoot(id: UUID(), url: root)
    let first = AssetScan.run(roots: [scanRoot], previous: [], now: Date())
    check(first.entries.count == 4, "models and IRs under the folder are found, whatever their depth")
    check(first.stats.added == 4 && first.stats.removed == 0, "…all of them new")
    check(first.stats.parsed == 4, "…and all of them read")
    check(first.stats.models == 2 && first.stats.irs == 2,
          "a .wav is an impulse response, a Linear .nam is one too, and a WaveNet .nam is a model")
    check(first.entries.first { $0.relative == "tweed/deluxe.nam" }?.name == "Deluxe",
          "a row shows the name the capture was given")
    check(first.entries.first { $0.relative == "tweed/deluxe.nam" }?.make == "Fender",
          "…and the brand that came with it")
    check(first.entries.first { $0.relative == "cabs/greenback.wav" }?.sampleRate == 48000,
          "a wav's rate reaches the entry")
    check(!first.entries.contains { $0.relative.hasSuffix(".txt") || $0.relative.hasPrefix(".") },
          "other files and hidden names are not models")

    let second = AssetScan.run(roots: [scanRoot], previous: first.entries, now: Date())
    check(second.stats.parsed == 0, "a second scan of an unchanged folder reads no file at all")
    check(second.stats.added == 0 && second.stats.updated == 0 && second.stats.removed == 0,
          "…and reports nothing changed")
    let wasAdded = first.entries.first { $0.relative == "tweed/deluxe.nam" }?.addedAt
    let stillAdded = second.entries.first { $0.relative == "tweed/deluxe.nam" }?.addedAt
    check(wasAdded != nil && wasAdded == stillAdded, "…and keeps the day each file was first seen")

    let jcmAdded = second.entries.first { $0.relative == "brit/jcm800.nam" }?.addedAt
    let jcm = root.appending(path: "brit/jcm800.nam")
    write(namText(name: "JCM800", make: "Marshall", model: "JCM 800", weights: 20), to: jcm)
    let third = AssetScan.run(roots: [scanRoot], previous: second.entries, now: Date())
    check(third.stats.parsed == 1, "a file that changed is the only one read again")
    check(third.stats.updated == 1 && third.stats.added == 0, "…and it is reported as updated")
    check(third.entries.first { $0.relative == "brit/jcm800.nam" }?.model == "JCM 800", "…with its new info")
    check(third.entries.first { $0.relative == "brit/jcm800.nam" }?.addedAt == jcmAdded,
          "…and the day it was first seen still")

    try? FileManager.default.removeItem(at: jcm)
    let fourth = AssetScan.run(roots: [scanRoot], previous: third.entries, now: Date())
    check(fourth.stats.removed == 1, "a file that is gone is removed from the list")
    check(!fourth.entries.contains { $0.relative == "brit/jcm800.nam" }, "…and is not listed any more")

    let missing = ScanRoot(id: UUID(), url: root.appending(path: "not-here"))
    let fifth = AssetScan.run(roots: [missing], previous: fourth.entries, now: Date())
    check(fifth.entries.isEmpty, "a folder that is not there contributes nothing")
    check(fifth.issues.count == 1 && fifth.issues[0].message.contains("not found"),
          "…and says why rather than failing silently")
    check(fifth.stats.removed == fourth.entries.count, "…and what it held is pruned with it")

    let nested = AssetScan.run(roots: [scanRoot, ScanRoot(id: UUID(), url: root.appending(path: "tweed"))],
                               previous: [], now: Date())
    check(nested.entries.count == fourth.entries.count,
          "a folder configured inside another does not list its files twice")

    let notAFolder = ScanRoot(id: UUID(), url: root.appending(path: "readme.txt"))
    let sixth = AssetScan.run(roots: [notAFolder], previous: [], now: Date())
    check(sixth.issues.count == 1 && sixth.entries.isEmpty, "a file where a folder was expected is reported, not read")

    // The store's side of the same rule: what a scan found and what the store already
    // holds is the same list, so a launch scan of an unchanged library writes nothing
    // either.
    check(AssetSync.changes(from: fourth.entries, to: fourth.entries).isEmpty,
          "a scan's own result is not something the store has to rewrite")
}

// MARK: - The library an older build left behind

func testAssetLibraryImport() {
    print("reading the library an older build wrote")
    let rootID = UUID()
    let json = """
    {
      "version": 1,
      "savedAt": "2026-02-03T04:05:06Z",
      "roots": [
        {"id": "\(rootID.uuidString)", "path": "/Users/someone/models", "bookmark": "AAAA",
         "isSecurityScoped": true, "addedAt": "2026-02-03T04:05:06Z"}
      ],
      "entries": [
        {"rootID": "\(rootID.uuidString)", "relative": "tweed/deluxe.nam", "kind": "model",
         "name": "Deluxe", "make": "Fender", "model": "Deluxe Reverb", "architecture": "WaveNet",
         "sampleRate": 48000, "channels": null, "frames": null, "size": 1234,
         "modified": "2026-02-03T04:05:06Z", "addedAt": "2026-02-03T04:05:06Z"},
        {"rootID": "\(rootID.uuidString)", "relative": "cabs/v30.wav", "kind": "neural",
         "name": "V30", "make": "Celestion", "model": null, "architecture": null,
         "sampleRate": 44100, "channels": 2, "frames": 2048, "size": 4096,
         "modified": "2026-02-03T04:05:06Z", "addedAt": "2026-02-03T04:05:06Z"}
      ]
    }
    """

    do {
        let snapshot = try AssetSnapshot.decodeLegacy(Data(json.utf8))
        check(snapshot.roots.count == 1 && snapshot.entries.count == 2,
              "the folder the older build had, and the files in it")
        check(snapshot.roots[0].id == rootID && snapshot.roots[0].path == "/Users/someone/models",
              "…with the path a row shows")
        check(snapshot.roots[0].bookmark != nil && snapshot.roots[0].isSecurityScoped,
              "…and the bookmark that is what actually survives a relaunch")
        check(snapshot.entries[0].relative == "tweed/deluxe.nam" && snapshot.entries[0].size == 1234,
              "…and each file with what the last scan knew about it")
        check(snapshot.entries[0].id == "\(rootID.uuidString)/tweed/deluxe.nam",
              "an imported file keeps the identity the scan reckons with")

        let written = ISO8601DateFormatter().date(from: "2026-02-03T04:05:06Z")
        check(written != nil && snapshot.roots[0].addedAt == written,
              "dates are read as the writer wrote them, or every file would look new")

        // The rule the JSON store kept, and the reason the store keeps it: a file written
        // by a build that knows a kind this one does not must not cost the user their
        // folder list.
        check(snapshot.entries[1].kind == .model,
              "a kind this build does not know reads as a model")
        check(snapshot.entries[1].frames == 2048 && snapshot.entries[1].sampleRate == 44100,
              "…and its own numbers come with it")
    } catch {
        check(false, "the library an older build wrote is readable: \(error)")
    }

    do {
        _ = try AssetSnapshot.decodeLegacy(Data("this is not the library".utf8))
        check(false, "a file that is not the library is refused rather than half-read")
    } catch {
        check(true, "a file that is not the library is refused rather than half-read")
    }
}

// MARK: - What the store has to write

func testAssetChanges() {
    print("writing back only what changed")

    let root = UUID()
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func entry(_ relative: String, size: Int = 100, modified: TimeInterval = 0) -> AssetEntry {
        AssetEntry(rootID: root, relative: relative, kind: .model, name: relative,
                   make: "Fender", model: nil, architecture: nil, sampleRate: nil,
                   channels: nil, frames: nil, size: size,
                   modified: base.addingTimeInterval(modified), addedAt: base)
    }

    let stored = [entry("a.nam"), entry("b.nam")]
    check(AssetSync.changes(from: stored, to: stored).isEmpty,
          "a library that is exactly what is stored is nothing to write")

    let grown = [entry("a.nam"), entry("b.nam", size: 200)]
    let updated = AssetSync.changes(from: stored, to: grown)
    check(updated.updated.map(\.relative) == ["b.nam"],
          "a file that changed is the one row rewritten")
    check(updated.inserted.isEmpty && updated.removedIDs.isEmpty, "…and nothing else is touched")

    check(AssetSync.changes(from: stored, to: [entry("a.nam"), entry("b.nam", modified: 10)])
            .updated.map(\.relative) == ["b.nam"],
          "a date that moved is a change too — it is half of what the scan's own cache keys on")

    let withNew = AssetSync.changes(from: stored, to: stored + [entry("c.nam")])
    check(withNew.inserted.map(\.relative) == ["c.nam"],
          "a file that was not there before is a row to insert")
    check(withNew.updated.isEmpty && withNew.removedIDs.isEmpty, "…and nothing else")

    check(AssetSync.changes(from: stored, to: [entry("a.nam")]).removedIDs == ["\(root.uuidString)/b.nam"],
          "a file that is gone is a row to delete")
    check(AssetSync.changes(from: stored, to: []).removedIDs.count == stored.count,
          "…and a folder that went takes every row in it")

    // A file that moved folder is a different entry, not an edit: identity is the path
    // under the root, which is what stops a container that moved from rewriting the lot.
    let moved = AssetSync.changes(from: stored, to: [entry("a.nam"), entry("moved/b.nam")])
    check(moved.inserted.count == 1 && moved.removedIDs.count == 1 && moved.updated.isEmpty,
          "a file under a different path is a new row and a deleted one")
}

// MARK: - Sections and order

func testAssetOrdering() {
    print("grouping and sorting the entries")

    let models = UUID()
    let irs = UUID()
    let labels = [models: "Models", irs: "IRs"]
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func entry(_ relative: String, _ kind: AssetKind, _ make: String,
               added: TimeInterval = 0, updated: TimeInterval = 0, root: UUID? = nil) -> AssetEntry {
        AssetEntry(rootID: root ?? models, relative: relative, kind: kind,
                   name: relative.split(separator: "/").last.map(String.init) ?? relative,
                   make: make, model: nil, architecture: nil, sampleRate: nil,
                   channels: nil, frames: nil, size: 0,
                   modified: base.addingTimeInterval(updated), addedAt: base.addingTimeInterval(added))
    }

    let entries = [
        entry("b/greenback.wav", .ir, "Celestion", updated: 10),
        entry("a/deluxe.nam", .model, "Fender", updated: 30),
        entry("a/mystery.nam", .model, MakeHeuristics.unknown, updated: 5),
        entry("b/jcm.nam", .model, "Marshall", added: 100, updated: 20),
        entry("z/tweed.wav", .ir, "Fender", updated: 40, root: irs),
    ]

    let standard = AssetOrdering.sections(entries, rootLabels: labels, grouping: .standard)
    check(standard.map(\.title) == ["Models › Fender", "Models › Marshall", "Models › Unknown",
                                    "Impulse Responses › Celestion", "Impulse Responses › Fender"],
          "the defaults group by type and then make, models first and Unknown last")

    let byName = AssetOrdering.sections(entries, rootLabels: labels, grouping:
        AssetGrouping(groupBy: .none, thenBy: .none, sortBy: .name, thenSortBy: .name))
    check(byName.count == 1 && byName[0].title == nil, "grouping by None is one list with no heading")
    check(byName[0].entries.map(\.name) == ["deluxe.nam", "greenback.wav", "jcm.nam", "mystery.nam", "tweed.wav"],
          "…sorted by name")

    let byUpdated = AssetOrdering.sections(entries, rootLabels: labels, grouping:
        AssetGrouping(groupBy: .none, thenBy: .none, sortBy: .updated, thenSortBy: .name))
    check(byUpdated[0].entries.first?.relative == "z/tweed.wav",
          "sorting by Updated is newest first")

    let byAdded = AssetOrdering.sections(entries, rootLabels: labels, grouping:
        AssetGrouping(groupBy: .none, thenBy: .none, sortBy: .added, thenSortBy: .name))
    check(byAdded[0].entries.first?.relative == "b/jcm.nam", "sorting by Added is newest first too")

    let byMake = AssetOrdering.sections(entries, rootLabels: labels, grouping:
        AssetGrouping(groupBy: .none, thenBy: .none, sortBy: .make, thenSortBy: .name))
    check(byMake[0].entries.map(\.make) == ["Celestion", "Fender", "Fender", "Marshall", MakeHeuristics.unknown],
          "sorting by Make keeps Unknown at the end, where the headings put it")

    let byType = AssetOrdering.sections(entries, rootLabels: labels, grouping:
        AssetGrouping(groupBy: .none, thenBy: .none, sortBy: .type, thenSortBy: .name))
    check(byType[0].entries.prefix(3).allSatisfy(\.isModel), "sorting by Type puts every model first")
    check(byType[0].entries.dropFirst(3).allSatisfy { !$0.isModel }, "…and every impulse response after them")

    let byPath = AssetOrdering.sections(entries, rootLabels: labels, grouping:
        AssetGrouping(groupBy: .path, thenBy: .none, sortBy: .filename, thenSortBy: .name))
    check(byPath.map(\.title) == ["IRs/z", "Models/a", "Models/b"],
          "grouping by Path names each folder by its root, and a file at a root by the root alone")

    let collapsed = AssetOrdering.sections(entries, rootLabels: labels, grouping:
        AssetGrouping(groupBy: .type, thenBy: .type, sortBy: .make, thenSortBy: .updated))
    check(collapsed.map(\.title) == ["Models", "Impulse Responses"],
          "a second level equal to the first collapses to one heading")

    let withoutHeading = AssetOrdering.sections(entries, rootLabels: labels, grouping:
        AssetGrouping(groupBy: .type, thenBy: .none, sortBy: .name, thenSortBy: .name))
    check(withoutHeading.count == 2, "the second level can be None on its own")

    // The same data drawn twice puts every row in the same place: a tie on the sort key
    // falls through to the path rather than to whatever the dictionary felt like.
    let ties = [entry("b/same.nam", .model, "Fender"), entry("a/same.nam", .model, "Fender")]
    let first = AssetOrdering.sections(ties, rootLabels: labels, grouping:
        AssetGrouping(groupBy: .none, thenBy: .none, sortBy: .make, thenSortBy: .updated))
    let second = AssetOrdering.sections(Array(ties.reversed()), rootLabels: labels, grouping:
        AssetGrouping(groupBy: .none, thenBy: .none, sortBy: .make, thenSortBy: .updated))
    check(first[0].entries.map(\.relative) == second[0].entries.map(\.relative),
          "two files that tie on every sort key still come out in one order")
    check(first[0].entries.map(\.relative) == ["a/same.nam", "b/same.nam"], "…and that order is the path")

    let entryID = entry("tweed/deluxe.nam", .model, "Fender")
    check(entryID.libraryID == "tweed/deluxe", "an entry can name itself the way the device's library would")
    check(entryID.fileStem == "deluxe" && entryID.directory == "tweed", "…and knows its own folder")
}
