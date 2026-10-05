import SwiftUI

/// What a subview is to `ChainFlowLayout`.
enum FlowRole: Hashable, Sendable {
    /// A tile (with its leading wire) or a drop gap, laid out in reading order.
    case item
    /// One straight run of the wire drawn across a line break.
    case wire(lineBreak: Int, piece: FlowArrangement.WirePiece)
}

struct FlowRoleKey: LayoutValueKey {
    static let defaultValue: FlowRole = .item
}

/// Lays a chain out left to right and — given a width — wraps it onto further
/// rows like words in a paragraph, with the signal wire running from the end of
/// each row down, back across, and into the start of the next.
///
/// The return wire is made of plain rectangles **placed by this layout**, not
/// drawn over the top from measured frames. Measured frames report where tiles
/// will end up, not where they are mid-animation, so an overlay wire would jump
/// ahead of the tiles whenever a gap opens and pushes one onto the next row.
/// Placed here, the wire moves in the same transaction as the tiles.
struct ChainFlowLayout: Layout {
    /// The width to wrap at, or nil for one line.
    var wrapWidth: CGFloat?

    static let style = FlowArrangement.Style(
        rowSpacing: Metrics.wrapRowSpacing,
        wireThickness: Metrics.wireThickness,
        stubLength: Metrics.nodeSpacing
    )

    private func arrange(_ subviews: Subviews) -> (flow: FlowArrangement, items: [Int]) {
        let items = subviews.indices.filter { subviews[$0][FlowRoleKey.self] == .item }
        // Every tile has a fixed ideal size; the layout never squeezes one.
        let sizes = items.map { subviews[$0].sizeThatFits(.unspecified) }
        return (FlowArrangement(sizes: sizes, wrapWidth: wrapWidth, style: Self.style), items)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews).flow.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (flow, items) = arrange(subviews)

        func place(_ index: Int, at frame: CGRect) {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }

        for (n, index) in items.enumerated() {
            place(index, at: flow.itemFrames[n])
        }
        for index in subviews.indices {
            guard case .wire(let lineBreak, let piece) = subviews[index][FlowRoleKey.self] else { continue }
            let frame = lineBreak < flow.wires.count ? flow.wires[lineBreak][piece.rawValue] : flow.restingWire
            place(index, at: frame)
        }
    }
}

/// The toolbar icon for the wrap toggle: a picture of what the chain looks like
/// in the current mode — tiles wrapped onto two rows with the wire turning back
/// under them, or a single row running off the edge.
struct WrapGlyph: Shape {
    var wraps: Bool

    func path(in rect: CGRect) -> Path {
        // Drawn on a 24 × 18 grid, then scaled to the rect.
        var p = Path()
        func tile(_ x: CGFloat, _ y: CGFloat) {
            p.addRoundedRect(in: CGRect(x: x, y: y, width: 7.5, height: 6), cornerSize: CGSize(width: 1.6, height: 1.6))
        }
        func wire(_ points: CGPoint...) {
            p.addLines(points)
        }

        if wraps {
            tile(1, 1)
            tile(12, 1)
            tile(5, 11)
            wire(CGPoint(x: 8.5, y: 4), CGPoint(x: 12, y: 4))
            wire(CGPoint(x: 19.5, y: 4), CGPoint(x: 22.5, y: 4), CGPoint(x: 22.5, y: 9),
                 CGPoint(x: 2, y: 9), CGPoint(x: 2, y: 14), CGPoint(x: 5, y: 14))
        } else {
            tile(1, 6)
            tile(11.5, 6)
            tile(22, 6)            // cut off by the edge: the row carries on out of view
            wire(CGPoint(x: 8.5, y: 9), CGPoint(x: 11.5, y: 9))
            wire(CGPoint(x: 19, y: 9), CGPoint(x: 22, y: 9))
        }

        return p.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 24, y: rect.height / 18))
    }
}

/// The wrap toggle's label.
struct WrapToggleIcon: View {
    let wraps: Bool

    var body: some View {
        WrapGlyph(wraps: wraps)
            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: 24, height: 18)
            .clipped()
    }
}
