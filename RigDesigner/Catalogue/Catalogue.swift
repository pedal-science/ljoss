import Foundation

/// A component the user can drag into a chain.
struct ComponentSpec: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var subtitle: String
    var category: ComponentCategory
    var sources: Set<SourceKind>
    var symbol: String
    var params: [ParamSpec]

    init(
        _ id: String,
        _ name: String,
        _ subtitle: String,
        _ category: ComponentCategory,
        _ sources: [SourceKind],
        _ symbol: String,
        _ params: [ParamSpec]
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.category = category
        self.sources = Set(sources)
        self.symbol = symbol
        self.params = params
    }

    func suits(_ source: SourceKind) -> Bool { sources.contains(source) }
}

enum ComponentCategory: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case amp, cab, drive, dynamics, eq, modulation, delay, reverb, pitch, filter, vocal, utility
    var id: String { rawValue }

    /// Lives here rather than with the design tokens because `Catalogue.search`
    /// matches on it: a name the catalogue itself reads belongs at the catalogue's
    /// layer, not above it. The colour and the symbol stay in `DesignSystem`.
    var displayName: String {
        switch self {
        case .amp: "Amp"
        case .cab: "Cab / IR"
        case .drive: "Drive"
        case .dynamics: "Dynamics"
        case .eq: "EQ"
        case .modulation: "Modulation"
        case .delay: "Delay"
        case .reverb: "Reverb"
        case .pitch: "Pitch"
        case .filter: "Filter"
        case .vocal: "Vocal"
        case .utility: "Utility"
        }
    }
}

/// The static library of components, plus the specs for the fixed endpoints.
enum Catalogue {

    private static let index: [String: ComponentSpec] = Dictionary(
        allComponents.map { ($0.id, $0) },
        uniquingKeysWith: { a, _ in a }
    )

    static func component(_ id: String) -> ComponentSpec? { index[id] }

    /// A stand-in for a component id this build does not know, so a rig saved by
    /// a newer version still opens and shows the user what is missing rather
    /// than refusing to load.
    static func placeholder(for id: String) -> ComponentSpec {
        ComponentSpec(id, "Unknown Block", id, .utility, SourceKind.allCases.map { $0 }, "questionmark.square.dashed", [])
    }

    static func resolve(_ id: String) -> ComponentSpec { index[id] ?? placeholder(for: id) }

    static func components(for source: SourceKind, category: ComponentCategory? = nil) -> [ComponentSpec] {
        allComponents.filter { spec in
            spec.suits(source) && (category == nil || spec.category == category)
        }
    }

    static func search(_ query: String, source: SourceKind) -> [ComponentSpec] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return components(for: source) }
        return components(for: source).filter {
            $0.name.lowercased().contains(q)
                || $0.subtitle.lowercased().contains(q)
                || $0.category.displayName.lowercased().contains(q)
        }
    }

    /// Categories that actually contain something for this source, so the
    /// palette never shows an empty tab.
    static func categories(for source: SourceKind) -> [ComponentCategory] {
        ComponentCategory.allCases.filter { cat in
            allComponents.contains { $0.category == cat && $0.suits(source) }
        }
    }

    // MARK: - Fixed endpoints

    static func inputParams(for source: SourceKind) -> [ParamSpec] {
        switch source {
        case .vocal:
            [
                .pick("source", "Source", ["Mic", "Line", "USB", "Aux"], "Mic"),
                .range("gain", "Gain", 30, 0, 60, unit: "dB"),
                .toggle("phantom", "48V Phantom", true),
                .toggle("pad", "-20 dB Pad", false),
                .range("lowcut", "Low Cut", 80, 20, 300, unit: "Hz"),
            ]
        case .guitar, .bass:
            [
                .pick("source", "Source", ["Instrument", "Line", "USB", "Aux"], "Instrument"),
                .range("gain", "Gain", 0, -12, 24, unit: "dB"),
                .pick("impedance", "Impedance", ["Auto", "1 MΩ", "230 kΩ", "32 kΩ"], "Auto"),
                .toggle("pad", "-10 dB Pad", false),
            ]
        }
    }

    static let outputParams: [ParamSpec] = [
        .pick("destination", "Destination", ["Main L/R", "Amp Out", "Headphones", "USB", "Send 1/2"], "Main L/R"),
        .range("level", "Level", 0, -60, 12, unit: "dB"),
        .range("pan", "Pan", 0, -100, 100, unit: "%"),
        .toggle("mono", "Sum to Mono", false),
    ]

    // MARK: - Split and merge

    static func splitParams(for mode: SplitMode) -> [ParamSpec] {
        var base: [ParamSpec] = [
            .pick("mode", "Split Mode", SplitMode.allCases.map(\.displayName), mode.displayName)
        ]
        switch mode {
        case .crossover:
            base.append(.range("crossover", "Crossover", 800, 60, 8000, unit: "Hz"))
        case .aB, .dynamic:
            base.append(.range("balance", "Balance", 0, -100, 100, unit: "%"))
        case .yCable:
            break
        }
        return base
    }

    static let laneParams: [ParamSpec] = [
        .range("level", "Level", 0, -60, 12, unit: "dB"),
        .range("pan", "Pan", 0, -100, 100, unit: "%"),
        .toggle("mute", "Mute", false),
        .toggle("phase", "Invert Phase", false),
    ]
}
