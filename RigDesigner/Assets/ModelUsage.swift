import Foundation

// Which models a rig is actually using.
//
// "Used" means chosen for a node that runs a NAM capture. It is deliberately not
// derived from what is on disk and not counted per session: the list is a history the
// finder records when the user commits — closing a node's config, switching rigs, or
// leaving the app — and the date it keeps is the last time that happened
// (`docs/ASSETS.md`).
//
// No SwiftUI here: this file is in the source list of `Tests/run-model-tests.sh`.

enum ModelUsage {

    /// The model a block is set to, as user data keys are spelled, or nil when the
    /// block runs no capture or none has been chosen.
    static func pickedModel(in block: Block) -> String? {
        guard BlockMappings.mapping(for: block.componentID)?
            .requiredAssets.contains(.model) == true,
              let picked = block.values[AssetKind.model.valueKey]?.optionValue,
              !picked.isEmpty else { return nil }
        return picked.lowercased()
    }

    /// Every model picked anywhere in a rig, including chains the layout is hiding —
    /// a hidden chain is still the user's work, and a model chosen in it has been used.
    static func pickedModels(in rig: Rig) -> [String] {
        rig.allBlocks.compactMap(pickedModel(in:))
    }
}
