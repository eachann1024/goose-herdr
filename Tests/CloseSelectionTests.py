#!/usr/bin/env python3
"""Run AppModel's post-refresh close selection: python3 Tests/CloseSelectionTests.py."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/AppModel.swift").read_text()
start = source.index("            if let selected = selectedPane, selected.deviceID == deviceID,")
end = source.index("            if let space = selectedSpace", start)
selection = source[start:end]
assert source.index("let previousPaneOrder = visibleSessions.map") < source.index(
    "sessions[deviceID]?.agents = snapshot.agents"
), "capture sidebar order before replacing the snapshot"

harness = r'''
import Foundation
struct PaneRef: Hashable { let deviceID: UUID; let paneID: String }
struct Entry { let ref: PaneRef }
func refreshed(
    selected: PaneRef?, previousPaneOrder: [PaneRef], agents: [PaneRef],
    terminals: [PaneRef] = [], deviceID: UUID
) -> PaneRef? {
    var selectedPane = selected
    let visibleSessions = (agents + terminals).map { Entry(ref: $0) }
    let paneIDs = Set((agents + terminals).filter { $0.deviceID == deviceID }.map(\.paneID))
''' + selection + r'''
    return selectedPane
}
let device = UUID()
let other = UUID()
let a = PaneRef(deviceID: device, paneID: "a")
let b = PaneRef(deviceID: device, paneID: "b")
let c = PaneRef(deviceID: device, paneID: "c")
let remote = PaneRef(deviceID: other, paneID: "b")
// First/middle closes go down; closing the last goes up.
assert(refreshed(selected: a, previousPaneOrder: [a,b,c], agents: [b,c], deviceID: device) == b)
assert(refreshed(selected: b, previousPaneOrder: [a,b,c], agents: [a,c], deviceID: device) == c)
assert(refreshed(selected: c, previousPaneOrder: [a,b,c], agents: [a,b], deviceID: device) == b)
// A snapshot may remove multiple neighbors at once.
assert(refreshed(selected: a, previousPaneOrder: [a,b,c], agents: [c], deviceID: device) == c)
assert(refreshed(selected: c, previousPaneOrder: [a,b,c], agents: [a], deviceID: device) == a)
// Closing a background row (or a failed close) must not change selection.
assert(refreshed(selected: b, previousPaneOrder: [a,b,c], agents: [b,c], deviceID: device) == b)
assert(refreshed(selected: a, previousPaneOrder: [a,b,c], agents: [a,b,c], deviceID: device) == a)
// Agent-to-terminal boundary follows the same visible sidebar order.
assert(refreshed(selected: b, previousPaneOrder: [a,b,c], agents: [a], terminals: [c], deviceID: device) == c)
// Device-qualified identities, scoped lists, restored/missing selections and empty state.
assert(refreshed(selected: b, previousPaneOrder: [a,b,remote], agents: [a,remote], deviceID: device) == remote)
assert(refreshed(selected: remote, previousPaneOrder: [a,remote], agents: [a], deviceID: device) == remote)
assert(refreshed(selected: b, previousPaneOrder: [b,c], agents: [c], deviceID: device) == c)
assert(refreshed(selected: a, previousPaneOrder: [], agents: [b], deviceID: device) == nil)
assert(refreshed(selected: a, previousPaneOrder: [a], agents: [], deviceID: device) == nil)
assert(refreshed(selected: nil, previousPaneOrder: [], agents: [b], deviceID: device) == nil)
print("PASS: close selects next sidebar row, then previous; preserves live selection")
'''
with tempfile.TemporaryDirectory(prefix="close-selection-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
