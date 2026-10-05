import Foundation

extension Rig {

    /// Convert an on-screen gap into a model insertion slot.
    ///
    /// While a drag is in flight the element being moved is not rendered, so
    /// rendered indices in its container run one short of model indices past its
    /// position. Mapping here — rather than compensating in the view — keeps the
    /// gap drawn exactly where the eye expects it.
    ///
    /// This composes correctly with the adjustment inside `move(from:to:)`:
    /// mapping produces a slot in the *current* model (which still contains the
    /// dragged element), and `move` then accounts for the hole its own removal
    /// leaves. Applying only one of the two is the classic off-by-one.
    func modelSlot(for slot: RenderSlot, hiding hiddenID: UUID?) -> InsertionSlot? {
        guard let list = elements(at: slot.container) else { return nil }

        guard let hiddenID,
              let hiddenIndex = list.firstIndex(where: { $0.id == hiddenID })
        else {
            return InsertionSlot(container: slot.container, index: min(slot.renderedIndex, list.count))
        }

        let rendered = slot.renderedIndex
        let modelIndex = rendered <= hiddenIndex ? rendered : rendered + 1
        return InsertionSlot(container: slot.container, index: min(modelIndex, list.count))
    }

    /// The rendered ids of a container with the dragged element removed — what
    /// the canvas actually lays out.
    func renderedIDs(in path: ContainerPath, hiding hiddenID: UUID?) -> [UUID] {
        (elements(at: path) ?? [])
            .map(\.id)
            .filter { $0 != hiddenID }
    }
}
