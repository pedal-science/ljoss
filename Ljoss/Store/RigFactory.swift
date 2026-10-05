import Foundation

/// Builds new rigs, and the starter set a first-run user sees.
enum RigFactory {

    static func block(_ componentID: String) -> ChainElement {
        .block(Block(componentID: componentID))
    }

    static func emptyRig(name: String, layout: RigLayout = .single) -> Rig {
        let now = Date()
        return Rig(
            name: name,
            layout: layout,
            chains: chains(for: layout),
            createdAt: now,
            modifiedAt: now
        )
    }

    static func chains(for layout: RigLayout) -> [SignalChain] {
        switch layout {
        case .single:
            [SignalChain(name: "Guitar", source: .guitar)]
        case .dual:
            [
                SignalChain(name: "Guitar", source: .guitar),
                SignalChain(name: "Vocal", source: .vocal),
            ]
        }
    }

    /// Ensure a rig has at least `count` chains, adding sensible new ones.
    ///
    /// Grow-only by design — see `Rig.activeChains`. A layout change must never
    /// be able to delete a chain the user has filled with blocks.
    static func chains(growing existing: [SignalChain], toAtLeast count: Int) -> [SignalChain] {
        guard existing.count < count else { return existing }
        var result = existing
        let templates = chains(for: .dual)
        while result.count < count {
            let template = templates[min(result.count, templates.count - 1)]
            let name = result.contains { $0.name == template.name }
                ? "\(template.name) \(result.count + 1)"
                : template.name
            result.append(SignalChain(name: name, source: template.source))
        }
        return result
    }

    // MARK: - Starter content

    static func starterRigs() -> [Rig] {
        let now = Date()

        var lead = Rig(
            name: "Crunch Lead",
            layout: .single,
            chains: [
                SignalChain(name: "Guitar", source: .guitar, elements: [
                    block("dyn.gate"),
                    block("drive.green"),
                    block("amp.britplexi"),
                    block("cab.412brit"),
                    block("delay.tape"),
                    block("verb.hall"),
                ])
            ],
            createdAt: now.addingTimeInterval(-7200),
            modifiedAt: now.addingTimeInterval(-7200)
        )
        lead.normalize()

        // A rig that shows off the parallel routing: the reverb sits in its own
        // wet lane alongside a dry path.
        let wetDry = ParallelSection(lanes: [
            Lane(elements: [block("verb.shimmer")]),
            Lane(elements: [block("delay.pingpong")]),
        ])
        var ambient = Rig(
            name: "Ambient Wash",
            layout: .single,
            chains: [
                SignalChain(name: "Guitar", source: .guitar, elements: [
                    block("dyn.comp.optical"),
                    block("amp.cleanblack"),
                    block("cab.212chime"),
                    .parallel(wetDry),
                    block("eq.highcut"),
                ])
            ],
            createdAt: now.addingTimeInterval(-3600),
            modifiedAt: now.addingTimeInterval(-3600)
        )
        ambient.normalize()

        var band = Rig(
            name: "Guitar + Vocal",
            layout: .dual,
            chains: [
                SignalChain(name: "Guitar", source: .guitar, elements: [
                    block("drive.transparent"),
                    block("amp.chime"),
                    block("cab.112open"),
                    block("delay.slapback"),
                ]),
                SignalChain(name: "Vocal", source: .vocal, elements: [
                    block("vocal.preamp"),
                    block("dyn.deesser"),
                    block("dyn.comp.studio"),
                    block("verb.vocalplate"),
                ]),
            ],
            createdAt: now,
            modifiedAt: now
        )
        band.normalize()

        return [band, ambient, lead]
    }
}
