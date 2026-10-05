import Foundation

// How a rig is spelled as JSON, in one place.
//
// Two things write a rig file — the library's own save and the export — and they must
// agree: an exported `ljoss.json` is only worth anything if the app reads it back
// identically. Two `JSONEncoder`s configured the same way in two files would drift the
// first time one of them gained a setting, and the failure would be silent (a file that
// still loads, but not the same file). So the strategy lives here and both callers ask
// for it. This is deliberately not `Rig: Codable`'s business: a date format is a
// decision about the *file*, not about the tree.
//
// No SwiftUI here: this file is in the source list of `Tests/run-model-tests.sh`.

enum RigJSON {

    /// Pretty and key-sorted, because a rig file is a thing people read, diff and
    /// hand-edit, and Swift's per-process string hashing would otherwise shuffle the
    /// keys between runs.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encode(_ rig: Rig) throws -> Data {
        try makeEncoder().encode(rig)
    }

    static func decode(_ data: Data) throws -> Rig {
        try makeDecoder().decode(Rig.self, from: data)
    }
}
