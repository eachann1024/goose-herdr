#!/usr/bin/env python3
"""New Session sheet routing: python3 Tests/NewSessionSheetTests.py.

Compiles the real AppModel routing (quickNewTerminal, the sheet's default space,
its confirm) and the real visible-spaces scope against small stubs, the same way
Tests/SpaceRouteTests.py does.
"""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Sources/GooseAgent/AppModel.swift").read_text()
content = (ROOT / "Sources/GooseAgent/ContentView.swift").read_text()

def extract(start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

space_entry = extract("    struct SpaceEntry: Identifiable {", "\n    var visibleSpaces")
filtered_device = extract("    var filteredDevice: Device? {", "\n\n    private var devicesInScope")
devices_in_scope = extract("    private var devicesInScope: [Device] {", "\n    /// Aggregate connection state")
visible_spaces = extract("    var visibleSpaces: [SpaceEntry] {", "\n    /// Agents across the scope")
is_filtered_out = extract("    private func isFilteredOut(", "\n    /// When jumping into a space")
priority = extract("    static let prioritySessionsKey", "\n    func sessionAttention(")
sheet = extract("    /// ⌘T asks for a space only in All Spaces or Priority sessions", "\n    /// Select the new pane. All Spaces")

for name, chunk in [
    ("quickNewTerminal", sheet),
    ("asksForNewSessionSpace", sheet),
    ("newSessionDefaultSpace", sheet),
    ("createNewSession", sheet),
    ("quickNewAgent", sheet),
    ("prioritySessionsEnabled", priority),
    ("visibleSpaces", visible_spaces),
    ("isFilteredOut", is_filtered_out),
]:
    assert name in chunk, f"slice marker drifted for {name}"

# The sheet opens only when All Spaces / Priority sessions / a vanished filter
# leave the destination unknown. A selected live space creates immediately.
gate = sheet[sheet.index("func quickNewTerminal"):sheet.index("/// Space the sheet")]
assert "asksForNewSessionSpace" in gate
assert "newSession = .terminal" in gate
assert "createNewSession(in: selectedSpace, type: .terminal)" in gate
assert "startNewTerminal(" not in gate
# A per-kind shortcut asks only when the space is not already chosen.
assert "createNewSession(in: selectedSpace, type: .agent(kind))" in sheet
# Confirm re-resolves the space, forwards the fresh root shell and never invents a space.
confirm = sheet[sheet.index("func createNewSession("):sheet.index("/// `agent.bypassDefault`")]
assert "visibleSpaces.first(where: { $0.ref == ref })" in confirm
assert "rootPaneID" in confirm and "agentBypass(for: kind)" in confirm
assert "selectedSpace" not in confirm and "firstVisiblePaneRef" not in confirm
# The default never guesses the list head.
default = sheet[sheet.index("var newSessionDefaultSpace"):sheet.index("/// Sheet confirm")]
assert "return nil" in default and "spaces.first" not in default

# The sheet carries all of it: cards, the in-place space form, the catalog.
assert ".sheet(item: $model.newSession) { request in NewSessionSheet(model: model, request: request) }" in content
view = content[content.index("private struct NewSessionSheet: View"):content.index("struct NewSpaceListing:")]
assert "model.newSessionDefaultSpace" in view, "the default comes from the model"
assert "model.visibleSpaces" in view, "options come from the live space list"
assert "model.createNewSession(in: space, type: type, rootPaneID: rootPaneID)" in view, "confirm routes through the model"
assert ".disabled(!canCreate)" in view, "no live space or agent disables confirm"
assert "isCreatingSpace" in view and "guard !isCreatingSpace" in view, "a second create cannot start"
assert "SheetLayout.medium" in view and "SheetLayout.narrow" not in view
assert "SheetCardMetrics" in view
assert "List(selection" not in view, "space cards, not a native blue-selection list"
assert "DirectoryPickerField(" in view and "model.createSpace(" in view, "the existing form opens in place"
assert ".sheet(" not in view, "the space form is not a second sheet"
assert ".keyboardShortcut(showsNewSpaceForm ? nil : .defaultAction)" in view, "Return belongs to the open form"
assert ".keyboardShortcut(.cancelAction)" in view
assert "AgentKindLabel.display(" in view and "AgentKindOrder.visibleSorted(" in view, "kinds come from the catalog"
assert "model.session(device.id).agentCatalog" in view
assert 'case "claude"' not in view and 'case "pi"' not in view, "no hardcoded kind list in the sheet"

catalog = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text())["strings"]
for key in [
    "New Session", "Choose a space and what to open in it", "Choose a space for the new agent",
    "SPACE", "TYPE", "Create a space on this device before opening a session.",
    "That space no longer exists", "Loading agents…", "No agents available on this device",
    "%@ is not available on this device", "Choose a space for the new terminal",
    "Create", "Cancel", "Terminal", "New Space", "Defaults to the folder name",
]:
    for language in ["en", "zh-Hans"]:
        assert catalog[key]["localizations"][language]["stringUnit"]["value"], f"{key} missing {language}"
assert "Create a space on this device before opening a terminal." not in catalog, "dead copy came back"

harness = r'''
import Foundation

enum SidebarSectionID { static let spacesHiddenKey = "sidebar.spacesHidden" }
enum NewSessionType: Equatable {
    case choose, terminal
    case agent(String)
}
struct SpaceRef: Hashable { let deviceID: UUID; let workspaceID: String }
struct Device: Equatable {
    let id: UUID
    let name: String
    static let local = Device(id: UUID(), name: "Local")
}
struct WorkspaceInfo { let workspaceID: String; let label: String }
struct DeviceState { var workspaces: [WorkspaceInfo] = [] }
struct ShellSession { let id: UUID; let device: Device }
struct SessionStub { let device: Device; let workspaceID: String }
enum HerdrService { static func bypassFlags(for kind: String) -> [String]? { kind == "pi" ? ["--yolo"] : nil } }

class Model {
    let defaults: UserDefaults
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    var devices: [Device] = []
    var deviceFilter: UUID?
    var selectedSpace: SpaceRef?
    var selectedAttachedEntry: SessionStub?
    var selectedShell: ShellSession?
    var newSession: NewSessionType?
    var terminals: [(UUID, String, String?)] = []
    var agents: [(UUID, String, String, Bool, String?)] = []
    var shells: [UUID] = []
    private var spaces: [UUID: [WorkspaceInfo]] = [:]

    func stubSpaces(_ id: UUID, _ ids: [String]) {
        spaces[id] = ids.map { WorkspaceInfo(workspaceID: $0, label: $0) }
    }
    func session(_ id: UUID) -> DeviceState { DeviceState(workspaces: spaces[id] ?? []) }
    func device(_ id: UUID) -> Device? { devices.first { $0.id == id } }
    func startNewTerminal(device: Device, workspaceID: String, rootPaneID: String? = nil) {
        terminals.append((device.id, workspaceID, rootPaneID))
    }
    func startNewAgent(device: Device, kind: String, workspaceID: String?, bypass: Bool, rootPaneID: String? = nil) {
        agents.append((device.id, kind, workspaceID ?? "", bypass, rootPaneID))
    }
    func newShellSession(on device: Device) { shells.append(device.id) }
''' + "\n".join(
    chunk.replace("@Published ", "").replace("private ", "").replace("UserDefaults.standard", "defaults")
    for chunk in [space_entry, filtered_device, devices_in_scope, visible_spaces,
                  is_filtered_out, priority, sheet]
) + r'''
}
''' + r'''
let suite = "new-session-sheet-check-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let model = Model(defaults)
let local = Device(id: UUID(), name: "Local")
let remote = Device(id: UUID(), name: "Remote")
model.devices = [local, remote]
model.stubSpaces(local.id, ["w1", "w2"])
model.stubSpaces(remote.id, ["w1"])
func ref(_ device: Device, _ workspace: String) -> SpaceRef {
    SpaceRef(deviceID: device.id, workspaceID: workspace)
}
func attached(_ device: Device, _ workspace: String) -> SessionStub {
    SessionStub(device: device, workspaceID: workspace)
}

// Priority sessions: the remembered filter sits on w1 while the selected session
// lives in w2 — the sheet defaults to the session and creates nothing yet.
defaults.set(true, forKey: Model.prioritySessionsKey)
model.selectedSpace = ref(local, "w1")
model.selectedAttachedEntry = attached(local, "w2")
assert(model.prioritySessionsEnabled)
assert(model.newSessionDefaultSpace == ref(local, "w2"), "the selected session's space beats the stale filter")
model.quickNewTerminal()
assert(model.newSession == .terminal && model.terminals.isEmpty, "Priority sessions asks instead of creating in the filter's space")
model.createNewSession(in: model.newSessionDefaultSpace, type: .terminal)
assert(model.terminals.count == 1 && model.terminals[0].0 == local.id && model.terminals[0].1 == "w2")
assert(model.terminals[0].2 == nil, "a space the sheet did not create has no root pane to reuse")
assert(model.shells.isEmpty)

// Cross-host selection wins even when workspace IDs collide.
model.selectedAttachedEntry = attached(remote, "w1")
assert(model.newSessionDefaultSpace == ref(remote, "w1"))
model.terminals = []
model.createNewSession(in: model.newSessionDefaultSpace, type: .terminal)
assert(model.terminals.map { $0.0 } == [remote.id])
model.deviceFilter = local.id
assert(model.newSessionDefaultSpace == ref(local, "w1"), "filtered-out selection is never a default")
model.deviceFilter = nil

// A selected space is already the destination; skip the sheet.
defaults.set(false, forKey: Model.prioritySessionsKey)
model.selectedAttachedEntry = nil
model.selectedSpace = ref(local, "w1")
model.newSession = nil
model.terminals = []
assert(!model.asksForNewSessionSpace)
model.quickNewTerminal()
assert(model.newSession == nil && model.terminals.count == 1
       && model.terminals[0].0 == local.id && model.terminals[0].1 == "w1",
       "a selected space creates the terminal there")
assert(model.newSessionDefaultSpace == ref(local, "w1"), "a valid remembered space is the fallback")

// All Spaces with a focused session: the same sheet, defaulting to that session.
defaults.set(true, forKey: Model.prioritySessionsKey)
model.selectedAttachedEntry = attached(local, "w2")
model.selectedSpace = nil
model.newSession = nil
model.terminals = []
model.quickNewTerminal()
assert(model.newSession == .terminal && model.terminals.isEmpty, "All Spaces asks for the space")
assert(model.newSessionDefaultSpace == ref(local, "w2"), "the global default is the current session")

// With no focused session and no valid remembered space nothing is preselected.
model.selectedAttachedEntry = nil
model.selectedSpace = nil
assert(model.newSessionDefaultSpace == nil, "no context means no guessed space")
assert(model.visibleSpaces.count == 3, "the options stay every space of the scope")
model.selectedAttachedEntry = attached(remote, "gone")
assert(model.newSessionDefaultSpace == nil, "a session in a vanished space is not the default")

// An active standalone shell keeps its own New Terminal behaviour.
model.selectedShell = ShellSession(id: UUID(), device: local)
model.selectedAttachedEntry = attached(local, "w2")
model.selectedSpace = ref(local, "w1")
model.newSession = nil
model.terminals = []
model.shells = []
model.quickNewTerminal()
assert(model.newSession == nil && model.shells == [local.id] && model.terminals.isEmpty,
       "the standalone shell path is untouched")
assert(model.newSessionDefaultSpace == ref(local, "w1"), "the hidden attached pane is not a default")
model.selectedShell = nil

// Per-kind shortcuts: Priority still asks; a selected space launches there.
defaults.set(true, forKey: Model.prioritySessionsKey)
model.selectedSpace = ref(local, "w1")
model.selectedAttachedEntry = attached(local, "w2")
model.newSession = nil
model.agents = []
model.quickNewAgent(kind: "codex")
assert(model.newSession == .agent("codex") && model.agents.isEmpty,
       "Priority sessions ask for the space")
defaults.set(false, forKey: Model.prioritySessionsKey)
model.newSession = nil
model.quickNewAgent(kind: "codex")
assert(model.newSession == nil && model.agents.count == 1
       && model.agents[0].0 == local.id && model.agents[0].1 == "codex" && model.agents[0].2 == "w1",
       "a selected space launches the agent there")

// Confirm forwards the root shell of the space this sheet created.
model.agents = []
let created = ref(local, "w2")
model.createNewSession(in: created, type: .agent("pi"), rootPaneID: "w2:p1")
assert(model.agents.count == 1)
assert(model.agents[0].0 == local.id && model.agents[0].1 == "pi" && model.agents[0].2 == "w2")
assert(model.agents[0].3 && model.agents[0].4 == "w2:p1", "bypass default plus the fresh root pane")
model.createNewSession(in: created, type: .terminal, rootPaneID: "w2:p1")
assert(model.terminals.last?.2 == "w2:p1", "a terminal in the new space reveals its own root shell")

// Bypass off, or a kind with no skip-permissions flag, starts without args.
defaults.set(false, forKey: "agent.bypassDefault")
model.createNewSession(in: created, type: .agent("pi"))
assert(model.agents.last?.3 == false)
defaults.removeObject(forKey: "agent.bypassDefault")
model.createNewSession(in: created, type: .agent("codex"))
assert(model.agents.last?.3 == false)

// A space that closed while the sheet was open, or an unresolved type, creates nothing.
model.terminals = []
model.agents = []
model.createNewSession(in: nil, type: .terminal)
model.createNewSession(in: ref(local, "gone"), type: .terminal)
model.createNewSession(in: created, type: .choose)
assert(model.terminals.isEmpty && model.agents.isEmpty, "no live space means no session")
print("PASS: New Session default space, gate, root-pane reuse and confirm re-validation")
'''
with tempfile.TemporaryDirectory(prefix="new-session-sheet-") as directory:
    swift = Path(directory) / "Check.swift"
    swift.write_text(harness)
    subprocess.run(["swift", str(swift)], check=True)
