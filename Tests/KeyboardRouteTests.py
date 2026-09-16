#!/usr/bin/env python3
"""Run production keyboard methods with native menus: python3 Tests/KeyboardRouteTests.py."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/TerminalView.swift").read_text()
start = source.index("    override func keyDown(with event: NSEvent)")
end = source.index("\n    // MARK: Mouse", start)
methods = source[start:end]

# ponytail: only Ghostty/PTY are stubbed; full terminal integration needs a live surface.
harness = r'''
import AppKit

final class Session {
    var bytes = Data()
    func sendInput(_ data: Data) { bytes.append(data) }
}
final class Host { let session = Session() }
class Base: NSView {
    var marked = false
    var downs = 0
    var ups = 0
    override var acceptsFirstResponder: Bool { true }
    func hasMarkedText() -> Bool { marked }
    override func keyDown(with event: NSEvent) { downs += 1 }
    override func keyUp(with event: NSEvent) { ups += 1 }
}
final class Terminal: Base {
    let processHost: Host? = Host()
    var locallyConsumedKeyCode: UInt16?
''' + methods + r'''
}
final class Target: NSObject {
    var hits = 0
    @objc func run(_ sender: Any?) { hits += 1 }
}
let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                      styleMask: [], backing: .buffered, defer: false)
let terminal = Terminal()
window.contentView = terminal
precondition(window.makeFirstResponder(terminal))
let target = Target()
let main = NSMenu()
let menu = NSMenu(title: "Agent")
menu.autoenablesItems = false
let parent = main.addItem(withTitle: "Agent", action: nil, keyEquivalent: "")
parent.submenu = menu
let pi = menu.addItem(withTitle: "Pi", action: #selector(Target.run(_:)), keyEquivalent: "p")
pi.keyEquivalentModifierMask = [.option]
pi.target = target
app.mainMenu = main

func event(_ chars: String, _ ignoring: String, _ key: UInt16,
           flags: NSEvent.ModifierFlags = [.option], type: NSEvent.EventType = .keyDown) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                    timestamp: 1, windowNumber: window.windowNumber, context: nil,
                    characters: chars, charactersIgnoringModifiers: ignoring,
                    isARepeat: false, keyCode: key)!
}
// Exercise the terminal entry point reached by Option-only events.
terminal.keyDown(with: event("π", "p", 35))
precondition(target.hits == 1 && terminal.downs == 0, "Option-P must trigger only the app command")
terminal.keyUp(with: event("π", "p", 35, type: .keyUp))
precondition(terminal.ups == 0, "consumed shortcuts must not leak a release to the PTY")
terminal.keyDown(with: event("≈", "x", 7))
precondition(target.hits == 1 && terminal.downs == 1, "unbound Option keys must reach Ghostty")
terminal.keyUp(with: event("≈", "x", 7, type: .keyUp))
precondition(terminal.ups == 1)
terminal.keyDown(with: event("", "", 51))
precondition(terminal.processHost!.session.bytes == Data([0x1b, 0x7f]), "Option-Delete keeps its editing bytes")
terminal.marked = true
terminal.keyDown(with: event("π", "p", 35))
precondition(target.hits == 1 && terminal.downs == 2, "IME composition takes priority")
terminal.marked = false
pi.isEnabled = false
terminal.keyDown(with: event("π", "p", 35))
// NSMenu reserves a disabled shortcut without invoking its action.
precondition(target.hits == 1 && terminal.downs == 2, "disabled commands must not run")
pi.isEnabled = true
pi.keyEquivalent = "x"
terminal.keyDown(with: event("π", "p", 35))
terminal.keyDown(with: event("≈", "x", 7))
precondition(target.hits == 2 && terminal.downs == 3, "remapped bindings must apply immediately")
terminal.keyDown(with: event("x", "x", 7, flags: []))
precondition(target.hits == 2 && terminal.downs == 4, "plain typing must remain terminal input")
print("PASS: terminal keyboard routing, remapping, passthrough, IME, disabled commands, key release")
'''
with tempfile.TemporaryDirectory(prefix="keyboard-route-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
