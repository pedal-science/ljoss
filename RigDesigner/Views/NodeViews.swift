import SwiftUI

// MARK: - Node tile

/// One effect block on the canvas. This is the primary drag handle, which is
/// why it is deliberately large.
struct NodeTile: View {
    let block: Block
    var isSelected: Bool = false
    var isGhost: Bool = false

    private var spec: ComponentSpec { Catalogue.resolve(block.componentID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: spec.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(block.isEnabled ? spec.category.accent : .secondary)
                Spacer(minLength: 0)
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

            Text(spec.category.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: Metrics.nodeWidth, height: Metrics.nodeHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
                .fill(spec.category.accent.opacity(block.isEnabled ? 0.18 : 0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
                .strokeBorder(
                    isSelected ? spec.category.accent : spec.category.accent.opacity(0.35),
                    lineWidth: isSelected ? 3 : 1.5
                )
        }
        .opacity(block.isEnabled ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous))
        .shadow(color: .black.opacity(isGhost ? 0.32 : 0), radius: isGhost ? 18 : 0, y: isGhost ? 10 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(spec.name))
        .accessibilityHint(Text(block.isEnabled ? "Enabled" : "Bypassed"))
    }
}

// MARK: - Endpoints

/// The fixed Input / Output caps. Never draggable, never removable.
struct EndpointTile: View {
    enum Kind { case input, output }
    let kind: Kind
    let source: SourceKind
    var isSelected: Bool = false

    private var title: String { kind == .input ? "Input" : "Output" }
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
