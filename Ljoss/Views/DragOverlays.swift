import SwiftUI

/// The tile that follows the finger.
///
/// Drawn at the root, above everything, so it is never clipped by a scroll view
/// or a lane background. Positioned from the global pointer minus the point
/// inside the tile where it was grabbed, so it does not snap to the touch.
struct DragGhostLayer: View {
    @Environment(RigEditor.self) private var editor

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            if let payload = editor.drag.payload {
                ghost(for: payload)
                    .offset(
                        x: editor.drag.ghostOrigin.x - origin.x,
                        y: editor.drag.ghostOrigin.y - origin.y
                    )
                    .scaleEffect(1.06, anchor: .center)
                    .rotationEffect(.degrees(editor.drag.isOverTrash ? -4 : 0))
                    .opacity(editor.drag.isOverTrash ? 0.7 : 1)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func ghost(for payload: DragPayload) -> some View {
        switch payload {
        case .newComponent(let componentID):
            NodeTile(block: Block(componentID: componentID), isGhost: true)
        case .existing(let id, _):
            if let element = element(id: id) {
                switch element {
                case .block(let block):
                    NodeTile(block: block, isGhost: true)
                case .parallel(let section):
                    ParallelGhost(section: section)
                }
            }
        }
    }

    private func element(id: UUID) -> ChainElement? {
        guard let address = editor.rig.address(ofElement: id) else { return nil }
        return editor.rig.element(at: address)
    }
}

/// A compact stand-in when a whole split section is in flight.
struct ParallelGhost: View {
    let section: ParallelSection

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 20, weight: .semibold))
            Text("Split")
                .font(.system(size: 14, weight: .semibold))
            Text("\(section.lanes.count) lanes")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: Metrics.nodeWidth, height: Metrics.nodeHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.nodeCorner, style: .continuous)
                .strokeBorder(.secondary, lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
    }
}

/// Drop here to delete. Only shown while an existing node is in flight, so it
/// never takes up space during normal editing.
struct TrashZone: View {
    @Environment(RigEditor.self) private var editor

    private var isVisible: Bool {
        editor.drag.isActive && editor.drag.payload?.existingID != nil
    }

    private var isTargeted: Bool { editor.drag.isOverTrash }

    var body: some View {
        let generation = editor.layoutGeneration

        Group {
            if isVisible {
                HStack(spacing: 10) {
                    Image(systemName: isTargeted ? "trash.fill" : "trash")
                        .font(.system(size: 20, weight: .semibold))
                    Text(isTargeted ? "Release to remove" : "Drag here to remove")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(isTargeted ? Color.white : Color.red)
                .padding(.horizontal, 24)
                .frame(height: 64)
                .background {
                    Capsule().fill(isTargeted ? Color.red : Color.red.opacity(0.16))
                }
                .overlay {
                    Capsule().strokeBorder(Color.red.opacity(isTargeted ? 0 : 0.5), lineWidth: 2)
                }
                .scaleEffect(isTargeted ? 1.08 : 1)
                .reportGlobalFrame(generation: generation) { editor.registry.trashRect = $0 }
                .onDisappear { editor.registry.trashRect = .zero }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(Anim.lift, value: isVisible)
        .animation(Anim.lift, value: isTargeted)
    }
}
