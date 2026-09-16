#!/usr/bin/env python3
"""⌘W peel order: python3 Tests/CloseCommandTests.py."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/AppModel.swift").read_text()
keep_start = source.index("    var hasKeepAliveWork:")
keep_end = source.index("\n    // MARK: - Selection", keep_start)
keep = source[keep_start:keep_end]
action_start = source.index("    enum CloseCommandAction: Equatable {")
action_end = source.index("    @discardableResult", action_start)
action = source[action_start:action_end]
assert "return .closeSpace" in action
assert "return .keepWindow" in action

harness = r'''
import Foundation

struct Tree { var leaves = ["a", "b"]; var focusedID = "b" }
struct ShellSession { let id = UUID() }
struct SpaceRef: Hashable { let deviceID: UUID; let workspaceID: String }
struct DeviceSessionState {
    var workspaces: [String] = []
    var agents: [String] = []
    var panes: [String] = []
}
struct RetainedSpace {}

@MainActor final class Model {
    var currentSplitTree: Tree?
    var terminalGroupID: String? = "a"
    var selectedShell: ShellSession?
    var selectedShellID: UUID?
    var isFileManagerActive = false
    var selectedAttachedEntry: String?
    var selectedSpace: SpaceRef?
    var shellSessions: [ShellSession] = []
    var retainedSpaces: [RetainedSpace] = []
    var sessions: [UUID: DeviceSessionState] = [:]
''' + keep + action + r'''
}

@main struct Check {
    @MainActor static func main() {
        let model = Model()
        assert(model.closeCommandAction() == .closeWindow)
        assert(!model.hasKeepAliveWork)

        model.currentSplitTree = Tree()
        assert(model.closeCommandAction() == .closeSplit)

        model.currentSplitTree = nil
        model.selectedShell = ShellSession()
        assert(model.closeCommandAction() == .closeShell)

        model.selectedShell = nil
        model.isFileManagerActive = true
        assert(model.closeCommandAction() == .leaveFiles)

        model.isFileManagerActive = false
        model.selectedAttachedEntry = "pane"
        assert(model.closeCommandAction() == .closePane)

        model.selectedAttachedEntry = nil
        model.selectedSpace = SpaceRef(deviceID: UUID(), workspaceID: "space")
        assert(model.closeCommandAction() == .closeSpace)

        model.selectedSpace = nil
        model.retainedSpaces = [RetainedSpace()]
        assert(model.hasKeepAliveWork)
        assert(model.closeCommandAction() == .keepWindow, "empty retained space must not quit")

        model.retainedSpaces = []
        model.sessions[UUID()] = DeviceSessionState(workspaces: ["live"], agents: [], panes: [])
        assert(model.hasKeepAliveWork)
        assert(model.closeCommandAction() == .keepWindow, "a remaining space must not quit")

        model.sessions = [:]
        model.shellSessions = [ShellSession()]
        assert(model.hasKeepAliveWork)
        assert(model.closeCommandAction() == .keepWindow, "a remaining shell must not quit")

        model.shellSessions = []
        assert(!model.hasKeepAliveWork)
        assert(model.closeCommandAction() == .closeWindow)
        print("PASS: ⌘W closes space after last tab, and never quits while work remains")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="close-command-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
