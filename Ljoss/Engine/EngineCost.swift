import Foundation

// What this app makes of the device's cost table: the verdict on the rig that is playing
// (`engine.status.cost`) and on one that is not (`rig.cost`), and the cache that keeps a
// verdict for the session.
//
// D9 splits the job: the engine owns the table, the fit check and the refusal; this app shows
// the indicator and refuses to make an unusable rig active. This file is the app's half of
// that — what "unusable" means, what the player is told, and when a verdict goes stale. It has
// no SwiftUI and no Network, so the arithmetic and the cache are in the fast test set beside
// the wire types.

// MARK: - When a verdict is stale

/// The cost table a verdict was asked against.
///
/// **This is what invalidates a cached verdict**, and it is the whole of what does. A verdict
/// is a statement about one document against one table, so a hit needs both: the document (an
/// edited rig has a different cost even though nothing about the device changed), and this,
/// because the numbers are the device's and are re-measured (D2, P1). `rows` and `measured`
/// are here because a table that was re-measured in place has the same path and can still have
/// the same row count; `measured` is the ISO timestamp the bench writes into the file.
///
/// The engine's `generation` is deliberately **not** part of it. It moves on every publish —
/// including this app's own — and a verdict about a rig that is not playing depends on the
/// table and the document alone, so keying on it would re-ask on every switch and give up the
/// cache's one job. What else drops verdicts is said where it happens: an edit
/// (`EngineSession.rigDidChange`) and a rescan of the device's library
/// (`EngineSession.refreshAssets`), since a model replaced under `models_root` can change what
/// a node is charged without touching the table.
struct CostTableKey: Hashable, Sendable {
    var path: String?
    var ok: Bool?
    var rows: Int?
    var measured: String?

    /// From `engine.status.cost`, which is where the row count and the measurement are. The
    /// `rig.cost` reply describes the same table more thinly, so the status is the one the
    /// cache is keyed on and the only one it compares.
    init(status cost: EngineCost?) {
        path = cost?.table
        ok = cost?.tableOk
        rows = cost?.tableRows
        measured = cost?.tableMeasured
    }

    /// Whether the table has been described at all. Before the first status, or against an
    /// engine too old to report one, there is nothing to compare — so nothing is cached.
    var isKnown: Bool { path != nil || rows != nil || measured != nil }
}

// MARK: - A verdict

/// What the device said a rig would cost, and what that means for playing it.
struct RigCostReport: Equatable, Sendable {
    var cost: EngineCost
    var slimmedModels: [EngineSlimmedModel] = []

    /// The device would refuse to publish this rig: it does not fit even with its dearest
    /// models on Lite. It is **unusable**, and this app does not make it active (P5).
    var isOver: Bool { cost.over == true || cost.verdict == "over" }

    /// It would play a smaller model than it names, so it would not sound like this rig (D6).
    var isTrimmed: Bool { cost.trimmed == true || !slimmedModels.isEmpty }

    /// Why the device will not play it, in this app's words rather than the engine's: the two
    /// numbers that decided it, so the player can see how far over it is.
    var refusalReason: String {
        var text = "Its blocks cost \(RigCostReport.fraction(cost.cost ?? cost.fullCost)) of a core"
        if isTrimmed { text += " with the dearest models on Lite" }
        text += ", and a rig may have \(RigCostReport.fraction(cost.headroom ?? 0.8))."
        return text
    }

    /// A cost as a player reads it: fractions of one core, two decimals. The unit belongs in
    /// the sentence, not in here.
    static func fraction(_ value: Double?) -> String {
        guard let value else { return "an unknown amount" }
        return String(format: "%.2f", value)
    }
}

// MARK: - Naming the blocks that were trimmed

/// One block playing its Lite submodel (D6), named the way the player knows it.
struct TrimmedBlock: Identifiable, Equatable, Sendable {
    /// The engine's node id, which is what an entry is identified by wherever it came from.
    var id: String
    /// The app's own name for the block — "Brit 800" — or, when the element is not one of the
    /// rig's, the model reference, which is still the thing that sounds different.
    var name: String
    var reference: String?
    var row: String?
    var cost: Double?
    var fullCost: Double?
}

/// The running rig's trimmed blocks, with the two strings the UI needs: one that fits in a
/// toolbar, and the sentence behind it.
struct TrimmedRig: Equatable, Sendable {
    var blocks: [TrimmedBlock]

    /// What the toolbar shows: the fact first, then the blocks, capped so a rig with a dozen
    /// trimmed models does not push the rest of the toolbar off the screen.
    var label: String {
        let names = blocks.prefix(2).map(\.name)
        let rest = blocks.count - names.count
        return "Lite: " + names.joined(separator: ", ") + (rest > 0 ? " +\(rest)" : "")
    }

    /// The whole of it, for the tooltip: every block, what it saves, and the one thing D6
    /// exists to say — a Lite model is a different network, not a smaller setting.
    var detail: String {
        let named = blocks.map { block -> String in
            var text = block.name
            if let cost = block.cost, let full = block.fullCost {
                text += " (\(RigCostReport.fraction(cost)) of a core instead of \(RigCostReport.fraction(full)))"
            }
            return text
        }
        let subject = blocks.count == 1 ? "One model" : "\(blocks.count) models"
        return "\(subject) playing smaller than the rig names, to fit this device's cost table: "
            + named.joined(separator: ", ")
            + ". A Lite model is a separately trained network, so this rig does not sound like the "
            + "rig as written."
    }
}

extension EngineSlimmedModel {
    /// The block as the player knows it.
    ///
    /// `rig` is the document this app last sent — the only thing that turns the engine's
    /// `element`, a block's UUID, back into the name on its tile. An element that is not in it
    /// (another client's rig, or one reloaded from the device) is named by what the engine does
    /// know: the model reference.
    func named(in rig: Rig?) -> TrimmedBlock {
        var name = reference ?? node ?? element ?? "a block"
        if let element, let id = UUID(uuidString: element),
           let block = rig?.allBlocks.first(where: { $0.id == id }) {
            name = Catalogue.resolve(block.componentID).name
        }
        return TrimmedBlock(id: node ?? element ?? name, name: name, reference: reference,
                            row: row, cost: cost, fullCost: fullCost)
    }
}

extension EngineStatus {
    /// The trimmed models of the rig being heard, named, or nil when nothing was trimmed —
    /// which is the common case and the one the toolbar must stay quiet for.
    func trimmedRig(in rig: Rig?) -> TrimmedRig? {
        let blocks = slimmedModels.map { $0.named(in: rig) }
        return blocks.isEmpty ? nil : TrimmedRig(blocks: blocks)
    }
}

// MARK: - The cache

/// What the device has been asked about the rigs in the library, for one connection.
///
/// Asking is a round trip, and the answer is the same for a rig the player picks twice, so it
/// is kept. What makes an entry stale is `CostTableKey`'s business; this is only the store.
struct CostVerdicts: Equatable, Sendable {

    struct Entry: Equatable, Sendable {
        /// The document the question was about. Kept rather than hashed, because the test for
        /// a hit is the same equality `EngineSession` already has to hand: it encodes the rig
        /// before it can send it.
        var document: EngineDocument
        var table: CostTableKey
        var report: RigCostReport
    }

    private var entries: [UUID: Entry] = [:]

    /// The verdict for this rig, if it is still about the document it would send and the table
    /// the device is using now.
    func report(for rig: UUID, document: EngineDocument, table: CostTableKey) -> RigCostReport? {
        guard table.isKnown, let entry = entries[rig],
              entry.table == table, entry.document == document else { return nil }
        return entry.report
    }

    /// The verdict as a *list row* can afford to ask for it: no document, because a row is
    /// drawn far more often than a rig is sent. An entry whose rig has been edited since may
    /// still be here, and `forget` is what removes it — on the edit itself, which is the only
    /// way a rig changes.
    func known(_ rig: UUID) -> RigCostReport? { entries[rig]?.report }

    mutating func store(_ report: RigCostReport, for rig: UUID,
                        document: EngineDocument, table: CostTableKey) {
        guard table.isKnown else { return }
        entries[rig] = Entry(document: document, table: table, report: report)
    }

    /// An edit makes a verdict stale before anything else can: the rig is about to be asked
    /// about again, and until it is, the list has no business marking it.
    mutating func forget(_ rig: UUID) { entries[rig] = nil }

    /// A different device, or one that has been re-measured, describes different costs.
    mutating func removeAll() { entries.removeAll() }
}
