import Foundation
import Observation

/// The finder's user data, kept where iCloud keeps it.
///
/// `NSUbiquitousKeyValueStore` is the app's iCloud key-value store: the system syncs it
/// between the user's devices and restores it after the app is deleted and re-installed,
/// which is exactly the promise a rating needs. It only works in a **code-signed** build
/// carrying the `com.apple.developer.ubiquity-kvstore-identifier` entitlement
/// (`RigDesigner/RigDesigner.entitlements`). With the entitlement but no iCloud account
/// signed in, it persists locally and never syncs; without the entitlement it is inert —
/// every write silently no-ops, so signing is not optional here (`docs/ASSETS.md`).
///
/// One blob under one key rather than a key per model: it is small, it is always read
/// and written whole, and the store's keyspace is shared with anything else the app
/// keeps there.
@MainActor
@Observable
final class ModelUserDataStore {

    /// The key the blob lives under in the key-value store. Versioned, so a future
    /// shape can be recognized rather than guessed at.
    static let storageKey = "RigDesigner.ModelUserData.v1"

    private(set) var data: ModelUserData

    @ObservationIgnored private let store: NSUbiquitousKeyValueStore
    /// `nonisolated(unsafe)` because the one thing that touches it off the main actor is
    /// `deinit`, which has to remove it; the notification it observes is queued on the
    /// main queue, where every other access happens.
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    init(store: NSUbiquitousKeyValueStore = .default) {
        self.store = store
        self.data = Self.decode(store.data(forKey: Self.storageKey))
        // A change made on another device arrives as a notification. The system has
        // already merged it; all this has to do is read it back.
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Reading

    /// The remembered search words, in the order the chip row shows them.
    var terms: [SearchTerm] { data.rankedTerms() }

    func rating(for entry: AssetEntry) -> Int? { data.rating(for: entry.userKey) }
    func isUsed(_ entry: AssetEntry) -> Bool { data.isUsed(entry.userKey) }

    // MARK: - Writing

    func rate(_ stars: Int, for entry: AssetEntry, at now: Date = Date()) {
        mutate { $0.rate(stars, for: entry.userKey, at: now) }
    }

    func clearRating(for entry: AssetEntry) {
        mutate { $0.clearRating(for: entry.userKey) }
    }

    /// Note that these models have just been used, stamping each with `now`.
    func markUsed(_ keys: [String], at now: Date = Date()) {
        mutate { $0.markUsed(keys, at: now) }
    }

    /// Remember the words of a settled search.
    func remember(_ words: [String], at now: Date = Date()) {
        mutate { $0.remember(words, at: now) }
    }

    // MARK: - The store

    /// Change, and write only if something actually changed: closing a node's config
    /// with nothing picked must not touch the key-value store, whose writes are
    /// quota'd and, when iCloud is on, are network traffic.
    private func mutate(_ change: (inout ModelUserData) -> Void) {
        var updated = data
        change(&updated)
        guard updated != data else { return }
        data = updated
        save()
    }

    private func save() {
        guard let encoded = try? Self.encoder.encode(data) else { return }
        store.set(encoded, forKey: Self.storageKey)
        store.synchronize()
    }

    private func reload() {
        data = Self.decode(store.data(forKey: Self.storageKey))
    }

    private static func decode(_ data: Data?) -> ModelUserData {
        guard let data, let decoded = try? decoder.decode(ModelUserData.self, from: data) else {
            return ModelUserData()
        }
        return decoded
    }
}
