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
commands = (ROOT / "Sources/GooseAgent/GooseAgentApp.swift").read_text()
for name, direction in [("focusLeft", "left"), ("focusRight", "right"), ("focusUp", "up"), ("focusDown", "down"), ("swapLeft", "left"), ("swapRight", "right"), ("swapUp", "up"), ("swapDown", "down")]:
    binding = f"modifiers: AppShortcuts.chord(for: .{name}).modifiers)"
    assert commands.split(binding, 1)[1].lstrip().startswith(
        f".disabled(focusedSplitTree?.neighbor(.{direction}) == nil)"
    ), f"{name} must only be enabled when that neighbor exists"
import re
catalog = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text())["strings"]
titles = dict(re.findall(r'case \.(\w+): return "([^"]+)"', shortcuts.split("    var detail:")[0]))
details = dict(re.findall(r'case \.(\w+): return "([^"]+)"', shortcuts.split("    var detail:")[1].split("    var conflictLabel:")[0]))
assert titles.keys() == details.keys()
for name, detail in details.items():
    assert detail != titles[name], f"{name} repeats its title as description"
    for language in ("en", "zh-Hans"):
        for text in (titles[name], detail):
            assert catalog[text]["localizations"][language]["stringUnit"]["value"]
assert catalog["Advanced"]["localizations"]["zh-Hans"]["stringUnit"]["value"] == "高级操作"


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
quick_new_terminal = slice_between("    /// ⌘T asks for a space only in All Spaces or Priority sessions", "\n    /// Space the sheet")
create_new_session = slice_between("    /// Sheet confirm. Re-resolves", "\n    /// `agent.bypassDefault`")
agent_bypass = slice_between("    /// `agent.bypassDefault`", "\n    /// Explicit per-kind commands")
quick_new_agent = slice_between("    /// Explicit per-kind commands fix the kind", "\n    /// Select the new pane. All Spaces")
reveal_created = slice_between("    /// Select the new pane. All Spaces", "\n    func startNewTerminal(")
start_new_terminal = slice_between("    func startNewTerminal(", "\n    /// New Agent:")
start_new_agent = slice_between("    func startNewAgent(", "\n    // MARK: - Retained empty spaces")
for name, chunk in [
    ("quickNewTerminal", quick_new_terminal),
    ("asksForNewSessionSpace", quick_new_terminal),
    ("createNewSession", create_new_session),
    ("quickNewAgent", quick_new_agent),
    ("revealCreatedSession", reveal_created),
    ("selectSpace", select_space),
    ("isFilteredOut", filtering),
]:
    assert name in chunk, f"slice marker drifted for {name}"
assert "revealCreatedSession(" in start_new_terminal and "revealCreatedSession(" in start_new_agent
assert "waitForStartedAgent(" in start_new_agent
assert "startingPanes.insert" in start_new_agent
assert "selectedSpace = SpaceRef" not in start_new_terminal
assert "selectedSpace = SpaceRef" not in start_new_agent

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
        create_new_session,
        agent_bypass,
        quick_new_agent,
        reveal_created,
    ]
)

harness = '''import AppKit
import Foundation
import SwiftUI

enum SidebarSectionID { static let spacesHiddenKey = "sidebar.spacesHidden" }
struct PaneRef: Hashable { let deviceID: UUID; let paneID: String }
struct SpaceRef: Hashable, Codable { let deviceID: UUID; let workspaceID: String }
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
enum NewSessionType: Equatable {
    case choose, terminal
    case agent(String)
}

@MainActor final class Model {
    var devices: [Device] = []
    var deviceFilter: UUID?
    static let selectedSpaceKey = "session.selectedSpace"
    var prioritySessionsEnabled = false
    var newSession: NewSessionType?
    var selectedPane: PaneRef?
    var selectedShellID: UUID?
    var shellSessions: [ShellSession] = []
    var lastPaneBySpace: [SpaceRef: PaneRef] = [:]
    var attachSessions: [AttachedStub] = []
    var panesByWorkspace: [String: [PaneRef]] = [:]
    var selectedAttachedEntry: AttachedStub? {
        guard let selectedPane, let device = device(selectedPane.deviceID),
              let workspaceID = panesByWorkspace.first(where: { $0.value.contains(selectedPane) })?.key
        else { return nil }
        return AttachedStub(device: device, workspaceID: workspaceID)
    }
    struct PiLaunch { var presented = true }
    var piLaunch: PiLaunch?
    var isFileManagerActive = false
    var actionError: String?
    var started: [(UUID, String)] = []
    var shells: [UUID] = []
    var launched: [(UUID, String, String?)] = []
    var focusRequests = 0
    private var states: [UUID: DeviceState] = [:]

    func stubWorkspaces(_ id: UUID, _ ids: [String]) {
        states[id] = DeviceState(workspaces: ids.map { WorkspaceInfo(workspaceID: $0) })
    }
    func session(_ id: UUID) -> DeviceState { states[id] ?? DeviceState() }
    func device(_ id: UUID) -> Device? { devices.first { $0.id == id } }
    var visibleAgents: [AgentEntryStub] {
        if let space = selectedSpace {
            return (panesByWorkspace[space.workspaceID] ?? []).map { AgentEntryStub(ref: $0) }
        }
        return panesByWorkspace.values.flatMap { $0 }.map { AgentEntryStub(ref: $0) }
    }
    var visibleTerminals: [AgentEntryStub] { [] }
    var visibleSessions: [AgentEntryStub] { visibleAgents + visibleTerminals }
    var firstVisiblePaneRef: PaneRef? { visibleSessions.first?.ref }
    func preferredVisibleAgent() -> AgentEntryStub? { nil }
    func startNewTerminal(device: Device, workspaceID: String, rootPaneID: String? = nil) {
        started.append((device.id, workspaceID))
    }
    func newShellSession(on device: Device) { shells.append(device.id) }
    func startNewAgent(device: Device, kind: String, workspaceID: String?, bypass: Bool, rootPaneID: String? = nil) {
        launched.append((device.id, kind, workspaceID))
    }
    func refresh(_ id: UUID) async {}
    func actionErrorMessage(_ error: Error, device: Device) -> String { "failed" }
    func requestCreatedSessionFocus() { focusRequests += 1 }

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

        // Leaving a space remembers its last session as an id only; the old
        // attach is dropped and coming back reloads that session.
        let first = PaneRef(deviceID: local.id, paneID: "w1:p1")
        let second = PaneRef(deviceID: local.id, paneID: "w1:p2")
        let other = PaneRef(deviceID: local.id, paneID: "w2:p1")
        model.panesByWorkspace = ["w1": [first, second], "w2": [other]]
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
        model.selectedPane = second
        model.attachSessions = [AttachedStub(device: local, workspaceID: "w1")]
        model.selectSpace(SpaceRef(deviceID: local.id, workspaceID: "w2"))
        assert(model.selectedPane == other, "a new space falls back to its first visible session")
        assert(!model.attachSessions.isEmpty, "leaving a space preserves live split PTYs")
        assert(model.lastPaneBySpace[SpaceRef(deviceID: local.id, workspaceID: "w1")] == second)
        model.selectSpace(SpaceRef(deviceID: local.id, workspaceID: "w1"))
        assert(model.selectedPane == second, "returning restores the last session")
        model.panesByWorkspace["w1"] = [first]
        model.selectSpace(SpaceRef(deviceID: local.id, workspaceID: "w2"))
        model.selectSpace(SpaceRef(deviceID: local.id, workspaceID: "w1"))
        assert(model.selectedPane == first, "a missing last session falls back")
        model.panesByWorkspace = [:]
        model.lastPaneBySpace = [:]
        model.attachSessions = []

        // Routing: a standalone shell keeps its own New Terminal behaviour, and
        // that branch stays ahead of the sheet gate.
        model.selectedSpace = nil
        model.selectedPane = nil
        let shell = ShellSession(id: UUID(), title: "Terminal 1", device: local)
        model.shellSessions = [shell]
        model.selectedShellID = shell.id
        model.quickNewTerminal()
        assert(model.newSession == nil && model.shells == [local.id] && model.started.isEmpty,
               "an active standalone shell opens another standalone shell")

        // Routing: All Spaces has no space to create in, so ⌘T asks for one
        // instead of guessing.
        model.selectedShellID = nil
        model.shellSessions = []
        model.shells = []
        model.quickNewTerminal()
        assert(model.newSession == .terminal && model.shells.isEmpty && model.started.isEmpty,
               "All Spaces asks for the space instead of spawning a shell")

        // Routing: a selected space creates the terminal there; only the
        // selected standalone shell keeps its own New Terminal behaviour.
        model.newSession = nil
        model.selectedShellID = nil
        model.shellSessions = []
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
        model.shells = []
        model.started = []
        model.quickNewTerminal()
        assert(model.newSession == nil && model.started.count == 1
               && model.started[0].0 == local.id && model.started[0].1 == "w1" && model.shells.isEmpty,
               "a selected space creates the terminal there")
        model.shellSessions = [shell]
        model.selectedShellID = shell.id
        model.shells = []
        model.started = []
        model.quickNewTerminal()
        assert(model.shells == [local.id] && model.started.isEmpty && model.newSession == nil,
               "standalone shell bypasses the sheet")
        model.selectedShellID = nil
        model.shellSessions = []
        model.shells = []

        // A device filter never changes fixed-terminal routing; the sheet
        // revalidates the chosen space when Confirm is pressed.
        model.selectedShellID = nil
        model.shellSessions = []
        model.setDeviceFilter(remote.id)
        model.selectedSpace = nil
        model.shells = []
        model.newSession = nil
        model.quickNewTerminal()
        assert(model.newSession == .terminal && model.shells.isEmpty && model.started.isEmpty,
               "a filtered attached session still opens the terminal sheet")

        model.setDeviceFilter(nil)
        model.selectedSpace = nil
        model.newSession = nil
        model.quickNewTerminal()
        assert(model.newSession == .terminal && model.shells.isEmpty,
               "All Spaces opens the terminal sheet")

        // Priority sessions keep a remembered space that can disagree with
        // the focused session, so they ask instead of creating there.
        model.prioritySessionsEnabled = true
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
        model.newSession = nil
        model.started = []
        model.quickNewTerminal()
        assert(model.newSession == .terminal && model.started.isEmpty,
               "Priority sessions ask for the space")
        model.prioritySessionsEnabled = false

        // Per-kind shortcuts: a filtered-out space cannot start an agent,
        // so the sheet asks. A selected live space launches there.
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
        model.setDeviceFilter(remote.id)
        model.newSession = nil
        model.quickNewAgent(kind: "pi")
        assert(model.newSession == .agent("pi") && model.launched.isEmpty,
               "a filtered-out space cannot start an agent")
        model.setDeviceFilter(nil)
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
        model.newSession = nil
        model.launched = []
        model.quickNewAgent(kind: "pi")
        assert(model.newSession == nil && model.launched.count == 1
               && model.launched[0].0 == local.id && model.launched[0].1 == "pi" && model.launched[0].2 == "w1",
               "a selected space launches the agent there")

        // Creating a session from All Spaces must not steal the space filter.
        model.selectedSpace = nil
        model.selectedPane = first
        model.isFileManagerActive = true
        model.selectedShellID = UUID()
        model.focusRequests = 0
        model.revealCreatedSession(deviceID: local.id, workspaceID: "w2", paneID: "new-pane")
        assert(model.selectedSpace == nil, "All Spaces stays selected after a new session")
        assert(model.selectedPane == PaneRef(deviceID: local.id, paneID: "new-pane"))
        assert(model.selectedShellID == nil && model.isFileManagerActive == false)
        assert(model.focusRequests == 1, "new session asks the terminal to take key focus")
        model.selectedSpace = SpaceRef(deviceID: local.id, workspaceID: "w1")
        model.revealCreatedSession(deviceID: local.id, workspaceID: "w1", paneID: "w1-new")
        assert(model.selectedSpace == SpaceRef(deviceID: local.id, workspaceID: "w1"),
               "an active space filter stays on that space")
        model.revealCreatedSession(deviceID: local.id, workspaceID: "revived", paneID: "revived-pane")
        assert(model.selectedSpace == SpaceRef(deviceID: local.id, workspaceID: "revived"),
               "a revived workspace remaps the existing space filter")

        // Shortcuts: New / New Terminal / New Space / Close / Pi keep the required
        // defaults, stay remappable, and the retired general New Agent id is gone
        // rather than shadowing a live binding.
        let suite = "goose-herdr-space-route-check"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        assert(AppShortcuts.chord(for: .newItem, store: store) == KeyChord(key: "t", modifiers: .command),
               "New default is cmd-T")
        assert(AppShortcuts.chord(for: .quickNewTerminal, store: store) == KeyChord(key: "t", modifiers: [.command, .shift]),
               "New Terminal default is shift-cmd-T")
        assert(AppShortcuts.chord(for: .newSpace, store: store) == KeyChord(key: "n", modifiers: .command),
               "New Space default is cmd-N")
        assert(AppShortcuts.chord(for: .close, store: store) == KeyChord(key: "w", modifiers: .command),
               "Close default is cmd-W")
        assert(AgentKindShortcuts.chord(for: "pi", store: store) == KeyChord(key: "p", modifiers: .option),
               "Pi default is option-P")
        assert(AgentKindShortcuts.chord(for: "codex", store: store) == nil,
               "other agents stay unbound")
        assert(AppShortcutID.allCases.first == .newItem, "New is listed above New Terminal")
        assert(AppShortcutID.allCases.map { $0.rawValue }.sorted() == [
            "close", "equalizeSplits", "focusDown", "focusLeft", "focusRight", "focusUp",
            "growPane", "narrowPane", "newItem", "newSpace", "quickNewTerminal", "search", "settings",
            "shrinkPane", "splitHorizontal", "splitVertical", "swapDown", "swapLeft",
            "swapRight", "swapUp", "toggleSidebar", "widenPane"
        ], "the general shortcut set includes New plus every split command and no retired New Agent command")
        assert(AppShortcutID.primaryCases.map(\.rawValue) == [
            "newItem", "quickNewTerminal", "newSpace", "search", "settings", "toggleSidebar", "close",
            "splitVertical", "splitHorizontal"
        ], "everyday shortcuts stay in the always-visible General list")
        assert(AppShortcutID.advancedCases.map(\.rawValue) == [
            "focusLeft", "focusRight", "focusUp", "focusDown",
            "swapLeft", "swapRight", "swapUp", "swapDown",
            "widenPane", "narrowPane", "growPane", "shrinkPane",
            "equalizeSplits"
        ], "pane focus, swap, and resize stay collapsed under Advanced")

        assert(Set(AppShortcutID.allCases.map { $0.defaultChord }).count == AppShortcutID.allCases.count)
        for (id, focus) in [(AppShortcutID.swapLeft, AppShortcutID.focusLeft), (.swapRight, .focusRight), (.swapUp, .focusUp), (.swapDown, .focusDown)] {
            assert(id.defaultChord.modifiers == [.command, .option, .shift])
            assert(id.defaultChord.key == focus.defaultChord.key)
            assert(AppShortcuts.isChordTaken(id.defaultChord, excludingGeneral: id, store: store) == nil)
            assert(AppShortcuts.isChordTaken(id.defaultChord, excludingGeneral: .close, store: store) == id.conflictLabel)
            let custom = KeyChord(key: "s", modifiers: [.command, .shift])
            AppShortcuts.set(custom, for: id, store: store)
            assert(AppShortcuts.chord(for: id, store: store) == custom)
            AppShortcuts.reset(id, store: store)
            assert(AppShortcuts.chord(for: id, store: store) == id.defaultChord)
        }
        let legacyStore = ["quickNewAgent": KeyChord(key: "n", modifiers: [.command, .shift]),
                           "newAgent": KeyChord(key: "a", modifiers: [.command])]
        store.set(try! JSONEncoder().encode(legacyStore), forKey: AppShortcuts.storageKey)
        assert(AppShortcuts.chord(for: .quickNewTerminal, store: store) == KeyChord(key: "t", modifiers: [.command, .shift]),
               "a retired New Agent entry does not shadow New Terminal")
        AppShortcuts.set(KeyChord(key: "j", modifiers: [.command, .shift]), for: .quickNewTerminal, store: store)
        AppShortcuts.set(KeyChord(key: "b", modifiers: [.command, .control]), for: .newSpace, store: store)
        assert(AppShortcuts.chord(for: .quickNewTerminal, store: store) == KeyChord(key: "j", modifiers: [.command, .shift]),
               "custom terminal binding survives")
        assert(AppShortcuts.display(for: .quickNewTerminal, store: store) == "\\u{21E7}\\u{2318}J",
               "menus and help show the custom binding")
        store.removePersistentDomain(forName: suite)
        defaults.removeObject(forKey: SidebarSectionID.spacesHiddenKey)
        defaults.removeObject(forKey: Model.selectedSpaceKey)
        print("PASS: hidden-space scope, last-session restore, filter-safe routing, shortcut boundaries")
    }
}
'''

# Static boundaries a compiled slice cannot see.
all_sources = "\n".join(p.read_text() for p in (ROOT / "Sources").rglob("*.swift"))
for stale in [
    "sessionsHiddenKey", "sessionsExpandedKey", "agentsHiddenKey", "terminalsHiddenKey",
    "showNewAgent", "NewAgentSheet", "NewTerminalSheet", "NewTerminalSpaceSheet",
    "showNewTerminalSpacePicker",
]:
    assert stale not in all_sources, f"removed sidebar/agent-picker wiring came back: {stale}"
assert "func quickNewAgent(kind: String)" in source, "per-kind agent launch must stay"
assert "func createNewItem(space:" in source, "New panel creates in the chosen space"
assert "showNewItem" in source, "New panel is a distinct sheet flag"
assert "case newItem" in shortcuts, "New is a general shortcut above New Terminal"
assert commands.index('Button("New") { focusedModel?.showNewItem = true }') < commands.index(
    'Button("New Terminal") { focusedModel?.quickNewTerminal() }'
), "File menu lists New above New Terminal"
assert "func createNewSession(" in source, "the New Session sheet confirms through one path"
assert 'newSession = .choose' in (ROOT / "Sources/GooseAgent/SidebarView.swift").read_text(), (
    "the Priority sessions header plus opens the session sheet"
)
assert "func revealCreatedSession(" in source, "created sessions share one reveal path"
assert "0.5" in source[source.index("func requestCreatedSessionFocus("):source.index("func focusSplit(")], "slow attach needs a late focus retry"
root_view = (ROOT / "Sources/GooseAgent/ContentView.swift").read_text()
assert "struct NewItemSheet" in root_view, "New panel lives next to New Space"
become_key = root_view.split("NSWindow.didBecomeKeyNotification", 1)[1]
assert "pendingCreatedSessionFocus = false" not in become_key.split("private func paneHandleInset", 1)[0], "key-window noise must not flush created-session focus"
activate = slice_between("    func activateSpace(", "\n    /// Best-effort root path")
assert "selectSpace(ref)" in activate and "reviveRetainedSpace(" not in activate, (
    "empty-space click must keep the placeholder, not spawn a terminal"
)
assert "Create first: closing the last pane" not in source, "last-tab close must not spawn a replacement"
root_view = (ROOT / "Sources/GooseAgent/ContentView.swift").read_text()
assert ".onChange(of: spacesHidden, initial: true)" in root_view
assert "model.synchronizeSpaceVisibility()" in root_view
sidebar = (ROOT / "Sources/GooseAgent/SidebarView.swift").read_text()
assert "if !spacesHidden {" in sidebar
assert 'Toggle("Spaces"' in (ROOT / "Sources/GooseAgent/GooseAgentApp.swift").read_text()
catalog = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text())["strings"]
for gone in ["New Agent", "New Agent…", "Hide Sessions", "Default agent", "Show in New Agent",
            "No terminals — click to create one",
            "This space has no terminals. Click the space name to create one."]:
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
