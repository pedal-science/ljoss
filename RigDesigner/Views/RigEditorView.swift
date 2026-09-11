import SwiftUI

struct RigEditorView: View {
    @State private var editor: RigEditor
    @State private var paletteSource: SourceKind
    @State private var showingInspector = false
    /// A viewing preference, not part of the rig: on by default, remembered
    /// across launches, and the same for every rig.
    @AppStorage("wrapsChains") private var wrapsChains = true

    private let library: RigLibrary

    init(rig: Rig, library: RigLibrary) {
        self.library = library
        _editor = State(initialValue: RigEditor(rig: rig, library: library))
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
