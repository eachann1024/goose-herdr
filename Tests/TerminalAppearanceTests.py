#!/usr/bin/env python3
"""Run the linked Ghostty engine, not source-string assertions. Requires make build."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
products = root / "build/Build/Products/Debug"
source = (root / "Sources/GooseAgent/TerminalView.swift").read_text()
config = source.split("    static var appearanceConfigSource: TerminalController.ConfigSource {", 1)[1].split(
    "    /// Font settings", 1
)[0]
appearance = source.split("    // SwiftUI's scheme must reach the surface", 1)[1].split(
    "    // Colors are theme-only", 1
)[0]
appearance = appearance[appearance.index("    view.appearance ="):].replace(
    "GhosttyRuntime.controller", "controller"
)
swift = r'''
import AppKit
import GhosttyTerminal

final class Replies: @unchecked Sendable {
    let lock = NSLock()
    var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    func take() -> String {
        lock.lock(); defer { lock.unlock() }
        defer { bytes.removeAll() }
        return String(decoding: bytes, as: UTF8.self)
    }
}
@main struct Check {
    @MainActor static var appearanceConfigSource: TerminalController.ConfigSource {
CONFIG
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let controller = TerminalController(configSource: appearanceConfigSource, theme: TerminalTheme(
            light: TerminalConfiguration { $0.withBackground("#FFFFFF") },
            dark: TerminalConfiguration { $0.withBackground("#101012") }
        ))
        precondition(controller.lastConfigurationIssue == nil)
        let replies = Replies()
        let session = InMemoryTerminalSession(write: { replies.append($0) }, resize: { _ in })
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3)) }
        func send(_ text: String) { session.receive(Data(text.utf8)); pump() }
        func appearance(_ dark: Bool) {
APPEARANCE
            pump()
        }
        appearance(true)
        _ = replies.take()
        send("\u{1b}[?996n\u{1b}]11;?\u{1b}\\")
        let initial = replies.take()
        precondition(initial.contains("\u{1b}[?997;1n"), "Initial dark query: \(initial.debugDescription)")
        precondition(initial.contains("rgb:1010/1010/1212"))
        send("\u{1b}[?2031h")
        _ = replies.take()
        for dark in [false, true, false] {
            let report = "\u{1b}[?997;\(dark ? 1 : 2)n"
            appearance(dark)
            let notification = replies.take()
            precondition(notification.hasSuffix(report), "Live notification: \(notification.debugDescription)")
            send("\u{1b}[?996n\u{1b}]11;?\u{1b}\\")
            let answer = replies.take()
            precondition(answer.contains(report), "Query: \(answer.debugDescription)")
            precondition(answer.contains(dark ? "rgb:1010/1010/1212" : "rgb:ffff/ffff/ffff"))
        }
        send("\u{1b}[?2031l")
        _ = replies.take()
        appearance(true)
        precondition(replies.take().isEmpty, "Unsubscribed clients must not receive notifications")
        print("PASS: Ghostty dark/light queries, OSC 11, live notifications and unsubscribe")
        withExtendedLifetime(window) {}
    }
}
'''.replace("CONFIG", config).replace("APPEARANCE", appearance)

with tempfile.TemporaryDirectory(prefix="goose-terminal-appearance-") as directory:
    tmp = Path(directory)
    for name in ["TerminalLight.ghostty", "TerminalDark.ghostty"]:
        shutil.copy(root / "Resources" / name, tmp / name)
    shutil.copytree(products / "GhosttyKit_GhosttyTerminal.bundle", tmp / "GhosttyKit_GhosttyTerminal.bundle")
    path = tmp / "Check.swift"
    path.write_text(swift)
    executable = tmp / "check"
    subprocess.run([
        "swiftc", "-parse-as-library", str(path), "-o", str(executable),
        "-I", str(products), "-I", str(products / "include/libghostty"), "-L", str(products),
        *[str(products / f"{name}.o") for name in ["GhosttyTerminal", "GhosttyKit", "MSDisplayLink"]],
        "-lghostty", "-lc++", "-framework", "Carbon", "-framework", "Security",
    ], check=True, timeout=90)
    subprocess.run([str(executable)], check=True, timeout=20)
