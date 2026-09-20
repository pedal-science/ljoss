import Foundation
import Observation

// The app's view of the device.
//
// Three things it is deliberately not. It is **not** part of the rig: connection,
// health and generation never touch `Rig`, because writing them into the document
// would mark every rig modified and thrash the library's 400 ms autosave. It is
// **not** a mirror of the engine: this app owns the document and `rig.get` is a
// diagnostic, so nothing is ever rehydrated from the device. And it is **not**
// synchronous: a reply is an acknowledgement, and what the device is actually
// hearing is `audible_generation` catching up with `generation`.

@MainActor
@Observable
final class EngineSession {

    enum Connection: Equatable, Sendable {
        case offline
        case connecting
        case online
        case failed(String)

        var isOnline: Bool { self == .online }
    }

    /// Coalesce the flurry a drag produces into one apply, the same shape
    /// `RigLibrary` uses for its writes. Shorter than the 400 ms disk debounce
    /// because this one is what the player hears.
    private static let applyDebounce = Duration.milliseconds(250)

    /// A few hertz, as docs/ui-integration-plan.md §6.3 asks for. There is no
    /// telemetry subscription to replace it with yet.
    private static let statusInterval = Duration.milliseconds(500)

    // MARK: State the UI reads

    private(set) var connection: Connection = .offline
    private(set) var hello: EngineHello?
    private(set) var status: EngineStatus?
    private(set) var assets = AssetsResponse()

    /// Why the current rig cannot be sent. Empty when it can.
    private(set) var refusals: [EncodeRefusal] = []

    /// The device's own words for the last thing it would not do. Shown verbatim:
    /// the message names the node and lists the alternatives, and re-deriving it
    /// here is how two clients end up disagreeing.
    private(set) var lastFailure: EngineFailure?

    private(set) var isSending = false

    var settings: EngineSettings

    // MARK: Private

    private var client: EngineClient?
    private var poller: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var latest: Rig?

    init(settings: EngineSettings = EngineSettingsStore.load()) {
        self.settings = settings
    }

    // MARK: - Connecting

    func connect() async {
        if let missing = settings.whatIsMissing {
            connection = .failed(missing)
            return
        }
        await open()
    }

    private func open() async {
        disconnect()
        connection = .connecting

        let client = EngineClient(host: settings.host, port: settings.port, token: settings.token)
        self.client = client

        do {
            hello = try await client.connect()
            connection = .online
            lastFailure = nil
            // The catalogue is small and static except for the library-backed
            // options, so one fetch per connection is the documented story.
            assets = (try? await client.call(AssetsRequest(refresh: false),
                                             expecting: AssetsResponse.self)) ?? AssetsResponse()
            startPolling()
            // Reconcile: the device is running whatever it was left with, and this
            // app owns the document, so the document wins.
            if let latest { await send(latest) }
        } catch {
            connection = .failed(describe(error))
            self.client = nil
        }
    }

    func disconnect() {
        poller?.cancel(); poller = nil
        debounce?.cancel(); debounce = nil
        let client = self.client
        self.client = nil
        Task { await client?.close() }
        connection = .offline
        status = nil
        hello = nil
    }

    /// Nothing is polled while the app is in the background; a device that went away
    /// meanwhile is noticed on the next call rather than by a timer nobody watched.
    func pause() {
        poller?.cancel()
        poller = nil
    }

    func resume() {
        guard connection.isOnline, poller == nil else { return }
        startPolling()
    }

    // MARK: - Sending

    /// Called from `RigEditor.rig.didSet`, beside the library's own write. A drag is
    /// local and a drop is one commit, so this fires once per committed edit.
    func rigDidChange(_ rig: Rig) {
        latest = rig
        // Encoded even when offline, so the canvas can badge what this device could
        // not play before anyone tries to send it.
        refusals = DocumentEncoder.encode(rig).refusals

        guard connection.isOnline else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.applyDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.send(rig)
        }
    }

    /// Re-send the whole document. The recovery path when the device and this app
    /// have drifted apart — another client, an operator's reload, a failed node.
    func resend() async {
        guard let latest else { return }
        await send(latest)
    }

    private func send(_ rig: Rig) async {
        guard let client, connection.isOnline else { return }

        var result = DocumentEncoder.encode(rig)
        result.refusals.append(contentsOf: channelRefusals(for: result))
        refusals = result.refusals

        guard result.refusals.isEmpty, let document = result.document else { return }

        isSending = true
        defer { isSending = false }

        do {
            _ = try await client.call(ApplyRequest(document: document), expecting: ApplyResponse.self)
            lastFailure = nil

            // A hidden chain is sent and then muted, visibly: `layout` is a viewing
            // preference, and a layout tap that silently changed what is audible is
            // the failure the grow-only layout was designed to avoid.
            let hidden = Set(result.hiddenChainIDs)
            for chain in document.chains {
                _ = try? await client.call(
                    MuteRequest(mute: hidden.contains(chain.id), chain: chain.id),
                    expecting: EmptyResponse.self)
            }
            await refreshStatus()
        } catch let failure as EngineFailure {
            // A refusal is a normal answer: the connection stays open and the running
            // plan is untouched.
            lastFailure = failure
        } catch {
            connection = .failed(describe(error))
        }
    }

    /// A chain bound to a channel the device does not have is refused at load, naming
    /// the chain. Saying so first is the same answer with somewhere to go.
    private func channelRefusals(for result: EncodeResult) -> [EncodeRefusal] {
        guard let document = result.document, let status else { return [] }
        let capture = status.captureChannels ?? 1
        let playback = status.playbackChannels ?? 1

        return document.chains.compactMap { chain in
            if chain.inputChannel >= capture {
                return EncodeRefusal(
                    chain: chain.name, subject: nil,
                    message: "needs input channel \(chain.inputChannel + 1), and the device is "
                           + "configured for \(capture)")
            }
            if chain.outputChannel >= playback {
                return EncodeRefusal(
                    chain: chain.name, subject: nil,
                    message: "needs output channel \(chain.outputChannel + 1), and the device is "
                           + "configured for \(playback)")
            }
            return nil
        }
    }

    func setMuted(_ muted: Bool, chain: String?) async {
        guard let client else { return }
        _ = try? await client.call(MuteRequest(mute: muted, chain: chain), expecting: EmptyResponse.self)
        await refreshStatus()
    }

    func refreshAssets() async {
        guard let client else { return }
        if let fresh = try? await client.call(AssetsRequest(refresh: true), expecting: AssetsResponse.self) {
            assets = fresh
        }
    }

    // MARK: - Status

    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: Self.statusInterval)
            }
        }
    }

    private func refreshStatus() async {
        guard let client else { return }
        do {
            status = try await client.call(PlainRequest("engine.status"),
                                           expecting: StatusResponse.self).status
        } catch let error as EngineTransportError {
            connection = .failed(error.message)
            poller?.cancel()
            poller = nil
        } catch {
            // A protocol-level refusal to a status call is odd but not fatal.
            lastFailure = error as? EngineFailure
        }
    }

    // MARK: - What the UI shows

    /// `ok`, `warn` or `error` — one field, derived by the engine from its issues so
    /// the light and the list cannot disagree.
    var health: String {
        guard connection.isOnline else { return "offline" }
        return status?.health ?? "warn"
    }

    var issues: [EngineIssue] { status?.issues ?? [] }

    /// True while the device is still crossfading into what was last sent.
    var isAdopting: Bool { status.map { !$0.isAdopted } ?? false }

    /// Whether this device can play a block at all. Unknown when offline, which is
    /// why it is an optional rather than a false.
    func canPlay(_ componentID: String) -> Bool? {
        guard connection.isOnline else { return nil }
        return BlockMappings.isMapped(componentID)
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case let transport as EngineTransportError: transport.message
        case let failure as EngineFailure: failure.message
        default: String(describing: error)
        }
    }
}
