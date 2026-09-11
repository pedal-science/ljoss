import SwiftUI

/// Geometry snapshot used to register a container. Bundling the rendered ids
/// with the rect means the registry is refreshed when the *contents* change,
/// not only when the frame moves.
private struct ContainerSnapshot: Equatable {
    var rect: CGRect
    var ids: [UUID]
}

// MARK: - A series of elements

/// Renders one lane of a parallel section: a horizontal run of elements with a
/// drop gap in every space between them. Lanes never wrap; a chain's top level
/// is `ChainFlowView`.
struct ElementSequenceView: View {
    let container: ContainerPath
    let elements: [ChainElement]
    let depth: Int

    @Environment(RigEditor.self) private var editor

    private var rendered: [ChainElement] {
        let hidden = editor.drag.hiddenElementID
        return elements.filter { $0.id != hidden }
    }

    private func isTarget(_ index: Int) -> Bool {
        editor.drag.target == .slot(RenderSlot(container: container, renderedIndex: index))
    }

    var body: some View {
        let items = rendered
        let ids = items.map(\.id)

        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, element in
                DropGap(isOpen: isTarget(index), width: editor.drag.ghostSize.width)
                ElementView(element: element, container: container, depth: depth)
                if index < items.count - 1 { Connector() }
            }
            DropGap(isOpen: isTarget(items.count), width: editor.drag.ghostSize.width)
        }
        // An empty lane still needs a body to drop into.
        .frame(minWidth: items.isEmpty ? Metrics.nodeWidth : 0, minHeight: Metrics.nodeHeight)
        .background {
            if items.isEmpty { DryOutline() }
        }
        .onGeometryChange(for: ContainerSnapshot.self) { proxy in
            ContainerSnapshot(rect: proxy.frame(in: .global), ids: ids)
        } action: { snapshot in
            editor.registry.setContainer(
                container,
                rect: snapshot.rect,
                depth: depth,
                renderedIDs: snapshot.ids
            )
        }
        // A container that goes away — a split pruned, a rig switched — must not
        // leave its rect behind, or a stale lane can win a later hit test and
        // silently swallow drops.
        .onDisappear { editor.registry.removeContainer(container) }
    }
}

// MARK: - A chain's top level

/// A chain's top level — Input, its elements, Output — on one line, or wrapped
/// onto several rows to fit a width.
///
/// Every element is one flow item carrying its own leading wire, preceded by its
/// drop gap as a separate item. Keeping the gap separate is what lets it open at
/// the end of a row when there is room, and wrap to the start of the next row —
/// right before the tile it will precede — when there is not.
struct ChainFlowView: View {
    let chain: SignalChain
    /// The width to wrap at, or nil for one line.
    let wrapWidth: CGFloat?

    @Environment(RigEditor.self) private var editor

    private var container: ContainerPath { .top(chain.id) }

    private func isTarget(_ index: Int) -> Bool {
        editor.drag.target == .slot(RenderSlot(container: container, renderedIndex: index))
    }

    var body: some View {
        let hidden = editor.drag.hiddenElementID
        let items = chain.elements.filter { $0.id != hidden }
        let ids = items.map(\.id)
        let gapWidth = editor.drag.ghostSize.width
        // Enough wire for the most rows the chain could need: every tile on a
        // row of its own, plus one open gap. Unused pieces sit at zero size.
        let wirePieces = (items.count + 2) * FlowArrangement.WirePiece.allCases.count

        ChainFlowLayout(wrapWidth: wrapWidth) {
            EndpointTile(kind: .input, source: chain.source,
                         isSelected: editor.selection == .input(chain.id))
                .onTapGesture { editor.selection = .input(chain.id) }
                .reportGlobalFrame { editor.registry.setEndpoint(.leading, rect: $0, for: container) }

            ForEach(Array(items.enumerated()), id: \.element.id) { index, element in
                DropGap(isOpen: isTarget(index), width: gapWidth)
                HStack(spacing: 0) {
                    Connector()
                    ElementView(element: element, container: container, depth: 0)
                }
            }

            if items.isEmpty {
                HStack(spacing: 0) {
                    Connector()
                    DropGap(isOpen: isTarget(0), width: gapWidth)
                        .frame(minWidth: Metrics.nodeWidth, minHeight: Metrics.nodeHeight)
                        .background { DryOutline() }
                }
            } else {
                DropGap(isOpen: isTarget(items.count), width: gapWidth)
            }

            HStack(spacing: 0) {
                Connector()
                EndpointTile(kind: .output, source: chain.source,
                             isSelected: editor.selection == .output(chain.id))
                    .onTapGesture { editor.selection = .output(chain.id) }
                    .reportGlobalFrame { editor.registry.setEndpoint(.trailing, rect: $0, for: container) }
            }

            ForEach(0..<wirePieces, id: \.self) { n in
                Rectangle()
                    .fill(.tertiary)
                    .layoutValue(key: FlowRoleKey.self, value: .wire(
                        lineBreak: n / FlowArrangement.WirePiece.allCases.count,
                        piece: FlowArrangement.WirePiece(rawValue: n % FlowArrangement.WirePiece.allCases.count)!
                    ))
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: ContainerSnapshot.self) { proxy in
            ContainerSnapshot(rect: proxy.frame(in: .global), ids: ids)
        } action: { snapshot in
            editor.registry.setContainer(container, rect: snapshot.rect, depth: 0, renderedIDs: snapshot.ids)
        }
        .onDisappear { editor.registry.removeContainer(container) }
    }
}

// MARK: - One element

struct ElementView: View {
    let element: ChainElement
    let container: ContainerPath
    let depth: Int

    @Environment(RigEditor.self) private var editor

    var body: some View {
        switch element {
        case .block(let block):
            BlockNodeView(block: block, container: container)
        case .parallel(let section):
            ParallelSectionView(section: section, container: container, depth: depth)
        }
    }
}

struct BlockNodeView: View {
    let block: Block
    let container: ContainerPath

    @Environment(RigEditor.self) private var editor

    private var isSelected: Bool { editor.selection == .block(block.id) }

    var body: some View {
        NodeTile(block: block, isSelected: isSelected)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
                editor.registry.setElement(block.id, rect: rect)
            }
            .onDisappear { editor.registry.removeElement(block.id) }
            .onTapGesture { editor.selection = .block(block.id) }
            .contextMenu {
                Button {
                    editor.toggleEnabled(blockID: block.id)
                } label: {
                    Label(block.isEnabled ? "Bypass" : "Enable",
                          systemImage: block.isEnabled ? "power" : "power.circle")
                }
                Button { editor.selection = .block(block.id) } label: {
                    Label("Edit Parameters", systemImage: "slider.horizontal.3")
                }
                Button { editor.duplicateElement(id: block.id) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                if container.depth < Rig.maxParallelDepth {
                    Button { editor.splitAtElement(id: block.id) } label: {
                        Label("Split Here", systemImage: "arrow.triangle.branch")
                    }
                }
                Divider()
                Button(role: .destructive) { editor.removeElement(id: block.id) } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
    }
}

// MARK: - Parallel section

struct ParallelSectionView: View {
    let section: ParallelSection
    let container: ContainerPath
    let depth: Int

    @Environment(RigEditor.self) private var editor

    var body: some View {
        HStack(spacing: 0) {
            SplitBracket(lanes: section.lanes.count, isSplit: true)
                .onTapGesture { editor.selection = .parallel(section.id) }

            VStack(alignment: .leading, spacing: Metrics.laneSpacing) {
                ForEach(Array(section.lanes.enumerated()), id: \.element.id) { laneIndex, lane in
                    ElementSequenceView(
                        container: container.appending(
                            LaneStep(parallelID: section.id, laneIndex: laneIndex)
                        ),
                        elements: lane.elements,
                        depth: depth + 1
                    )
                }
            }
            .padding(.vertical, 8)

            SplitBracket(lanes: section.lanes.count, isSplit: false)
                .onTapGesture { editor.selection = .parallel(section.id) }
        }
        .padding(.horizontal, 4)
        .background {
            RoundedRectangle(cornerRadius: Metrics.nodeCorner + 6, style: .continuous)
                .fill(.quinary)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rect in
            editor.registry.setElement(section.id, rect: rect)
        }
        .onDisappear { editor.registry.removeElement(section.id) }
        .contextMenu {
            Button { editor.addLane(toParallel: section.id) } label: {
                Label("Add Lane", systemImage: "plus")
            }
            Button { editor.selection = .parallel(section.id) } label: {
                Label("Split Settings", systemImage: "slider.horizontal.3")
            }
            Divider()
            Button { editor.joinParallel(id: section.id) } label: {
                Label("Join Into Series", systemImage: "arrow.triangle.merge")
            }
        }
    }
}

/// The fan-out / fan-in bracket drawn either side of a parallel section.
struct SplitBracket: View {
    let lanes: Int
    let isSplit: Bool

    var body: some View {
        Image(systemName: isSplit ? "arrow.triangle.branch" : "arrow.triangle.merge")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(isSplit ? "Split into \(lanes) lanes" : "Join lanes"))
    }
}

// MARK: - A whole chain

struct ChainRowView: View {
    let chain: SignalChain
    /// Wrap the chain onto more rows to fit the width, rather than scrolling
    /// sideways to reach the end of it.
    let wraps: Bool

    @Environment(RigEditor.self) private var editor
    @State private var viewportWidth: CGFloat = 0

    /// The width rows break at, or nil for one line. Also nil until the row has
    /// been measured once, so the first pass lays out a line, not a column.
    private var wrapWidth: CGFloat? {
        guard wraps, viewportWidth > 0 else { return nil }
        return viewportWidth - 2 * Metrics.canvasPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            // Still a scroll view when wrapping: a split section wider than the
            // screen cannot wrap internally, so it overflows its row and the row
            // scrolls, rather than being clipped.
            ScrollView(.horizontal) {
                ChainFlowView(chain: chain, wrapWidth: wrapWidth)
                    .animation(Anim.reflow, value: wraps)
                    .padding(.horizontal, Metrics.canvasPadding)
                    .padding(.vertical, 12)
                    .dragSurface(.canvas)
            }
            // While a node is lifted the scroll view must not compete for the
            // gesture; auto-scroll takes over programmatically instead.
            .scrollDisabled(editor.drag.isActive)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .dragAutoScroll(.horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.quinary.opacity(0.5))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: chain.source.symbol)
                .font(.system(size: 13, weight: .semibold))
            Text(chain.name)
                .font(.system(size: 14, weight: .semibold))
            Text("\(chain.blockCount) blocks")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
    }
}
