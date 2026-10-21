import Foundation
import Observation

// The tuner's reading, polled — and only while the tuner is on screen.
//
// **Why not part of `EngineSession`.** The same reason `EngineLevelsModel` is not: `status` is one
// observed property that every block on the canvas reads, and a reading that changes thirty times a
// second would invalidate the whole rig to move a needle. This is its own object, and only the panel
// reads it.
//
// **Why 30 Hz.** A needle slower than about 12 Hz reads as broken, and 30 Hz is what the panel
// draws; the engine's own state is published once per block (750 Hz at 48 kHz with a 64-frame
// quantum), so the rate is a display choice rather than a measurement one.
//
// **Why the view decides.** Nothing is asked at all until the tuner panel is visible: `setWatching`
// starts the loop and stops it, so a tuner that is closed costs a closed socket's worth of nothing.
// One request is in flight at a time, so a slow link sends less often rather than piling up.
@MainActor
@Observable
final class TunerModel {

    private static let interval = Duration.milliseconds(33)

    /// The newest reading, or `waiting` before the first reply.
    private(set) var reading = TunerReading.waiting

    /// Whether this engine has the tuner at all: `nc.tuner` in its schema and the `node_state`
    /// feature for the reading. False means the panel's button is disabled rather than the
    /// document refused (an engine that predates the node would refuse the whole publish).
    private(set) var isSupported = false

    /// Why the reading stopped moving, if it did. A transport failure is the session's business —
    /// it notices on its own poll — so this only records it.
    private(set) var failure: String?

    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var client: EngineClient?
    @ObservationIgnored private var watching = false

    // MARK: - Lifecycle

    /// Called when a connection comes up and again after a reconnect, so the two never disagree
    /// about whether there is a device to ask.
    func start(using client: EngineClient, supported: Bool) {
        self.client = client
        isSupported = supported
        failure = nil
        // An engine without the tuner is not a failure: its button is disabled, and that is said
        // once rather than as a refusal every 33 ms.
        reading = TunerReading.waiting
        restart()
    }

    /// Stop polling and forget the connection. Also what going to the background does.
    func stop() {
        poller?.cancel()
        poller = nil
        client = nil
        watching = false
        reading = TunerReading.waiting
    }

    func pause() { stop() }

    /// The tuner panel became visible (or went away): ask for a reading, or stop asking.
    func setWatching(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        reading = TunerReading.waiting
        if on {
            restart()
        } else {
            poller?.cancel()
            poller = nil
        }
    }

    var isWatching: Bool { watching }

    private func restart() {
        poller?.cancel()
        poller = nil
        guard watching, isSupported, client != nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    private func refresh() async {
        guard let client else { return }
        do {
            let reply = try await client.call(PlainRequest("rig.state"), expecting: StateResponse.self)
            failure = nil
            let fresh = TunerReading.decoding(reply)
            // Only when what the panel draws changed: `blocks` moves every block, and assigning an
            // equal reading would redraw the view thirty times a second for nothing.
            if fresh != reading { reading = fresh }
        } catch {
            failure = (error as? EngineTransportError)?.message
                ?? (error as? EngineFailure)?.message
                ?? String(describing: error)
        }
    }
}
