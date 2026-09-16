#!/usr/bin/env python3
"""Notification scope regression: python3 Tests/NotificationRouteTests.py."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/GooseAgent/AppModel.swift").read_text()
start = source.index("    func reveal(")
reveal = source[start:source.index("\n    // MARK: - Shell terminals", start)]
notification = (root / "Sources/GooseAgent/NotificationManager.swift").read_text()
assert "model.reveal(PaneRef(deviceID: deviceID, paneID: paneID), preservingSpaceScope: true)" in notification

harness = '''import Foundation
struct PaneRef: Equatable { let deviceID: UUID; let paneID: String }
struct SpaceRef: Equatable { let deviceID: UUID; let workspaceID: String }
struct Entry { let paneID: String; let workspaceID: String }
struct State { var panes: [Entry] = []; var agents: [Entry] = [] }
final class Model {
    var isFileManagerActive = true
    var deviceFilter: UUID?
    var selectedSpace: SpaceRef?
    var selectedPane: PaneRef?
    var selectedShellID: UUID? = UUID()
    var hasTerminalSplits = true
    var showSearch = false
    var pendingSplitAgentFocus = false
    var states: [UUID: State] = [:]
    func session(_ id: UUID) -> State { states[id] ?? State() }
''' + reveal + '''
}
let local = UUID(), remote = UUID()
let target = PaneRef(deviceID: remote, paneID: "p1")
let targetSpace = SpaceRef(deviceID: remote, workspaceID: "w1")
let otherSpace = SpaceRef(deviceID: remote, workspaceID: "w2")
let localSpace = SpaceRef(deviceID: local, workspaceID: "w1")
// All spaces, same space, another space, and same workspace ID on another device.
for initialSpace in [nil, targetSpace, otherSpace, localSpace] as [SpaceRef?] {
    for panesAvailable in [true, false] {
        let model = Model()
        let entry = Entry(paneID: "p1", workspaceID: "w1")
        model.states[remote] = panesAvailable
            ? State(panes: [entry]) : State(agents: [entry])
        // A matching pane ID on another device must not determine the target space.
        model.states[local] = State(panes: [Entry(paneID: "p1", workspaceID: "wrong")])
        model.selectedSpace = initialSpace
        model.deviceFilter = initialSpace?.deviceID
        model.reveal(target, preservingSpaceScope: true)
        assert(model.selectedSpace == (initialSpace == nil ? nil : targetSpace))
        assert(model.selectedPane == target)
        assert(model.selectedShellID == nil && !model.isFileManagerActive)
        assert(model.deviceFilter == nil || model.deviceFilter == remote)
        assert(!model.pendingSplitAgentFocus)
    }
}
// Search retains its existing all-spaces navigation and deferred split focus.
let search = Model()
search.selectedSpace = otherSpace
search.showSearch = true
search.reveal(target)
assert(search.selectedSpace == nil && search.selectedPane == target)
assert(search.pendingSplitAgentFocus)
// A stale notification must not leave the target behind an unrelated space filter.
let stale = Model()
stale.selectedSpace = otherSpace
stale.reveal(target, preservingSpaceScope: true)
assert(stale.selectedSpace == nil && stale.selectedPane == target)
print("PASS: notification all/same/other/cross-device space routing; search unchanged")
'''
with tempfile.TemporaryDirectory(prefix="notification-route-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
