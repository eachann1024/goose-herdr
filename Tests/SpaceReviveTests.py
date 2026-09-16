#!/usr/bin/env python3
"""Run actual restore logic with a fake service: python3 Tests/SpaceReviveTests.py."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/GooseAgent/AppModel.swift").read_text()
start = source.index("    private func reviveRetainedWorkspace(")
end = source.index("    private func retainDisappearedSpaces(", start)
method = source[start:end].replace("private func", "func", 1)
store = source[source.index("struct RetainedSpace: Codable"):source.index("/// Live state for one device")]
store = store.replace("= .standard", '= UserDefaults(suiteName: "goose-herdr-revive-check")!')
harness = r'''
import Foundation
struct SpaceRef: Hashable { let deviceID: UUID; let workspaceID: String }
struct Device { let id = UUID() }
struct WorkspaceInfo {
    let workspaceID: String
    var number = 0
    var label = "Space"
    var focused: Bool? = false
    var paneCount: Int? = 1
    var tabCount: Int? = 1
    var cwd: String? = "/tmp"
}
struct Session { var workspaces: [WorkspaceInfo] }
enum Failure: Error { case create, move, close }
''' + store + r'''
@MainActor final class Service {
    var ids = ["a", "c"]
    var failCreate = false
    var failMove = false
    var failClose = false
    var onMutation: (() -> Void)?
    func createWorkspace(label: String?, cwd: String?) async throws -> (workspaceID: String, rootPaneID: String?) {
        assert(label == "Space" && cwd == "/tmp")
        if failCreate { throw Failure.create }
        ids.append("new")
        onMutation?()
        await Task.yield()
        return ("new", "pane")
    }
    func moveWorkspaceBlock(workspaceIDs: [String], beforeWorkspaceID: String?) async throws {
        if failMove { throw Failure.move }
        ids.removeAll { workspaceIDs.contains($0) }
        let index = beforeWorkspaceID.flatMap { ids.firstIndex(of: $0) } ?? ids.count
        ids.insert(contentsOf: workspaceIDs, at: index)
        onMutation?()
        await Task.yield()
    }
    func closeWorkspace(workspaceID: String) async throws {
        if failClose { throw Failure.close }
        ids.removeAll { $0 == workspaceID }
    }
}
@MainActor final class Model {
    let backend = Service()
    var retainedSpaces: [RetainedSpace] = []
    var revivingSpaces: Set<SpaceRef> = []
    var statusGenerations: [UUID: UInt64] = [:]
    var dismissedSpaceKeys: Set<String> = []
    var sessions: [UUID: Session] = [:]
    var rows: [WorkspaceInfo] {
        get { sessions.values.first?.workspaces ?? [] }
        set { sessions[deviceID] = Session(workspaces: newValue) }
    }
    var deviceID = UUID()
    var selectedSpace: SpaceRef?
    var scheduled = 0
    func session(_ id: UUID) -> Session { Session(workspaces: rows) }
    func service(for device: Device) -> Service { backend }
    func scheduleRefresh(_ id: UUID) { scheduled += 1 }
    func spaceKey(deviceID: UUID, workspaceID: String) -> String { "\(deviceID)-\(workspaceID)" }
    func isRetainedSpace(_ ref: SpaceRef) -> Bool { retainedSpaces.contains { $0.ref == ref } }
    func markSpaceDismissed(_ ref: SpaceRef) {
        dismissedSpaceKeys.insert(spaceKey(deviceID: ref.deviceID, workspaceID: ref.workspaceID))
    }
    func dismissRetainedSpace(_ ref: SpaceRef) {
        markSpaceDismissed(ref)
        retainedSpaces.removeAll { $0.ref == ref }
        rows.removeAll { $0.workspaceID == ref.workspaceID }
    }
''' + method + r'''
}
@main struct Check {
    @MainActor static func main() async throws {
        let device = Device()
        defer { UserDefaults(suiteName: "goose-herdr-revive-check")!.removePersistentDomain(forName: "goose-herdr-revive-check") }
        // First, middle, last, plus adjacent gray slots and an all-gray list.
        for (order, ghosts, target) in [
            (["b", "a", "c"], ["b"], "b"),
            (["a", "b", "c"], ["b"], "b"),
            (["a", "c", "b"], ["b"], "b"),
            (["a", "b", "d", "c"], ["b", "d"], "b"),
            (["a", "b", "d", "c"], ["b", "d"], "d"),
            (["b", "d"], ["b", "d"], "d"),
        ] {
            let model = Model()
            model.deviceID = device.id
            model.selectedSpace = SpaceRef(deviceID: device.id, workspaceID: target)
            model.rows = order.map { WorkspaceInfo(workspaceID: $0) }
            model.backend.ids = order.filter { !ghosts.contains($0) }
            model.retainedSpaces = ghosts.map {
                RetainedSpace(deviceID: device.id, workspaceID: $0, label: "Space", cwd: "/tmp", sortIndex: order.firstIndex(of: $0)!)
            }
            model.backend.onMutation = {
                assert(model.rows.map(\.workspaceID) == order, "no intermediate sidebar jump")
                assert(!model.revivingSpaces.isEmpty, "refresh stays paused during restore")
            }
            let restored = try await model.reviveRetainedWorkspace(device: device, workspaceID: target)
            assert(restored?.workspaceID == "new" && restored?.rootPaneID == "pane")
            assert(model.selectedSpace == SpaceRef(deviceID: device.id, workspaceID: "new"), "filter must move before refresh, never flash All Spaces")
            assert(model.rows.map(\.workspaceID) == order.map { $0 == target ? "new" : $0 }, "replace the gray row in place before refresh")
            let merged = RetainedSpaceStore.merging(model.backend.ids.map { WorkspaceInfo(workspaceID: $0) }, with: model.retainedSpaces)
            assert(merged.map(\.workspaceID) == order.map { $0 == target ? "new" : $0 })
            assert(model.revivingSpaces.isEmpty && model.scheduled == 1)
            assert(model.statusGenerations[device.id] == 1, "invalidate in-flight snapshots")
        }
        for failure in [Failure.create, .move, .close] {
            let model = Model()
            model.deviceID = device.id
            model.rows = ["a", "b", "c"].map { WorkspaceInfo(workspaceID: $0) }
            model.retainedSpaces = [RetainedSpace(deviceID: device.id, workspaceID: "b", label: "Space", cwd: "/tmp", sortIndex: 1)]
            model.backend.failCreate = failure == .create
            model.backend.failMove = failure != .create
            model.backend.failClose = failure == .close
            do {
                _ = try await model.reviveRetainedWorkspace(device: device, workspaceID: "b")
                assertionFailure("expected failure")
            } catch {}
            assert(model.retainedSpaces.count == 1 && model.rows.map(\.workspaceID) == ["a", "b", "c"])
            assert(model.revivingSpaces.isEmpty && model.scheduled == 1)
            assert(model.backend.ids == (failure == .close ? ["a", "c", "new"] : ["a", "c"]))
            if failure == .close {
                assert(!model.dismissedSpaceKeys.contains(model.spaceKey(deviceID: device.id, workspaceID: "new")))
            }
        }
        print("PASS: restored spaces keep their slots; failed restores retain the original")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="space-revive-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
