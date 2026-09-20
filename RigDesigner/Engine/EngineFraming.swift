import Foundation

// The TCP transport's framing.
//
// A stream socket has no message boundaries, so the framing is the smallest thing
// that puts them back: a u32 **little-endian** byte count followed by exactly that
// many bytes of one JSON body. The engine's own `framing.h` writes the length byte
// by byte rather than copying a `uint32_t`, because the wire format is a byte order
// and not whatever this machine happens to use; this does the same.
//
// It lives apart from `EngineClient` so it can be tested without a socket. The
// daemon's tests cover a message arriving one byte at a time and two messages
// arriving in one read; so do ours.

enum EngineFraming {

    static let headerBytes = 4

    /// The daemon's own `tcp_max_message_bytes` default.
    static let defaultMaxMessageBytes = 1 << 20

    enum Failure: Error, Sendable, Hashable {
        /// A length the far end would never have sent, so the stream is out of step.
        /// There is no resynchronising a stream after this — the connection is done.
        case declaredTooLarge(Int)
    }

    static func frame(_ body: Data) -> Data {
        let length = UInt32(body.count)
        var framed = Data(capacity: headerBytes + body.count)
        framed.append(UInt8(length & 0xff))
        framed.append(UInt8((length >> 8) & 0xff))
        framed.append(UInt8((length >> 16) & 0xff))
        framed.append(UInt8((length >> 24) & 0xff))
        framed.append(body)
        return framed
    }

    /// Take every complete message out of `buffer`, leaving any partial tail behind.
    static func cut(from buffer: inout Data,
                    maxMessageBytes: Int = defaultMaxMessageBytes) throws -> [Data] {
        var bodies: [Data] = []
        while true {
            guard buffer.count >= headerBytes else { return bodies }

            let header = [UInt8](buffer.prefix(headerBytes))
            let length = Int(UInt32(header[0])
                             | UInt32(header[1]) << 8
                             | UInt32(header[2]) << 16
                             | UInt32(header[3]) << 24)

            // Checked from the header alone, before a byte of the body is waited for.
            guard length <= maxMessageBytes else { throw Failure.declaredTooLarge(length) }
            guard buffer.count >= headerBytes + length else { return bodies }

            bodies.append(Data(buffer.dropFirst(headerBytes).prefix(length)))
            buffer.removeFirst(headerBytes + length)
        }
    }
}
