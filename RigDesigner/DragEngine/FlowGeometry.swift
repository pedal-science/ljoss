import CoreGraphics

/// Geometry for a chain laid out like wrapped text: which row each tile lands
/// on, where it sits, and the wire that carries the signal from the end of one
/// row to the start of the next.
///
/// Pure — no SwiftUI — so the line-breaking rules can be asserted without a
/// view hierarchy. `ChainFlowLayout` is a thin adapter over this.
struct FlowArrangement: Equatable {

    struct Style: Equatable, Sendable {
        /// Vertical gap between rows; the return wire runs through its middle.
        var rowSpacing: CGFloat
        var wireThickness: CGFloat
        /// How far the wire runs right of a row's last tile before turning down.
        var stubLength: CGFloat
        /// Kept clear at the right of every row so the out stub and its turn
        /// never run past the wrap width.
        var trailingReserve: CGFloat { stubLength + wireThickness }
    }

    struct Row: Equatable {
        /// Indices into the item list, left to right.
        var items: [Int]
        /// From x = 0 to the end of the row's last item; as tall as its tallest.
        var frame: CGRect
    }

    /// The four straight runs of wire across one line break, drawn as filled
    /// rects that meet edge to edge: none overlap, so a translucent wire colour
    /// shows no dark spots at the corners.
    enum WirePiece: Int, CaseIterable, Sendable {
        /// Out of the row's last tile, to the right.
        case outStub
        /// Down, past the bottom of the row.
        case rightDrop
        /// Back across, through the gutter between the rows.
        case returnRun
        /// Down the left margin to the next row's wire height.
        case leftDrop
    }

    /// Top-leading frames, one per item, in the layout's own space.
    var itemFrames: [CGRect]
    var rows: [Row]
    /// One entry per line break (`rows.count - 1`), indexed by `WirePiece.rawValue`.
    var wires: [[CGRect]]
    var size: CGSize
    /// Where an unused wire piece sits: zero-sized at the end of the last row,
    /// so a piece coming into use grows out from where the flow ends.
    var restingWire: CGRect

    /// - Parameter wrapWidth: The width to wrap at, or nil to keep everything on
    ///   one line.
    init(sizes: [CGSize], wrapWidth: CGFloat?, style: Style) {
        // Line breaking.
        let limit = wrapWidth.map { $0 - style.trailingReserve }
        var grouped: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            // Break before an item that would overrun the row — except an item
            // with no width (a closed drop gap), which fits anywhere and so must
            // never be what starts a row, and except on a row that is still
            // empty, where an item wider than the limit simply overflows.
            if let limit, size.width > 0, x > 0, x + size.width > limit {
                grouped.append([])
                x = 0
            }
            grouped[grouped.count - 1].append(i)
            x += size.width
        }

        // Placement: items on a row share its vertical centre, which is where
        // the wire runs through them.
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        var rows: [Row] = []
        var y: CGFloat = 0
        for items in grouped {
            let height = items.map { sizes[$0].height }.max() ?? 0
            var cursor: CGFloat = 0
            for i in items {
                let s = sizes[i]
                frames[i] = CGRect(x: cursor, y: y + (height - s.height) / 2, width: s.width, height: s.height)
                cursor += s.width
            }
            rows.append(Row(items: items, frame: CGRect(x: 0, y: y, width: cursor, height: height)))
            y += height + style.rowSpacing
        }

        // The return wire: right out of the last tile, down past the row, back
        // across the gutter, and down into the next row from the left. The next
        // row's first tile carries its own leading wire, which completes the run.
        let t = style.wireThickness
        let h = t / 2
        let s = style.stubLength
        let wires: [[CGRect]] = zip(rows, rows.dropFirst()).map { above, below in
            let right = above.frame.maxX
            let left: CGFloat = 0
            let y0 = above.frame.midY
            let run = above.frame.maxY + style.rowSpacing / 2
            let y1 = below.frame.midY
            var pieces = Array(repeating: CGRect.zero, count: WirePiece.allCases.count)
            pieces[WirePiece.outStub.rawValue] =
                CGRect(x: right, y: y0 - h, width: s + h, height: t)
            pieces[WirePiece.rightDrop.rawValue] =
                CGRect(x: right + s - h, y: y0 + h, width: t, height: run - y0)
            pieces[WirePiece.returnRun.rawValue] =
                CGRect(x: left - t, y: run - h, width: right + s - h - (left - t), height: t)
            pieces[WirePiece.leftDrop.rawValue] =
                CGRect(x: left - t, y: run + h, width: t, height: y1 - run)
            return pieces
        }

        let widest = rows.map(\.frame.width).max() ?? 0
        let last = rows[rows.count - 1].frame

        self.itemFrames = frames
        self.rows = rows
        self.wires = wires
        self.size = CGSize(
            width: widest + (rows.count > 1 ? style.trailingReserve : 0),
            height: max(0, y - style.rowSpacing)
        )
        self.restingWire = CGRect(x: last.maxX, y: last.midY, width: 0, height: 0)
    }
}

/// Which slot a pointer is aiming at in a container whose tiles may be wrapped
/// onto several rows.
enum FlowHitTest {

    /// Something on screen that marks a position in the container.
    struct Mark: Equatable {
        var rect: CGRect
        /// The slot the pointer means when it is left of this mark's midpoint.
        var before: Int
        /// The slot it means when it is right of the midpoint, with nothing
        /// further along the row.
        var after: Int

        /// A rendered element at `index`.
        static func element(_ index: Int, _ rect: CGRect) -> Mark {
            Mark(rect: rect, before: index, after: index + 1)
        }
        /// A fixed tile that both sides of lead to the same slot — a chain's
        /// Input (slot 0) or Output (slot `count`).
        static func endpoint(slot: Int, _ rect: CGRect) -> Mark {
            Mark(rect: rect, before: slot, after: slot)
        }
    }

    /// - Parameters:
    ///   - marks: Everything positioned in the container, in reading order.
    ///   - count: The number of rendered elements, which is the last slot.
    static func insertionIndex(marks: [Mark], count: Int, at point: CGPoint) -> Int {
        guard !marks.isEmpty else { return count }

        // Group into rows. Tiles on one row overlap vertically, because they
        // are centred on the same wire; a tile wholly below the row so far
        // starts the next. (Comparing x instead — "it moved back left" — breaks
        // as soon as an open gap pushes a row's first tile right.)
        var rows: [[Mark]] = []
        var bottom = -CGFloat.infinity
        for mark in marks {
            if rows.isEmpty || mark.rect.minY > bottom {
                rows.append([mark])
                bottom = mark.rect.maxY
            } else {
                rows[rows.count - 1].append(mark)
                bottom = max(bottom, mark.rect.maxY)
            }
        }

        // The pointer's row: the space between two rows splits at its midpoint.
        var row = rows[rows.count - 1]
        for r in 0..<(rows.count - 1) {
            let aboveBottom = rows[r].map(\.rect.maxY).max() ?? 0
            let belowTop = rows[r + 1].map(\.rect.minY).min() ?? 0
            if point.y < (aboveBottom + belowTop) / 2 {
                row = rows[r]
                break
            }
        }

        // Within the row, the first tile whose midpoint is right of the pointer.
        for mark in row where point.x < mark.rect.midX {
            return min(mark.before, count)
        }
        return min(row[row.count - 1].after, count)
    }
}
