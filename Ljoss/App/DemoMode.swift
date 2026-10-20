#if os(macOS)
import AppKit
import SwiftUI

/// A scripted, hands-off run of the app, for making the pedal's video (pedal-science/comms,
/// `video/`): build one rig, connect to the engine the script names, make the script's edits
/// through the same `RigEditor` calls the canvas makes, and save the window after each.
///
/// Off unless `LJOSS_DEMO` names a directory holding `demo.json`. It never touches the user's own
/// things: the rig library and the asset store live in that directory, the engine's address and
/// token come from the script, and nothing is written to preferences or the keychain — the
/// session is made from the script's settings, so the keychain is not even read.
@MainActor
final class DemoMode {

    static let current: DemoMode? = DemoMode.fromEnvironment()

    let directory: URL
    let script: Script
    /// Held for the whole run. The app runs in the background, and App Nap would otherwise
    /// stretch the engine session's 250 ms debounce to seconds: a toggle would reach the engine
    /// only when the next edit did.
    private let activity: NSObjectProtocol

    struct Script: Decodable {
        struct Engine: Decodable {
            var host: String
            var port: UInt16
            var tokenFile: String
        }

        /// A block, or a parallel section when `lanes` is set.
        struct Element: Decodable {
            var block: String?
            /// The engine's library id of the amp's model (`engine.model`).
            var model: String?
            /// The engine's library id of the cab's impulse response (`engine.ir`).
            var ir: String?
            var values: [String: Double]?
            var enabled: Bool?
            var lanes: [[Element]]?
        }

        /// `wait`, `snap`, `toggle`, `set`, `append`, `addLane` or `quit`. Blocks are counted in
        /// signal order (lanes top to bottom), parallel sections likewise, both from 0.
        struct Step: Decodable {
            var op: String
            var block: Int?
            var parallel: Int?
            var component: String?
            var param: String?
            var value: Double?
            var ms: Int?
            var name: String?
            var elements: [Element]?
        }

        var engine: Engine
        var rigName: String
        var window: [Double]?
        var elements: [Element]
        var steps: [Step]
    }

    private init(directory: URL, script: Script) {
        self.directory = directory
        self.script = script
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "LJOSS_DEMO scripted run")
    }

    private static func fromEnvironment() -> DemoMode? {
        guard let path = ProcessInfo.processInfo.environment["LJOSS_DEMO"], !path.isEmpty else { return nil }
        let directory = URL(filePath: path, directoryHint: .isDirectory)
        do {
            let data = try Data(contentsOf: directory.appending(path: "demo.json"))
            return DemoMode(directory: directory, script: try JSONDecoder().decode(Script.self, from: data))
        } catch {
            print("LJOSS_DEMO: cannot read \(path)/demo.json: \(error)")
            return nil
        }
    }

    var libraryDirectory: URL { directory.appending(path: "library", directoryHint: .isDirectory) }
    var assetsDirectory: URL { directory.appending(path: "assets", directoryHint: .isDirectory) }
    var outputDirectory: URL { directory.appending(path: "out", directoryHint: .isDirectory) }

    var engineSettings: EngineSettings {
        let token = (try? String(contentsOfFile: script.engine.tokenFile, encoding: .utf8)) ?? ""
        return EngineSettings(host: script.engine.host, port: script.engine.port,
                              token: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - The rig

    /// The script's rig, made with the app's own types so it is exactly what the canvas would make.
    func makeRig() -> Rig {
        var rig = RigFactory.emptyRig(name: script.rigName)
        rig.chains[0].elements = script.elements.map(Self.element)
        rig.normalize()
        return rig
    }

    private static func element(_ e: Script.Element) -> ChainElement {
        if let lanes = e.lanes {
            return .parallel(ParallelSection(lanes: lanes.map { Lane(elements: $0.map(element)) }))
        }
        var block = Block(componentID: e.block ?? "util.gain", isEnabled: e.enabled ?? true)
        for (key, value) in e.values ?? [:] { block.values[key] = .number(value) }
        if let model = e.model { block.values[AssetKind.model.valueKey] = .option(model) }
        if let ir = e.ir { block.values[AssetKind.ir.valueKey] = .option(ir) }
        return .block(block)
    }

    // MARK: - Running the script

    private var started = false
    /// The editor on screen. SwiftUI can build the editor more than once (hiding the rig list
    /// rebuilds the detail column), so each step uses the one that appeared last, not the one
    /// the run started with.
    private weak var current: RigEditor?

    func attach(_ editor: RigEditor) {
        current = editor
    }

    /// Starts the run once, on a task of its own. Not on the view's `.task`: that is cancelled when
    /// SwiftUI replaces the view, and a cancelled task's sleeps return at once — every wait in the
    /// script would be skipped and the edits would land in one burst.
    func start(editor first: RigEditor, engine: EngineSession?) {
        if current == nil { current = first }
        guard !started else { return }
        started = true
        runner = Task { @MainActor in await self.run(engine: engine) }
    }

    private var runner: Task<Void, Never>?

    private func run(engine: EngineSession?) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        placeWindow()

        // Until the engine has the rig: a snap before then would show the canvas, but the screen in
        // the video is meant to be showing the same rig at the same moment.
        for _ in 0..<100 where engine?.connection.isOnline != true {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(1))
        print("LJOSS_DEMO: engine \(String(describing: engine?.connection))")
        current?.didAppear()
        try? await Task.sleep(for: .seconds(1.5))

        for step in script.steps {
            guard let editor = current else { break }
            switch step.op {
            case "wait":
                try? await Task.sleep(for: .milliseconds(step.ms ?? 500))
            case "snap":
                placeWindow()
                try? await Task.sleep(for: .milliseconds(step.ms ?? 900))
                snap(step.name ?? "snap")
            case "toggle":
                if let id = blockID(step.block, in: editor.rig) { editor.toggleEnabled(blockID: id) }
            case "set":
                if let id = blockID(step.block, in: editor.rig), let param = step.param, let value = step.value {
                    editor.rig.mutateBlock(id: id) { $0.values[param] = .number(value) }
                }
            case "append":
                if let component = step.component, let chain = editor.rig.chains.first {
                    editor.append(componentID: component, toChain: chain.id)
                }
            case "addLane":
                addLane(step, editor: editor)
            case "quit":
                NSApp.terminate(nil)
            default:
                print("LJOSS_DEMO: unknown step '\(step.op)'")
            }
        }
    }

    /// A new lane holding the step's elements, as one edit: the engine and the canvas see the lane
    /// arrive full rather than empty and then filled.
    private func addLane(_ step: Script.Step, editor: RigEditor) {
        guard let parallel = parallelID(step.parallel, in: editor.rig),
              let path = editor.rig.container(holdingParallel: parallel) else { return }
        var rig = editor.rig
        let before = rig.elements(at: path)?.compactMap(\.asParallel).first { $0.id == parallel }?.lanes.count ?? 0
        guard rig.addLane(to: parallel, in: path) else { return }
        let lane = path.appending(LaneStep(parallelID: parallel, laneIndex: before))
        for (i, e) in (step.elements ?? []).enumerated() {
            _ = rig.insert(Self.element(e), at: InsertionSlot(container: lane, index: i), normalizing: false)
        }
        rig.normalize()
        withAnimation(Anim.reflow) { editor.rig = rig }
        // A drop re-measures the canvas; an edit made here has to ask for it the same way.
        editor.didAppear()
    }

    private func blockID(_ index: Int?, in rig: Rig) -> UUID? {
        guard let index else { return nil }
        let ids = rig.chains.first.map { Self.blocks(in: $0.elements) } ?? []
        return ids.indices.contains(index) ? ids[index] : nil
    }

    private func parallelID(_ index: Int?, in rig: Rig) -> UUID? {
        guard let index else { return nil }
        let ids = rig.chains.first.map { Self.parallels(in: $0.elements) } ?? []
        return ids.indices.contains(index) ? ids[index] : nil
    }

    private static func blocks(in elements: [ChainElement]) -> [UUID] {
        elements.flatMap { e -> [UUID] in
            switch e {
            case .block(let b): [b.id]
            case .parallel(let p): p.lanes.flatMap { blocks(in: $0.elements) }
            }
        }
    }

    private static func parallels(in elements: [ChainElement]) -> [UUID] {
        elements.flatMap { e -> [UUID] in
            switch e {
            case .block: []
            case .parallel(let p): [p.id] + p.lanes.flatMap { parallels(in: $0.elements) }
            }
        }
    }

    // MARK: - The window

    private var window: NSWindow? {
        NSApp.windows.first { $0.contentView != nil && $0.isVisible && $0.className != "NSStatusBarWindow" }
    }

    private func placeWindow() {
        guard let window, let size = script.window, size.count == 2 else { return }
        window.setContentSize(NSSize(width: size[0], height: size[1]))
    }

    /// The whole window, title bar and toolbar included, from the app's own drawing: no screen
    /// recording, and the same result whatever else is on the screen.
    private func snap(_ name: String) {
        guard let window, let frame = window.contentView?.superview ?? window.contentView,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            print("LJOSS_DEMO: no window to snap for \(name)")
            return
        }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: outputDirectory.appending(path: "\(name).png"))
        print("LJOSS_DEMO: snapped \(name)")
    }
}
#endif
