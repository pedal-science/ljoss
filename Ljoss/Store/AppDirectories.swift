import Foundation

/// The app's own folder on disk, and the one-time move that followed the app's rename.
///
/// Everything the app writes for itself lives under one folder in Application Support —
/// the rigs, the asset library, and the local engine's scratch space — so the folder's name
/// is spelled here once rather than in each of the three places that used to spell it.
enum AppDirectories {

    /// What the folder is called. The app was RigDesigner until it was renamed, so this is
    /// also what `ljoss.json` and the local engine already assumed.
    static let name = "Ljoss"

    /// What the folder was called before the rename. Nothing looks anything up under this
    /// name; it is here only so the first launch of the renamed app can bring the old
    /// folder across — see `migrateLegacyFolder`.
    static let legacyName = "RigDesigner"

    /// `~/Library/Application Support/Ljoss`, and its iOS equivalent.
    static func support(fileManager: FileManager = .default) -> URL {
        base(fileManager: fileManager).appending(path: name, directoryHint: .isDirectory)
    }

    /// Bring what an older build wrote under `Application Support/RigDesigner` into the
    /// folder's new name. Safe to call from anywhere, any number of times, including when
    /// there is nothing to move: after the first pass there is no old folder left.
    ///
    /// Entry by entry rather than one rename of the folder, because the new folder can
    /// already exist — the local engine makes `Ljoss/LocalEngine` on a Mac before any rig is
    /// saved. A whole-folder rename would then either fail or bury the rigs, which is the
    /// one outcome worth this much code to avoid. An entry that already exists under the new
    /// name wins, and the old folder is only removed once it has been emptied: a folder left
    /// holding something is still a folder the user can find and open.
    @MainActor
    static func migrateLegacyFolder(fileManager: FileManager = .default) {
        let legacy = base(fileManager: fileManager)
            .appending(path: legacyName, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let entries = try? fileManager.contentsOfDirectory(
                at: legacy, includingPropertiesForKeys: nil
              )
        else { return }

        let current = support(fileManager: fileManager)
        try? fileManager.createDirectory(at: current, withIntermediateDirectories: true)
        for entry in entries {
            let destination = current.appending(path: entry.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.moveItem(at: entry, to: destination)
        }
        if let left = try? fileManager.contentsOfDirectory(atPath: legacy.path), left.isEmpty {
            try? fileManager.removeItem(at: legacy)
        }
    }

    /// Application Support itself, which Foundation creates on request because it may not
    /// exist yet on a machine that has never run anything that writes there.
    private static func base(fileManager: FileManager) -> URL {
        (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
    }
}
