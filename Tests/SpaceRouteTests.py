#!/usr/bin/env python3
"""Space listing / new-terminal routing / shortcut regression: python3 Tests/SpaceRouteTests.py.

Compiles the real AppModel methods (sliced out of Sources/GooseAgent/AppModel.swift) and the
real shortcut store (Sources/GooseAgent/KeyboardShortcuts.swift) against small stubs, the same
way Tests/PaneCloseTests.py does for performClosePane.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Sources/GooseAgent/AppModel.swift").read_text()
shortcuts = (ROOT / "Sources/GooseAgent/KeyboardShortcuts.swift").read_text()


def slice_between(start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


# workspace.create already returns a shell; never create a second one here.
create_space = slice_between("    func createNewSpace(", "\n    /// Creates a persistent shell tab")
assert "startNewTerminal(" not in create_space and "createTab(" not in create_space
assert "created.rootPaneID.map" in create_space

# Real code under test.
space_entry = slice_between("    struct SpaceEntry: Identifiable {", "\n    var visibleSpaces")
filtered_device = slice_between("    var filteredDevice: Device? {", "\n\n    private var devicesInScope")
devices_in_scope = slice_between("    private var devicesInScope: [Device] {", "\n    /// Aggregate connection state")
visible_spaces = slice_between("    var visibleSpaces: [SpaceEntry] {", "\n    /// Agents across the scope")
selected_shell = slice_between("    var selectedShell: ShellSession? {", "\n    /// Every click opens another terminal.")
select_space = slice_between("    func selectSpace(_ ref: SpaceRef?) {", "\n    func setDeviceFilter(")
# Exercise the real property observer as well as the immediate visibility sync.
selected_space = slice_between("    @Published var selectedSpace", "\n    @Published var selectedPane")
filtering = slice_between("    func setDeviceFilter(", "\n    /// When jumping into a space")
quick_new_terminal = slice_between("    /// Create a terminal in the current space", "\n    /// Explicit per-kind commands")
quick_new_agent = slice_between("    /// Explicit per-kind commands start an agent without a picker.", "\n    func startNewTerminal(")
for name, chunk in [
    ("quickNewTerminal", quick_new_terminal),
    ("quickNewAgent", quick_new_agent),
    ("selectSpace", select_space),
    ("isFilteredOut", filtering),
]:
    assert name in chunk, f"slice marker drifted for {name}"

extracted = "\n".join(
    chunk.replace("private func", "func").replace("private var", "var")
    for chunk in [
        space_entry,
        selected_space,
        filtered_device,
        devices_in_scope,
        visible_spaces,
        selected_shell,
        select_space,
        filtering,
        quick_new_terminal,
        quick_new_agent,
    ]
)

harness = '''import AppKit
import Foundation
import SwiftUI

enum SidebarSectionID { static let spacesHiddenKey = "sidebar.spacesHidden" }
struct PaneRef: Equatable { let deviceID: UUID; let paneID: String }
struct SpaceRef: Equatable { let deviceID: UUID; let workspaceID: String }
struct Device: Equatable {
    let id: UUID
    let name: String
    static let local = Device(id: UUID(), name: "Local")
}
struct WorkspaceInfo { let workspaceID: String }
struct ShellSession { let id: UUID; let title: String; let device: Device }
struct AttachedStub { let device: Device; let workspaceID: String }
struct AgentEntryStub { let ref: PaneRef }
struct DeviceState { var workspaces: [WorkspaceInfo] = [] }
enum HerdrService { static func bypassFlags(for kind: String) -> [String]? { nil } }

@MainActor final class Model {
    var devices: [Device] = []
    var deviceFilter: UUID?
    var selectedPane: PaneRef?
    var selectedShellID: UUID?
    var shellSessions: [ShellSession] = []
    var selectedAttachedEntry: AttachedStub?
    var isFileManagerActive = false
    var actionError: String?
    var started: [(UUID, String)] = []
    var shells: [UUID] = []
    var launched: [(UUID, String, String?)] = []
    private var states: [UUID: DeviceState] = [:]

    func stubWorkspaces(_ id: UUID, _ ids: [String]) {
        states[id] = DeviceState(workspaces: ids.map { WorkspaceInfo(workspaceID: $0) })
    }
    func session(_ id: UUID) -> DeviceState { states[id] ?? DeviceState() }
    func device(_ id: UUID) -> Device? { devices.first { $0.id == id } }
    var firstVisiblePaneRef: PaneRef? { nil }
    func preferredVisibleAgent() -> AgentEntryStub? { nil }
    func startNewTerminal(device: Device, workspaceID: String) { started.append((device.id, workspaceID)) }
    func newShellSession(on device: Device) { shells.append(device.id) }
    func startNewAgent(device: Device, kind: String, workspaceID: String?, bypass: Bool) {
        launched.append((device.id, kind, workspaceID))
    }
    func refresh(_ id: UUID) async {}
    func actionErrorMessage(_ error: Error, device: Device) -> String { "failed" }

''' + extracted + '''
}

''' + "\n".join(line for line in shortcuts.splitlines() if not line.startswith("import ")) + '''

@main struct Check {
    @MainActor static func main() {
        let local = Device(id: UUID(), name: "Local")
        let remote = Device(id: UUID(), name: "Remote")
        let model = Model()
        model.devices = [local, remote]
        model.stubWorkspaces(local.id, ["w1", "w2"])
        model.stubWorkspaces(remote.id, ["r1"])

        // Every space of the filtered device is listed, and only those.
        assert(model.visibleSpaces.map(\\.ref) == [
            SpaceRef(deviceID: local.id, workspaceID: "w1"),
            SpaceRef(deviceID: local.id, workspaceID: "w2"),
            SpaceRef(deviceID: remote.id, workspaceID: "r1"),
        ], "all spaces across all devices")
        model.setDeviceFilter(remote.id)
        assert(model.visibleSpaces.map(\\.ref) == [SpaceRef(deviceID: remote.id, workspaceID: "r1")],
               "device filter scopes the space list")
        assert(model.visibleSpaces.map(\\.ref).count == 1, "spaces of other devices are hidden while filtered")

        // Hiding Spaces clears a pre-existing filter without changing the active content.
        model.setDeviceFilter(nil)
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: SidebarSectionID.spacesHiddenKey)
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
        model.selectedPane = PaneRef(deviceID: local.id, paneID: "p1")
        let activeShellID = UUID()
        model.selectedShellID = activeShellID
        model.isFileManagerActive = true
        defaults.set(true, forKey: SidebarSectionID.spacesHiddenKey)
        model.synchronizeSpaceVisibility()
        assert(model.selectedSpace == nil, "hiding clears the existing filter immediately")
        assert(model.selectedPane == PaneRef(deviceID: local.id, paneID: "p1"))
        assert(model.selectedShellID == activeShellID && model.isFileManagerActive)
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w2")
        assert(model.selectedSpace == nil, "async creation cannot reapply a hidden filter")
        model.selectSpace(SpaceRef(deviceID: local.id, workspaceID: "w1"))
        assert(model.selectedSpace == nil, "hidden space selections stay unfiltered")
        model.setDeviceFilter(remote.id)
        assert(model.visibleSpaces.count == 1, "hiding Spaces preserves device scope")
        defaults.set(false, forKey: SidebarSectionID.spacesHiddenKey)
        model.synchronizeSpaceVisibility()
        assert(model.selectedSpace == nil, "showing Spaces does not resurrect the old filter")

        // Visible spaces remain selectable.
        model.setDeviceFilter(nil)
        model.selectSpace(SpaceRef(deviceID: local.id, workspaceID: "w2"))
        assert(model.selectedSpace == SpaceRef(deviceID: local.id, workspaceID: "w2"), "space selection sticks")
        assert(model.isFileManagerActive == false, "space click leaves the Files page")

        // Routing: current standalone shell first.
        model.selectedSpace = nil
        model.selectedPane = nil
        let shell = ShellSession(id: UUID(), title: "Terminal 1", device: local)
        model.shellSessions = [shell]
        model.selectedShellID = shell.id
        model.quickNewTerminal()
        assert(model.shells == [local.id] && model.started.isEmpty, "standalone shell wins")

        // Routing: the selected space, then the filter as a hard boundary.
        model.selectedShellID = nil
        model.shellSessions = []
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
        model.shells = []
        model.quickNewTerminal()
        assert(model.started.map { $0.0 } == [local.id] && model.started.map { $0.1 } == ["w1"],
               "selected space opens the terminal")

        model.started = []
        model.setDeviceFilter(remote.id)
        model.quickNewTerminal()
        assert(model.started.isEmpty, "a filtered-out space is not used")
        assert(model.shells == [remote.id], "the filter's device gets the standalone terminal")

        model.selectedShellID = shell.id
        model.shellSessions = [shell]
        model.shells = []
        model.quickNewTerminal()
        assert(model.shells == [remote.id], "a standalone shell on a filtered-out device is not reused")

        model.selectedShellID = nil
        model.shellSessions = []
        model.setDeviceFilter(nil)
        model.selectedSpace = nil
        model.shells = []
        model.quickNewTerminal()
        assert(model.shells == [local.id], "no selection falls back to the first device")

        // Per-kind agent launch obeys the same boundary.
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
        model.setDeviceFilter(remote.id)
        model.quickNewAgent(kind: "pi")
        assert(model.launched.isEmpty, "a filtered-out space does not start an agent")
        model.setDeviceFilter(nil)
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
        model.quickNewAgent(kind: "pi")
        assert(model.launched.count == 1 && model.launched[0].0 == local.id && model.launched[0].2 == "w1",
               "per-kind agent launch still works in the selected space")

        // Shortcuts: New Terminal / New Space / Close / Pi keep the required
        // defaults, stay remappable, and the retired general New Agent id is gone
        // rather than shadowing a live binding.
        let suite = "goose-herdr-space-route-check"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        assert(AppShortcuts.chord(for: .quickNewTerminal, store: store) == KeyChord(key: "t", modifiers: .command),
               "New Terminal default is cmd-T")
        assert(AppShortcuts.chord(for: .newSpace, store: store) == KeyChord(key: "n", modifiers: .command),
               "New Space default is cmd-N")
        assert(AppShortcuts.chord(for: .close, store: store) == KeyChord(key: "w", modifiers: .command),
               "Close default is cmd-W")
        assert(AgentKindShortcuts.chord(for: "pi", store: store) == KeyChord(key: "p", modifiers: .option),
               "Pi default is option-P")
        assert(AgentKindShortcuts.chord(for: "codex", store: store) == nil,
               "other agents stay unbound")
        assert(AppShortcutID.allCases.map { $0.rawValue }.sorted() == ["close", "newSpace", "quickNewTerminal"],
               "no general New Agent shortcut remains")
        let legacyStore = ["quickNewAgent": KeyChord(key: "n", modifiers: [.command, .shift]),
                           "newAgent": KeyChord(key: "a", modifiers: [.command])]
        store.set(try! JSONEncoder().encode(legacyStore), forKey: AppShortcuts.storageKey)
        assert(AppShortcuts.chord(for: .quickNewTerminal, store: store) == KeyChord(key: "t", modifiers: .command),
               "a retired New Agent entry does not shadow New Terminal")
        AppShortcuts.set(KeyChord(key: "j", modifiers: [.command, .shift]), for: .quickNewTerminal, store: store)
        AppShortcuts.set(KeyChord(key: "b", modifiers: [.command, .control]), for: .newSpace, store: store)
        assert(AppShortcuts.chord(for: .quickNewTerminal, store: store) == KeyChord(key: "j", modifiers: [.command, .shift]),
               "custom terminal binding survives")
        assert(AppShortcuts.display(for: .quickNewTerminal, store: store) == "\\u{21E7}\\u{2318}J",
               "menus and help show the custom binding")
        store.removePersistentDomain(forName: suite)
        defaults.removeObject(forKey: SidebarSectionID.spacesHiddenKey)
        print("PASS: hidden-space scope, filter-safe routing, shortcut boundaries")
    }
}
'''

# Static boundaries a compiled slice cannot see.
all_sources = "\n".join(p.read_text() for p in (ROOT / "Sources").rglob("*.swift"))
for stale in [
    "sessionsHiddenKey", "sessionsExpandedKey", "agentsHiddenKey", "terminalsHiddenKey",
    "showNewAgent", "NewAgentSheet", "NewTerminalSheet",
]:
    assert stale not in all_sources, f"removed sidebar/agent-picker wiring came back: {stale}"
assert "func quickNewAgent(kind: String)" in source, "per-kind agent launch must stay"
assert "func activateSpace(" in source, "empty spaces open a terminal on click"
assert "Create first: closing the last pane" not in source, "last-tab close must not spawn a replacement"
root_view = (ROOT / "Sources/GooseAgent/ContentView.swift").read_text()
assert ".onChange(of: spacesHidden, initial: true)" in root_view
assert "model.synchronizeSpaceVisibility()" in root_view
sidebar = (ROOT / "Sources/GooseAgent/SidebarView.swift").read_text()
assert "if !spacesHidden {" in sidebar
assert 'Toggle("Spaces"' in (ROOT / "Sources/GooseAgent/GooseAgentApp.swift").read_text()
catalog = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text())["strings"]
for gone in ["New Agent", "New Agent…", "Sessions", "Hide Sessions", "Default agent", "Show in New Agent"]:
    assert gone not in catalog, f"dead localization came back: {gone}"

with tempfile.TemporaryDirectory(prefix="space-route-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "space-route-check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    preferences = Path(os.path.expanduser("~/Library/Preferences/goose-herdr-space-route-check.plist"))
    if preferences.exists():
        preferences.unlink()
