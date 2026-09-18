#!/usr/bin/env python3
"""Space drag reorder, gray placeholders included: python3 Tests/RetainedSpaceReorderTests.py.

Compiles the real AppModel `moveSpace` / `storeRetainedSlots`, the real
WorkspaceReorder, and the real RetainedSpaceStore against a fake service, so a
placeholder drag, a live drag across a placeholder, and a failed RPC can be
checked end to end — including what reaches `workspace.move_block`.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Sources/GooseAgent/AppModel.swift").read_text()
reorder = (ROOT / "Packages/HerdrKit/Sources/HerdrKit/WorkspaceReorder.swift").read_text()


def extract(start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


store = extract("struct RetainedSpace: Codable", "\n/// Live state for one device's herdr session.")
store = store.replace("= .standard", '= UserDefaults(suiteName: "goose-herdr-retained-reorder-check")!')
move = extract(
    "    /// Reorders a Space by dropping it on another Space of the same device.",
    "\n    /// Reorders a session tab by dropping it",
).replace("private func", "func", 1)

assert "storeRetainedSlots" in move, "slice marker drifted"
assert "WorkspaceReorder.liveMove(" in move, "moveSpace must split the local and live moves"
assert "isReorderable" not in reorder, "placeholders are drag targets again, not a filter"

harness = (
    r'''
import Foundation

struct WorkspaceInfo: Equatable {
    let workspaceID: String
    var number = 0
    var label = "Space"
    var focused: Bool? = false
    var paneCount: Int? = 0
    var tabCount: Int? = 0
    var cwd: String? = nil
}

struct SpaceRef: Hashable { let deviceID: UUID; let workspaceID: String }
struct Device { let id: UUID; let name: String }
struct SpaceEntry {
    let device: Device
    let workspace: WorkspaceInfo
    var id: String { workspace.workspaceID }
}
struct Session { var workspaces: [WorkspaceInfo] }
enum Failure: Error { case move }
struct Animation {
    static func easeInOut(duration: Double) -> Animation { Animation() }
}
func withAnimation<Result>(_ animation: Animation?, _ body: () throws -> Result) rethrows -> Result {
    try body()
}
'''
    + store
    + reorder.replace("import Foundation\n", "", 1)
    + r'''
@MainActor final class Service {
    var live: [String]
    var moves: [(ids: [String], before: String?)] = []
    var failMove = false

    init(live: [String]) { self.live = live }

    func moveWorkspaceBlock(workspaceIDs: [String], beforeWorkspaceID: String?) async throws {
        moves.append((workspaceIDs, beforeWorkspaceID))
        if failMove { throw Failure.move }
        live.removeAll { workspaceIDs.contains($0) }
        let index = beforeWorkspaceID.flatMap { live.firstIndex(of: $0) } ?? live.count
        live.insert(contentsOf: workspaceIDs, at: index)
    }
}

@MainActor final class Model {
    let device = Device(id: UUID(), name: "local")
    let backend: Service
    var retainedSpaces: [RetainedSpace] = []
    var sessions: [UUID: Session] = [:]
    var actionError: String?
    var refreshes = 0

    init(order: [String], ghosts: [String]) {
        backend = Service(live: order.filter { !ghosts.contains($0) })
        sessions[device.id] = Session(workspaces: order.map { WorkspaceInfo(workspaceID: $0) })
        retainedSpaces = ghosts.map {
            RetainedSpace(
                deviceID: device.id,
                workspaceID: $0,
                label: "Ghost",
                cwd: nil,
                sortIndex: order.firstIndex(of: $0)!
            )
        }
    }

    var rows: [String] { sessions[device.id]!.workspaces.map(\.workspaceID) }
    var slots: [String: Int] {
        Dictionary(uniqueKeysWithValues: retainedSpaces.map { ($0.workspaceID, $0.sortIndex) })
    }

    func entry(_ id: String) -> SpaceEntry {
        SpaceEntry(
            device: device,
            workspace: sessions[device.id]!.workspaces.first { $0.workspaceID == id }!
        )
    }

    func isRetainedSpace(_ ref: SpaceRef) -> Bool { retainedSpaces.contains { $0.ref == ref } }
    func service(for device: Device) -> Service { backend }
    func actionErrorMessage(_ error: Error, device: Device) -> String { "space move failed" }

    /// The snapshot path: herdr's live order merged with the stored gray slots.
    func refresh(_ deviceID: UUID) async {
        refreshes += 1
        sessions[deviceID]?.workspaces = RetainedSpaceStore.merging(
            backend.live.map { WorkspaceInfo(workspaceID: $0) },
            with: retainedSpaces.filter { $0.deviceID == deviceID }
        )
    }
'''
    + move
    + r'''
}

struct Case {
    let order: [String]
    let ghosts: [String]
    let source: String
    let target: String
    let placeAfter: Bool
    let rows: [String]
    let move: (String, String?)?
    let slots: [String: Int]
}

func settle() async {
    for _ in 0..<40 { await Task.yield() }
}

func persistedSlots() -> [String: Int] {
    Dictionary(uniqueKeysWithValues: RetainedSpaceStore.load().map { ($0.workspaceID, $0.sortIndex) })
}

@main struct Check {
    @MainActor static func main() async {
        let suite = "goose-herdr-retained-reorder-check"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)

        // Gray rows drag like any other row; only herdr-visible order reaches the wire.
        let cases: [Case] = [
            Case(order: ["A", "P", "B"], ghosts: ["P"], source: "P", target: "A", placeAfter: false,
                 rows: ["P", "A", "B"], move: nil, slots: ["P": 0]),
            Case(order: ["A", "P", "B"], ghosts: ["P"], source: "P", target: "B", placeAfter: true,
                 rows: ["A", "B", "P"], move: nil, slots: ["P": 2]),
            Case(order: ["A", "P", "B"], ghosts: ["P"], source: "A", target: "P", placeAfter: true,
                 rows: ["P", "A", "B"], move: nil, slots: ["P": 0]),
            Case(order: ["A", "B", "P", "C"], ghosts: ["P"], source: "C", target: "A", placeAfter: false,
                 rows: ["C", "A", "B", "P"], move: ("C", "A"), slots: ["P": 3]),
            Case(order: ["A", "P", "B"], ghosts: ["P"], source: "P", target: "A", placeAfter: true,
                 rows: ["A", "P", "B"], move: nil, slots: ["P": 1]),
        ]

        for (index, item) in cases.enumerated() {
            let model = Model(order: item.order, ghosts: item.ghosts)
            RetainedSpaceStore.save(model.retainedSpaces)
            model.moveSpace(model.entry(item.source), onto: model.entry(item.target), placeAfter: item.placeAfter)
            assert(model.rows == item.rows, "case \(index): the sidebar moves at once")
            await settle()
            assert(model.rows == item.rows, "case \(index): the order sticks")
            if let move = item.move {
                assert(model.backend.moves.count == 1, "case \(index): one move_block call")
                let sent = model.backend.moves[0]
                assert(sent.ids == [move.0] && sent.before == move.1, "case \(index): payload \(sent)")
            } else {
                assert(model.backend.moves.isEmpty, "case \(index): local-only drop sends nothing")
            }
            for sent in model.backend.moves {
                assert(sent.ids.allSatisfy { !item.ghosts.contains($0) }, "case \(index): no dead id sent")
                assert(sent.before.map { !item.ghosts.contains($0) } ?? true, "case \(index): no dead before id sent")
            }
            assert(model.slots == item.slots, "case \(index): gray slot follows the row")
            assert(persistedSlots() == item.slots, "case \(index): gray slot persists")
            await model.refresh(model.device.id)
            assert(model.rows == item.rows, "case \(index): refresh merge rebuilds the same order")
            let relaunched = RetainedSpaceStore.merging(
                model.backend.live.map { WorkspaceInfo(workspaceID: $0) },
                with: RetainedSpaceStore.load()
            )
            assert(relaunched.map(\.workspaceID) == item.rows, "case \(index): relaunch rebuilds the same order")
        }

        // A failed backend move must not leave a phantom order or hide the error.
        let failureCases: [(order: [String], ghosts: [String], source: String, target: String,
                           placeAfter: Bool, optimistic: [String], rows: [String],
                           slots: [String: Int], live: [String])] = [
            (["A", "B", "P"], ["P"], "B", "A", false, ["B", "A", "P"], ["A", "B", "P"], ["P": 2], ["A", "B"]),
            (["A", "P", "B"], ["P"], "A", "B", true, ["P", "B", "A"], ["A", "P", "B"], ["P": 1], ["A", "B"]),
        ]
        for item in failureCases {
            let model = Model(order: item.order, ghosts: item.ghosts)
            RetainedSpaceStore.save(model.retainedSpaces)
            model.backend.failMove = true
            model.moveSpace(model.entry(item.source), onto: model.entry(item.target), placeAfter: item.placeAfter)
            assert(model.rows == item.optimistic, "the row moves at once")
            await settle()
            assert(model.backend.moves.count == 1 && model.backend.moves[0].ids == [item.source],
                   "the move was attempted")
            assert(model.rows == item.rows, "a failed move puts the row back")
            assert(model.slots == item.slots, "gray slots roll back too")
            assert(persistedSlots() == item.slots, "rolled-back slots persist")
            assert(model.backend.live == item.live, "herdr kept its order")
            assert(model.refreshes > 0, "a failed move reconciles with a snapshot")
            assert(model.actionError == "space move failed", "the failure is still surfaced")
        }

        print("PASS: gray spaces drag locally, live order is the only thing sent, failures roll back")
    }
}
'''
)

with tempfile.TemporaryDirectory(prefix="retained-reorder-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
