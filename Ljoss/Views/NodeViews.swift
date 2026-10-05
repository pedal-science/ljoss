import SwiftUI

/// Supplies the meters with the session's levels and one shared clock.
///
/// A view modifier rather than an environment object of its own: the meters are read by tiles
/// that already have the session, and a second observable to inject would be one more thing to
/// forget in a preview.
struct MeterReaderProvider: ViewModifier {
    @Environment(EngineSession.self) private var session: EngineSession?
    @State private var reader = MeterReader()

    func body(content: Content) -> some View {
        content
            .environment(reader)
            .task(id: tickIdentity) {
                // The tiles read `reader`, which is updated on the same cadence the levels model
                // polls at. Driving it from a task rather than from the levels poll keeps the
                // decay off the poller's critical path — and means a meter whose view is not on
                // screen costs nothing but the shared poll.
                while !Task.isCancelled {
                    reader.tick(session?.levels.levels)
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
    }

    /// Restarting the tick loop when the connection changes means a reconnect picks up fresh
    /// levels rather than decaying the old ones forever.
    private var tickIdentity: String {
        "\(session?.levels.hasReading ?? false)-\(session?.connection.isOnline ?? false)"
    }
}

extension View {
    /// Give this subtree the meters' readings. Apply once, around the rig canvas.
    func meterReadings() -> some View { modifier(MeterReaderProvider()) }
}

// MARK: - Node tile

/// One effect block on the canvas. This is the primary drag handle, which is
/// why it is deliberately large.
struct NodeTile: View {
    let block: Block
    var isSelected: Bool = false
    var isGhost: Bool = false

    /// Optional so the tile still renders with no device set up, and in a preview.
    /// `canPlay` is nil while offline: "unknown" is not "unavailable".
    @Environment(EngineSession.self) private var session: EngineSession?
    /// The shared level readings. Present only inside a canvas that has `meterReadings()`.
    @Environment(MeterReader.self) private var meters: MeterReader?

    private var spec: ComponentSpec { Catalogue.resolve(block.componentID) }
    private var isUnplayable: Bool { session?.canPlay(block.componentID) == false }
    /// The device doesn't have this block's model or IR, so it plays the block as if
    /// bypassed. Shown as not configured: a marker, a dashed outline, and what's missing.
    private var missing: EngineIssue? { session?.missingAsset(for: block.id) }
    private var missingText: String {
        missing?.kind == "ir" ? "IR not on device" : "Model not on device"
    }
    /// How loud the tile looks: a missing file sounds like a bypass, so it looks like one.
    private var isSounding: Bool { block.isEnabled && missing == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: spec.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(block.isEnabled ? spec.category.accent : .secondary)
                Spacer(minLength: 0)
                if missing != nil {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.orange)
                }
                if isUnplayable {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.orange)
                }
                if !block.isEnabled {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Text(spec.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(missing != nil ? missingText : spec.category.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(missing != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)

            // What this block is passing, right now. Only while it is in the signal path: a
            // bypassed block still runs but its output is not what the next node reads, so a bar
            // there would show a level that is not in the signal.
            if isSounding, let db = meters?.block(block.id) {
                LevelBar(db: db, height: 5)
            }
        }
        .padding(12)
        .frame(width: Metrics.nodeWidth, height: Metrics.nodeHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
                .fill(spec.category.accent.opacity(isSounding ? 0.18 : 0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
                .strokeBorder(
                    missing != nil ? Color.orange : (isSelected ? spec.category.accent : spec.category.accent.opacity(0.35)),
                    style: StrokeStyle(lineWidth: isSelected ? 3 : 1.5, dash: missing != nil ? [6, 4] : [])
                )
        }
        .opacity(isSounding ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous))
        .shadow(color: .black.opacity(isGhost ? 0.32 : 0), radius: isGhost ? 18 : 0, y: isGhost ? 10 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(spec.name))
        .accessibilityHint(Text(missing != nil
                                ? "\(missingText): plays as bypassed"
                                : isUnplayable
                                ? "Not available on the connected device"
                                : (block.isEnabled ? "Enabled" : "Bypassed, and still running")))
    }
}

// MARK: - Endpoints

/// The fixed Input / Output caps. Never draggable, never removable.
struct EndpointTile: View {
    enum Kind { case input, output }
    let kind: Kind
    let source: SourceKind
    var isSelected: Bool = false

    @Environment(MeterReader.self) private var meters: MeterReader?

    private var title: String { kind == .input ? "Input" : "Output" }

    /// \brief The device's own levels for this end, one bar per channel.
    ///
    /// The Input cap and the Output cap are the two places where a level is not "this block's" but
    /// the converter's: the ADC's before any routing, the DAC's after every chain has summed. Those
    /// are the numbers that answer "is anything arriving" and "is it too hot", which are the two
    /// questions a player with a silent or a nasty-sounding pedal asks first. Nil when the engine
    /// has no levels to give (an older engine, or nothing measured yet), which is why the tile
    /// shows nothing rather than a bar at the floor.
    private var side: MeterSide { kind == .input ? .input : .output }
    private var channels: [Double?] { meters?.channels(for: side) ?? [] }

    private var isClipping: Bool {
        guard let meters, kind == .output else { return false }
        return meters.clipped
    }
    private var symbol: String {
        switch kind {
        case .input: source == .vocal ? "music.mic" : "cable.connector"
        case .output: "speaker.wave.3"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(kind == .input ? source.displayName : "Main")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !channels.isEmpty {
                VStack(spacing: 3) {
                    LevelBars(values: channels, height: 7)
                    if isClipping {
                        Text("CLIP")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(width: Metrics.ioWidth, height: Metrics.nodeHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
                .fill(.quaternary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .contentShape(RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(source.displayName)"))
        .accessibilityValue(Text(kind == .output && isClipping ? "clipping" : ""))
    }
}

// MARK: - Connector and gap

/// The wire between two nodes.
///
/// In a chain's top level each tile carries one of these on its leading side,
/// so a tile that wraps onto a new row takes the wire into it along with it.
struct Connector: View {
    var body: some View {
        Rectangle()
            .fill(.tertiary)
            .frame(width: Metrics.nodeSpacing, height: Metrics.wireThickness)
    }
}

/// Dashed outline marking an element list with nothing in it yet.
struct DryOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
            .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            .overlay {
                Text("Dry")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
    }
}

/// The space that opens up to receive a dragged item.
///
/// Its whole job is to animate its own width between zero and a full node, so
/// the surrounding `HStack` reflows and the chain visibly "opens up". Nothing is
/// inserted into the model to achieve this.
struct DropGap: View {
    let isOpen: Bool
    var width: CGFloat = Metrics.nodeWidth

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
            .strokeBorder(
                Color.accentColor.opacity(0.9),
                style: StrokeStyle(lineWidth: 2.5, dash: [7, 6])
            )
            .background {
                RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
            .frame(width: isOpen ? width : 0, height: Metrics.nodeHeight)
            .padding(.horizontal, isOpen ? Metrics.nodeSpacing / 2 : 0)
            .opacity(isOpen ? 1 : 0)
            .allowsHitTesting(false)
    }
}
