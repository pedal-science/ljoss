import SwiftUI

/// The drawer of components the user drags into a chain.
///
/// It deliberately lives in the same pane as the canvas: the drag is a custom
/// gesture tracked in the global coordinate space, and keeping both under one
/// root means dragging from tray to canvas is the same code path as reordering.
struct PaletteTray: View {
    @Environment(RigEditor.self) private var editor
    @Binding var source: SourceKind
    @State private var category: ComponentCategory?
    @State private var query: String = ""

    private var availableSources: [SourceKind] {
        var seen: [SourceKind] = []
        for chain in editor.rig.activeChains where !seen.contains(chain.source) {
            seen.append(chain.source)
        }
        return seen
    }

    private var results: [ComponentSpec] {
        let base = query.isEmpty
            ? Catalogue.components(for: source, category: category)
            : Catalogue.search(query, source: source)
        return base
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            categoryRow

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(results) { spec in
                        PaletteItem(spec: spec)
                    }
                    if results.isEmpty {
                        Text("No components match.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .dragSurface(.palette)
            }
            .scrollDisabled(editor.drag.isActive)
            .scrollIndicators(.hidden)
        }
        .padding(.top, 10)
        .background(.bar)
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("Components")
                .font(.headline)

            if availableSources.count > 1 {
                Picker("Source", selection: $source) {
                    ForEach(availableSources) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 110, maxWidth: 200)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 16)
    }

    private var categoryRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                CategoryChip(title: "All", symbol: "square.grid.2x2",
                             tint: .accentColor, isOn: category == nil) {
                    category = nil
                }
                ForEach(Catalogue.categories(for: source)) { cat in
                    CategoryChip(title: cat.displayName, symbol: cat.symbol,
                                 tint: cat.accent, isOn: category == cat) {
                        category = (category == cat) ? nil : cat
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }
}

struct CategoryChip: View {
    let title: String
    let symbol: String
    let tint: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(isOn ? tint.opacity(0.28) : Color.secondary.opacity(0.14), in: Capsule())
            .overlay {
                Capsule().strokeBorder(isOn ? tint : .clear, lineWidth: 2)
            }
            .foregroundStyle(isOn ? tint : Color.primary)
        }
        .buttonStyle(.plain)
        // Comfortably past the 44pt minimum.
        .frame(minHeight: Metrics.minTouchTarget)
    }
}

/// A single draggable component in the tray.
struct PaletteItem: View {
    let spec: ComponentSpec
    @Environment(RigEditor.self) private var editor
    @Environment(EngineSession.self) private var session: EngineSession?

    /// False while offline: the palette shows every block until a device says
    /// otherwise, because designing without one is the normal case.
    private var isUnplayable: Bool { session?.canPlay(spec.id) == false }

    var body: some View {
        let generation = editor.layoutGeneration

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: spec.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(spec.category.accent)
                Spacer(minLength: 0)
                if isUnplayable {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Text(spec.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(spec.category.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: Metrics.paletteItemWidth, height: Metrics.paletteItemHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(spec.category.accent.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(spec.category.accent.opacity(0.35), lineWidth: 1.5)
        }
        .opacity(isUnplayable ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .reportGlobalFrame(generation: generation) { editor.registry.setPaletteItem(spec.id, rect: $0) }
        .onDisappear { editor.registry.removePaletteItem(spec.id) }
        .onTapGesture {
            // Tapping is the no-drag route: append to the end of the matching chain.
            if let chain = editor.rig.activeChains.first(where: { $0.source == spec.category.preferredSource(for: spec) })
                ?? editor.rig.activeChains.first {
                editor.append(componentID: spec.id, toChain: chain.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(spec.name))
        .accessibilityHint(Text(isUnplayable
                                ? "Not available on the connected device. Double tap to add anyway, or drag onto the chain"
                                : "Double tap to add to the end of the chain, or drag onto the chain"))
    }
}

private extension ComponentCategory {
    /// Best-guess chain for a tapped component when a rig has more than one.
    func preferredSource(for spec: ComponentSpec) -> SourceKind {
        if spec.sources.contains(.guitar) { return .guitar }
        if spec.sources.contains(.bass) { return .bass }
        return .vocal
    }
}
