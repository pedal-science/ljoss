import Foundation
import Observation

// The device's audio levels, polled — the numbers behind every meter in the app.
//
// **Why this is not part of `EngineSession`.** `EngineSession.status` is one observed
// property, and `NodeTile` reads it (through `missingAsset(for:)`) to show a block as not
// configured. Putting levels in there would mean a fresh status object twenty times a
// second, invalidating every block on the canvas at meter rate — the rig would redraw itself
// continuously to move a few bars. So levels live here, in their own observable object, and
// only the views that draw a meter read it.
//
// **Why 20 Hz.** Fast enough that a player sees a level move as they play (a meter slower
// than about 12 Hz reads as broken), and slow enough that the cost is nothing: one small
// reply per poll, built by the engine from atomics it has already written. The engine's own
// per-period peaks are computed at 750 Hz whatever this polls at, so the poll rate is a
// display choice and not a measurement one — which is why it is a constant here rather than
// a setting.
//
// **Why an empty window holds.** The engine's probes are read-and-reset: each read takes the
// window that just ended, so two reads in quick succession leave an empty window behind. An
// empty window is not silence — it is a reading of nothing — and drawing it as the floor
// would make the meter flicker to silence every time anything else asked the engine a
// question. So the last window with samples in it stays on screen.
@MainActor
@Observable
final class EngineLevelsModel {

    /// How often the device is asked. See the note above for why this number.
    private static let interval = Duration.milliseconds(50)

    /// The most recent reading, or an empty one before the first reply — which is how a view
    /// tells "nothing yet" from "silence" (`hasSignal` is nil until something arrives).
    private(set) var levels: EngineLevels?

    /// Whether this engine measures levels at all. Nil until `start` has been told.
    private(set) var isSupported = false

    /// Why the numbers stopped moving, if they did. The meter keeps its last value, and the
    /// view can say "held" rather than lying about a fresh reading.
    private(set) var failure: String?

    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var client: EngineClient?

    /// Whether anything at all was measured, and whether we have a reading yet.
    var hasSignal: Bool? { levels?.hasSignal }
    var hasReading: Bool { levels != nil }

    // MARK: - Lifecycle, driven by the session

    /// Start polling on a live connection, unless the engine has said it cannot measure.
    ///
    /// Called by `EngineSession` when a connection comes up and again after a reconnect, so the
    /// two never disagree about whether there is a device to ask. A different client is a new
    /// connection: the poller is restarted on it rather than left on a half-closed one.
    func start(using client: EngineClient, supported: Bool) {
        self.client = client
        isSupported = supported
        poller?.cancel()
        poller = nil
        failure = nil
        guard supported else {
            // Not a failure: an engine without the feature is one whose meters are simply not
            // there, and saying so once beats a refusal every 50 ms.
            levels = nil
            return
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    /// Stop polling and forget the connection. The last levels stay on screen deliberately: a
    /// meter that blanks the instant the network hiccups is harder to read than one holding a
    /// stale value, and `EngineSession.connection` is what says the device is gone.
    func stop() {
        poller?.cancel()
        poller = nil
        client = nil
    }

    /// The app is going to the background: stop asking. Called beside `EngineSession.pause`.
    func pause() { stop() }

    private func refresh() async {
        guard let client else { return }
        do {
            let reply = try await client.call(PlainRequest("engine.levels"),
                                              expecting: LevelsResponse.self)
            failure = nil
            guard let fresh = reply.levels else { return }
            levels = EngineLevels.combining(previous: levels, fresh: fresh)
        } catch {
            // A transport failure is the session's business — it notices on its own poll and
            // will call `stop` — so this only records why the numbers stopped moving.
            failure = (error as? EngineTransportError)?.message
                ?? (error as? EngineFailure)?.message
                ?? String(describing: error)
        }
    }
}
