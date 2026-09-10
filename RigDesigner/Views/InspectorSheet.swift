import SwiftUI

/// Parameter editing for whatever is selected on the canvas.
struct InspectorSheet: View {
    @Environment(RigEditor.self) private var editor
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
                }

                if spec.params.isEmpty {
                    Section { Text("No parameters.").foregroundStyle(.secondary) }
                } else {
                    Section("Parameters") {
                        ForEach(spec.params) { param in
                            ParamRow(spec: param, value: Binding(
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

                Section(isInput ? "Input" : "Output") {
                    ForEach(params) { param in
                        ParamRow(spec: param, value: Binding(
                            get: { node.values[param.id] ?? param.defaultValue },
                            set: { v in
                                if isInput { editor.rig.chains[chainIndex].input.values[param.id] = v }
                                else { editor.rig.chains[chainIndex].output.values[param.id] = v }
                            }
                        ))
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
                Section("Split") {
                    Picker("Mode", selection: Binding(
                        get: { section.splitMode },
                        set: { m in editor.rig.mutateParallel(in: path, parallelID: id) { $0.splitMode = m } }
                    )) {
                        ForEach(SplitMode.allCases) { m in Text(m.displayName).tag(m) }
                    }
                    .frame(minHeight: Metrics.minTouchTarget)

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
                }

                ForEach(Array(section.lanes.enumerated()), id: \.element.id) { index, lane in
                    Section("Lane \(index + 1)") {
                        LabeledSlider(title: "Level", unit: "dB", range: -60...12,
                                      value: laneBinding(path, id, index, \.level))
                        LabeledSlider(title: "Pan", unit: "%", range: -100...100,
                                      value: Binding(
                                        get: { lane.pan * 100 },
                                        set: { v in editor.rig.mutateLane(containerOfParallel: path, parallelID: id, laneIndex: index) { $0.pan = v / 100 } }
                                      ))
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
    @Binding var value: ParamValue

    var body: some View {
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
