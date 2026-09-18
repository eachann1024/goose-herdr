#!/usr/bin/env python3
"""Static contract check for the root-rendered Codex-style tooltip."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
tooltip = (root / "Sources/GooseAgent/CodexTooltip.swift").read_text()
shortcuts = (root / "Sources/GooseAgent/KeyboardShortcuts.swift").read_text()
sidebar = (root / "Sources/GooseAgent/SidebarView.swift").read_text()
content = (root / "Sources/GooseAgent/ContentView.swift").read_text()

assert "struct TooltipLayer: View" in tooltip
assert ".allowsHitTesting(false)" in tooltip
assert "TooltipPlacement.origin" in tooltip
assert "TooltipDismissal.didDismiss" in tooltip
assert ".codexTooltip(id.title, shortcut: id.shortcut)" in sidebar
assert "overlayPreferenceValue(TooltipRequestKey.self)" in content
for shortcut in ("search", "settings", "toggleSidebar"):
    assert f"case {shortcut}" in shortcuts
# These user-visible bindings must not drift back to hardcoded key strings.
assert '.keyboardShortcut("b", modifiers: .command)' not in content
assert '.keyboardShortcut("k", modifiers: .command)' not in content
# Execute the production placement calculation, not a Python copy of it.
placement = tooltip.split("enum TooltipPlacement {", 1)[1].split("/// The hovered", 1)[0]
with tempfile.TemporaryDirectory() as directory:
    source = Path(directory) / "Placement.swift"
    source.write_text("import AppKit\nenum TooltipPlacement {" + placement + '''
let container = CGSize(width: 400, height: 300)
let bubble = CGSize(width: 124, height: 30)
func place(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    TooltipPlacement.origin(anchor: CGRect(x: x, y: y, width: 24, height: 24),
                            bubble: bubble, container: container)
}
assert(place(188, 100) == CGPoint(x: 138, y: 64)) // above, centered
assert(place(188, 4) == CGPoint(x: 138, y: 34))   // flips below
assert(place(0, 100).x == 6)                     // clamps left
assert(place(376, 100).x == 270)                 // clamps right
assert(place(188, 276).y == 240)                 // bottom control stays above
''')
    subprocess.run(["/usr/bin/swift", str(source)], check=True)
print("PASS: root tooltip, measured edge placement, click dismissal, and live shortcut sources")
