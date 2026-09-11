import CoreGraphics

// Assertions for wrapped layout: where rows break, the return wire, and which
// slot a pointer means once a chain spans several rows. See docs/DRAG-ENGINE.md.

private let style = FlowArrangement.Style(rowSpacing: 32, wireThickness: 3, stubLength: 14)
private let tile = CGSize(width: 162, height: 104)
private let closedGap = CGSize(width: 0, height: 104)

private func rowsOf(_ flow: FlowArrangement) -> [[Int]] { flow.rows.map(\.items) }

// MARK: - Line breaking

func testFlowWrapping() {
    let four = Array(repeating: tile, count: 4)

    let line = FlowArrangement(sizes: four, wrapWidth: nil, style: style)
    check(rowsOf(line) == [[0, 1, 2, 3]], "no wrap width: one line")
    check(line.wires.isEmpty, "one line: no return wire")
    check(line.size == CGSize(width: 648, height: 104), "one line: no trailing reserve")

    // 17pt reserve at the right: 2 × 162 = 324 fits in 341, 3 × 162 does not.
    let wrapped = FlowArrangement(sizes: four, wrapWidth: 358, style: style)
    check(rowsOf(wrapped) == [[0, 1], [2, 3]], "wraps two tiles to a row")
    check(wrapped.itemFrames[2].origin == CGPoint(x: 0, y: 136), "next row starts at the left, one gutter down")
    check(wrapped.size == CGSize(width: 341, height: 240), "wrapped size includes the reserve")

    let exact = FlowArrangement(sizes: four, wrapWidth: 324 + style.trailingReserve, style: style)
    check(rowsOf(exact) == [[0, 1], [2, 3]], "a tile exactly filling the row stays on it")

    // A closed gap has no width: it must never be what starts a row, or the
    // row would begin with an invisible item and the wire would miss its tile.
    let gaps = FlowArrangement(sizes: [tile, closedGap, tile, closedGap, tile], wrapWidth: 358, style: style)
    check(rowsOf(gaps) == [[0, 1, 2, 3], [4]], "closed gaps stay on the row before a break")

    // An open gap after a full row: it wraps to the start of the next row,
    // directly before the tile it precedes.
    let openGap = CGSize(width: 162, height: 104)
    let open = FlowArrangement(sizes: [tile, tile, openGap, tile], wrapWidth: 358, style: style)
    check(rowsOf(open) == [[0, 1], [2, 3]], "an open gap that does not fit opens at the next row's start")

    // Too wide for any row: it gets a row to itself and overflows it.
    let wide = CGSize(width: 600, height: 236)
    let over = FlowArrangement(sizes: [tile, wide, tile], wrapWidth: 358, style: style)
    check(rowsOf(over) == [[0], [1], [2]], "an oversized item takes a row alone")
    check(over.size.width == 600 + style.trailingReserve, "and the flow widens to hold it")

    let mixed = FlowArrangement(sizes: [tile, wide], wrapWidth: nil, style: style)
    check(mixed.itemFrames[0].midY == mixed.itemFrames[1].midY, "tiles on a row share a centre line")
}

// MARK: - Return wire

func testFlowWire() {
    let flow = FlowArrangement(sizes: Array(repeating: tile, count: 3), wrapWidth: 358, style: style)
    check(flow.wires.count == 1, "one break, one wire")
    let w = flow.wires[0]
    let out = w[FlowArrangement.WirePiece.outStub.rawValue]
    let down = w[FlowArrangement.WirePiece.rightDrop.rawValue]
    let run = w[FlowArrangement.WirePiece.returnRun.rawValue]
    let drop = w[FlowArrangement.WirePiece.leftDrop.rawValue]
    let above = flow.rows[0].frame
    let below = flow.rows[1].frame

    check(out.minX == above.maxX && out.midY == above.midY, "leaves the last tile at wire height")
    check(down.maxX == out.maxX && down.minY == out.maxY, "turns down at the end of the stub")
    check(down.maxY > above.maxY, "drops past the bottom of the row")
    check(run.maxX == down.minX && run.minY < down.maxY && run.maxY == down.maxY, "turns back along the gutter")
    check(run.midY > above.maxY && run.midY < below.minY, "runs back between the rows")
    check(drop.minX == run.minX && drop.minY == run.maxY, "turns down at the left margin")
    check(drop.maxX == 0 && drop.maxY == below.midY + 1.5, "arrives at the next row's wire, flush with its first tile")
    check(out.maxX <= 358, "never runs past the wrap width")

    var overlaps = false
    for i in w.indices {
        for j in w.indices where j > i {
            let shared = w[i].intersection(w[j])
            if !shared.isNull && shared.width > 0 && shared.height > 0 { overlaps = true }
        }
    }
    check(!overlaps, "no two pieces overlap")
}

// MARK: - Hit testing across rows

func testFlowHitTesting() {
    let flow = FlowArrangement(sizes: Array(repeating: tile, count: 5), wrapWidth: 358, style: style)
    // Treat item 0 as Input, 1...3 as elements 0...2, 4 as Output: rows [[In, e0], [e1, e2], [Out]].
    let f = flow.itemFrames
    check(rowsOf(flow) == [[0, 1], [2, 3], [4]], "fixture wraps as expected")
    let marks: [FlowHitTest.Mark] = [
        .endpoint(slot: 0, f[0]),
        .element(0, f[1]), .element(1, f[2]), .element(2, f[3]),
        .endpoint(slot: 3, f[4]),
    ]
    func at(_ x: CGFloat, _ y: CGFloat) -> Int {
        FlowHitTest.insertionIndex(marks: marks, count: 3, at: CGPoint(x: x, y: y))
    }
    let r0 = f[1].midY, r1 = f[2].midY, r2 = f[4].midY

    check(at(10, r0) == 0, "over Input: the first slot")
    check(at(f[1].midX - 1, r0) == 0, "left half of the first block: before it")
    check(at(f[1].midX + 1, r0) == 1, "right half of the last block on a row: the slot after it")
    check(at(340, r0) == 1, "past the end of a row: the slot that starts the next")
    check(at(5, r1) == 1, "the start of the next row is that same slot")
    check(at(f[3].midX + 1, r1) == 3, "right half of the last block: the end")
    check(at(f[4].midX - 1, r2) == 3, "Output alone on a row below: still the end, not before row 0's blocks")
    check(at(f[4].midX + 60, r2) == 3, "right of Output: the end")
    check(at(300, f[1].maxY + 10) == 1, "upper half of a gutter belongs to the row above")
    check(at(10, f[2].minY - 10) == 1, "lower half belongs to the row below")

    // A gap opened at the start of a row pushes its first tile right of the
    // tile above. Rows must still be told apart by height, not by x.
    let pushed: [FlowHitTest.Mark] = [
        .element(0, CGRect(x: 0, y: 0, width: 162, height: 104)),
        .element(1, CGRect(x: 176, y: 136, width: 162, height: 104)),
    ]
    let i = FlowHitTest.insertionIndex(marks: pushed, count: 2, at: CGPoint(x: 100, y: 180))
    check(i == 1, "a row pushed right by an open gap is still its own row")

    let single: [FlowHitTest.Mark] = [.element(0, CGRect(x: 0, y: 0, width: 100, height: 50)),
                                      .element(1, CGRect(x: 120, y: 0, width: 100, height: 50))]
    check(FlowHitTest.insertionIndex(marks: single, count: 2, at: CGPoint(x: 60, y: 25)) == 1,
          "one line: the plain midpoint rule")
    check(FlowHitTest.insertionIndex(marks: single, count: 2, at: CGPoint(x: 500, y: 25)) == 2,
          "one line: past the end")
    check(FlowHitTest.insertionIndex(marks: [], count: 0, at: .zero) == 0, "nothing on screen: the only slot")
}
