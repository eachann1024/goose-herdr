#!/usr/bin/env python3
"""Regression: python3 Tests/UnreadSelectionTests.py (requires Swift)."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/AppModel.swift").read_text()
start = source.index("    @Published var selectedPane:")
selection = source[start:source.index("    /// Kept-alive attaches", start)]
selection = selection.replace("@Published ", "").replace("UserDefaults.standard", "defaults")
pane = source[source.index("struct PaneRef:"):source.index("\nstruct SpaceRef:")]
harness = r'''
import Foundation
''' + pane + r'''
struct AgentUnreadKey: Hashable { let deviceID: UUID; let paneID: String }
class Model {
    let defaults = UserDefaults(suiteName: "unread-selection-" + UUID().uuidString)!
    var unreadAgents: Set<AgentUnreadKey> = []
    func noteSelectedAttachSession() {}
''' + selection + r'''
}
let model = Model()
let device = UUID()
let a = PaneRef(deviceID: device, paneID: "a")
let b = PaneRef(deviceID: device, paneID: "b")
let ak = AgentUnreadKey(deviceID: device, paneID: "a")
let bk = AgentUnreadKey(deviceID: device, paneID: "b")
let other = AgentUnreadKey(deviceID: UUID(), paneID: "b")
model.selectedPane = a
model.unreadAgents = [ak, bk, other]
model.selectedPane = b
assert(model.unreadAgents == [other], "switching clears both visited panes, not another device")
model.unreadAgents.insert(bk)
assert(model.unreadAgents.contains(bk), "completion on the current pane remains noticeable")
model.selectedPane = b
assert(model.unreadAgents == [other], "clicking the current pane acknowledges completion")
model.selectedPane = nil
model.unreadAgents.insert(ak)
model.selectedPane = a
assert(model.unreadAgents == [other], "opening from no selection acknowledges completion")
model.unreadAgents.insert(ak)
model.selectedPane = nil
assert(model.unreadAgents == [other], "leaving a completed pane still clears its flag")
print("PASS: opening, reselecting and leaving acknowledge completion with device isolation")
'''
with tempfile.TemporaryDirectory(prefix="unread-selection-") as directory:
    swift = Path(directory) / "Check.swift"
    swift.write_text(harness)
    subprocess.run(["swift", str(swift)], check=True)
