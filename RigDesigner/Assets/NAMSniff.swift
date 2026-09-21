import Foundation

/// What a `.nam` file says about itself, read without loading the model.
struct NAMInfo: Equatable, Sendable {
    var architecture: String?
    var sampleRate: Double?
    /// `metadata.name` — the name the person who made the capture gave it.
    var name: String?
    var make: String?
    var model: String?
    var gearType: String?
}

/// What a `.wav` file's header says.
struct WAVInfo: Equatable, Sendable {
    var sampleRate: Double?
    var channels: Int?
    var frames: Int?
}

/// Reading a file's own description, boundedly.
///
/// This is a **sniff, not a parse**, and it is the same sniff the daemon's registry
/// does (`namchain/src/assets/registry.cpp`): for a `.nam`, the keys we want found in
/// the front of the file and, for the rate, in the tail; for a `.wav`, its chunk
/// headers found in the first few kilobytes. A model's weights are megabytes of JSON
/// numbers, so parsing every file whole would make a scan of a real library cost
/// seconds and hundreds of megabytes — and nothing functional depends on any of it,
/// because it is *loading* a model that decides whether it is usable.
///
/// A field outside the window comes back nil, which a row shows as a dash. That is the
/// honest failure, and it is the rule `docs/assets.md` keeps on the other side: nil for
/// "the file did not say", nil for "the file could not be read", never a number that
/// looks like an answer.
enum NAMSniff {

    /// The daemon's own window sizes. Matching them means the two libraries describe
    /// the same file the same way, including the fields each of them gives up on.
    static let prefixBytes = 16 * 1024
    static let tailBytes = 1024
    static let wavHeaderBytes = 4 * 1024

    /// The architecture whose container is an impulse response rather than a model:
    /// the reference core's `Linear` model is a convolution, and namchain's registry
    /// accepts a `.nam` in an IR root for exactly that reason.
    static let irArchitecture = "Linear"

    // MARK: - .nam

    /// `architecture` and `sample_rate`, plus whatever `metadata` the window holds.
    ///
    /// The reference writer puts `metadata` and `architecture` near the front and
    /// `sample_rate` after the weights, which can be hundreds of kilobytes further on,
    /// so the tail is read only for what the front did not answer.
    static func nam(at url: URL) -> NAMInfo {
        var info = NAMInfo()

        if let front = text(prefix: url, limit: prefixBytes) {
            info.architecture = stringField("architecture", in: front)
            info.sampleRate = numberField("sample_rate", in: front)
            if let metadata = jsonObject(named: "metadata", in: front) {
                info.name = string(metadata["name"])
                info.make = string(metadata["gear_make"])
                info.model = string(metadata["gear_model"])
                info.gearType = string(metadata["gear_type"])
            }
        }

        if (info.sampleRate == nil || info.architecture == nil),
           let tail = text(tail: url, limit: tailBytes) {
            if info.sampleRate == nil { info.sampleRate = numberField("sample_rate", in: tail) }
            if info.architecture == nil { info.architecture = stringField("architecture", in: tail) }
        }

        if let rate = info.sampleRate, rate <= 0 { info.sampleRate = nil }
        if info.architecture?.isEmpty == true { info.architecture = nil }
        return info
    }

    // MARK: - .wav

    /// A RIFF `fmt ` and `data` pair, read from the header.
    ///
    /// Reading stops at the first `data` chunk header, so a WAV whose header is buried
    /// behind megabytes of metadata reports no frame count rather than being read
    /// whole — the same clamp the daemon's probe makes.
    static func wav(at url: URL) -> WAVInfo? {
        guard let header = data(prefix: url, limit: wavHeaderBytes), header.count >= 12 else {
            return nil
        }
        let bytes = [UInt8](header)
        guard chunk(bytes, at: 0) == "RIFF", chunk(bytes, at: 8) == "WAVE" else { return nil }

        var sampleRate: Double?
        var channels: Int?
        var bits = 0
        var dataBytes: Int?
        var haveFormat = false

        var at = 12
        while at + 8 <= bytes.count {
            let size = Int(u32(bytes, at + 4))
            let payload = at + 8

            if chunk(bytes, at: at) == "fmt ", payload + 16 <= bytes.count {
                channels = Int(u16(bytes, payload + 2))
                sampleRate = Double(u32(bytes, payload + 4))
                bits = Int(u16(bytes, payload + 14))
                haveFormat = true
            } else if chunk(bytes, at: at) == "data" {
                dataBytes = size
            }

            if haveFormat, dataBytes != nil { break }
            // Chunks are word-aligned, so an odd size is followed by a pad byte.
            at = payload + size + (size % 2)
        }

        guard haveFormat else { return nil }
        var frames: Int?
        if let dataBytes {
            let frameBytes = (bits / 8) * max(channels ?? 1, 1)
            frames = frameBytes == 0 ? nil : dataBytes / frameBytes
        }
        if let rate = sampleRate, rate <= 0 { sampleRate = nil }
        return WAVInfo(sampleRate: sampleRate, channels: channels, frames: frames)
    }

    // MARK: - Windows

    private static func data(prefix url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit)
    }

    private static func text(prefix url: URL, limit: Int) -> String? {
        data(prefix: url, limit: limit).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func text(tail url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let want = min(UInt64(limit), size)
        guard (try? handle.seek(toOffset: size - want)) != nil,
              let body = try? handle.read(upToCount: Int(want)) else { return nil }
        return String(decoding: body, as: UTF8.self)
    }

    // MARK: - The JSON out of the window

    /// The index of the first character of a key's value, whitespace and the `:` gone.
    private static func valueStart(after key: String, in text: String) -> String.Index? {
        guard let found = text.range(of: "\"\(key)\"") else { return nil }
        var at = found.upperBound
        func skipWhitespace() {
            while at < text.endIndex, text[at] == " " || text[at] == "\t"
                    || text[at] == "\n" || text[at] == "\r" {
                at = text.index(after: at)
            }
        }
        skipWhitespace()
        guard at < text.endIndex, text[at] == ":" else { return nil }
        at = text.index(after: at)
        skipWhitespace()
        return at < text.endIndex ? at : nil
    }

    private static func stringField(_ key: String, in text: String) -> String? {
        guard let start = valueStart(after: key, in: text), text[start] == "\"" else { return nil }
        var at = text.index(after: start)
        var out = ""
        while at < text.endIndex {
            let character = text[at]
            if character == "\\" {
                let escaped = text.index(after: at)
                guard escaped < text.endIndex else { return nil }
                out.append(text[escaped])
                at = text.index(after: escaped)
                continue
            }
            if character == "\"" {
                let value = out.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            out.append(character)
            at = text.index(after: at)
        }
        return nil
    }

    private static func numberField(_ key: String, in text: String) -> Double? {
        guard let start = valueStart(after: key, in: text) else { return nil }
        var at = start
        var digits = ""
        while at < text.endIndex, text[at].isNumber || text[at] == "." || text[at] == "-"
                || text[at] == "+" || text[at] == "e" || text[at] == "E" {
            digits.append(text[at])
            at = text.index(after: at)
        }
        return Double(digits)
    }

    /// A complete JSON object under `key`, or nil when the window cut it in half.
    ///
    /// Brace matching rather than a regex, and then `JSONSerialization` on the slice:
    /// the object is small even when the file is not, so this parses the metadata for
    /// real instead of pattern-matching fields out of the whole window, where a
    /// `"name"` inside the training settings would be indistinguishable from the
    /// capture's own name.
    private static func jsonObject(named key: String, in text: String) -> [String: Any]? {
        guard let start = valueStart(after: key, in: text), text[start] == "{" else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var at = start
        while at < text.endIndex {
            let character = text[at]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let end = text.index(after: at)
                    guard let body = String(text[start..<end]).data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: body) else { return nil }
                    return object as? [String: Any]
                }
            }
            at = text.index(after: at)
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - RIFF

    private static func chunk(_ bytes: [UInt8], at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
}
