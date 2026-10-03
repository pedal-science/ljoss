import Foundation

// Assertions for the rig export.
//
// What is checked here is the shape of the thing that leaves the app, because an export
// is the one artefact a person hands to another tool: the folder, the two names, and that
// `ljoss.json` is spelled exactly as the library spells its own rig files. A zip the
// writer and the reader agree on but nothing else can open would pass a round-trip test
// and fail its only purpose, so the archive is parsed through its **central directory**
// (`ZipArchive`), which is the part a real unpacker uses.

// MARK: - Helpers

/// A `ZipSaving` that keeps the bytes and can be told to fail, which is the only way to
/// reach "the disk said no" without a disk.
private final class RecordingSaver: ZipSaving, @unchecked Sendable {
    private(set) var saved: [(data: Data, url: URL)] = []
    var failure: Error?

    nonisolated init() {}

    nonisolated func save(_ archive: Data, to url: URL) throws {
        if let failure { throw failure }
        saved.append((archive, url))
    }
}

private struct DiskIsFull: LocalizedError {
    var errorDescription: String? { "the disk is full" }
}

private func exportRig(_ name: String, _ elements: [ChainElement]) -> Rig {
    Rig(name: name,
        layout: .single,
        chains: [SignalChain(name: "Guitar", source: .guitar, elements: elements)],
        createdAt: Date(timeIntervalSince1970: 1_000_000),
        modifiedAt: Date(timeIntervalSince1970: 2_000_000))
}

private func ampElement(_ model: String = "tweed/deluxe") -> ChainElement {
    .block(Block(componentID: "amp.brit800", values: ["engine.model": .option(model)]))
}

/// The object a `JSONSerialization` pass makes, so a test can assert on keys.
private func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func assertZipLooksRight() {
    do {
        let rig = exportRig("Crunch Lead", [ampElement()])
        let archive = try ZipArchive(data: RigExport.archive(for: rig))

        check(archive.folderName == "Crunch Lead",
              "the archive's one folder is named after the rig — got \(archive.folderName ?? "nil")")
        check(archive.names.contains("Crunch Lead/ljoss.json"),
              "the rig document is inside it as ljoss.json — got \(archive.names)")
        check(archive.names.contains("Crunch Lead/namchain.json"),
              "the engine document is inside it as namchain.json — got \(archive.names)")
        check(archive.entries.count == 3,
              "exactly the folder and its two files, and nothing else — got \(archive.names)")
        check(archive.entries.filter { !$0.isDirectory }.count == 2,
              "two files, no more")
    } catch {
        check(false, "the archive should read back: \(error)")
    }
}

private func assertTheRigDocumentIsTheLibrarysOwn() {
    do {
        let rig = exportRig("Crunch Lead", [ampElement()])
        let archive = try ZipArchive(data: RigExport.archive(for: rig))
        let exported = try archive.content("Crunch Lead/ljoss.json")

        check(exported == (try RigJSON.encode(rig)),
              "ljoss.json is byte for byte what the library writes, so the app reads it back identical")

        guard let decoded = try? RigJSON.decode(exported) else {
            check(false, "ljoss.json decodes as a rig")
            return
        }
        check(decoded == rig, "and it is the same rig, down to the node ids")
    } catch {
        check(false, "the rig document should be readable: \(error)")
    }
}

private func assertTheEngineDocumentIsTheRealOne() {
    do {
        let rig = exportRig("Crunch Lead", [ampElement()])
        let archive = try ZipArchive(data: RigExport.archive(for: rig))
        let exported = try archive.content("Crunch Lead/namchain.json")

        guard let document = jsonObject(exported) else {
            check(false, "namchain.json parses as a JSON object")
            return
        }
        check(document["name"] as? String == "Crunch Lead",
              "the engine document carries the rig's name — got \(document["name"] ?? "nil")")

        let chains = document["chains"] as? [[String: Any]] ?? []
        check(chains.count == 1, "one chain — got \(chains.count)")

        let nodes = chains.first?["nodes"] as? [[String: Any]] ?? []
        let types = nodes.compactMap { $0["type"] as? String }
        check(types.contains("nc.input"), "the chain has an input")

        // An amp lowers to two nodes: the model the NAM core runs and the tone stack. The
        // model is a *parameter* of the node, inline beside `id`/`type`/`element`, which is
        // how the engine's own rig files spell it.
        guard let nam = nodes.first(where: { $0["type"] as? String == "nc.nam" }) else {
            check(false, "the amp's NAM node is in the document — got \(types)")
            return
        }
        check(nam["model"] as? String == "tweed/deluxe",
              "and the model the block names travelled with it — got \(nam["model"] ?? "nil")")
        check(!(nam["element"] as? String ?? "").isEmpty,
              "the node carries the block's own element id, which is how an edit addresses it")
        check(types.contains("fx.amp.tonestack"), "and the amp's tone stack came with it")
        check(nodes.contains { ($0["type"] as? String) == "nc.output" },
              "the chain has an output")
    } catch {
        check(false, "the engine document should be readable: \(error)")
    }
}

private func assertARefusalRefusesTheWholeExport() {
    do {
        // A `.parallel` section that is not a Y split: the encoder refuses it by name and
        // returns no document at all, which is the case this export has to respect.
        var section = ParallelSection(splitMode: .crossover)
        section.lanes = [Lane(elements: [ampElement()]), Lane()]
        let rig = exportRig("Crossover Rig", [.parallel(section)])

        do {
            _ = try RigExport.archive(for: rig)
            check(false, "a rig the encoder refuses must not produce an archive")
        } catch let error as RigExportError {
            guard case .refused(let reasons) = error else {
                check(false, "the failure should be a refusal, not \(error)")
                return
            }
            check(reasons.count == 1, "one reason for one refused section — got \(reasons)")
            check(reasons.first?.contains("Crossover") == true,
                  "and it names what to change — got \(reasons.first ?? "nil")")
            check(error.errorDescription?.contains("cannot be sent to namchain") == true,
                  "the message a user sees says what is wrong")
        }
    } catch {
        check(false, "building the failing rig should not throw: \(error)")
    }
}

private func assertAMissingModelRefusesTheExport() {
    do {
        // An amp with no model chosen: the encoder refuses it — this app's own words are
        // "needs a model chosen from the device's library".
        let rig = exportRig("Bare Amp", [.block(Block(componentID: "amp.brit800"))])
        do {
            _ = try RigExport.archive(for: rig)
            check(false, "an unconfigured amp must not produce an archive")
        } catch let error as RigExportError {
            check(error.errorDescription?.contains("model") == true,
                  "the refusal names the missing model — got \(error.errorDescription ?? "nil")")
        }
    } catch {
        check(false, "building the failing rig should not throw: \(error)")
    }
}

private func assertStarterRigsRefuseWithEveryReason() {
    // The rigs the app makes for a new user name no model and no impulse response, and use
    // blocks the engine has no equivalent for — so they are exactly the case the "a refusal
    // refuses the export" rule exists for. What matters is that the refusal names **all** of
    // it: a user fixing one problem at a time and being refused again each round would be
    // worse served than one told the whole list now.
    for rig in RigFactory.starterRigs() {
        do {
            _ = try RigExport.archive(for: rig)
            check(false, "“\(rig.name)” names no model, so it must not export")
        } catch let error as RigExportError {
            guard case .refused(let reasons) = error else {
                check(false, "“\(rig.name)” should be refused, not \(error)")
                continue
            }
            check(!reasons.isEmpty, "“\(rig.name)” is refused for a named reason")
            check(reasons.allSatisfy { $0.contains("·") },
                  "every reason names its chain and block — got \(reasons)")
            check(reasons.contains { $0.localizedCaseInsensitiveContains("model") },
                  "and the missing model is among them — got \(reasons)")
            check(error.errorDescription?.contains("namchain") == true,
                  "the message says what the rig cannot be sent to")
        } catch {
            check(false, "building “\(rig.name)” should throw a refusal, not \(error)")
        }
    }
}

private func assertNamesAreSanitised() {
    // An entry name is a path. A rig called "../../etc/passwd" must not write outside the
    // folder the user chose — and one called "Guitar / Vocal" must not become two folders.
    let traversal = exportRig("../../etc/passwd", [ampElement()])
    let traversalFolder = RigExport.folderName(for: traversal)
    check(traversalFolder == "etc passwd",
          "a traversal name is flattened to plain words — got “\(traversalFolder)”")
    check(!traversalFolder.contains("/") && !traversalFolder.contains(".."),
          "so it can neither become a path nor climb out of the archive's folder")
    check(!traversalFolder.hasPrefix("."), "and the folder is not hidden")

    let slashed = exportRig("Guitar / Vocal", [ampElement()])
    do {
        let archive = try ZipArchive(data: RigExport.archive(for: slashed))
        check(archive.folderName == "Guitar Vocal",
              "a slash in a name is a space, not a second folder — got \(archive.folderName ?? "nil")")
        check(archive.entries.filter(\.isDirectory).count == 1,
              "still exactly one folder in the archive")
    } catch {
        check(false, "the slashed name should still export: \(error)")
    }

    check(RigExport.folderName(for: exportRig("..", [ampElement()])) == "Rig",
          "a name that is only dots falls back rather than naming a folder “..”")
    check(RigExport.folderName(for: exportRig("   ", [ampElement()])) == "Rig",
          "and so does a name that is only spaces")

    let colon = exportRig("Verse: Chorus", [ampElement()])
    check(!RigExport.suggestedFileName(for: colon).contains(":"),
          "the suggested file name has no colon, which the filesystem would refuse")

    let unicode = exportRig("Café ✓ Rig", [ampElement()])
    do {
        let archive = try ZipArchive(data: RigExport.archive(for: unicode))
        check(archive.folderName == "Café ✓ Rig",
              "a name outside ASCII survives — got \(archive.folderName ?? "nil")")
    } catch {
        check(false, "a non-ASCII name should export: \(error)")
    }
}

private func assertAWriteFailureIsReported() {
    let saver = RecordingSaver()
    saver.failure = DiskIsFull()
    let rig = exportRig("Crunch Lead", [ampElement()])

    do {
        try RigExport.export(rig, using: saver, to: URL(fileURLWithPath: "/nowhere/rig.zip"))
        check(false, "a writer that fails must not report success")
    } catch {
        check((error as? DiskIsFull) != nil,
              "the writer's own failure comes back rather than being swallowed — got \(error)")
    }
    check(saver.saved.isEmpty, "and nothing was recorded as written")
}

private func assertTheLiveWriterWritesTheFile() {
    // The one place `FolderZipSaver` is exercised: a real file, read back with the archive
    // reader, which is what the menu item does minus the save panel.
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "ljoss-export-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    let destination = directory.appending(path: "Crunch Lead.zip")

    defer { try? FileManager.default.removeItem(at: directory) }

    let rig = exportRig("Crunch Lead", [ampElement()])
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RigExport.export(rig, using: FolderZipSaver(), to: destination)

        let written = try Data(contentsOf: destination)
        let archive = try ZipArchive(data: written)
        check(archive.names.contains("Crunch Lead/namchain.json"),
              "the file on disk is the same archive — got \(archive.names)")
        check(written == (try RigExport.archive(for: rig)),
              "and it is byte for byte the archive the exporter built")
    } catch {
        check(false, "writing the zip to a real file should work: \(error)")
    }
}

private func assertTheArchiveIsStable() {
    // Two exports of one rig differ only in the ids the rig already carried: the writer
    // must not stamp a time or an order that changes between runs, or every export of an
    // unchanged rig would differ and a diff would be useless.
    let rig = exportRig("Crunch Lead", [ampElement()])
    do {
        check(try RigExport.archive(for: rig) == (try RigExport.archive(for: rig)),
              "two exports of one rig are byte-identical")
    } catch {
        check(false, "exporting twice should work: \(error)")
    }
}

// MARK: - Entry point

func testRigExport() {
    print("exporting a rig as a zip of two documents")

    assertZipLooksRight()
    assertTheRigDocumentIsTheLibrarysOwn()
    assertTheEngineDocumentIsTheRealOne()
    assertARefusalRefusesTheWholeExport()
    assertAMissingModelRefusesTheExport()
    assertStarterRigsRefuseWithEveryReason()
    assertNamesAreSanitised()
    assertAWriteFailureIsReported()
    assertTheLiveWriterWritesTheFile()
    assertTheArchiveIsStable()
}
