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
//
// How an edit reaches the device depends on what the engine does with it
// (`EngineEdits`). A control whose parameter the engine ramps is **streamed** as it
// moves: `rig.patch` `set_param`, no more often than `streamInterval`, one patch in
// flight at a time, and the last value always sent. Anything else is the whole
// document, once the rig has been still for `applyDebounce`.

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

    /// How long a structural edit waits for the rig to be still before it goes as one
    /// `rig.apply`. The burst an edit produces becomes one rebuild, and a control whose
    /// parameter cannot ramp behaves as commit-on-release. Shorter than the 400 ms disk
    /// debounce because this one is what the player hears.
    private static let applyDebounce = Duration.milliseconds(250)

    /// The most often a ramped parameter is sent while its control moves.
    private static let streamInterval = Duration.milliseconds(10)

    /// A few hertz, as docs/ui-integration-plan.md §6.3 asks for. There is no
    /// telemetry subscription to replace it with yet.
    private static let statusInterval = Duration.milliseconds(500)

    /// The waits between tries while a connection is wanted: short at first, for a device
    /// that is still starting or a permission just granted, then every 30 s.
    private static let retryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30),
    ]

    // MARK: State the UI reads

    /// The device's audio levels, polled at their own rate and kept out of `status`.
    ///
    /// A separate object because `status` is read by every block on the canvas: putting levels
    /// in it would invalidate the whole rig twenty times a second to move a few bars
    /// (EngineLevels has the reasoning). This session owns its lifetime, so pausing the app or
    /// losing the device stops the meter polling too.
    let levels = EngineLevelsModel()

    private(set) var connection: Connection = .offline
    private(set) var hello: EngineHello?
    private(set) var status: EngineStatus?
    private(set) var assets = AssetsResponse()

    /// What the device has been asked about the rigs in the library, for this connection.
    /// Observed, because a verdict arriving is what marks a rig unusable in the list and tells
    /// the editor why nothing is playing.
    private(set) var costVerdicts = CostVerdicts()

    /// Why the current rig cannot be sent. Empty when it can.
    private(set) var refusals: [EncodeRefusal] = []

    /// The device's own words for the last thing it would not do. Shown verbatim:
    /// the message names the node and lists the alternatives, and re-deriving it
    /// here is how two clients end up disagreeing.
    private(set) var lastFailure: EngineFailure?

    private(set) var isSending = false

    /// A connection is wanted and will be tried again: what a failure says is not final.
    private(set) var isRetrying = false

    var settings: EngineSettings

    // MARK: Private

    // Plumbing, not state any view shows, so not observed. `rigDidChange` reads and writes
    // most of it, and a view that calls it while building its body would otherwise be
    // invalidated by its own write and rebuild forever.
    @ObservationIgnored private var client: EngineClient?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var latest: Rig?

    /// What the engine ramps, from `engine.schema`. Nil when the device did not say, and
    /// then every edit goes as a whole document, as it always did before streaming.
    @ObservationIgnored private var catalogue: EngineCatalogue?

    /// The document the engine will hold once everything already sent, or waiting in
    /// `pending`, has landed. Each new rig is compared with it. Nil until a whole document
    /// has been applied on this connection, or once the two may have drifted apart.
    @ObservationIgnored private var baseline: EngineDocument?

    /// The chains the last apply muted as hidden.
    @ObservationIgnored private var baselineHidden: [String] = []

    /// Ramps not yet sent, and the task sending them. At most one patch is in flight.
    @ObservationIgnored private var pending = PendingEdits()
    @ObservationIgnored private var gate = StreamGate(interval: EngineSession.streamInterval)
    @ObservationIgnored private var sender: Task<Void, Never>?

    /// A whole document waiting out `applyDebounce`, and what the rig encoded to when the
    /// wait last started.
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var debounced: EngineDocument?

    /// Whole documents on their way. Whatever changes meanwhile is looked at when they land.
    @ObservationIgnored private var applying = 0

    /// Whether the app should be connected: from `connect()` until the player's
    /// `disconnect()`. While it is, a connection that fails or drops is tried again, so a
    /// device that is still booting or restarts, or a permission granted after the first
    /// try, needs nothing from the player.
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var reconnect: Task<Void, Never>?
    @ObservationIgnored private var attempts = 0

    /// An engine that answered `unknown_method` to `rig.cost`. Asking it per rig would be a
    /// round trip per click for the same answer, and an older engine is not a broken one: the
    /// rigs go as they always did and the engine's own refusal is the backstop.
    @ObservationIgnored private var costUnsupported = false

    /// The table the cost verdicts were asked against, so a re-measured one is noticed.
    @ObservationIgnored private var costTable = CostTableKey(status: nil)

    /// In the background nothing is polled, and nothing is retried either.
    @ObservationIgnored private var paused = false

    init(settings: EngineSettings = EngineSettingsStore.load()) {
        self.settings = settings
    }

    // MARK: - Connecting

    func connect() async {
        if let missing = settings.whatIsMissing {
            connection = .failed(missing)
            return
        }
        wantsConnection = true
        attempts = 0
        await open()
    }

    private func open() async {
        reconnect?.cancel(); reconnect = nil
        close()
        connection = .connecting

        let client = EngineClient(host: settings.host, port: settings.port, token: settings.token)
        self.client = client

        do {
            hello = try await client.connect()
            connection = .online
            attempts = 0
            if isRetrying { isRetrying = false }
            lastFailure = nil
            // The catalogue is small and static except for the library-backed
            // options, so one fetch per connection is the documented story.
            assets = (try? await client.call(AssetsRequest(refresh: false),
                                             expecting: AssetsResponse.self)) ?? AssetsResponse()
            // What the engine ramps. A device that does not say gets every edit as a whole
            // document: slower to hear and a rebuild each time, but never wrong.
            if hello?.has("schema") == true, hello?.has("smooth_params") == true,
               let schema = try? await client.call(PlainRequest("engine.schema"),
                                                   expecting: SchemaResponse.self) {
                catalogue = EngineCatalogue(schema: schema)
            }
            startPolling()
            // The meters, only if this engine says it measures levels: an older one is not a
            // broken one, and `start` says so once rather than refusing every 50 ms.
            levels.start(using: client, supported: hello?.has("levels") ?? false)
            // Reconcile: the device is running whatever it was left with, and this
            // app owns the document, so the document wins.
            if let latest { await apply(latest) }
        } catch {
            // A refusal, such as a wrong token or a protocol the device does not speak,
            // will not change by itself. Anything else is the network or the device, and
            // might.
            lost(describe(error), on: client, retrying: !(error is EngineFailure))
        }
    }

    /// The player's disconnect. Nothing reconnects until `connect()` is called again.
    func disconnect() {
        wantsConnection = false
        reconnect?.cancel(); reconnect = nil
        if isRetrying { isRetrying = false }
        close()
        connection = .offline
    }

    /// Let go of the connection and everything that belonged to it.
    private func close() {
        levels.stop()
        poller?.cancel(); poller = nil
        debounce?.cancel(); debounce = nil
        debounced = nil
        sender?.cancel(); sender = nil
        pending.removeAll()
        baseline = nil
        catalogue = nil
        costUnsupported = false
        // A verdict is about one device's table, and this is no longer that device.
        costVerdicts.removeAll()
        costTable = CostTableKey(status: nil)
        let client = self.client
        self.client = nil
        Task { await client?.close() }
        status = nil
        hello = nil
    }

    /// The connection failed or went away. While one is wanted, it is tried again after a
    /// wait. Only the current connection's failure counts: closing it fails whatever else
    /// was waiting on it too, and those would otherwise replace the reason with their own.
    private func lost(_ why: String, on client: EngineClient?, retrying: Bool = true) {
        if let client, self.client !== client { return }
        close()
        connection = .failed(why)
        if retrying {
            scheduleReconnect()
        } else {
            wantsConnection = false
            if isRetrying { isRetrying = false }
        }
    }

    private func scheduleReconnect() {
        guard wantsConnection, !paused, reconnect == nil else { return }
        let delay = Self.retryDelays[min(attempts, Self.retryDelays.count - 1)]
        attempts += 1
        if !isRetrying { isRetrying = true }
        reconnect = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.reconnect = nil
            await self.open()
        }
    }

    /// Nothing is polled or retried while the app is in the background. A device that went
    /// away meanwhile is noticed on the next call rather than by a timer nobody watched,
    /// and a connection still wanted is tried again as soon as the app is back.
    func pause() {
        paused = true
        levels.pause()
        poller?.cancel()
        poller = nil
        reconnect?.cancel()
        reconnect = nil
    }

    func resume() {
        paused = false
        if connection.isOnline {
            if poller == nil { startPolling() }
        } else if wantsConnection, connection != .connecting {
            attempts = 0
            scheduleReconnect()
        }
    }

    // MARK: - Sending

    /// Called from `RigEditor.rig.didSet`, beside the library's own write: once per
    /// drop on the canvas, and at every step of a knob.
    func rigDidChange(_ rig: Rig) {
        latest = rig
        // Encoded even when offline, so the canvas can badge what this device could
        // not play before anyone tries to send it.
        let encoded = DocumentEncoder.encode(rig)
        if encoded.refusals != refusals { refusals = encoded.refusals }

        // A verdict is about the document it was asked about, and any edit is a new document.
        // Dropped only when there is one to drop: this runs at every step of a knob, and writing
        // an observed property per step would redraw the library for nothing. Compared here
        // rather than per row, because a list draws a row far more often than a rig is sent; an
        // unusable rig is asked about again by the debounce below, since it can never be sent and
        // so never takes the ramp path.
        if costVerdicts.known(rig.id) != nil { costVerdicts.forget(rig.id) }

        guard connection.isOnline else { return }
        route(encoded)
    }

    /// Re-send the whole document. The recovery path when the device and this app
    /// have drifted apart — another client, an operator's reload, a failed node.
    func resend() async {
        guard let latest else { return }
        debounce?.cancel(); debounce = nil
        debounced = nil
        await apply(latest)
    }

    /// Stream the change if the engine can ramp all of it. Otherwise send the whole
    /// document, once the rig has been still for `applyDebounce`.
    private func route(_ encoded: EncodeResult) {
        guard connection.isOnline else { return }
        if debounce == nil, applying == 0, let edits = ramps(to: encoded) {
            queue(edits, reaching: encoded.document)
            return
        }
        scheduleDocument(encoded.document)
    }

    /// The ramps that take the engine from `baseline` to this rig: empty when nothing
    /// it holds differs, nil when only a whole document will do.
    private func ramps(to encoded: EncodeResult) -> [ParamEdit]? {
        guard let baseline, let catalogue, let document = encoded.document,
              encoded.hiddenChainIDs == baselineHidden,
              channelRefusals(for: encoded).isEmpty else { return nil }
        switch EngineEdits.change(from: baseline, to: document, catalogue: catalogue) {
        case .none: return []
        case .ramps(let edits): return edits
        case .structural: return nil
        }
    }

    private func queue(_ edits: [ParamEdit], reaching document: EngineDocument?) {
        guard !edits.isEmpty, let document else { return }
        baseline = document
        pending.add(edits)
        pump()
    }

    // MARK: Ramps

    /// Send what `pending` holds, no sooner than `streamInterval` after the last patch
    /// and never while one is on its way. Whatever is waiting goes when that time
    /// comes, so the last value of a drag is always sent.
    private func pump() {
        guard sender == nil, !pending.isEmpty, let client else { return }
        let wait = gate.wait(at: .now)
        sender = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            await self?.flush(using: client)
        }
    }

    private func flush(using client: EngineClient) async {
        // A reconnect since this was scheduled has started over with its own state.
        guard self.client === client else { return }
        await sendPending(using: client)
        guard self.client === client else { return }
        sender = nil
        pump()
    }

    /// Everything waiting, one patch per chain.
    private func sendPending(using client: EngineClient) async {
        guard connection.isOnline else {
            pending.removeAll()
            return
        }
        for batch in pending.take() {
            gate.sent(at: .now)
            do {
                let reply = try await client.call(batch.request, expecting: PatchResponse.self)
                if reply.kind == "structural" {
                    // The engine rebuilt for a parameter the schema says ramps. Streaming it
                    // would be a rebuild at every step, so it goes back to whole documents.
                    for edit in batch.edits { catalogue?.stopRamping(edit.type, edit.param) }
                }
            } catch let failure as EngineFailure {
                // A refused patch leaves the engine as it was, so the two now disagree, and
                // the whole document puts them back in step.
                lastFailure = failure
                resynchronise()
                return
            } catch {
                lost(describe(error), on: client)
                return
            }
        }
    }

    private func resynchronise() {
        baseline = nil
        pending.removeAll()
        if let latest { scheduleDocument(DocumentEncoder.encode(latest).document) }
    }

    // MARK: Whole documents

    /// Send the whole document once the rig has been still for `applyDebounce`.
    ///
    /// A change the engine could reach from the waiting document by ramps alone does not
    /// restart the wait: the document is encoded when it goes, so it will carry that
    /// change too. That is what lets a knob whose first step adds a node — a lane or
    /// output level leaving 0 dB — be heard 250 ms into the drag rather than after it.
    private func scheduleDocument(_ document: EngineDocument?) {
        guard applying == 0 else { return }
        if debounce != nil, let debounced, let document, let catalogue,
           EngineEdits.change(from: debounced, to: document, catalogue: catalogue) != .structural {
            return
        }
        debounced = document
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.applyDebounce)
            guard !Task.isCancelled else { return }
            await self?.debounceElapsed()
        }
    }

    private func debounceElapsed() async {
        debounce = nil
        debounced = nil
        guard let latest else { return }
        // The rig may have come back within reach of ramps while it waited: a toggle
        // turned off again costs nothing.
        let encoded = DocumentEncoder.encode(latest)
        if let edits = ramps(to: encoded) {
            queue(edits, reaching: encoded.document)
            return
        }
        await apply(latest)
    }

    /// Send the whole document, and then look again at whatever changed on the way.
    ///
    /// **The device's verdict comes before the document does** (P5, D6). A rig the cost table
    /// would refuse is never sent, so the rig that is playing keeps playing and the reason is
    /// the editor's to show rather than something the player has to find in Settings. It is
    /// asked here rather than at the click, because this is the one funnel every whole document
    /// goes through: the debounced edit, a reconnect, and the resend button alike.
    ///
    /// A ramp cannot change a rig's cost — a rampable parameter is a number inside a node, and
    /// what is charged for is the units: the models, the IRs and the node types — so the
    /// streamed path above needs no gate.
    private func apply(_ rig: Rig) async {
        if let document = DocumentEncoder.encode(rig).document,
           let report = await cost(of: rig, document: document), report.isOver {
            return
        }
        applying += 1
        await send(rig)
        applying -= 1
        if applying == 0, connection.isOnline, let latest, latest != rig {
            route(DocumentEncoder.encode(latest))
        }
    }

    // MARK: - Cost

    /// What the device says a rig would cost, asked before it is played and kept for the
    /// session.
    ///
    /// D9 gives the engine the table, the fit check and the refusal, and this app the showing
    /// and the refusal to activate; so this asks rather than adding costs up here, which would
    /// be the second cost model D9 rules out. Nothing is published or compiled by the question,
    /// which is what makes it safe to ask about a rig nobody has played.
    ///
    /// Nil is "no verdict", and it is not a refusal: an engine too old to know the method, a
    /// document it will not parse, a device that has gone away, or an asset the rig names that
    /// the device has not got. All of those leave the rig to go exactly as it did before, and
    /// the engine's own `over_budget` refusal is the backstop.
    func cost(of rig: Rig, document: EngineDocument) async -> RigCostReport? {
        guard connection.isOnline, let client, !costUnsupported else { return nil }
        let table = CostTableKey(status: status?.cost)
        if let known = costVerdicts.report(for: rig.id, document: document, table: table) {
            return known
        }

        do {
            let reply = try await client.call(CostRequest(document: document), expecting: CostResponse.self)
            guard let cost = reply.cost else { return nil }
            let report = RigCostReport(cost: cost, slimmedModels: reply.slimmedModels ?? [])
            costVerdicts.store(report, for: rig.id, document: document, table: table)
            return report
        } catch let failure as EngineFailure {
            if failure.code == "unknown_method" { costUnsupported = true }
            return nil
        } catch {
            lost(describe(error), on: client)
            return nil
        }
    }

    /// What the device has already said about a rig, for the library to mark and the editor to
    /// explain. Nil until it has been asked, and after an edit — see `rigDidChange`.
    func costReport(for rig: UUID) -> RigCostReport? { costVerdicts.known(rig) }

    private func send(_ rig: Rig) async {
        guard let client, connection.isOnline else { return }

        var result = DocumentEncoder.encode(rig)
        result.refusals.append(contentsOf: channelRefusals(for: result))
        refusals = result.refusals

        guard result.refusals.isEmpty, let document = result.document else { return }

        isSending = true
        defer { isSending = false }

        do {
            // Ramps still waiting go first. They are relative to what the engine holds
            // now, and one sent after the document would name what it replaced.
            await sendPending(using: client)
            guard connection.isOnline else { return }

            _ = try await client.call(ApplyRequest(document: document), expecting: ApplyResponse.self)
            lastFailure = nil
            baseline = document
            baselineHidden = result.hiddenChainIDs

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
            lost(describe(error), on: client)
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
            // A rescan can find a model that was replaced on the device, and a node is charged
            // for the family and size the *file* declares: the table has not moved, and every
            // verdict about a rig naming that model has.
            costVerdicts.removeAll()
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
            let fresh = try await client.call(PlainRequest("engine.status"),
                                              expecting: StatusResponse.self).status
            // The table is the one thing outside this app that a verdict depends on, and it is
            // re-measured on the device (D2, P1): a table that has moved retires every verdict
            // asked against the old one, which is also what unmarks a rig in the list.
            let table = CostTableKey(status: fresh?.cost)
            if table.isKnown, table != costTable {
                costTable = table
                costVerdicts.removeAll()
            }
            status = fresh
        } catch let error as EngineTransportError {
            lost(error.message, on: client)
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

    /// Why a block plays as bypassed on the device: its model or IR isn't there. Nil
    /// offline, and for every block the device has what it needs for.
    func missingAsset(for block: UUID) -> EngineIssue? {
        guard connection.isOnline else { return nil }
        return status?.missingAsset(element: block)
    }

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
