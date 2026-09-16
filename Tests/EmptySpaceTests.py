#!/usr/bin/env python3
"""Retained empty-space merge / persist: python3 Tests/EmptySpaceTests.py."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Sources/GooseAgent/AppModel.swift").read_text()
begin = source.index("struct RetainedSpace: Codable")
end = source.index("\n/// Live state for one device's herdr session.", begin)
block = source[begin:end]

harness = r'''
import Foundation

struct WorkspaceInfo: Equatable {
    let workspaceID: String
    let number: Int
    let label: String
    let focused: Bool?
    let paneCount: Int?
    let tabCount: Int?
    let cwd: String?

    init(
        workspaceID: String,
        number: Int,
        label: String,
        focused: Bool? = nil,
        paneCount: Int? = nil,
        tabCount: Int? = nil,
        cwd: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.number = number
        self.label = label
        self.focused = focused
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.cwd = cwd
    }
}

struct SpaceRef: Hashable {
    let deviceID: UUID
    let workspaceID: String
}

''' + block + r'''

@main struct Check {
    static func main() {
        let device = UUID()
        let live = [
            WorkspaceInfo(workspaceID: "w2", number: 1, label: "Keep"),
        ]
        let retained = [
            RetainedSpace(deviceID: device, workspaceID: "w1", label: "Ghost", cwd: "/tmp", sortIndex: 0),
            RetainedSpace(deviceID: device, workspaceID: "w2", label: "Stale", cwd: nil, sortIndex: 1),
            RetainedSpace(deviceID: device, workspaceID: "w3", label: "Tail", cwd: nil, sortIndex: 2),
        ]
        let merged = RetainedSpaceStore.merging(live, with: retained)
        assert(merged.map(\.workspaceID) == ["w1", "w2", "w3"], "ghosts keep their slots; live IDs win")
        assert(merged[0].label == "Ghost" && merged[0].paneCount == 0 && merged[0].cwd == "/tmp")
        assert(merged[1].label == "Keep")

        let suite = "goose-herdr-empty-space-check"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        RetainedSpaceStore.save(retained, defaults: store)
        let loaded = RetainedSpaceStore.load(defaults: store)
        assert(loaded == retained, "retained spaces persist until the user closes them")
        RetainedSpaceStore.save([], defaults: store)
        assert(RetainedSpaceStore.load(defaults: store).isEmpty)
        store.removePersistentDomain(forName: suite)
        print("PASS: empty spaces merge into live list and persist")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="empty-space-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "empty-space-check"
    Path(swift).write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
