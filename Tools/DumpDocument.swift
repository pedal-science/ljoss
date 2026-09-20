import Foundation

// Print the engine document for a named test rig, exactly as the app would send it.
//
// This exists so that a test run against a real `namchaind` is testing *this app's* bytes
// rather than JSON someone wrote out by hand to look like them. It compiles the same
// SwiftUI-free sources as Tests/run-model-tests.sh and calls the same `DocumentEncoder`
// the live session calls, so there is no second encoder to drift away from the first.

@main
enum DumpDocument {

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let name = arguments.first, let make = TestRigs.byName[name] else {
            FileHandle.standardError.write(Data(
                "usage: dump-engine-document <\(TestRigs.names)> [--bare]\n".utf8))
            exit(2)
        }

        let result = DocumentEncoder.encode(make())
        for refusal in result.refusals {
            FileHandle.standardError.write(Data(
                "refused: \(refusal.chain): \(refusal.message)\n".utf8))
        }
        guard let document = result.document else { exit(1) }

        // `--bare` prints chains[0] alone. `namchain-render --graph` takes exactly one
        // chain, and the daemon reads a chain with no wrapper as chain "main" on channels
        // 0 and 0. The wrapped form is what `rig.apply` carries, and that path is
        // exercised from the app itself rather than from here.
        let data: Data
        if arguments.contains("--bare") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(document.chains[0])
        } else {
            data = try document.jsonData(pretty: true)
        }

        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
