#!/usr/bin/env python3
"""Run native alignment checks: python3 Tests/TitlebarAlignmentTests.py."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/ContentView.swift").read_text()
start = source.index("private final class WindowTitlebarInteractionView")
end = source.index("\nprivate struct WindowTitlebarInteractionModifier", start)
harness = "import AppKit\n" + source[start:end] + r'''
let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                      backing: .buffered, defer: false)
window.titleVisibility = .hidden
window.titlebarAppearsTransparent = true
private let strip = WindowTitlebarInteractionView()
window.contentView!.addSubview(strip)
let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
let originalX = kinds.map { window.standardWindowButton($0)!.frame.minX }
for size in [NSSize(width: 800, height: 600), NSSize(width: 640, height: 420)] {
    window.setContentSize(size)
    // Different heights ensure alignment follows the title, not a fixed 14pt offset.
    for height: CGFloat in [28, 40] {
        strip.frame = NSRect(x: 78, y: window.contentView!.bounds.height - height,
                             width: size.width - 78, height: height)
        strip.alignsWindowButtons = true
        strip.layout()
        for (index, kind) in kinds.enumerated() {
            let button = window.standardWindowButton(kind)!
            let frame = strip.convert(button.bounds, from: button)
            assert(abs(frame.midY - strip.bounds.midY) < 0.01)
            assert(button.frame.minX == originalX[index])
        }
        let previous = kinds.map { window.standardWindowButton($0)!.frame }
        strip.alignsWindowButtons = false
        strip.frame.origin.y -= 10
        strip.layout()
        assert(kinds.map { window.standardWindowButton($0)!.frame } == previous,
               "Settings and other titlebar drag regions must not reposition buttons")
    }
}
print("Titlebar alignment passed")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "main.swift"
    path.write_text(harness)
    subprocess.run(["swift", str(path)], check=True)
