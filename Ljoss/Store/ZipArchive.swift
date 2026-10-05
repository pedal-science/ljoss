import Foundation

// A zip file, in memory, both ways.
//
// The app ships one format it shares with something outside itself — a rig export a CLI
// can unpack — and Foundation has no archiver: `FileManager` has no zip, and
// `NSFileCoordinator`'s `.forUploading` option (the trick that works on macOS) has no iOS
// equivalent, so this multiplatform target cannot reach it. The alternative was a package
// dependency for two files in one folder.
//
// So this is the format's *stored* subset and nothing else: no compression, no zip64, no
// encryption, no data descriptors. That is a deliberate limit rather than a gap — the
// payload is a few kilobytes of JSON, an archiver that had to be trusted about a deflate
// stream would be a liability, and `unzip`, Finder, Python's `zipfile` and
// `System.IO.Compression` all read a stored archive.
//
// A zip must be given its central directory, and that is the end of the file, so this
// builds the whole archive in memory and writes it in one go. Measured against the
// alternative of seeking back to patch sizes in: a rig export is small, and an archive
// that is a `Data` is one that a test can read back without a sandbox or a file.
//
// No SwiftUI here: this file is in the source list of `Tests/run-model-tests.sh`.

// MARK: - Writing

/// A zip under construction.
struct ZipWriter {

    private struct Entry {
        var name: String
        var isDirectory: Bool
        var crc: UInt32
        var content: Data
    }

    private var entries: [Entry] = []

    init() {}

    /// The names added so far, in the order they will appear in the directory.
    var names: [String] { entries.map(\.name) }

    /// Add a folder. It carries no content; it is here so that an unpacker which does not
    /// invent the parent of a path still shows it.
    mutating func addDirectory(_ name: String) {
        entries.append(Entry(name: name.hasSuffix("/") ? name : name + "/",
                             isDirectory: true,
                             crc: ZipCRC32.checksum(of: Data()),
                             content: Data()))
    }

    /// Add a stored file. `name` is its whole path inside the archive, `/`-separated.
    mutating func addFile(_ name: String, _ data: Data) {
        entries.append(Entry(name: name,
                             isDirectory: false,
                             crc: ZipCRC32.checksum(of: data),
                             content: data))
    }

    /// The whole archive, directory record and all.
    func finish() -> Data {
        var out = Data()
        // Where each local header went, so the directory can point at it.
        var offsets: [Int] = []
        offsets.reserveCapacity(entries.count)

        for entry in entries {
            let name = Array(entry.name.utf8)
            offsets.append(out.count)
            out.appendLE(UInt32(0x0403_4b50))                 // "PK\3\4"
            out.appendLE(UInt16(20))                          // version needed
            // Bit 11: the name is UTF-8 rather than CP437, which matters as soon as a
            // rig is called anything but ASCII.
            out.appendLE(UInt16(1 << 11))
            out.appendLE(UInt16(0))                           // stored
            out.appendLE(UInt16(0))                           // modified time
            out.appendLE(UInt16(0x21))                        // modified date: 1980-01-01
            out.appendLE(entry.crc)
            out.appendLE(UInt32(entry.content.count))         // compressed size
            out.appendLE(UInt32(entry.content.count))         // uncompressed size
            out.appendLE(UInt16(name.count))
            out.appendLE(UInt16(0))                           // extra field length
            out.append(contentsOf: name)
            out.append(entry.content)
        }

        let directoryStart = out.count

        for (offset, entry) in zip(offsets, entries) {
            let name = Array(entry.name.utf8)
            out.appendLE(UInt32(0x0201_4b50))                 // "PK\1\2"
            out.appendLE(UInt16(20))                          // version made by
            out.appendLE(UInt16(20))                          // version needed
            out.appendLE(UInt16(1 << 11))
            out.appendLE(UInt16(0))                           // stored
            out.appendLE(UInt16(0))                           // modified time
            out.appendLE(UInt16(0x21))                        // modified date
            out.appendLE(entry.crc)
            out.appendLE(UInt32(entry.content.count))
            out.appendLE(UInt32(entry.content.count))
            out.appendLE(UInt16(name.count))
            out.appendLE(UInt16(0))                           // extra field length
            out.appendLE(UInt16(0))                           // comment length
            out.appendLE(UInt16(0))                           // disk number
            out.appendLE(UInt16(0))                           // internal attributes
            // 0o40755 for a directory and 0o100644 for a file, in the top half of the
            // external attributes — what Info-ZIP writes, and what unpacks anywhere.
            out.appendLE(entry.isDirectory ? UInt32(0o40755 << 16) : UInt32(0o100644 << 16))
            out.appendLE(UInt32(offset))
            out.append(contentsOf: name)
        }

        let directoryLength = out.count - directoryStart

        out.appendLE(UInt32(0x0605_4b50))                     // "PK\5\6"
        out.appendLE(UInt16(0))                               // this disk
        out.appendLE(UInt16(0))                               // disk holding the directory
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt32(directoryLength))
        out.appendLE(UInt32(directoryStart))
        out.appendLE(UInt16(0))                               // comment length
        return out
    }
}

// MARK: - Reading

enum ZipArchiveError: Error, Equatable {
    case notAZipFile
    case truncated
    case unsupported(String)
}

/// A zip, read back.
///
/// This is here for the tests and for anything that wants to check an archive without
/// shelling out to `unzip`. It reads the **central directory** rather than walking local
/// headers, so it also proves that the directory the writer produced is the one a real
/// unpacker will use — a local-header walk would happily read an archive nothing else can.
struct ZipArchive {

    struct Entry: Equatable {
        var name: String
        var isDirectory: Bool
        var method: UInt16
        var crc: UInt32
        var size: Int
        var localHeaderOffset: Int
    }

    private let data: Data
    let entries: [Entry]

    init(data: Data) throws {
        self.data = data
        let end = try Self.endOfCentralDirectory(in: data)
        let count = Int(end.count)
        var cursor = Int(end.directoryOffset)

        var entries: [Entry] = []
        entries.reserveCapacity(count)

        for _ in 0..<count {
            guard cursor + 46 <= data.count else { throw ZipArchiveError.truncated }
            guard Self.uint32(data, at: cursor) == 0x0201_4b50 else {
                throw ZipArchiveError.notAZipFile
            }
            let flags = Self.uint16(data, at: cursor + 8)
            let method = Self.uint16(data, at: cursor + 10)
            let crc = Self.uint32(data, at: cursor + 16)
            let compressed = Int(Self.uint32(data, at: cursor + 20))
            let uncompressed = Int(Self.uint32(data, at: cursor + 24))
            let nameLength = Int(Self.uint16(data, at: cursor + 28))
            let extraLength = Int(Self.uint16(data, at: cursor + 30))
            let commentLength = Int(Self.uint16(data, at: cursor + 32))
            let localHeaderOffset = Int(Self.uint32(data, at: cursor + 42))
            let nameStart = cursor + 46

            guard nameStart + nameLength <= data.count else { throw ZipArchiveError.truncated }

            // Bit 11, or the name is CP437 by the letter of the format, which no rig name
            // this app can produce is. Refusing beats decoding it as mojibake.
            let name = Self.name(in: data, at: nameStart, length: nameLength)
            guard flags & (1 << 11) != 0 else {
                throw ZipArchiveError.unsupported("“\(name)” is not marked as a UTF-8 name")
            }

            entries.append(Entry(name: name,
                                 isDirectory: name.hasSuffix("/"),
                                 method: method,
                                 crc: crc,
                                 size: uncompressed,
                                 localHeaderOffset: localHeaderOffset))
            cursor = nameStart + nameLength + extraLength + commentLength

            // A stored entry has these equal, so a document that disagrees with itself is
            // caught here rather than handed on as a size that will not read.
            guard method == 0, compressed == uncompressed else {
                throw ZipArchiveError.unsupported("“\(name)” is not stored, and only a stored "
                                                  + "entry can be read here")
            }
        }

        self.entries = entries
    }

    /// The names, in directory order.
    var names: [String] { entries.map(\.name) }

    /// One entry's bytes, with its CRC checked.
    func content(_ name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw ZipArchiveError.unsupported("no entry called “\(name)”")
        }
        let start = try Self.contentStart(of: entry, in: data)
        guard start + entry.size <= data.count else { throw ZipArchiveError.truncated }
        let content = data.subdata(in: start..<(start + entry.size))
        guard ZipCRC32.checksum(of: content) == entry.crc else {
            throw ZipArchiveError.unsupported("“\(name)” does not match its checksum")
        }
        return content
    }

    /// The single folder an export is wrapped in: the name of the only directory entry,
    /// without its trailing slash. Nil when there is not exactly one.
    var folderName: String? {
        let directories = entries.filter(\.isDirectory)
        guard directories.count == 1, let name = directories.first?.name else { return nil }
        return String(name.dropLast())
    }

    // MARK: Plumbing

    private static func name(in data: Data, at start: Int, length: Int) -> String {
        String(decoding: data.subdata(in: start..<(start + length)), as: UTF8.self)
    }

    private static func contentStart(of entry: Entry, in data: Data) throws -> Int {
        let offset = entry.localHeaderOffset
        guard offset + 30 <= data.count else { throw ZipArchiveError.truncated }
        guard uint32(data, at: offset) == 0x0403_4b50 else { throw ZipArchiveError.notAZipFile }
        let nameLength = Int(uint16(data, at: offset + 26))
        let extraLength = Int(uint16(data, at: offset + 28))
        return offset + 30 + nameLength + extraLength
    }

    private struct EndOfCentralDirectory {
        var count: UInt16
        var directoryOffset: UInt32
    }

    /// The end record, found from the back: it is the only fixed point in the file, and a
    /// comment may follow it, so the search starts at the last offset it could occupy.
    private static func endOfCentralDirectory(in data: Data) throws -> EndOfCentralDirectory {
        guard data.count >= 22 else { throw ZipArchiveError.truncated }
        let lastPossibleStart = data.count - 22
        let earliest = max(0, data.count - 22 - 65_535)

        var start = lastPossibleStart
        while start >= earliest {
            if uint32(data, at: start) == 0x0605_4b50 {
                return EndOfCentralDirectory(count: uint16(data, at: start + 10),
                                             directoryOffset: uint32(data, at: start + 16))
            }
            start -= 1
        }
        throw ZipArchiveError.notAZipFile
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16
            | UInt32(data[base + 3]) << 24
    }
}

// MARK: - CRC-32

/// The checksum every entry carries, from the format's own reflected polynomial
/// (IEEE 802.3, 0xEDB88320).
enum ZipCRC32 {

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func checksum(of data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Little-endian writing

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
