import Foundation

// What the *user* has said about the local library, as opposed to what is in it.
//
// The library lists what is on disk; this is the part that only exists because
// somebody used the app: the rating they gave a capture, the models they have used in
// a node, and the words they have searched for. None of it is derivable from a file,
// so it is kept as user data — the store that holds it puts it where iCloud keeps it,
// because a rating that dies with the app is a rating the user has to give twice
// (`docs/ASSETS.md`).
//
// No SwiftUI here: this file is in the source list of `Tests/run-model-tests.sh`.

// MARK: - One model's rating

/// The stars the user gave a model, and when.
struct ModelRating: Codable, Hashable, Sendable {
    /// 1…5. Clamped on the way in, so a value that is not a rating cannot be stored.
    var stars: Int
    var ratedAt: Date
}

// MARK: - A model that has been used

/// One model the user has used in a node, and the last time they did.
struct UsedModel: Codable, Hashable, Sendable, Identifiable {
    /// `AssetEntry.userKey` — the model's library id, lowercased.
    var key: String
    var lastUsed: Date

    var id: String { key }
}

// MARK: - A word that has been searched for

/// One word the user has searched for, and how they have used it.
struct SearchTerm: Codable, Hashable, Sendable, Identifiable {
    var word: String
    /// How many settled searches have included this word.
    var count: Int
    var lastUsed: Date

    var id: String { word }
}

// MARK: - All of it

/// The whole of the finder's user data, as one value.
///
/// One value rather than three stores: it is written as one blob, read as one, and the
/// three parts share a lifetime. Dictionaries rather than arrays for ratings and uses,
/// because both are asked "what about this model" far more often than they are listed.
struct ModelUserData: Codable, Sendable, Equatable {

    private(set) var ratings: [String: ModelRating] = [:]
    private(set) var used: [String: UsedModel] = [:]
    private(set) var terms: [SearchTerm] = []

    private enum CodingKeys: String, CodingKey {
        case ratings, used, terms
    }

    /// How many remembered words are kept. The row shows only what fits on one line
    /// anyway, so a longer tail is memory the user will never see.
    static let maximumTerms = 60
    /// How many used models are kept. A use is a memory of membership, not a document:
    /// a model older than a thousand others has stopped being useful and is dropped,
    /// which also bounds what goes into the iCloud key-value store.
    static let maximumUsed = 1000

    // MARK: - Ratings

    func rating(for key: String) -> Int? { ratings[key]?.stars }

    /// Save a rating. `stars` is clamped to 1…5, so the UI cannot write a value the
    /// filter would not understand.
    mutating func rate(_ stars: Int, for key: String, at now: Date = Date()) {
        guard !key.isEmpty else { return }
        ratings[key] = ModelRating(stars: min(max(stars, 1), 5), ratedAt: now)
    }

    /// Forget a rating, which is what "not rated" means. Kept because "All (rated)"
    /// must be able to become false again.
    mutating func clearRating(for key: String) {
        ratings.removeValue(forKey: key)
    }

    // MARK: - Uses

    func isUsed(_ key: String) -> Bool { used[key] != nil }

    /// Note that these models have just been used, stamping each with `now`. Marking a
    /// model already in the list updates its last-used date rather than adding it twice.
    mutating func markUsed(_ keys: [String], at now: Date = Date()) {
        let distinct = Set(keys.filter { !$0.isEmpty })
        guard !distinct.isEmpty else { return }
        for key in distinct { used[key] = UsedModel(key: key, lastUsed: now) }
        trimUsed()
    }

    private mutating func trimUsed() {
        guard used.count > Self.maximumUsed else { return }
        let newest = used.values.sorted { $0.lastUsed > $1.lastUsed }
        used = Dictionary(uniqueKeysWithValues: newest.prefix(Self.maximumUsed).map { ($0.key, $0) })
    }

    // MARK: - Search history

    /// Remember the words of a settled search: a new word starts at one use, one
    /// already known is counted again and stamped with `now`.
    mutating func remember(_ words: [String], at now: Date = Date()) {
        guard !words.isEmpty else { return }
        for word in words {
            if let index = terms.firstIndex(where: { $0.word == word }) {
                terms[index].count += 1
                terms[index].lastUsed = now
            } else {
                terms.append(SearchTerm(word: word, count: 1, lastUsed: now))
            }
        }
        trimTerms()
    }

    private mutating func trimTerms() {
        guard terms.count > Self.maximumTerms else { return }
        terms = Array(rankedTerms().prefix(Self.maximumTerms))
    }

    /// The remembered words in the order the chip row shows them.
    ///
    /// Most recent first and most used second, which is the priority the brief asks
    /// for: a word from yesterday that has been used twice comes before one from last
    /// week that has been used fifty times. The word itself breaks a tie, so the row
    /// does not reshuffle between two draws of the same history.
    func rankedTerms() -> [SearchTerm] {
        terms.sorted { a, b in
            if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            if a.count != b.count { return a.count > b.count }
            return a.word < b.word
        }
    }
}

// MARK: - Reading a store that has moved on

/// An unrecognised value is a rating of nil rather than a decode failure, on the same
/// forward-compatibility argument `AssetKind` keeps: data written by a build that knows
/// more than this one must not cost the user everything they have rated. A store that
/// cannot be read at all starts empty, which is a finder that remembers nothing yet.
extension ModelUserData {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        ratings = (try? container.decode([String: ModelRating].self, forKey: .ratings)) ?? [:]
        used = (try? container.decode([String: UsedModel].self, forKey: .used)) ?? [:]
        terms = (try? container.decode([SearchTerm].self, forKey: .terms)) ?? []
        trimUsed()
        trimTerms()
    }
}
