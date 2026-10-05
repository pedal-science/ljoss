import SwiftUI

struct RigEditorView: View {
    @State private var editor: RigEditor
    @State private var paletteSource: SourceKind
    @State private var showingInspector = false
    /// A viewing preference, not part of the rig: on by default, remembered
    /// across launches, and the same for every rig.
    @AppStorage("wrapsChains") private var wrapsChains = true

    private let library: RigLibrary
    /// Settings is the window's mode, not this view's, so the button that opens them is
    /// handed in — and the device control, which used to open a popover of its own, now
    /// goes to the same page.
    private let openSettings: () -> Void

    init(rig: Rig, library: RigLibrary, engine: EngineSession, openSettings: @escaping () -> Void = {}) {
        self.library = library
        self.openSettings = openSettings
        _editor = State(initialValue: RigEditor(rig: rig, library: library, engine: engine))
        _paletteSource = State(initialValue: rig.chains.first?.source ?? .guitar)
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var trayHeight: CGFloat {
        sizeClass == .compact ? Metrics.trayHeightCompact : Metrics.trayHeightRegular
    }
    #else
    private var trayHeight: CGFloat { Metrics.trayHeightRegular }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            canvas
            Divider()
            PaletteTray(source: $paletteSource)
                .frame(height: trayHeight)
        }
        .overlay(alignment: .bottom) {
            TrashZone()
                .padding(.bottom, trayHeight + 20)
        }
        .overlay { DragGhostLayer() }
        .environment(editor)
        .onAppear { editor.didAppear() }
        .navigationTitle(editor.rig.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingInspector) {
            InspectorSheet()
                .environment(editor)
        }
        .onChange(of: editor.selection) { _, new in
            showingInspector = new != nil
        }
        .onChange(of: showingInspector) { _, shown in
            if !shown { editor.selection = nil }
        }
        // A tick as the gap jumps to a new slot, and a thump on pick-up.
        .sensoryFeedback(.selection, trigger: editor.drag.targetChangeCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: editor.drag.isActive) { _, now in now }
    }

    private var canvas: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(editor.rig.activeChains) { chain in
                    ChainRowView(chain: chain, wraps: wrapsChains)
                }

                if editor.rig.activeChains.allSatisfy({ $0.elements.isEmpty }) {
                    hint
                }
            }
            .padding(.vertical, 16)
        }
        // The meters read one shared set of level readings, decayed for display: see
        // LevelMeters. Applied here rather than per tile, so a rig of forty blocks costs the
        // same one poll per 50 ms as a rig of one.
        .meterReadings()
        .scrollDisabled(editor.drag.isActive)
        // Wrapped chains can outgrow the screen vertically, so the canvas
        // auto-scrolls too. Not past its bottom edge, though: below it is the
        // palette tray, and a pointer there has not asked for anything.
        .dragAutoScroll(.vertical, scrollsPastTrailingEdge: false)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hint: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Press and hold a component below, then drag it onto the chain. Tap one to add it to the end.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            EngineStatusControl(openSettings: openSettings)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $wrapsChains) {
                Label {
                    Text("Wrap")
                } icon: {
                    WrapToggleIcon(wraps: wrapsChains)
                }
            }
            .toggleStyle(.button)
            .help(wrapsChains
                  ? "Wrap on: chains continue on the next row"
                  : "Wrap off: chains stay on one row and scroll")
            .accessibilityLabel(Text("Wrap Chains"))
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Layout", selection: layoutBinding) {
                    ForEach(RigLayout.allCases) { layout in
                        Label(layout.displayName,
                              systemImage: layout == .single ? "rectangle" : "rectangle.split.1x2")
                            .tag(layout)
                    }
                }
            } label: {
                Label("Layout", systemImage: "rectangle.split.1x2")
            }
        }
    }

    private var layoutBinding: Binding<RigLayout> {
        Binding(
            get: { editor.rig.layout },
            set: { editor.setLayout($0) }
        )
    }
}
