import Foundation

// Finding one model in a library of thousands.
//
// The matching is the part worth having in one place and asserting: it is a pure
// function of the entries, the query, the three filters and the user's own data, so
// every rule below is a sentence in `Tests/ModelFinderTests.swift` rather than
// something that has to be typed into the app to check.
//
// No SwiftUI here: this file is in the source list of `Tests/run-model-tests.sh`.

// MARK: - The three filters

/// 'All', 'Amp' or 'Amp + Cab'.
///
/// "Amp" is a model whose capture does not include a cabinet; "Amp + Cab" is one whose
/// `metadata.gear_type` names one. An impulse response is neither, so it is filtered
/// out by both — the two options are about NAM captures, which is what they say.
enum ModelTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case amp
    case ampCab

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All"
        case .amp: "Amp"
        case .ampCab: "Amp + Cab"
        }
    }
}

/// 'All', 'Yes' or 'No': whether the model has ever been used in a node.
enum ModelUsedFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case yes
    case no

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All"
        case .yes: "Yes"
        case .no: "No"
        }
    }
}

/// How 'My Rating' narrows the list.
///
/// The minimum is held beside the mode rather than inside it, because the star row and
/// the drop-down are two controls over one idea: choosing a star switches the mode to
/// `.minimum` and sets the number, and choosing `.minimum` in the drop-down uses
/// whichever number the stars already show.
enum ModelRatingMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case rated
    case minimum

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "No filtering"
        case .rated: "All (rated)"
        case .minimum: "Minimum (rated)"
        }
    }
}

/// The filter choices, as the view holds them.
struct ModelSearchFilters: Equatable, Sendable {
    var type: ModelTypeFilter = .all
    var used: ModelUsedFilter = .all
    var rating: ModelRatingMode = .none
    /// 1…5. Only read when `rating` is `.minimum`.
    var minimumStars: Int = 3
}

// MARK: - The search

enum ModelSearch {

    /// Split text into the words a search is made of.
    ///
    /// Punctuation, dashes and underscores are all separators, which is the same rule
    /// `MakeHeuristics` reads names by: `Ampeg-ABC_SVT123` is three words.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Everything about an entry a query is matched against, as words: what the file
    /// is called, where it sits, and what it said about itself.
    static func haystack(_ entry: AssetEntry) -> [String] {
        var fields = [entry.name, entry.fileName, entry.fileStem, entry.relative,
                      entry.directory, entry.make]
        if let model = entry.model { fields.append(model) }
        if let architecture = entry.architecture { fields.append(architecture) }
        if let gearType = entry.gearType { fields.append(gearType) }
        return fields.flatMap(words)
    }

    /// Whether every query word is found in the entry, as a whole word or part of one.
    ///
    /// A word matches when *some* word of the entry contains it, which is what makes
    /// `SVT` find `SVT123`. Every word must match — `ampeg svt` is the entry that has
    /// both, not everything that has either.
    static func matches(_ entry: AssetEntry, words query: [String]) -> Bool {
        guard !query.isEmpty else { return true }
        let tokens = haystack(entry)
        return query.allSatisfy { word in tokens.contains { $0.contains(word) } }
    }

    // MARK: Filters

    static func matchesType(_ entry: AssetEntry, _ filter: ModelTypeFilter) -> Bool {
        switch filter {
        case .all: true
        case .amp: entry.isModel && !entry.includesCab
        case .ampCab: entry.isModel && entry.includesCab
        }
    }

    static func matchesUse(_ entry: AssetEntry, _ filter: ModelUsedFilter,
                           userData: ModelUserData) -> Bool {
        switch filter {
        case .all: true
        case .yes: userData.isUsed(entry.userKey)
        case .no: !userData.isUsed(entry.userKey)
        }
    }

    /// 'All (rated)' is models the user has explicitly saved a rating for — a model
    /// never rated is not a model rated zero. 'Minimum (rated)' is the same set with
    /// the number applied.
    static func matchesRating(_ entry: AssetEntry, _ filters: ModelSearchFilters,
                              userData: ModelUserData) -> Bool {
        switch filters.rating {
        case .none:
            return true
        case .rated:
            return userData.rating(for: entry.userKey) != nil
        case .minimum:
            return (userData.rating(for: entry.userKey) ?? 0) >= filters.minimumStars
        }
    }

    // MARK: Everything at once

    static func results(_ entries: [AssetEntry],
                        words query: [String],
                        filters: ModelSearchFilters = ModelSearchFilters(),
                        userData: ModelUserData = ModelUserData()) -> [AssetEntry] {
        entries.filter { entry in
            matches(entry, words: query)
                && matchesType(entry, filters.type)
                && matchesUse(entry, filters.used, userData: userData)
                && matchesRating(entry, filters, userData: userData)
        }
    }

    /// The same, for a query that has just been typed.
    static func results(_ entries: [AssetEntry],
                        query: String,
                        filters: ModelSearchFilters = ModelSearchFilters(),
                        userData: ModelUserData = ModelUserData()) -> [AssetEntry] {
        results(entries, words: words(query), filters: filters, userData: userData)
    }

    /// Add a remembered word to what is already in the box.
    ///
    /// Word-wise, so tapping `SVT` when the box says `Ampeg svt` changes nothing. The
    /// remembered word is used as it was stored — lowercased — because that is what the
    /// chip shows and a search does not care about case.
    static func adding(_ word: String, to query: String) -> String {
        let normalized = word.lowercased()
        guard !words(query).contains(normalized) else { return query }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? normalized : "\(trimmed) \(normalized)"
    }
}
