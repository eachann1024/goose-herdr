#!/usr/bin/env python3
"""Exercise the real launch routing and motion geometry: python3 Tests/PiLaunchTests.py."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
model = (root / "Sources/GooseAgent/AppModel.swift").read_text()
view = (root / "Sources/GooseAgent/PiLaunchView.swift").read_text()
content = (root / "Sources/GooseAgent/ContentView.swift").read_text()
sidebar = (root / "Sources/GooseAgent/SidebarView.swift").read_text()
loading = view.split("struct PiLoadingView:", 1)[1].split("struct PiLaunchInkView:", 1)[0]
assert 'ProgressView()' not in loading and 'Color.clear' in loading
assert '.task(id: model.piLaunch?.failed)' in view
assert '@State private var ink = Theme.randomPiLaunchInk()' in view
assert 'PiLaunchMotion.hold' not in view
assert view.index('while model.piLaunch?.ready != true') < view.index('while !terminalHasContent') < view.index('visible = true') < view.index('expanded = true')
assert 'while ' not in view.split('expanded = true', 1)[1].split('model.finishPiLaunch', 1)[0], 'animation must not wait for startup after expansion'
assert '.offset(x: leading, y: top)' in content and 'geometry.size.width - leading' in content
assert 'ProgressView().controlSize(.small).accessibilityLabel(Text("Loading Pi"))' in sidebar
launch = model[model.index("    func startNewAgent("):model.index("    // MARK: - Retained empty spaces")]
state = model[model.index("    struct PiLaunch: Identifiable"):model.index("    @Published var piLaunch:")]
motion = view[view.index("enum PiLaunchMotion {"):view.index("struct PiLoadingView:")]
harness = r'''
import AppKit
import SwiftUI
struct PaneRef: Hashable { let deviceID: UUID; let paneID: String }
struct PaneInfo { let paneID: String; let workspaceID: String }
struct DeviceState { var panes: [PaneInfo] = [] }
struct Device { let id = UUID() }
enum HerdrError: Error { case rpc(String, String) }
@MainActor final class HerdrService {
    var releaseCreate = false
    var startEntered = false
    var releaseStart = false
    var ready = true
    var fail = false
    var closed = false
    var createdTabs = 0
    static func bypassFlags(for kind: String) -> [String]? { nil }
    func createTab(workspaceID: String?, cwd: String?, label: String?) async throws -> String {
        createdTabs += 1
        while !releaseCreate { await Task.yield() }
        return "pi-pane"
    }
    func startAgent(name: String, kind: String, paneID: String, args: [String], waitForShell: Bool) async throws {
        startEntered = true
        while !releaseStart { await Task.yield() }
        if fail { throw HerdrError.rpc("failed", "failed") }
    }
    func waitForStartedAgent(kind: String, paneID: String) async -> Bool { ready }
    func closePane(paneID: String) async throws { closed = true }
}
@MainActor final class Model {
''' + state + r'''
    var piLaunch: PiLaunch?
    var isFileManagerActive = false
    var selectedShellID: UUID?
    var selectedPane: PaneRef?
    var startingPanes: Set<PaneRef> = []
    var actionError: String?
    let backend = HerdrService()
    var states: [UUID: DeviceState] = [:]
    var reveals = 0
    func service(for device: Device) -> HerdrService { backend }
    func session(_ id: UUID) -> DeviceState { states[id] ?? DeviceState() }
    func noteLoading(_ ref: PaneRef) {}
    func refresh(_ id: UUID) async {}
    func reviveRetainedWorkspace(device: Device, workspaceID: String) async throws -> (workspaceID: String, rootPaneID: String?)? { nil }
    func actionErrorMessage(_ error: Error, device: Device) -> String { "failed" }
    func revealCreatedSession(deviceID: UUID, workspaceID: String?, paneID: String) {
        selectedPane = PaneRef(deviceID: deviceID, paneID: paneID)
        reveals += 1
    }
''' + launch + r'''
}
''' + motion + r'''
@main struct Check {
    @MainActor static func main() async {
        _ = NSApplication.shared
        assert(abs(PiLaunchMotion.cover + PiLaunchMotion.fade - 0.5) < 0.00001)
        for size in [CGSize(width: 980, height: 620), CGSize(width: 1800, height: 1200)] {
            for point in [CGPoint(x: 24, y: 100), CGPoint(x: 240, y: 570)] {
                let r = PiLaunchMotion.radius(size: size, origin: point)
                for x in [0.0, size.width] {
                    for y in [0.0, size.height] { assert(hypot(x - point.x, y - point.y) <= r) }
                }
            }
        }
        let device = Device()
        let model = Model()
        model.startNewAgent(device: device, kind: "pi", workspaceID: "w", bypass: false)
        assert(model.piLaunch != nil && model.selectedPane == nil, "loading begins before the first RPC")
        model.backend.releaseCreate = true
        while !model.backend.startEntered { await Task.yield() }
        assert(model.selectedPane?.paneID == "pi-pane" && model.reveals == 1)
        assert(model.piLaunch?.ready == false, "select immediately without exposing the terminal")
        model.backend.releaseStart = true
        while !model.startingPanes.isEmpty { await Task.yield() }
        assert(model.piLaunch?.ready == true && model.reveals == 1)

        let switched = Model()
        switched.startNewAgent(device: device, kind: "pi", workspaceID: "w", bypass: false)
        switched.piLaunch?.presented = false
        switched.selectedPane = PaneRef(deviceID: device.id, paneID: "other")
        switched.backend.releaseCreate = true
        switched.backend.releaseStart = true
        while switched.piLaunch?.ready != true { await Task.yield() }
        assert(switched.selectedPane?.paneID == "other" && switched.reveals == 0)

        let timeout = Model()
        timeout.backend.ready = false
        timeout.backend.releaseCreate = true
        timeout.backend.releaseStart = true
        timeout.startNewAgent(device: device, kind: "pi", workspaceID: "w", bypass: false)
        while timeout.piLaunch?.failed != true { await Task.yield() }
        assert(timeout.piLaunch?.revealed == false && !timeout.backend.closed)

        let failed = Model()
        failed.backend.fail = true
        failed.backend.releaseCreate = true
        failed.backend.releaseStart = true
        failed.startNewAgent(device: device, kind: "pi", workspaceID: "w", bypass: false)
        while failed.actionError == nil { await Task.yield() }
        assert(failed.piLaunch == nil && failed.backend.closed)

        // A space the New Session sheet just created already has herdr's root
        // shell in it: the agent starts there, beside no second tab, and a failed
        // launch leaves that root alone because this call never opened it.
        func rootPaneModel() -> Model {
            let model = Model()
            model.states[device.id] = DeviceState(panes: [PaneInfo(paneID: "root-pane", workspaceID: "w")])
            model.backend.releaseCreate = true
            model.backend.releaseStart = true
            return model
        }
        let fresh = rootPaneModel()
        fresh.startNewAgent(device: device, kind: "codex", workspaceID: "w", bypass: false, rootPaneID: "root-pane")
        while fresh.reveals == 0 { await Task.yield() }
        assert(fresh.backend.createdTabs == 0 && fresh.selectedPane?.paneID == "root-pane",
               "the new space's own root shell is reused")

        let freshFailure = rootPaneModel()
        freshFailure.backend.fail = true
        freshFailure.startNewAgent(device: device, kind: "codex", workspaceID: "w", bypass: false, rootPaneID: "root-pane")
        while freshFailure.actionError == nil { await Task.yield() }
        assert(freshFailure.backend.createdTabs == 0 && !freshFailure.backend.closed,
               "a root shell is not this call's to close")

        // A root that is gone by now — closed, or taken over by an agent, so it is
        // no longer a plain pane of that workspace — falls back to a normal tab,
        // and that tab keeps the cleanup it always had.
        let staleRoot = Model()
        staleRoot.backend.fail = true
        staleRoot.backend.releaseCreate = true
        staleRoot.backend.releaseStart = true
        staleRoot.startNewAgent(device: device, kind: "codex", workspaceID: "w", bypass: false, rootPaneID: "gone")
        while staleRoot.actionError == nil { await Task.yield() }
        assert(staleRoot.backend.createdTabs == 1 && staleRoot.backend.closed,
               "a vanished root shell falls back to a tab this call closes")
        print("PASS: immediate loading/selection, readiness, switch-away, timeout, failure, root-pane ownership and 0.5s geometry")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="pi-launch-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
