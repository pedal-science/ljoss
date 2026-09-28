import Foundation
import Network

// One TCP connection to namchaind.
//
// The whole client contract, from docs/daemon.md: **a length prefix, a token, and
// the JSON**. Everything intricate here is the first of those — a stream socket has
// no message boundaries, so one `receive` is not one message and two replies can
// arrive in one read. The daemon's own tests assert both cases, and the place a
// hand-rolled client goes wrong is exactly here.
//
// `tools/namchainctl/namchainctl.cpp` is the reference implementation.

actor EngineClient {

    /// The daemon's own default cap on a request. Checked on the way out, so an
    /// oversized document is refused before it is sent rather than costing the connection.
    private static let maxMessageBytes = EngineFraming.defaultMaxMessageBytes

    /// What a reply may be. Larger than a request: a reply lists the device's library.
    private static let maxReplyBytes = EngineFraming.maxReplyBytes

    /// Long enough for a document apply that has to compile and prewarm every chain,
    /// short enough that a dead device is noticed rather than waited on.
    private static let replyTimeout = Duration.seconds(10)

    /// What the system otherwise says only in its log, as "Local network prohibited":
    /// this app has not been allowed onto the local network. The permission follows the
    /// app's signing identity, so a differently signed build asks again.
    #if os(macOS)
    static let localNetworkDenied = "macOS is not letting Rig Designer reach the local network. "
        + "Allow it in System Settings → Privacy & Security → Local Network."
    #else
    static let localNetworkDenied = "iOS is not letting Rig Designer reach the local network. "
        + "Allow it in Settings → Privacy & Security → Local Network."
    #endif

    private let host: String
    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(label: "namchain.client")

    private var connection: NWConnection?
    private var reader: Task<Void, Never>?
    private var inbox = Data()
    private var pending: [String: Waiting] = [:]
    private var counter = 0

    /// Why the connection ended, once it has. Every later call is told at once, rather
    /// than sending into a closed socket and waiting out `replyTimeout` for an answer.
    private var ended: EngineTransportError?

    private struct Waiting {
        var continuation: CheckedContinuation<Data, Error>
        var timeout: Task<Void, Never>
    }

    init(host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    // MARK: - Connecting

    /// Open the socket and shake hands. Nothing else is answered until the token has
    /// been accepted, so the handshake is part of connecting rather than a first call
    /// the caller could forget to make.
    @discardableResult
    func connect() async throws -> EngineHello {
        close()
        ended = nil

        guard let endpoint = NWEndpoint.Port(rawValue: port) else {
            throw EngineTransportError.unreachable("\(port) is not a port number.")
        }
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            // Control messages are small and infrequent; waiting to fill a segment
            // would add latency to every knob.
            tcp.noDelay = true
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpoint, using: parameters)
        self.connection = connection

        try await waitUntilReady(connection)
        reader = Task { [weak self] in await self?.read(from: connection) }

        return try await call(HelloRequest(token: token.isEmpty ? nil : token),
                              expecting: EngineHello.self)
    }

    func close() {
        reader?.cancel()
        reader = nil
        connection?.cancel()
        connection = nil
        inbox.removeAll()
        failEveryonePending(with: EngineTransportError.closed)
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            // Weak: the connection holds this handler, so a strong reference back to it
            // would keep both alive after the connection is let go.
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .ready:
                    once.succeed(())
                case .failed(let error):
                    once.fail(.unreachable(error.localizedDescription))
                case .waiting(let error):
                    // `.waiting` means the path is not viable and Network will keep
                    // retrying. For an appliance on the LAN, saying why now beats
                    // hanging until someone gives up.
                    if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        once.fail(.unreachable(Self.localNetworkDenied))
                    } else {
                        once.fail(.unreachable(error.localizedDescription))
                    }
                case .cancelled:
                    once.fail(.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    // MARK: - Calling

    func call<Response: Decodable & Sendable>(_ request: some EngineRequest,
                                              expecting: Response.Type) async throws -> Response {
        var request = request
        counter += 1
        let id = String(counter)
        request.id = id

        let framed = try frame(request)
        let body = try await transmit(framed, waitingFor: id)

        let envelope = try decode(EngineEnvelope.self, from: body)
        if !envelope.ok { throw envelope.error ?? EngineFailure(code: "bad_request", message: "refused") }
        return try decode(Response.self, from: body)
    }

    private func frame(_ request: some EngineRequest) throws -> Data {
        let body = try EngineCoding.encoder.encode(request)
        guard body.count <= Self.maxMessageBytes else {
            throw EngineTransportError.frameTooLarge(body.count)
        }
        return EngineFraming.frame(body)
    }

    private func transmit(_ framed: Data, waitingFor id: String) async throws -> Data {
        guard let connection else { throw ended ?? EngineTransportError.notConnected }

        return try await withCheckedThrowingContinuation { continuation in
            // Registered before the bytes leave, because the reply can come back
            // before `send`'s completion handler runs.
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: Self.replyTimeout)
                await self?.giveUp(on: id)
            }
            pending[id] = Waiting(continuation: continuation, timeout: timeout)

            connection.send(content: framed, completion: .contentProcessed { [self] error in
                guard let error else { return }
                // Strongly held on purpose: the task is immediate, and a send that
                // failed has a waiter to release.
                Task { await fail(id, with: EngineTransportError.unreachable(error.localizedDescription)) }
            })
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        do {
            return try EngineCoding.decoder.decode(type, from: body)
        } catch {
            throw EngineTransportError.malformed(String(describing: error))
        }
    }

    // MARK: - Reading

    private func read(from connection: NWConnection) async {
        while !Task.isCancelled {
            do {
                let (chunk, done) = try await receive(from: connection)
                // A reader whose connection has since been replaced has nothing to say
                // about the new one, and ending it would take the new one down too.
                guard self.connection === connection else { return }
                if let chunk, !chunk.isEmpty {
                    inbox.append(chunk)
                    try cutFrames()
                }
                if done {
                    end(.closed)
                    return
                }
            } catch {
                guard self.connection === connection else { return }
                end(error as? EngineTransportError ?? .closed)
                return
            }
        }
    }

    /// The far end went away, or the stream can't be read any further. Whoever is
    /// waiting is told now, and so is every call after this.
    private func end(_ error: EngineTransportError) {
        ended = error
        connection?.cancel()
        connection = nil
        failEveryonePending(with: error)
    }

    private func receive(from connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error {
                    once.fail(.unreachable(error.localizedDescription))
                } else {
                    once.succeed((data, complete))
                }
            }
        }
    }

    /// A message may arrive in pieces, and several may arrive in one read.
    /// `EngineFraming` handles both, and is tested without a socket.
    private func cutFrames() throws {
        do {
            for body in try EngineFraming.cut(from: &inbox, maxMessageBytes: Self.maxReplyBytes) {
                deliver(body)
            }
        } catch EngineFraming.Failure.declaredTooLarge(let length) {
            // There is no resynchronising a stream after a framing error, so this
            // ends the connection rather than being read past.
            throw EngineTransportError.frameTooLarge(length)
        }
    }

    private func deliver(_ body: Data) {
        // Nothing is pushed today, so a reply with no id — or one nobody is waiting
        // for — is a stale answer to a call that already timed out. Dropping it is
        // correct; the alternative would be resuming a continuation twice.
        guard let id = (try? EngineCoding.decoder.decode(EngineEnvelope.self, from: body))?.id,
              let waiting = pending.removeValue(forKey: id) else { return }
        waiting.timeout.cancel()
        waiting.continuation.resume(returning: body)
    }

    // MARK: - Failing

    private func giveUp(on id: String) { fail(id, with: EngineTransportError.timedOut) }

    private func fail(_ id: String, with error: Error) {
        guard let waiting = pending.removeValue(forKey: id) else { return }
        waiting.timeout.cancel()
        waiting.continuation.resume(throwing: error)
    }

    private func failEveryonePending(with error: Error) {
        let waiting = pending
        pending.removeAll()
        for (_, one) in waiting {
            one.timeout.cancel()
            one.continuation.resume(throwing: error)
        }
    }
}

/// A continuation that can be handed to a callback which may fire more than once.
///
/// `NWConnection`'s state handler does exactly that — `.waiting` then `.ready`, or
/// `.failed` then `.cancelled` — and resuming a continuation twice is a crash rather
/// than a warning.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    /// `T` and the error are both `Sendable` so the value can cross out of the
    /// callback's isolation; `Result<T, any Error>` could not, because `any Error`
    /// is not.
    func succeed(_ value: T) { take()?.resume(returning: value) }

    func fail(_ error: EngineTransportError) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let waiting = continuation
        continuation = nil
        return waiting
    }
}
