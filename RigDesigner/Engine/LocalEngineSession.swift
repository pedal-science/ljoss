import Foundation

// The session's half of the local engine: pointing at it, and finding out whether one is already
// there.
//
// Kept out of `LocalEngine.swift` so that file stays about the process, and out of `EngineSession`
// so the session does not have to know that a local engine exists at all.

extension EngineSession {

    /// \brief Whether something that speaks this protocol is already listening on the port.
    ///
    /// Deliberately a real handshake rather than a port probe. A stale or foreign listener that
    /// merely accepts a connection would otherwise be adopted, and the failure would surface later
    /// as a protocol error instead of here as "that port is busy".
    func reachesLocalDaemon(port: UInt16, token: String) async -> Bool {
        let probe = EngineClient(host: "127.0.0.1", port: port, token: token)
        do {
            _ = try await probe.connect()
            await probe.close()
            return true
        } catch {
            await probe.close()
            return false
        }
    }

    /// \brief Use the local engine, without touching what the app remembers about a real device.
    ///
    /// The host, port and token go into this session's settings and nowhere else. That is the point
    /// of the local engine being a mode: a user who has a board configured keeps that configuration,
    /// and turning the local engine off leaves them pointed at it again.
    func adoptLocalEngine(port: UInt16, token: String) {
        settings = EngineSettings(host: "127.0.0.1", port: port, token: token)
        Task { await connect() }
    }
}
