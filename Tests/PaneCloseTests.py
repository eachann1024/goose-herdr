#!/usr/bin/env python3
"""Run the actual AppModel close method against an in-memory service: python3 Tests/PaneCloseTests.py."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/AppModel.swift").read_text()
start = source.index("    private func performClosePane(")
end = source.index("\n    // MARK: - Actions", start)
method = source[start:end].replace("private func", "func", 1)
assert "createTab(" not in method, "closing a pane must not create a replacement tab"
harness = r'''
import Foundation
struct PaneRef: Hashable { let deviceID: UUID; let paneID: String }
struct Device { let id = UUID() }
struct Pane { let paneID: String; let workspaceID: String; var cwd: String? = nil }
struct Workspace { let workspaceID: String; let paneCount: Int?; var label: String = ""; var cwd: String? = nil }
struct Snapshot { let panes: [Pane]?; let agents: [Pane]; let workspaces: [Workspace] }
struct DeviceState { var workspaces: [Workspace] = [] }
enum Failure: Error { case close }
@MainActor final class Service {
    var panes = [Pane(paneID: "agent", workspaceID: "space")]
    var spaceExists = true
    var created = 0
    var failClose = false
    var onClose: ((String) -> Void)?
    func snapshot() async throws -> Snapshot {
        await Task.yield()
        return Snapshot(panes: panes, agents: [], workspaces: spaceExists
            ? [Workspace(workspaceID: "space", paneCount: panes.count, label: "Space")] : [])
    }
    func createTab(workspaceID: String, cwd: String?, label: String?) async throws -> String {
        await Task.yield()
        precondition(false, "last-pane close must not create a replacement tab")
        return "unused"
    }
    func closePane(paneID: String) async throws {
        await Task.yield()
        onClose?(paneID)
        if failClose { throw Failure.close }
        panes.removeAll { $0.paneID == paneID }
        if panes.isEmpty { spaceExists = false }
    }
}
@MainActor final class Model {
    let backend = Service()
    var paneCloseTask: Task<Void, Never>?
    var closingPanes: Set<PaneRef> = []
    var actionError: String?
    var retained: [(String, String?, Int)] = []
    var states: [UUID: DeviceState] = [:]
    func service(for device: Device) -> Service { backend }
    func refresh(_ id: UUID) async {
        assert(closingPanes.count == 1, "suppress reconnect until the close refresh finishes")
    }
    func actionErrorMessage(_ error: Error, device: Device) -> String { "failed" }
    func session(_ id: UUID) -> DeviceState { states[id] ?? DeviceState() }
    func rememberClosedSpace(
        deviceID: UUID,
        workspaceID: String,
        label: String?,
        cwd: String?,
        sortIndex: Int
    ) {
        retained.append((workspaceID, label, sortIndex))
    }
''' + method + r'''
}
@main struct Check {
    @MainActor static func main() async {
        let device = Device()
        let model = Model()
        model.backend.onClose = { [weak model] paneID in
            assert(model?.closingPanes.contains(PaneRef(deviceID: device.id, paneID: paneID)) == true)
        }
        model.states[device.id] = DeviceState(workspaces: [
            Workspace(workspaceID: "before", paneCount: 1, label: "Before"),
            Workspace(workspaceID: "space", paneCount: 1, label: "Space"),
            Workspace(workspaceID: "after", paneCount: 1, label: "After"),
        ])
        let only = model.backend.panes[0].paneID
        model.performClosePane(PaneRef(deviceID: device.id, paneID: only), device: device)
        await model.paneCloseTask?.value
        assert(model.closingPanes.isEmpty)
        assert(!model.backend.spaceExists && model.backend.panes.isEmpty)
        assert(model.backend.created == 0)
        assert(model.retained.map(\.0) == ["space"])
        assert(model.retained[0].1 == "Space")
        assert(model.retained[0].2 == 1, "closing the last pane preserves the sidebar slot")

        // Two live panes: each close uses the remaining count. Only the last is retained.
        model.backend.spaceExists = true
        model.backend.panes = [
            Pane(paneID: "first", workspaceID: "space"),
            Pane(paneID: "second", workspaceID: "space"),
        ]
        model.retained = []
        model.performClosePane(PaneRef(deviceID: device.id, paneID: "first"), device: device)
        model.performClosePane(PaneRef(deviceID: device.id, paneID: "second"), device: device)
        await model.paneCloseTask?.value
        assert(!model.backend.spaceExists && model.backend.panes.isEmpty)
        assert(model.retained.map(\.0) == ["space"])

        // Failed close leaves the original pane and does not retain the space.
        model.backend.failClose = true
        model.backend.spaceExists = true
        model.backend.panes = [Pane(paneID: "survivor", workspaceID: "space")]
        model.retained = []
        model.actionError = nil
        model.performClosePane(PaneRef(deviceID: device.id, paneID: "survivor"), device: device)
        await model.paneCloseTask?.value
        assert(model.backend.panes.map(\.paneID) == ["survivor"] && model.backend.spaceExists)
        assert(model.retained.isEmpty && model.actionError != nil)
        assert(model.closingPanes.isEmpty, "failed closes must restore reconnect UI")

        // A stale close after explicit workspace removal must not recreate it.
        model.backend.failClose = false
        model.backend.panes = []
        model.backend.spaceExists = false
        model.retained = []
        model.performClosePane(PaneRef(deviceID: device.id, paneID: "survivor"), device: device)
        await model.paneCloseTask?.value
        assert(!model.backend.spaceExists && model.backend.created == 0 && model.retained.isEmpty)
        print("PASS: last pane can close, space is retained, no replacement tab")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="pane-close-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
