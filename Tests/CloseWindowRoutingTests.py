#!/usr/bin/env python3
"""⌘W dismisses Settings even when it is the main window: python3 Tests/CloseWindowRoutingTests.py."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/GooseAgentApp.swift").read_text()
start = source.index("enum CloseCommandRouting {")
end = source.index("\n@main", start)
assert "isSettingsWindow" in source[start:end]
assert "shouldDismissKeyWindow" in source[start:end]

harness = r'''
import AppKit

''' + source[start:end] + r'''

@main
struct Check {
    static func main() {
        let console = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        console.title = "Goose Agent"

        let settings = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settings.identifier = NSUserInterfaceItemIdentifier("settings")
        settings.title = String(localized: "Settings")

        let titledOnly = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        titledOnly.title = String(localized: "Settings")

        precondition(CloseCommandRouting.isSettingsWindow(settings))
        precondition(CloseCommandRouting.isSettingsWindow(titledOnly))
        precondition(!CloseCommandRouting.isSettingsWindow(console))

        // The failing case: Settings is focused, so AppKit makes it both key and main.
        precondition(
            CloseCommandRouting.shouldDismissKeyWindow(settings, main: settings),
            "⌘W must close Settings even after it becomes mainWindow"
        )
        precondition(
            CloseCommandRouting.shouldDismissKeyWindow(titledOnly, main: titledOnly),
            "title-only Settings windows must still dismiss"
        )
        precondition(
            CloseCommandRouting.shouldDismissKeyWindow(settings, main: console),
            "Settings as a non-main key window must dismiss"
        )
        precondition(
            !CloseCommandRouting.shouldDismissKeyWindow(console, main: console),
            "the focused console still peels split/tab/space"
        )
        precondition(
            CloseCommandRouting.shouldDismissKeyWindow(settings, main: nil)
        )
        precondition(
            !CloseCommandRouting.shouldDismissKeyWindow(nil, main: console)
        )
        print("PASS: ⌘W dismisses Settings instead of the console")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="close-window-routing-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
