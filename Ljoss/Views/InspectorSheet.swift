import SwiftUI

/// Parameter editing for whatever is selected on the canvas.
struct InspectorSheet: View {
    @Environment(RigEditor.self) private var editor
    @Environment(EngineSession.self) private var session: EngineSession?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch editor.selection {
                case .block(let id):     blockEditor(id)
                case .input(let id):     ioEditor(chainID: id, isInput: true)
                case .output(let id):    ioEditor(chainID: id, isInput: false)
                case .parallel(let id):  parallelEditor(id)
                case nil:                ContentUnavailableView("Nothing Selected", systemImage: "hand.tap")
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    // MARK: - Block

    @ViewBuilder
    private func blockEditor(_ id: UUID) -> some View {
        if let block = editor.rig.allBlocks.first(where: { $0.id == id }) {
            let spec = Catalogue.resolve(block.componentID)
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: spec.symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(spec.category.accent)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.name).font(.headline)
                            Text(spec.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Toggle("Enabled", isOn: Binding(
                        get: { block.isEnabled },
                        set: { on in editor.rig.mutateBlock(id: id) { $0.isEnabled = on } }
                    ))
                    .frame(minHeight: Metrics.minTouchTarget)
                } footer: {
                    // Bypass is not off: the device keeps the block running so its
                    // state stays warm, which is why un-bypassing does not click.
                    Text(block.isEnabled
                         ? "Bypassing a block keeps it running, so switching it back in does not click."
                         : "Bypassed. The device still runs this block, so its state stays warm.")
                }

                if isConnected && !isPlayable(block) {
                    Section {
                        Label("This device cannot play \(spec.name)",
                              systemImage: "waveform.slash")
                            .foregroundStyle(.orange)
                        Text("The rest of the rig is held back with it: a document is applied whole or not at all.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                assetSection(for: block)

                if spec.params.isEmpty {
                    Section { Text("No parameters.").foregroundStyle(.secondary) }
                } else {
                    Section("Parameters") {
                        ForEach(spec.params) { param in
                            ParamRow(
                                spec: param,
                                notSent: notSentReason(param.id, of: block),
                                value: Binding(
                                    get: { block.values[param.id] ?? param.defaultValue },
                                    set: { v in editor.rig.mutateBlock(id: id) { $0.values[param.id] = v } }
                                ))
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        editor.removeElement(id: id)
                        dismiss()
                    } label: {
                        Label("Remove Block", systemImage: "trash")
                    }
                    .frame(minHeight: Metrics.minTouchTarget)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(spec.name)
        } else {
            ContentUnavailableView("Block Not Found", systemImage: "questionmark.square.dashed")
        }
    }

    // MARK: - What the device can and cannot do

    private var isConnected: Bool { session?.connection.isOnline ?? false }

    private func isPlayable(_ block: Block) -> Bool {
        BlockMappings.isMapped(block.componentID)
    }

    /// Why a knob will not reach the device, or nil when it will.
    ///
    /// Only while connected: with no device there is nothing to be honest *about*,
    /// and every knob is still a real part of the document.
    private func notSentReason(_ param: String, of block: Block) -> String? {
        guard isConnected else { return nil }
        guard let mapping = BlockMappings.mapping(for: block.componentID) else {
            return "this device cannot play this block at all"
        }
        return mapping.outOfBand[param]
    }

    private func ioReason(_ param: String, isInput: Bool) -> String? {
        isInput ? IOMapping.inputOutOfBand[param] : IOMapping.outputOutOfBand[param]
    }

    /// The model or impulse response this block needs, listed from the device's own
    /// library. The value sent is the **id**; a path is refused outright from a
    /// network client.
    @ViewBuilder
    private func assetSection(for block: Block) -> some View {
        let needed = BlockMappings.mapping(for: block.componentID)?.requiredAssets ?? []
        if let session, session.connection.isOnline, !needed.isEmpty {
            Section {
                ForEach(needed, id: \.self) { kind in
                    assetPicker(kind, for: block, library: session.assets.list(for: kind))
                }
            } header: {
                Text("Device")
            } footer: {
                Text("Loaded from the device. A rig names these by id, so it means the same thing on any device that has them.")
            }
        }
    }

    @ViewBuilder
    private func assetPicker(_ kind: AssetKind, for block: Block, library: [EngineAsset]) -> some View {
        if library.isEmpty {
            LabeledContent(kind.noun.capitalized) {
                Text("None installed").foregroundStyle(.secondary)
            }
        } else {
            Picker(kind.noun.capitalized, selection: Binding(
                get: { block.values[kind.valueKey]?.optionValue ?? "" },
                set: { chosen in
                    editor.rig.mutateBlock(id: block.id) { $0.values[kind.valueKey] = .option(chosen) }
                }
            )) {
                Text("Choose\u{2026}").tag("")
                ForEach(library) { asset in
                    Text(asset.group.map { "\($0) / \(asset.name ?? asset.id)" } ?? asset.id)
                        .tag(asset.id)
                }
            }
            .frame(minHeight: Metrics.minTouchTarget)
        }
    }

    // MARK: - Input / Output

    @ViewBuilder
    private func ioEditor(chainID: UUID, isInput: Bool) -> some View {
        if let chainIndex = editor.rig.chains.firstIndex(where: { $0.id == chainID }) {
            let chain = editor.rig.chains[chainIndex]
            let params = isInput ? Catalogue.inputParams(for: chain.source) : Catalogue.outputParams
            let node = isInput ? chain.input : chain.output

            Form {
                Section("Chain") {
                    TextField("Name", text: Binding(
                        get: { chain.name },
                        set: { editor.rig.chains[chainIndex].name = $0 }
                    ))
                    .frame(minHeight: Metrics.minTouchTarget)

                    Picker("Source", selection: Binding(
                        get: { chain.source },
                        set: { editor.rig.chains[chainIndex].source = $0 }
                    )) {
                        ForEach(SourceKind.allCases) { s in Text(s.displayName).tag(s) }
                    }
                    .frame(minHeight: Metrics.minTouchTarget)
                }

                Section {
                    ForEach(params) { param in
                        ParamRow(
                            spec: param,
                            notSent: isConnected ? ioReason(param.id, isInput: isInput) : nil,
                            value: Binding(
                                get: { node.values[param.id] ?? param.defaultValue },
                                set: { v in
                                    if isInput { editor.rig.chains[chainIndex].input.values[param.id] = v }
                                    else { editor.rig.chains[chainIndex].output.values[param.id] = v }
                                }
                            ))
                    }
                } header: {
                    Text(isInput ? "Input" : "Output")
                } footer: {
                    if isConnected {
                        // Remembering a phantom-power setting the app never sends is
                        // honest. A knob that looks live and is not would not be.
                        Text("Settings marked here are the interface's, not the rig's. They are remembered, and never sent to the device.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isInput ? "Input" : "Output")
        } else {
            ContentUnavailableView("Chain Not Found", systemImage: "questionmark.square.dashed")
        }
    }

    // MARK: - Parallel

    @ViewBuilder
    private func parallelEditor(_ id: UUID) -> some View {
        if let address = editor.rig.address(ofElement: id),
           case .parallel(let section)? = editor.rig.element(at: address) {
            let path = address.container
            Form {
                Section {
                    Picker("Mode", selection: Binding(
                        get: { section.splitMode },
                        set: { m in editor.rig.mutateParallel(in: path, parallelID: id) { $0.splitMode = m } }
                    )) {
                        ForEach(SplitMode.allCases) { m in Text(m.displayName).tag(m) }
                    }
                    .frame(minHeight: Metrics.minTouchTarget)

                    // A Y split is routing; the other three are real DSP the engine
                    // has not built. Saying so here beats a refusal after the fact,
                    // and beats quietly sending a Y and letting it sound wrong.
                    if isConnected && section.splitMode != .yCable {
                        Label("This device only has the Y split. The rig will not be sent while this is set to \(section.splitMode.displayName).",
                              systemImage: "waveform.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if section.splitMode == .crossover {
                        LabeledSlider(title: "Crossover", unit: "Hz", range: 60...8000,
                                      value: Binding(
                                        get: { section.crossoverHz },
                                        set: { v in editor.rig.mutateParallel(in: path, parallelID: id) { $0.crossoverHz = v } }
                                      ))
                    }
                    if section.splitMode == .aB || section.splitMode == .dynamic {
                        LabeledSlider(title: "Balance", unit: "%", range: -100...100,
                                      value: Binding(
                                        get: { section.balance * 100 },
                                        set: { v in editor.rig.mutateParallel(in: path, parallelID: id) { $0.balance = v / 100 } }
                                      ))
                    }
                } header: {
                    Text("Split")
                }

                ForEach(Array(section.lanes.enumerated()), id: \.element.id) { index, lane in
                    Section("Lane \(index + 1)") {
                        LabeledSlider(title: "Level", unit: "dB", range: -60...12,
                                      value: laneBinding(path, id, index, \.level))
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledSlider(title: "Pan", unit: "%", range: -100...100,
                                          value: Binding(
                                            get: { lane.pan * 100 },
                                            set: { v in editor.rig.mutateLane(containerOfParallel: path, parallelID: id, laneIndex: index) { $0.pan = v / 100 } }
                                          ))
                            if isConnected {
                                Label("the engine is mono end to end and declares one channel per port",
                                      systemImage: "waveform.slash")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Toggle("Mute", isOn: Binding(
                            get: { lane.isMuted },
                            set: { v in editor.rig.mutateLane(containerOfParallel: path, parallelID: id, laneIndex: index) { $0.isMuted = v } }
                        ))
                        .frame(minHeight: Metrics.minTouchTarget)
                        Toggle("Invert Phase", isOn: Binding(
                            get: { lane.invertPhase },
                            set: { v in editor.rig.mutateLane(containerOfParallel: path, parallelID: id, laneIndex: index) { $0.invertPhase = v } }
                        ))
                        .frame(minHeight: Metrics.minTouchTarget)

                        if section.lanes.count > 2 {
                            Button(role: .destructive) {
                                editor.removeLane(index, fromParallel: id)
                            } label: {
                                Label("Remove Lane", systemImage: "minus.circle")
                            }
                            .frame(minHeight: Metrics.minTouchTarget)
                        }
                    }
                }

                Section {
                    Button {
                        editor.addLane(toParallel: id)
                    } label: {
                        Label("Add Lane", systemImage: "plus")
                    }
                    .frame(minHeight: Metrics.minTouchTarget)

                    Button {
                        editor.joinParallel(id: id)
                        dismiss()
                    } label: {
                        Label("Join Into Series", systemImage: "arrow.triangle.merge")
                    }
                    .frame(minHeight: Metrics.minTouchTarget)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Split")
        } else {
            ContentUnavailableView("Split Not Found", systemImage: "questionmark.square.dashed")
        }
    }

    private func laneBinding(
        _ path: ContainerPath,
        _ parallelID: UUID,
        _ laneIndex: Int,
        _ keyPath: WritableKeyPath<Lane, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                guard let address = editor.rig.address(ofElement: parallelID),
                      case .parallel(let p)? = editor.rig.element(at: address),
                      p.lanes.indices.contains(laneIndex) else { return 0 }
                return p.lanes[laneIndex][keyPath: keyPath]
            },
            set: { v in
                editor.rig.mutateLane(containerOfParallel: path, parallelID: parallelID, laneIndex: laneIndex) {
                    $0[keyPath: keyPath] = v
                }
            }
        )
    }
}

// MARK: - Parameter rows

struct ParamRow: View {
    let spec: ParamSpec
    /// Why this control will not reach the device, when it will not. A knob that
    /// looks live and is not is the one thing this integration is written to avoid.
    var notSent: String? = nil
    @Binding var value: ParamValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let notSent {
                Label(notSent, systemImage: "waveform.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(notSent == nil ? 1 : 0.7)
    }

    @ViewBuilder
    private var control: some View {
        switch spec.kind {
        case .continuous(let lo, let hi):
            LabeledSlider(
                title: spec.name,
                unit: spec.unit,
                range: lo...hi,
                value: Binding(
                    get: { value.doubleValue ?? lo },
                    set: { value = .number($0) }
                )
            )
        case .stepped(let lo, let hi, let step):
            LabeledSlider(
                title: spec.name,
                unit: spec.unit,
                range: lo...hi,
                step: step,
                value: Binding(
                    get: { value.doubleValue ?? lo },
                    set: { value = .number($0) }
                )
            )
        case .options(let options):
            Picker(spec.name, selection: Binding(
                get: { value.optionValue ?? options.first ?? "" },
                set: { value = .option($0) }
            )) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .frame(minHeight: Metrics.minTouchTarget)
        case .toggle:
            Toggle(spec.name, isOn: Binding(
                get: { value.boolValue ?? false },
                set: { value = .flag($0) }
            ))
            .frame(minHeight: Metrics.minTouchTarget)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    var unit: String?
    let range: ClosedRange<Double>
    var step: Double?
    @Binding var value: Double

    private var display: String {
        let magnitude = max(abs(range.lowerBound), abs(range.upperBound))
        let text = magnitude >= 100
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return unit.map { "\(text) \($0)" } ?? text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(display)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)

            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: Metrics.minTouchTarget)
    }
}
