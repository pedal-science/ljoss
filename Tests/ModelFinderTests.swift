import Foundation

// Assertions for the finder: what a query matches, how the remembered words are ranked
// and added, what a rating means, and which models count as used.
//
// The matching rules are the load-bearing part. "ampeg svt" finding "Ampeg ABC SVT123"
// is a claim about words, and one that silently stops being true still looks like a
// working search — which is exactly the kind of bug this file exists to catch.

// MARK: - Building entries

private func stem(of relative: String) -> String {
    let name = relative.split(separator: "/").last.map(String.init) ?? relative
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
    return String(name[..<dot])
}

private func found(_ relative: String,
                   name: String? = nil,
                   make: String = MakeHeuristics.unknown,
                   model: String? = nil,
                   gearType: String? = nil,
                   kind: AssetKind = .model) -> AssetEntry {
    AssetEntry(
        rootID: UUID(),
        relative: relative,
        kind: kind,
        name: name ?? stem(of: relative),
        make: make,
        model: model,
        architecture: kind == .model ? "WaveNet" : "Linear",
        gearType: gearType,
        sampleRate: nil,
        channels: nil,
        frames: nil,
        size: 1024,
        modified: Date(timeIntervalSince1970: 0),
        addedAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Matching

func testModelFinderMatching() {
    print("matching a search against the library")

    let entries = [
        found("Ampeg ABC SVT123.nam", make: "Ampeg"),
        found("Fender Deluxe Reverb.nam", make: "Fender", model: "Deluxe Reverb"),
        found("fndr-twin.nam", make: "Fender"),
        found("Orange PPC112.wav", name: "PPC112", make: "Orange", kind: .ir),
    ]

    func hits(_ query: String) -> [String] {
        ModelSearch.results(entries, query: query).map(\.relative)
    }

    check(hits("ampeg svt") == ["Ampeg ABC SVT123.nam"],
          "every word must match, and SVT is found inside SVT123")
    check(hits("SVT") == ["Ampeg ABC SVT123.nam"], "case does not matter")
    check(hits("svt123") == ["Ampeg ABC SVT123.nam"], "a whole word matches too")
    check(hits("ampeg fender") == [], "words from two different entries match neither")
    check(hits("reverb") == ["Fender Deluxe Reverb.nam"],
          "metadata is searched as well as the file's name")
    check(hits("fndr") == ["fndr-twin.nam"], "a word is found inside a dash-separated name")
    check(hits("orange") == ["Orange PPC112.wav"], "the make a row shows is searched")
    check(hits("") == entries.map(\.relative), "an empty search matches everything")
    check(hits("   ") == entries.map(\.relative), "so does one that is only spaces")
    check(hits("zzz") == [], "and a search nothing matches is empty rather than everything")
}

// MARK: - Filters

func testModelFinderFilters() {
    print("narrowing the library with the three filters")

    let amp = found("Ampeg SVT.nam", gearType: "amp")
    let ampCab = found("Fender Twin.nam", gearType: "amp_cab")
    let pedalCab = found("Boss Combo.nam", gearType: "amp_pedal_cab")
    let silent = found("Mystery.nam")
    let ir = found("V30.wav", kind: .ir)
    let all = [amp, ampCab, pedalCab, silent, ir]

    func listed(_ filters: ModelSearchFilters, _ data: ModelUserData = ModelUserData()) -> [String] {
        ModelSearch.results(all, query: "", filters: filters, userData: data).map(\.relative)
    }

    check(listed(ModelSearchFilters(type: .all)) == all.map(\.relative),
          "All is every model and every impulse response")
    check(listed(ModelSearchFilters(type: .amp)) == ["Ampeg SVT.nam", "Mystery.nam"],
          "Amp is a model that did not declare a cabinet — including one that said nothing")
    check(listed(ModelSearchFilters(type: .ampCab)) == ["Fender Twin.nam", "Boss Combo.nam"],
          "Amp + Cab is the gear types that name one, and no impulse response")

    var data = ModelUserData()
    check(listed(ModelSearchFilters(used: .yes), data).isEmpty, "nothing has been used yet")
    check(listed(ModelSearchFilters(used: .no), data).count == all.count, "so No is everything")
    data.markUsed([amp.userKey, ir.userKey])
    check(listed(ModelSearchFilters(used: .yes), data) == ["Ampeg SVT.nam", "V30.wav"],
          "Yes is what has been used")
    check(listed(ModelSearchFilters(used: .no), data) == ["Fender Twin.nam", "Boss Combo.nam", "Mystery.nam"],
          "No is the rest")

    check(listed(ModelSearchFilters(rating: .rated), data).isEmpty,
          "a model nobody rated is not in All (rated)")
    data.rate(4, for: amp.userKey)
    data.rate(2, for: ampCab.userKey)
    check(listed(ModelSearchFilters(rating: .rated), data) == ["Ampeg SVT.nam", "Fender Twin.nam"],
          "All (rated) is what the user has explicitly saved a rating for")
    check(listed(ModelSearchFilters(rating: .minimum, minimumStars: 3), data) == ["Ampeg SVT.nam"],
          "Minimum (rated) applies the number")
    check(listed(ModelSearchFilters(rating: .minimum, minimumStars: 1), data)
            == ["Ampeg SVT.nam", "Fender Twin.nam"],
          "…and a minimum of one is every rated model")
    data.clearRating(for: amp.userKey)
    check(listed(ModelSearchFilters(rating: .minimum, minimumStars: 3), data).isEmpty,
          "taking a rating back takes the model out of the filter")

    check(listed(ModelSearchFilters(type: .ampCab, used: .no, rating: .minimum, minimumStars: 1), data)
            == ["Fender Twin.nam"],
          "the filters compose")
    check(ModelSearch.results(all, query: "v30", filters: ModelSearchFilters(type: .ampCab)).isEmpty,
          "a search and a filter that cannot both be true is empty, not an error")
}

// MARK: - History

func testModelFinderHistory() {
    print("remembering and ranking searched words")

    let t0 = Date(timeIntervalSince1970: 1_000)

    var repeated = ModelUserData()
    repeated.remember(["ampeg", "svt"], at: t0)
    repeated.remember(["svt"], at: t0.addingTimeInterval(60))
    check(repeated.rankedTerms().map(\.word) == ["svt", "ampeg"],
          "the word searched most recently is first")
    check(repeated.rankedTerms().first?.count == 2, "a word searched again is counted again")

    var recentBeatsUsed = ModelUserData()
    recentBeatsUsed.remember(["old", "old", "old"], at: t0)
    recentBeatsUsed.remember(["new"], at: t0.addingTimeInterval(10))
    check(recentBeatsUsed.rankedTerms().map(\.word) == ["new", "old"],
          "recency has priority over the number of uses")

    var usedBreaksTie = ModelUserData()
    usedBreaksTie.remember(["b"], at: t0)
    usedBreaksTie.remember(["a"], at: t0)
    usedBreaksTie.remember(["b"], at: t0)
    check(usedBreaksTie.rankedTerms().map(\.word) == ["b", "a"],
          "with the same date, the more-used word is first")

    var stable = ModelUserData()
    stable.remember(["c", "b", "a"], at: t0)
    check(stable.rankedTerms().map(\.word) == ["a", "b", "c"],
          "a tie on both falls back to the word, so the row never reshuffles")

    check(ModelSearch.adding("SVT", to: "Ampeg svt") == "Ampeg svt",
          "a word the box already contains is not added again")
    check(ModelSearch.adding("fender", to: "Ampeg svt") == "Ampeg svt fender",
          "a new word is appended")
    check(ModelSearch.adding("fender", to: "") == "fender",
          "and it is the whole query when the box is empty")
    check(ModelSearch.adding("fender", to: "   ") == "fender",
          "…even when the box holds nothing but spaces")
}

// MARK: - Ratings and the store

func testModelUserData() {
    print("saving what the user has said about a model")

    var data = ModelUserData()
    check(data.rating(for: "a") == nil, "a model starts unrated")
    data.rate(4, for: "a", at: Date(timeIntervalSince1970: 5))
    check(data.rating(for: "a") == 4, "a rating is saved")
    data.rate(9, for: "a")
    check(data.rating(for: "a") == 5, "a rating above five is clamped, not stored")
    data.rate(0, for: "b")
    check(data.rating(for: "b") == 1, "a rating below one is clamped too")
    data.clearRating(for: "a")
    check(data.rating(for: "a") == nil, "a rating can be taken back")

    var original = ModelUserData()
    original.rate(3, for: "x", at: Date(timeIntervalSince1970: 1))
    original.markUsed(["x", "y"], at: Date(timeIntervalSince1970: 2))
    original.remember(["amp"], at: Date(timeIntervalSince1970: 3))
    let encoded = try! JSONEncoder().encode(original)
    let decoded = try! JSONDecoder().decode(ModelUserData.self, from: encoded)
    check(decoded == original, "the whole of it survives a round trip")

    // A store written by a build that knows more than this one must not cost the user
    // what this one does understand.
    let future = Data(#"{"ratings":{"z":{"stars":5,"ratedAt":0}},"somethingNew":true}"#.utf8)
    let salvaged = try! JSONDecoder().decode(ModelUserData.self, from: future)
    check(salvaged.rating(for: "z") == 5, "a field a later build added does not cost the ratings")
    check(salvaged.used.isEmpty, "the parts that were absent are empty rather than a failure")
}

// MARK: - Uses

func testModelUsage() {
    print("which models a rig is using")

    guard let ampID = BlockMappings.mappedIDs.first(where: {
        BlockMappings.mapping(for: $0)?.requiredAssets.contains(.model) == true
    }) else {
        check(false, "the catalogue has a block that runs a model")
        return
    }

    var block = Block(componentID: ampID)
    check(ModelUsage.pickedModel(in: block) == nil,
          "a node with no model picked has not used one")
    block.values[AssetKind.model.valueKey] = .option("Ampeg/SVT-123")
    check(ModelUsage.pickedModel(in: block) == "ampeg/svt-123",
          "the picked id is normalized the way user data is keyed")

    let rig = makeRig([.block(block)])
    check(ModelUsage.pickedModels(in: rig) == ["ampeg/svt-123"], "and it is found in the rig")

    var data = ModelUserData()
    let first = Date(timeIntervalSince1970: 10)
    data.markUsed(ModelUsage.pickedModels(in: rig), at: first)
    check(data.isUsed("ampeg/svt-123"), "a model that has been used is remembered")

    let second = first.addingTimeInterval(60)
    data.markUsed(["ampeg/svt-123"], at: second)
    check(data.used.count == 1, "using it again does not add it twice")
    check(data.used["ampeg/svt-123"]?.lastUsed == second, "…it moves its last-used date")
}
