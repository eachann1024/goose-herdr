#!/usr/bin/env python3
"""Regression: python3 Tests/AttachIdentityTests.py (requires Swift)."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/GooseAgent/AppModel.swift").read_text()
start = source.index("    enum AttachedEntry: Identifiable {")
entry = source[start:source.index("\n    struct SpaceEntry", start)]
start = source.index("    private func noteSelectedAttachSession()")
register = source[start:source.index("\n    /// Finished agents", start)]
harness = r'''
import Foundation
struct Device { let id: UUID }
struct PaneRef: Equatable { let deviceID: UUID; let paneID: String }
struct Pane { let paneID: String; let workspaceID = "w1" }
enum TerminalAttachTarget { case agent(paneID: String), terminal(terminalID: String) }
struct AgentEntry {
    let device: Device
    let agent: Pane
    var ref: PaneRef { PaneRef(deviceID: device.id, paneID: agent.paneID) }
    var id: String { "\(device.id.uuidString)-\(agent.paneID)" }
    var title: String { "pi" }
}
struct TerminalEntry {
    let device: Device
    let pane: Pane
    let terminalID = "t1"
    var ref: PaneRef { PaneRef(deviceID: device.id, paneID: pane.paneID) }
    var id: String { "\(device.id.uuidString)-\(pane.paneID)" }
    var title: String { "shell" }
}
struct Model {
''' + entry + r'''
    var selectedAttachedEntry: AttachedEntry?
    var attachSessions: [AttachedEntry] = []
''' + register.replace("private func", "mutating func") + r'''
}
@main struct Check {
    static func main() {
        let device = Device(id: UUID())
        let pane = Pane(paneID: "w1:p1")
        let terminal = Model.AttachedEntry.terminal(TerminalEntry(device: device, pane: pane))
        let agent = Model.AttachedEntry.agent(AgentEntry(device: device, agent: pane))
        var model = Model()
        model.selectedAttachedEntry = terminal
        model.noteSelectedAttachSession()
        // A snapshot detects pi, without assigning selectedPane again.
        model.selectedAttachedEntry = agent
        assert(model.attachSessions.filter { $0.id == model.selectedAttachedEntry?.id }.count == 1,
               "pi startup must leave exactly one cached terminal visible")
        // Switching away/back must reuse the existing surface, not attach twice.
        model.noteSelectedAttachSession()
        assert(model.attachSessions.count == 1)
        model.selectedAttachedEntry = terminal
        model.noteSelectedAttachSession()
        assert(model.attachSessions.count == 1 && model.attachSessions[0].id == terminal.id)
        let otherPane = Model.AttachedEntry.agent(AgentEntry(device: device, agent: Pane(paneID: "w1:p2")))
        let otherDevice = Model.AttachedEntry.agent(AgentEntry(device: Device(id: UUID()), agent: pane))
        assert(Set([terminal.id, otherPane.id, otherDevice.id]).count == 3)
        print("PASS: shell → pi → shell keeps one visible attach; pane/device IDs stay distinct")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="attach-identity-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
