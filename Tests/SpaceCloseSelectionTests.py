#!/usr/bin/env python3
"""Run with: python3 Tests/SpaceCloseSelectionTests.py."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Sources/GooseAgent/AppModel.swift").read_text()
start = source.index("    private func selectSpaceAfterClosing(")
end = source.index("\n    func dismissRetainedSpace", start)
helper = source[start:end].replace("private func", "func", 1)

# Live closes must let snapshot reconciliation choose from the old sidebar order.
assert "selectSpaceAfterClosing(space, previousOrder: previousSpaceOrder)" in source
assert "if self.selectedSpace == entry.ref { self.selectedSpace = nil }" not in source
assert "if selectedSpace == space { selectedSpace = nil }" not in source
retained = source[end:source.index("\n    func markSpaceDismissed", end)]
assert retained.index("workspaces.removeAll") < retained.index("selectSpaceAfterClosing")

harness = r'''
struct SpaceRef: Hashable {
    let deviceID: Int
    let workspaceID: String
}
struct SpaceEntry { let ref: SpaceRef }
final class Model {
    var selectedSpace: SpaceRef?
    var visibleSpaces: [SpaceEntry] = []
    var selections = 0
    func selectSpace(_ ref: SpaceRef?) {
        selectedSpace = ref
        selections += 1
    }
''' + helper + r'''
}
let a = SpaceRef(deviceID: 1, workspaceID: "a")
let b = SpaceRef(deviceID: 1, workspaceID: "b")
let c = SpaceRef(deviceID: 1, workspaceID: "c")
let remote = SpaceRef(deviceID: 2, workspaceID: "a")
let model = Model()
func check(_ closed: SpaceRef, order: [SpaceRef], remaining: [SpaceRef], expected: SpaceRef?) {
    model.selectedSpace = closed
    model.visibleSpaces = remaining.map { SpaceEntry(ref: $0) }
    model.selectSpaceAfterClosing(closed, previousOrder: order)
    assert(model.selectedSpace == expected)
}
check(b, order: [a, b, c], remaining: [a, c], expected: c)
check(c, order: [a, b, c], remaining: [a, b], expected: b)
check(a, order: [a], remaining: [], expected: nil)
check(b, order: [a, b, c, remote], remaining: [a, remote], expected: remote)
check(b, order: [a, b, c], remaining: [a], expected: a)
check(a, order: [a, remote], remaining: [remote], expected: remote)
model.selectedSpace = c
let count = model.selections
model.selectSpaceAfterClosing(a, previousOrder: [a, c])
assert(model.selectedSpace == c && model.selections == count, "closing another space must not steal selection")
model.selectedSpace = nil
model.selectSpaceAfterClosing(a, previousOrder: [a, c])
assert(model.selectedSpace == nil && model.selections == count, "All Spaces stays selected")
print("PASS: closing a space selects next, then previous, without stealing selection")
'''
with tempfile.TemporaryDirectory(prefix="space-close-selection-") as directory:
    swift = Path(directory) / "Check.swift"
    swift.write_text(harness)
    subprocess.run(["swift", str(swift)], check=True)
