import SwiftUI

/// Find a model fast.
///
/// This is the same listing Settings → Models & IRs shows — `AssetEntry` rows out of
/// `AssetLibrary`, grouped the same way — with the finding machinery in front of it: a
/// search box that matches as you type, the words searched before, and three filters.
///
/// It is also the **model picker** for a node that runs a NAM capture. Hand it an
/// `onPick` and its rows choose a model instead of doing nothing; that is the whole
/// difference between the settings page and the picker, so the two can never drift.
struct ModelFinderView: View {
    @Environment(AssetLibrary.self) private var assets
    @Environment(ModelUserDataStore.self) private var userData
    @Environment(\.dismiss) private var dismiss

    /// The model already chosen for the node being edited, if any, so the list can mark
    /// it. Matching is on the library id, case-insensitively.
    var selectedKey: String?
    /// Called when a row is chosen. Nil when the view is the browse-only settings page.
    var onPick: ((AssetEntry) -> Void)?

    @State private var query = ""
    /// The words of the last *settled* search. Typing changes `query`; only the debounce
    /// moves this, which is what stops a search running once per keystroke.
    @State private var settled: [String] = []
    @State private var filters = ModelSearchFilters()

    /// How long typing has to stop before a search is run and remembered. Short enough
    /// to feel like it is tracking the keyboard, long enough that a word is one search
    /// rather than eight.
    private static let debounce = Duration.milliseconds(300)

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            results
        }
        // `.task(id:)` cancels the previous task when the id changes, and `Task.sleep`
        // throws on cancellation: a debounce built out of the two, with no timer and no
        // Combine pipeline to keep in step.
        .task(id: query) { await settle() }
    }

    // MARK: - The controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchBox
            historyChips
            filterRows
            ScanStatusRow(state: assets.state, progress: assets.progress,
                          unavailableFolders: assets.issues.count)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var searchBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search models and impulse responses", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .submitLabel(.search)
                // Return searches at once rather than waiting out the debounce.
                .onSubmit { settleNow() }
                .accessibilityLabel(Text("Search"))

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear the search")
                .accessibilityLabel(Text("Clear Search"))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Metrics.minTouchTarget)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    /// The words searched before, as blocks to touch. One line, and only as many as fit
    /// on it: `OneLineFit` stops placing when the next one would run off the edge.
    @ViewBuilder
    private var historyChips: some View {
        let terms = userData.terms
        if !terms.isEmpty {
            OneLineFit(spacing: 8) {
                ForEach(terms) { term in
                    Button {
                        query = ModelSearch.adding(term.word, to: query)
                    } label: {
                        Text(term.word)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: Metrics.minTouchTarget)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Add “\(term.word)” to the search")
                }
            }
            .frame(height: Metrics.minTouchTarget)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Previous searches"))
        }
    }

    private var filterRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                filterLabel("Type")
                Picker("Type", selection: $filters.type) {
                    ForEach(ModelTypeFilter.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(minHeight: Metrics.minTouchTarget)

            HStack(spacing: 12) {
                filterLabel("Previously Used")
                Picker("Previously Used", selection: $filters.used) {
                    ForEach(ModelUsedFilter.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .frame(minHeight: Metrics.minTouchTarget)

            // The drop-down and the stars are two controls over one choice. The stars
            // need more width than a narrow window has, so the stacked variant is the
            // fallback rather than a truncation.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterLabel("My Rating")
                    ratingModePicker
                    Spacer(minLength: 8)
                    ratingStars
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        filterLabel("My Rating")
                        ratingModePicker
                        Spacer(minLength: 0)
                    }
                    ratingStars
                }
            }
            .frame(minHeight: Metrics.minTouchTarget)
        }
    }

    private func filterLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 108, alignment: .leading)
    }

    private var ratingModePicker: some View {
        Picker("My Rating", selection: $filters.rating) {
            ForEach(ModelRatingMode.allCases) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
    }

    /// Choosing a star is choosing a minimum, so it switches the drop-down to
    /// 'Minimum (rated)' if it was on something else.
    private var ratingStars: some View {
        StarSelector(filled: filters.rating == .minimum ? filters.minimumStars : 0) { stars in
            filters.minimumStars = stars
            filters.rating = .minimum
        }
        .accessibilityLabel(Text("Minimum rating"))
    }

    // MARK: - The search

    private func settle() async {
        try? await Task.sleep(for: Self.debounce)
        guard !Task.isCancelled else { return }
        settleNow()
    }

    /// Run and remember the search the box now holds. A settle that changes nothing —
    /// Return after the debounce already ran — is not a search and is not counted.
    private func settleNow() {
        let words = ModelSearch.words(query)
        guard words != settled else { return }
        settled = words
        userData.remember(words)
    }

    // MARK: - The results

    private var filtered: [AssetEntry] {
        ModelSearch.results(assets.entries, words: settled, filters: filters, userData: userData.data)
    }

    private var sections: [AssetSection] {
        AssetOrdering.sections(filtered, rootLabels: assets.rootLabels, grouping: .standard)
    }

    @ViewBuilder
    private var results: some View {
        if assets.roots.isEmpty {
            ContentUnavailableView(
                "No Folders Yet",
                systemImage: "folder",
                description: Text("Add the folders that hold your .nam models and impulse responses in Settings → Models & IRs.")
            )
        } else if assets.entries.isEmpty, !assets.state.isScanning {
            ContentUnavailableView(
                "No Models Found",
                systemImage: "waveform.slash",
                description: Text("Nothing was found in these folders. Add another folder, or rescan from Settings → Models & IRs.")
            )
        } else if filtered.isEmpty, !assets.state.isScanning {
            ContentUnavailableView {
                Label("Nothing Matches", systemImage: "magnifyingglass")
            } description: {
                Text(nothingMatches)
            }
        } else {
            List {
                ForEach(sections) { section in
                    if let title = section.title {
                        Section(title) { rows(section) }
                    } else {
                        Section { rows(section) }
                    }
                }
            }
            // The list can change under the pointer while a scan publishes, so — like
            // the settings page — it is not interactive until the scan is done. The
            // search box and the filters above stay live.
            .disabled(assets.state.isScanning)
            .opacity(assets.state.isScanning ? 0.5 : 1)
        }
    }

    private var nothingMatches: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No model or impulse response matches these filters."
            : "No model or impulse response matches “\(query)” with these filters."
    }

    private func rows(_ section: AssetSection) -> some View {
        ForEach(section.entries) { entry in
            row(entry)
        }
    }

    @ViewBuilder
    private func row(_ entry: AssetEntry) -> some View {
        let content = AssetRow(entry: entry, rating: rating(for: entry))
        if let onPick {
            content
                .contentShape(Rectangle())
                .onTapGesture { choose(entry, with: onPick) }
                .listRowBackground(isChosen(entry) ? Color.accentColor.opacity(0.15) : nil)
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }

    private func rating(for entry: AssetEntry) -> Binding<Int?> {
        Binding(
            get: { userData.rating(for: entry) },
            set: { stars in
                if let stars { userData.rate(stars, for: entry) }
                else { userData.clearRating(for: entry) }
            }
        )
    }

    private func isChosen(_ entry: AssetEntry) -> Bool {
        guard let selectedKey else { return false }
        return entry.userKey == selectedKey.lowercased()
    }

    /// Choosing a model is closing the picker: the value is set by `onPick`, and the
    /// page that pushed this one is what the user should be looking at again.
    private func choose(_ entry: AssetEntry, with pick: (AssetEntry) -> Void) {
        pick(entry)
        dismiss()
    }
}

// MARK: - One line, as much as fits

/// Lay views out in a single row, placing only the ones that fit.
///
/// The chip row asks for "as many words as fill the line", which is not something a
/// scroll view or a wrapping stack does: a scroll view hides the overflow off-screen
/// and a wrapping stack moves it to a second line. This measures each subview and stops
/// at the container's edge; whatever is left over is simply never placed, so it is
/// never drawn.
struct OneLineFit: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var height: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > width { break }
            x += (x > 0 ? spacing : 0) + size.width
            height = max(height, size.height)
        }
        return CGSize(width: min(x, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + size.width > bounds.maxX { break }
            if x > bounds.minX { x += spacing }
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width
        }
    }
}

// MARK: - Stars

/// A row of five stars that fills from the left, like the usual rating control.
///
/// One control for both jobs the finder has for stars: the minimum 'My Rating' filters
/// by, and the rating a model is given in the list. `hit` is separate from `size`
/// because the filter row has space for a fingertip-sized target and a list row does
/// not.
struct StarSelector: View {
    var filled: Int
    var size: CGFloat = 20
    var hit: CGFloat = 44
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onSelect(star)
                } label: {
                    Image(systemName: star <= filled ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(star <= filled ? Color.yellow : Color.secondary.opacity(0.5))
                        .frame(width: hit, height: hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(star == 1 ? "1 star" : "\(star) stars")
                .accessibilityLabel(Text("\(star) star\(star == 1 ? "" : "s")"))
                .accessibilityAddTraits(star <= filled ? [.isSelected] : [])
            }
        }
    }
}
