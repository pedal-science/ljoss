import SwiftUI

// The settings shell.
//
// Settings is a mode of the window, not a sheet: the rig library's column becomes the
// list of settings areas and the rig editor's pane becomes the area that is selected.
// The machinery is `ContentView`'s; what lives here is what it swaps in.

/// One page of the app's settings.
///
/// The order is the order they are listed in, and the first one is what settings opens
/// on by default.
enum SettingsArea: String, CaseIterable, Identifiable, Hashable {
    case hardware
    case models
    case find

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hardware: "Hardware"
        case .models: "Models & IRs"
        case .find: "Find Models"
        }
    }

    var symbol: String {
        switch self {
        case .hardware: "cable.connector"
        case .models: "waveform"
        case .find: "magnifyingglass"
        }
    }

    var subtitle: String {
        switch self {
        case .hardware: "The device this app plays through"
        case .models: "The folders your captures are kept in"
        case .find: "Search the captures in those folders"
        }
    }
}

// MARK: - The list

/// The areas, where the rig library usually is.
struct SettingsAreasList: View {
    @Binding var selection: SettingsArea?
    /// True when the list is a stack's root rather than a column: a row then pushes its
    /// area instead of selecting it, which is the same list doing the one thing that
    /// makes sense without a detail pane.
    var pushes: Bool = false

    var body: some View {
        Group {
            if pushes {
                List { rows }
            } else {
                List(selection: $selection) { rows }
            }
        }
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var rows: some View {
        Section {
            ForEach(SettingsArea.allCases) { area in
                if pushes {
                    NavigationLink(value: area) { label(area) }
                } else {
                    label(area).tag(area)
                }
            }
        } header: {
            Text("Settings")
        }
    }

    private func label(_ area: SettingsArea) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(area.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(area.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: area.symbol)
                .frame(width: 26)
        }
        .frame(minHeight: Metrics.minTouchTarget)
        .contentShape(Rectangle())
    }
}

// MARK: - The detail

/// What replaces the rig editor.
struct SettingsDetailView: View {
    var area: SettingsArea

    var body: some View {
        Group {
            switch area {
            case .hardware: HardwareSettingsView()
            case .models: ModelsAndIRsSettingsView()
            case .find: ModelFinderView()
            }
        }
        .navigationTitle(area.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - The button

/// The button that opens settings and, once they are open, closes them again.
///
/// Attached inside each navigation container's content rather than to the shell, because
/// that is where a toolbar item is collected from — and attached in every place the app
/// shows a column, so the button never moves and is never missing.
struct SettingsToolbarItem: View {
    var isOpen: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text("Settings")
            } icon: {
                Image(systemName: isOpen ? "gearshape.fill" : "gearshape")
            }
        }
        .help(isOpen ? "Close settings" : "Settings")
        .accessibilityLabel(Text(isOpen ? "Close Settings" : "Settings"))
    }
}

extension View {
    /// Add the settings button to this container's toolbar.
    func settingsToolbarItem(isOpen: Bool, action: @escaping () -> Void) -> some View {
        toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsToolbarItem(isOpen: isOpen, action: action)
            }
        }
    }
}
