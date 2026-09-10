import Foundation

// MARK: - Sources

/// The kind of instrument or voice a chain (or a component) is intended for.
enum SourceKind: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case guitar, bass, vocal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .guitar: "Guitar"
        case .bass: "Bass"
        case .vocal: "Vocal"
        }
    }

    var symbol: String {
        switch self {
        case .guitar: "guitars"
        case .bass: "guitars"
        case .vocal: "music.mic"
        }
    }
}

// MARK: - Parameters

/// A single stored parameter value. Codable synthesis handles the associated values.
enum ParamValue: Codable, Hashable, Sendable {
    case number(Double)
    case option(String)
    case flag(Bool)

    var doubleValue: Double? { if case .number(let d) = self { d } else { nil } }
    var optionValue: String? { if case .option(let s) = self { s } else { nil } }
    var boolValue: Bool? { if case .flag(let b) = self { b } else { nil } }
}

/// The shape of a parameter, declared by the catalogue rather than stored per instance.
enum ParamKind: Codable, Hashable, Sendable {
    case continuous(min: Double, max: Double)
    case stepped(min: Double, max: Double, step: Double)
    case options([String])
    case toggle
}

/// A catalogue-level declaration of one knob/switch on a component.
struct ParamSpec: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var kind: ParamKind
    var defaultValue: ParamValue
    var unit: String?

    init(_ id: String, _ name: String, _ kind: ParamKind, _ defaultValue: ParamValue, unit: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
        self.unit = unit
    }

    /// Convenience for the overwhelmingly common 0–10 style continuous control.
    static func knob(_ id: String, _ name: String, _ def: Double = 5, min: Double = 0, max: Double = 10, unit: String? = nil) -> ParamSpec {
        ParamSpec(id, name, .continuous(min: min, max: max), .number(def), unit: unit)
    }

    static func range(_ id: String, _ name: String, _ def: Double, _ min: Double, _ max: Double, unit: String? = nil) -> ParamSpec {
        ParamSpec(id, name, .continuous(min: min, max: max), .number(def), unit: unit)
    }

    static func pick(_ id: String, _ name: String, _ options: [String], _ def: String) -> ParamSpec {
        ParamSpec(id, name, .options(options), .option(def))
    }

    static func toggle(_ id: String, _ name: String, _ def: Bool = false) -> ParamSpec {
        ParamSpec(id, name, .toggle, .flag(def))
    }
}
