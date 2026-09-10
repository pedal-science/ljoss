import Foundation

// Assertions for the model layer: the tree edits and the render-slot mapping.
//
// These cover the places where a mistake is silent rather than a crash — an
// off-by-one that shuffles a block one position, or a normalisation rule that
// quietly deletes routing. See docs/ARCHITECTURE.md and docs/DRAG-ENGINE.md.

nonisolated(unsafe) var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok    \(label)")
    } else {
        print("  FAIL  \(label)")
        failures += 1
    }
}

func blk(_ name: String) -> ChainElement { .block(Block(componentID: name)) }

/// Render a chain compactly: "a b <x,y|z>" — angle brackets are a parallel,
/// pipes separate lanes.
func shape(_ elements: [ChainElement]) -> String {
    elements.map { element in
        switch element {
        case .block(let b): b.componentID
        case .parallel(let p): "<" + p.lanes.map { shape($0.elements) }.joined(separator: "|") + ">"
        }
    }.joined(separator: " ")
}

func makeRig(_ elements: [ChainElement]) -> Rig {
    Rig(
        name: "Test",
        chains: [SignalChain(name: "Guitar", source: .guitar, elements: elements)],
        createdAt: Date(timeIntervalSince1970: 0),
        modifiedAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Reordering

func testReordering() {
    print("reordering within a container")

    do {
        var rig = makeRig([blk("a"), blk("b"), blk("c"), blk("d")])
        let chain = rig.chains[0].id
        _ = rig.move(from: ElementAddress(container: .top(chain), index: 0),
                     to: InsertionSlot(container: .top(chain), index: 3))
        check(shape(rig.chains[0].elements) == "b c a d",
              "forward move adjusts for the hole it leaves — got \(shape(rig.chains[0].elements))")
    }

    do {
        var rig = makeRig([blk("a"), blk("b"), blk("c"), blk("d")])
        let chain = rig.chains[0].id
        _ = rig.move(from: ElementAddress(container: .top(chain), index: 3),
                     to: InsertionSlot(container: .top(chain), index: 1))
        check(shape(rig.chains[0].elements) == "a d b c",
              "backward move needs no adjustment — got \(shape(rig.chains[0].elements))")
    }

    do {
        var rig = makeRig([blk("a"), blk("b"), blk("c")])
        let chain = rig.chains[0].id
        for slot in [1, 2] {
            _ = rig.move(from: ElementAddress(container: .top(chain), index: 1),
                         to: InsertionSlot(container: .top(chain), index: slot))
            check(shape(rig.chains[0].elements) == "a b c",
                  "dropping onto its own slot (\(slot)) is a no-op — got \(shape(rig.chains[0].elements))")
        }
    }

    do {
        var rig = makeRig([blk("a"), blk("b"), blk("c")])
        let chain = rig.chains[0].id
        _ = rig.move(from: ElementAddress(container: .top(chain), index: 0),
                     to: InsertionSlot(container: .top(chain), index: 3))
        check(shape(rig.chains[0].elements) == "b c a",
              "move to the end — got \(shape(rig.chains[0].elements))")
    }
}

// MARK: - Parallel sections

func testParallels() {
    print("parallel sections")

    var rig = makeRig([blk("a"), blk("b"), blk("c")])
    let chain = rig.chains[0].id

    let parallel = rig.wrapInParallel(at: ElementAddress(container: .top(chain), index: 1))
    check(parallel != nil, "wrapping returns the new section id")
    check(shape(rig.chains[0].elements) == "a <b|> c",
          "wrap puts the element in lane 0 and leaves a dry lane — got \(shape(rig.chains[0].elements))")

    guard let parallel else { return }
    func lane(_ i: Int) -> ContainerPath {
        ContainerPath.top(chain).appending(LaneStep(parallelID: parallel, laneIndex: i))
    }

    check(rig.move(from: ElementAddress(container: .top(chain), index: 2),
                   to: InsertionSlot(container: lane(1), index: 0)),
          "a block can be dragged into a lane")
    check(shape(rig.chains[0].elements) == "a <b|c>",
          "…and lands there — got \(shape(rig.chains[0].elements))")

    _ = rig.move(from: ElementAddress(container: lane(0), index: 0),
                 to: InsertionSlot(container: .top(chain), index: 0))
    check(shape(rig.chains[0].elements) == "b a <|c>",
          "emptying ONE lane preserves it as a dry path — got \(shape(rig.chains[0].elements))")

    _ = rig.move(from: ElementAddress(container: lane(1), index: 0),
                 to: InsertionSlot(container: .top(chain), index: 3))
    check(shape(rig.chains[0].elements) == "b a c",
          "emptying EVERY lane prunes the split so the space closes up — got \(shape(rig.chains[0].elements))")
}

// MARK: - Rejected edits

func testRejectedEdits() {
    print("edits that must be refused")

    do {
        var rig = makeRig([blk("a")])
        let chain = rig.chains[0].id
        guard let parallel = rig.wrapInParallel(at: ElementAddress(container: .top(chain), index: 0)) else {
            check(false, "wrap succeeded"); return
        }
        let lane1 = ContainerPath.top(chain).appending(LaneStep(parallelID: parallel, laneIndex: 1))
        check(!rig.move(from: ElementAddress(container: .top(chain), index: 0),
                        to: InsertionSlot(container: lane1, index: 0)),
              "a parallel cannot be moved into its own lane")
        check(shape(rig.chains[0].elements) == "<a|>",
              "…and the tree is untouched by the refusal — got \(shape(rig.chains[0].elements))")
    }

    do {
        var rig = makeRig([blk("a")])
        let chain = rig.chains[0].id
        guard let parallel = rig.wrapInParallel(at: ElementAddress(container: .top(chain), index: 0)) else {
            check(false, "wrap succeeded"); return
        }
        let lane0 = ContainerPath.top(chain).appending(LaneStep(parallelID: parallel, laneIndex: 0))
        let nested = ParallelSection(lanes: [Lane(elements: [blk("x")]), Lane()])
        check(!rig.insert(.parallel(nested), at: InsertionSlot(container: lane0, index: 0)),
              "nesting cap is enforced (maxParallelDepth = \(Rig.maxParallelDepth))")
    }
}

// MARK: - Render slot mapping

func testRenderSlotMapping() {
    print("rendered gap -> model slot -> move")

    // The dragged element is not rendered, so the user sees the list without it.
    // Dropping in rendered gap i must place it exactly at position i of what
    // they can see. This is the composition of modelSlot(for:hiding:) with the
    // index adjustment inside move(from:to:).
    for draggedIndex in 0..<4 {
        for gap in 0...3 {
            var rig = makeRig([blk("a"), blk("b"), blk("c"), blk("d")])
            let chain = rig.chains[0].id
            let dragged = rig.chains[0].elements[draggedIndex].id

            let rendered = rig.renderedIDs(in: .top(chain), hiding: dragged)
            guard rendered.count == 3 else {
                check(false, "hidden element is excluded from the rendered list"); continue
            }

            let slot = RenderSlot(container: .top(chain), renderedIndex: gap)
            guard let modelSlot = rig.modelSlot(for: slot, hiding: dragged),
                  let address = rig.address(ofElement: dragged) else {
                check(false, "slot resolves"); continue
            }
            _ = rig.move(from: address, to: modelSlot)

            var expected = ["a", "b", "c", "d"]
            let name = expected.remove(at: draggedIndex)
            expected.insert(name, at: gap)

            check(shape(rig.chains[0].elements) == expected.joined(separator: " "),
                  "drag '\(name)' into gap \(gap) -> \(shape(rig.chains[0].elements))")
        }
    }
}

// MARK: - Persistence

func testCodableRoundTrip() {
    print("codable round trip")

    var rig = makeRig([blk("a"), blk("z")])
    let chain = rig.chains[0].id
    _ = rig.wrapInParallel(at: ElementAddress(container: .top(chain), index: 0))

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    guard let data = try? encoder.encode(rig),
          let decoded = try? decoder.decode(Rig.self, from: data) else {
        check(false, "rig encodes and decodes"); return
    }
    check(decoded == rig, "the recursive tree survives encode/decode unchanged")
    check(shape(decoded.chains[0].elements) == "<a|> z",
          "…including the parallel shape — got \(shape(decoded.chains[0].elements))")
}

// MARK: - Layout switching

func testLayoutIsNonDestructive() {
    print("layout switching")

    var rig = Rig(
        name: "Test",
        layout: .dual,
        chains: [
            SignalChain(name: "Guitar", source: .guitar, elements: [blk("a")]),
            SignalChain(name: "Vocal", source: .vocal, elements: [blk("v")]),
        ],
        createdAt: Date(timeIntervalSince1970: 0),
        modifiedAt: Date(timeIntervalSince1970: 0)
    )

    rig.layout = .single
    rig.chains = RigFactory.chains(growing: rig.chains, toAtLeast: RigLayout.single.chainCount)
    check(rig.activeChains.count == 1, "a single layout shows one chain")
    check(rig.chains.count == 2, "…but the hidden chain is NOT deleted")

    rig.layout = .dual
    rig.chains = RigFactory.chains(growing: rig.chains, toAtLeast: RigLayout.dual.chainCount)
    check(rig.activeChains.count == 2 && shape(rig.chains[1].elements) == "v",
          "…and switching back reveals it intact")
}
