import Foundation

// Exporting a rig as a zip of two documents.
//
// One folder, named after the rig, holding the same rig twice: `ljoss.json`, this app's
// own document, and `namchain.json`, the engine document `DocumentEncoder` lowers it to.
// It is the handover format — a rig out of this app and into a CLI, a bug report, or
// another machine — so it carries both halves rather than asking the receiver to run the
// encoder itself. `docs/EXPORT.md` states the layout, and why the two files are the two
// files.
//
// **A refusal refuses the export.** `DocumentEncoder` reports what it cannot lower: a
// block with no engine equivalent, a model or IR not chosen. Half of a rig in a zip is
// worse than no zip — it would play, and quietly be missing an amp — so the export fails
// with the engine's own words and the user fixes the rig. The user chose this; it is the
// honest half of "export" and it is what `ljoss.json` is for when it is not what they
// want.
//
// No SwiftUI here: this file is in the source list of `Tests/run-model-tests.sh`.

// MARK: - Failures

/// Why an export did not happen, in words that name the thing to change.
enum RigExportError: LocalizedError, Equatable {
    /// The rig cannot be lowered to a namchain document. `reasons` is the encoder's own
    /// list, already readable ("Guitar · Amp needs a model chosen from the device's
    /// library").
    case refused([String])
    /// The zip could not be written where the user asked.
    case writeFailed(String)
    /// Anything else, most plausibly a rig that would not encode — which would be a bug,
    /// not a state the user caused.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .refused(let reasons):
            if reasons.count == 1 {
                "This rig cannot be sent to namchain yet: \(reasons[0]). "
                + "Fix that and export again."
            } else {
                "This rig cannot be sent to namchain yet: "
                + reasons.joined(separator: "; ") + ". Fix those and export again."
            }
        case .writeFailed(let why):
            "The export could not be written: \(why)"
        case .failed(let why):
            "The export failed: \(why)"
        }
    }
}

// MARK: - The writer

/// Where a finished archive goes.
///
/// A protocol rather than a `FileManager` call, so the export can be exercised without a
/// sandbox, a temporary directory or a real file: the tests use a writer that keeps the
/// bytes in memory and can be told to fail, which is the only way to cover "the disk said
/// no" at all. The live implementation is `FolderZipSaver`.
protocol ZipSaving: Sendable {
    func save(_ archive: Data, to url: URL) throws
}

/// The real one: write the archive to the chosen file.
struct FolderZipSaver: ZipSaving {
    nonisolated init() {}

    nonisolated func save(_ archive: Data, to url: URL) throws {
        // `.atomic`, so a failure partway through cannot leave a truncated zip in place of
        // a good one the export is replacing — the same reason `RigLibrary` writes its own
        // files atomically.
        try archive.write(to: url, options: .atomic)
    }
}

// MARK: - The export

enum RigExport {

    /// What the rig is called inside the archive.
    static let rigFileName = "ljoss.json"
    /// And what the engine document is called.
    static let namchainFileName = "namchain.json"

    /// Build the archive and hand it to `writer`.
    ///
    /// Pure but for that last step, which is what makes an export testable: everything
    /// above it is a value.
    static func export(_ rig: Rig, using writer: any ZipSaving, to url: URL) throws {
        try writer.save(archive(for: rig), to: url)
    }

    /// The archive itself: `<rig name>/ljoss.json` and `<rig name>/namchain.json`.
    static func archive(for rig: Rig) throws -> Data {
        // Lowering first, so a refusal costs nothing and the error is the encoder's own.
        let lowered = DocumentEncoder.encode(rig)
        guard let document = lowered.document else {
            throw RigExportError.refused(lowered.refusals.map(\.text))
        }

        let folder = folderName(for: rig)

        let rigJSON: Data
        let namchainJSON: Data
        do {
            // The same spelling as the library's own file, through the same encoder, so an
            // exported `ljoss.json` is a rig this app reads back byte for byte.
            rigJSON = try RigJSON.encode(rig)
            namchainJSON = try document.jsonData(pretty: true)
        } catch {
            throw RigExportError.failed(error.localizedDescription)
        }

        var zip = ZipWriter()
        zip.addDirectory(folder)
        zip.addFile("\(folder)/\(rigFileName)", rigJSON)
        zip.addFile("\(folder)/\(namchainFileName)", namchainJSON)
        return zip.finish()
    }

    /// A rig name as a folder and file name inside the archive.
    ///
    /// An entry name is a *path*. A `/` would silently become a second folder, and `..`
    /// would climb out of the archive's own folder — an unpacker extracting such an archive
    /// writes outside the folder the user chose, the classic zip-slip, and a leading `.`
    /// makes the folder hidden. None of that is reachable from the UI (a rig name is free
    /// text, and `Rename` accepts anything), so it is sanitised rather than assumed. `:` is
    /// stripped at the same time because the default *file* name in the save panel comes
    /// from the same string, and a colon is refused by the filesystem before the zip is even
    /// built.
    ///
    /// The separators become spaces rather than being deleted, so "Guitar / Vocal" reads as
    /// "Guitar Vocal" and not "GuitarVocal"; runs of spaces are collapsed afterwards.
    /// Segments that are empty, `.` or `..` are dropped, which is what makes a name made
    /// only of dots and slashes fall back rather than produce a folder called "..".
    static func folderName(for rig: Rig) -> String {
        sanitise(rig.name, fallback: "Rig")
    }

    /// The name offered in the save panel, without its extension.
    static func suggestedFileName(for rig: Rig) -> String {
        sanitise(rig.name, fallback: "Rig Export")
    }

    private static func sanitise(_ name: String, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:\u{0}")
            .union(.newlines)
            .union(.controlCharacters)

        // `.omitted` splits on the illegal characters, so the segments a path would be made
        // of arrive separately and each can be judged on its own.
        let segments = name.components(separatedBy: illegal).compactMap { segment -> String? in
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            // "." and ".." are the two names a path may not contain; anything else starting
            // with a dot would make the folder hidden.
            if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "." }) { return nil }
            return trimmed
        }

        var cleaned = segments.joined(separator: " ")
        while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }
}
