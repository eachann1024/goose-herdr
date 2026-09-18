#!/usr/bin/env python3
"""⌃1…9,0 space slot mapping: python3 Tests/SpaceSwitchIndexTests.py."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Sources/GooseAgent/SessionIndexHints.swift").read_text()
app_model = (ROOT / "Sources/GooseAgent/AppModel.swift").read_text()
sidebar = (ROOT / "Sources/GooseAgent/SidebarView.swift").read_text()
commands = (ROOT / "Sources/GooseAgent/GooseAgentApp.swift").read_text()
catalog = json.loads((ROOT / "Resources/Localizable.xcstrings").read_text())["strings"]

start = source.index("enum SpaceSwitchIndex {")
end = source.index("\n@MainActor\nfinal class SessionIndexHintController")
mapping = source[start:end]
assert "index == 9 ? 0" in mapping
assert "isShowingSpaces" in source
assert "isControlOnly" in source
assert "func spaceSwitchNumber(for ref: SpaceRef?)" in app_model
assert "func selectSwitchableSpace(number: Int)" in app_model
assert "isShowingSpaces" in sidebar
assert "spaceSwitchNumber(for: nil)" in sidebar
assert "spaceSwitchNumber(for: entry.ref)" in sidebar
command = source[source.index("case .command:"):source.index("case .control:")]
assert "isShowingSpaces = true" not in command
space_row = sidebar[sidebar.index("private struct SpaceRowView"):sidebar.index("struct SpinnerView")]
assert space_row.index("ProjectSpaceIcon(") < space_row.index("SidebarSessionIndexSlot(")
assert space_row.index("SpaceAttentionGlyph(") < space_row.index("SidebarSessionIndexSlot(")
assert "keepsStatus" not in space_row
count_slot = space_row[space_row.index("SidebarSessionIndexSlot("):space_row.index(".padding(.horizontal, 8)")]
assert 'Text("\\(model.agentCount(in: entry))")' in count_slot
assert "if !isEmpty" not in count_slot  # Empty spaces keep their zero and shortcut anchor.

for number in list("1234567890"):
    label = f"Go to Space {number}"
    assert f'selectSwitchableSpace(number: {number})' in commands
    assert f'.keyboardShortcut("{number}", modifiers: .control)' in commands
    assert catalog[label]["localizations"]["en"]["stringUnit"]["value"] == label
    assert catalog[label]["localizations"]["zh-Hans"]["stringUnit"]["value"] == f"切换到空间 {number}"

harness = r'''
import Foundation
''' + mapping + r'''
@main struct Check {
    static func main() {
        precondition(SpaceSwitchIndex.number(forIndex: 0, count: 0) == nil)
        precondition(SpaceSwitchIndex.index(forNumber: 1, count: 0) == nil)

        for index in 0..<6 {
            precondition(SpaceSwitchIndex.number(forIndex: index, count: 6) == index + 1)
        }
        precondition(SpaceSwitchIndex.number(forIndex: 6, count: 6) == nil)
        precondition(SpaceSwitchIndex.index(forNumber: 6, count: 6) == 5)
        precondition(SpaceSwitchIndex.index(forNumber: 7, count: 6) == nil)
        precondition(SpaceSwitchIndex.index(forNumber: 0, count: 6) == nil)
        precondition(SpaceSwitchIndex.index(forNumber: 9, count: 6) == nil)

        for index in 0..<9 {
            precondition(SpaceSwitchIndex.number(forIndex: index, count: 9) == index + 1)
        }
        precondition(SpaceSwitchIndex.index(forNumber: 0, count: 9) == nil)

        for index in 0..<9 {
            precondition(SpaceSwitchIndex.number(forIndex: index, count: 10) == index + 1)
        }
        precondition(SpaceSwitchIndex.number(forIndex: 9, count: 10) == 0)
        precondition(SpaceSwitchIndex.index(forNumber: 0, count: 10) == 9)
        precondition(SpaceSwitchIndex.index(forNumber: 1, count: 10) == 0)

        for index in 0..<9 {
            precondition(SpaceSwitchIndex.number(forIndex: index, count: 14) == index + 1)
        }
        precondition(SpaceSwitchIndex.number(forIndex: 9, count: 14) == 0)
        precondition(SpaceSwitchIndex.number(forIndex: 10, count: 14) == nil)
        precondition(SpaceSwitchIndex.number(forIndex: 13, count: 14) == nil)
        precondition(SpaceSwitchIndex.index(forNumber: 0, count: 14) == 9)
        precondition(SpaceSwitchIndex.index(forNumber: 10, count: 14) == nil)
        precondition(SpaceSwitchIndex.index(forNumber: 9, count: 14) == 8)
    }
}
'''

with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "SpaceSwitchIndexTests.swift"
    path.write_text(harness)
    subprocess.check_call(["swiftc", "-parse-as-library", str(path), "-o", str(Path(tmp) / "check")])
    subprocess.check_call([str(Path(tmp) / "check")])
print("ok")
