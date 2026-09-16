#!/usr/bin/env python3
"""Regression: python3 Tests/SessionRestoreTests.py (requires Swift)."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/AppModel.swift").read_text()

def between(start, end):
    return source[source.index(start):source.index(end, source.index(start))]

pane = between("struct PaneRef:", "\nstruct SpaceRef:")
selection = between("    @Published var selectedPane:", "\n    /// Live attaches").replace("@Published ", "")
register = between("    private func noteSelectedAttachSession()", "\n    /// Finished agents")
initializer = between("    init() {", "\n    // MARK: - Derived state")
refresh = between("            if let selected = selectedPane, selected.deviceID == deviceID,", "\n        } catch {\n            // A snapshot is one request")
validation = between("        // Named-session devices are only available after discovery.", "\n    func service(for device:")

harness = r'''
import Foundation
let defaults = UserDefaults(suiteName: "session-restore-check-" + UUID().uuidString)!
''' + pane + r'''
struct Device { let id: UUID }
struct DeviceStore {
    static var devices: [Device] = []
    func load() -> [Device] { Self.devices }
}
struct SpaceRef { let deviceID: UUID; let workspaceID: String }
struct Workspace { let workspaceID: String }
struct Snapshot { let focusedPaneID: String? }
struct AgentUnreadKey: Hashable { let deviceID: UUID; let paneID: String }
struct Entry {
    let ref: PaneRef
    var id: PaneRef { ref }
    let workspaceID = "w1"
}
class Model {
    var devices: [Device]
    var deviceFilter: UUID?
    static let deviceFilterKey = "device.filter"
    var selectedSpace: SpaceRef?
    var unreadAgents: Set<AgentUnreadKey> = []
    var attachSessions: [Entry] = []
    var available: Set<PaneRef> = []
    var firstVisiblePaneRef: PaneRef?
    var visibleAgents: [Entry] { available.map { Entry(ref: $0) } }
    var visibleTerminals: [Entry] { [] }
    var visibleSessions: [Entry] { visibleAgents + visibleTerminals }
    var selectedAttachedEntry: Entry? {
        selectedPane.flatMap { available.contains($0) ? Entry(ref: $0) : nil }
    }
    func device(_ id: UUID) -> Device? { devices.first { $0.id == id } }
    func isRetainedSpace(_ ref: SpaceRef) -> Bool { false }
    func preferredVisibleAgent() -> Entry? { nil }
''' + selection + '\n' + register + '\n' + initializer + r'''
    func afterDiscovery() {
''' + validation + r'''
    func refresh(_ deviceID: UUID, panes: [String], focused: String?) -> Bool {
        let previousPaneOrder = visibleSessions.map(\.ref)
        let paneIDs = Set(panes)
        available = available.filter { $0.deviceID != deviceID }
        available.formUnion(panes.map { PaneRef(deviceID: deviceID, paneID: $0) })
        let snapshot = Snapshot(focusedPaneID: focused)
        let mergedWorkspaces: [Workspace] = []
''' + refresh + r'''
    }
}
@main struct Check {
    static func main() {
        let local = UUID(), remote = UUID()
        DeviceStore.devices = [Device(id: local), Device(id: remote)]
        let target = PaneRef(deviceID: remote, paneID: "w1:p2")
        let fallback = PaneRef(deviceID: local, paneID: "w1:p1")
        let first = Model()
        first.selectedPane = target
        let reopened = Model()
        reopened.afterDiscovery()
        assert(reopened.selectedPane == target, "relaunch remembers device + pane")
        assert(reopened.refresh(local, panes: ["w1:p1", "w1:p2"], focused: "w1:p1"))
        assert(reopened.selectedPane == target && reopened.attachSessions.isEmpty,
               "a faster device must not replace or attach the restored selection")
        assert(reopened.refresh(remote, panes: ["w1:p2", "w1:p3"], focused: "w1:p3"))
        assert(reopened.selectedPane == target && reopened.attachSessions.map(\.ref) == [target])
        assert(reopened.refresh(remote, panes: ["w1:p2"], focused: nil))
        assert(reopened.attachSessions.count == 1, "restored attach stays unique")

        let missing = Model()
        assert(missing.refresh(remote, panes: ["w1:p3"], focused: "w1:p3"))
        assert(missing.selectedPane?.paneID == "w1:p3", "missing pane uses existing focused fallback")
        missing.selectedPane = target
        let empty = Model()
        empty.firstVisiblePaneRef = fallback
        assert(empty.refresh(remote, panes: [], focused: nil))
        assert(empty.selectedPane == fallback, "empty device uses existing visible fallback")

        first.selectedPane = target
        DeviceStore.devices = [Device(id: local)]
        let removedDevice = Model()
        removedDevice.afterDiscovery()
        assert(removedDevice.selectedPane == nil)
        assert(removedDevice.refresh(local, panes: ["w1:p1"], focused: "w1:p1"))
        assert(removedDevice.selectedPane == fallback)
        first.selectedPane = target
        let discovered = Model()
        discovered.devices.append(Device(id: remote))
        discovered.afterDiscovery()
        assert(discovered.selectedPane == target, "named sessions validate after discovery")
        first.selectedPane = nil
        assert(Model().selectedPane == nil, "cleared selection is not resurrected")
        defaults.set(Data("invalid".utf8), forKey: "session.selectedPane")
        assert(Model().selectedPane == nil, "invalid stored data falls back safely")
        defaults.removeObject(forKey: "session.selectedPane")
        print("PASS: selection persists; parallel snapshots, attach registration and missing-target fallback")
    }
}
'''
harness = harness.replace("UserDefaults.standard", "defaults")
with tempfile.TemporaryDirectory(prefix="session-restore-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
