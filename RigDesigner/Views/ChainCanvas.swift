import SwiftUI

/// Geometry snapshot used to register a container. Bundling the rendered ids
/// with the rect means the registry is refreshed when the *contents* change,
/// not only when the frame moves.
private struct ContainerSnapshot: Equatable {
    var rect: CGRect
    var ids: [UUID]
}

private struct ScrollSnapshot: Equatable {
    var offsetX: CGFloat
    var maxX: CGFloat
}

/// Live scroll state, kept off SwiftUI state so auto-scroll ticks are free.
@MainActor
private final class ScrollBox {
    var offsetX: CGFloat = 0
    var maxX: CGFloat = 0
    var isAutoScrolling = false
}

// MARK: - A series of elements

/// Renders one container: a horizontal run of elements with a drop gap in every
/// space between them.
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
            if items.isEmpty {
                RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                    .overlay {
                        Text("Dry")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
            }
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

    @Environment(RigEditor.self) private var editor
    @State private var scrollPosition = ScrollPosition(idType: Never.self)
    @State private var scrollBox = ScrollBox()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    EndpointTile(kind: .input, source: chain.source,
                                 isSelected: editor.selection == .input(chain.id))
                        .onTapGesture { editor.selection = .input(chain.id) }
                    Connector()

                    ElementSequenceView(
                        container: .top(chain.id),
                        elements: chain.elements,
                        depth: 0
                    )

                    Connector()
                    EndpointTile(kind: .output, source: chain.source,
                                 isSelected: editor.selection == .output(chain.id))
                        .onTapGesture { editor.selection = .output(chain.id) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .dragSurface(.canvas)
            }
            // While a node is lifted the scroll view must not compete for the
            // gesture; auto-scroll takes over programmatically instead.
            .scrollDisabled(editor.drag.isActive)
            .scrollPosition($scrollPosition)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geo in
                ScrollSnapshot(
                    offsetX: geo.contentOffset.x,
                    maxX: max(0, geo.contentSize.width - geo.containerSize.width)
                )
            } action: { _, new in
                scrollBox.maxX = new.maxX
                // Accept the echo only when the user is driving. During
                // auto-scroll the reported offset lags our own writes by a
                // frame, and feeding it back makes the canvas judder.
                if !scrollBox.isAutoScrolling { scrollBox.offsetX = new.offsetX }
            }
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.quinary.opacity(0.5))
            }
            .reportGlobalFrame { editor.registry.setChainViewport(chain.id, rect: $0) }
            .task(id: editor.drag.isActive) {
                await runAutoScroll()
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

    // MARK: - Auto-scroll

    /// Slide the canvas when the pointer rests near an edge during a drag.
    ///
    /// There is no scroll-by-offset API, and `ScrollPosition.x` is not a live
    /// readout of where the user scrolled to, so this keeps its own accumulator
    /// seeded from `onScrollGeometryChange` and writes absolute positions.
    private func runAutoScroll() async {
        guard editor.drag.isActive else {
            scrollBox.isAutoScrolling = false
            return
        }
        let frameInterval = Duration.milliseconds(16)
        let dt = 1.0 / 60.0

        while !Task.isCancelled && editor.drag.isActive {
            try? await Task.sleep(for: frameInterval)
            guard !Task.isCancelled else { break }

            guard let viewport = editor.registry.chainViewports[chain.id] else { continue }
            let point = editor.drag.pointerGlobal

            // Only the chain the pointer is actually over should scroll.
            let verticalSlack: CGFloat = 40
            guard point.y >= viewport.minY - verticalSlack,
                  point.y <= viewport.maxY + verticalSlack else {
                scrollBox.isAutoScrolling = false
                continue
            }

            let velocity = autoScrollVelocity(point: point, viewport: viewport)
            guard velocity != 0 else {
                scrollBox.isAutoScrolling = false
                continue
            }

            let proposed = (scrollBox.offsetX + velocity * dt).clamped(to: 0...max(0, scrollBox.maxX))
            guard abs(proposed - scrollBox.offsetX) > 0.01 else {
                scrollBox.isAutoScrolling = false
                continue
            }

            scrollBox.isAutoScrolling = true
            scrollBox.offsetX = proposed
            scrollPosition.scrollTo(point: CGPoint(x: proposed, y: 0))

            // The finger is stationary while the content slides, so the gesture
            // has stopped firing. Without this the gap would stay pinned to the
            // slot the pointer was over when it stopped moving.
            editor.recomputeTarget()
        }
        scrollBox.isAutoScrolling = false
    }

    private func autoScrollVelocity(point: CGPoint, viewport: CGRect) -> CGFloat {
        let zone = Metrics.autoScrollZone
        let leftDepth = zone - (point.x - viewport.minX)
        let rightDepth = zone - (viewport.maxX - point.x)

        if leftDepth > 0 {
            return -Metrics.autoScrollMaxSpeed * ramp(leftDepth / zone)
        }
        if rightDepth > 0 {
            return Metrics.autoScrollMaxSpeed * ramp(rightDepth / zone)
        }
        return 0
    }

    /// Ease in so the edge of the zone nudges gently and the very edge races.
    private func ramp(_ t: CGFloat) -> CGFloat {
        let c = t.clamped(to: 0...1)
        return c * c
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
