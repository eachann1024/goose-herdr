#!/usr/bin/env python3
"""Compile production split/close/ownership dataflow without mounting terminal views."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/GooseAgent/AppModel.swift').read_text()
start = source.index('    @Published var splitTrees:')
end = source.index('    /// Standalone terminals.', start)
methods = source[start:end].replace('@Published ', '').replace('private func ', 'func ')
start = source.index('    func closeShellSession(')
end = source.index('    // MARK: - Lifecycle', start)
close = source[start:end]
harness = r'''
import Foundation
struct Device { var isLocal = true; static let local = Device() }
struct Ref: Equatable { let paneID: String }
struct AttachedEntry { let id: String; let ref: Ref; let title = "Agent"; let device = Device() }
struct ShellSession { let id: UUID; let title: String; let device: Device }
struct Pane { let paneID: String; let cwd: String? }
struct State { var panes: [Pane] = []; var agents: [Pane] = [] }
class ProcessStub { var currentWorkingDirectory: String? }
class Host { let process = ProcessStub() }
class Window { func makeFirstResponder(_ view: LineBreakTerminalView) {} }
class LineBreakTerminalView { let window: Window? = nil; let processHost: Host? = nil }
enum AttachViewRegistry { static func view(for id: String) -> LineBreakTerminalView? { nil } }
enum ShellViewRegistry {
    static func view(for id: UUID) -> LineBreakTerminalView? { nil }
    static func focus(_ id: UUID) {}
}
class Model {
    var isFileManagerActive = false
    var selectedAttachedEntry: AttachedEntry?
    var attachSessions: [AttachedEntry] = []
    var shellSessions: [ShellSession] = []
    var selectedShellID: UUID?
    var selectedShell: ShellSession? { shellSessions.first { $0.id == selectedShellID } }
    var state = State()
    func session(_ device: UUID) -> State { state }
'''
# Device UUID is only needed for cache access.
harness = harness.replace('struct Device { var isLocal', 'struct Device { let id = UUID(); var isLocal')
harness += methods + close + r'''
}
@main struct Check {
    static func main() {
        let model = Model()
        let entry = AttachedEntry(id: "attach", ref: Ref(paneID: "p"))
        model.attachSessions = [entry]
        model.selectedAttachedEntry = entry
        model.state.panes = [Pane(paneID: "p", cwd: "/tmp/project ")]
        // No view/PTY has been mounted. Each synchronous request still follows
        // the new focused leaf and carries its already determined startup cwd.
        model.splitFocusedTerminal(.vertical)
        model.splitFocusedTerminal(.vertical)
        model.splitFocusedTerminal(.horizontal)
        assert(model.currentSplitTree!.leaves.count == 4)
        assert(model.currentSplitTree!.focusedID == model.splitShells.last!.id.uuidString)
        assert(model.splitShells.allSatisfy { $0.workingDirectory == "/tmp/project " })

        let original = model.currentSplitTree!
        assert(original.leaves.allSatisfy { model.terminalLeafIsAlive($0, group: entry.id) })
        let source = original.focusedID
        let ownership = model.splitShells.map { "\($0.id):\($0.group):\($0.workingDirectory ?? "")" }
        let drag = model.beginTerminalPaneDrag(source, group: entry.id)!
        func unchanged() {
            assert(model.currentSplitTree == original)
            assert(model.splitShells.map { "\($0.id):\($0.group):\($0.workingDirectory ?? "")" } == ownership)
            assert(model.attachSessions.map(\.id) == [entry.id] && model.shellSessions.isEmpty)
        }
        assert(!model.dropTerminalPane(drag, token: UUID().uuidString, target: entry.id, group: entry.id))
        assert(!model.dropTerminalPane(drag, token: drag.token, target: source, group: entry.id))
        assert(!model.dropTerminalPane(drag, token: drag.token, target: "missing", group: entry.id))
        assert(!model.dropTerminalPane(drag, token: drag.token, target: entry.id, group: "other"))
        unchanged()
        model.isFileManagerActive = true
        assert(!model.dropTerminalPane(drag, token: drag.token, target: entry.id, group: entry.id))
        model.isFileManagerActive = false
        model.selectedAttachedEntry = nil
        assert(!model.dropTerminalPane(drag, token: drag.token, target: entry.id, group: entry.id))
        model.selectedAttachedEntry = entry
        unchanged()
        var stale = original
        stale.resize(along: .horizontal, grow: true)
        model.splitTrees[entry.id] = stale
        assert(!model.dropTerminalPane(drag, token: drag.token, target: entry.id, group: entry.id))
        assert(model.currentSplitTree == stale)
        for removed in [source, entry.id] {
            var closed = original
            assert(closed.close(removed))
            model.splitTrees[entry.id] = closed
            assert(!model.dropTerminalPane(drag, token: drag.token, target: entry.id, group: entry.id))
            assert(model.currentSplitTree == closed)
        }
        model.splitTrees[entry.id] = original
        model.focusTerminalLeaf(entry.id, group: entry.id) // focus alone does not invalidate geometry
        assert(model.dropTerminalPane(drag, token: drag.token, target: entry.id, group: entry.id))
        assert(model.currentSplitTree!.focusedID == source)
        assert(model.currentSplitTree!.root != original.root)
        assert(original.leaves.allSatisfy { model.terminalLeafIsAlive($0, group: entry.id) })
        assert(!model.dropTerminalPane(drag, token: drag.token, target: entry.id, group: entry.id))
        assert(model.swapTerminalLeaves(source, with: entry.id, group: entry.id))
        unchanged()
        model.swapSplit(.up)
        assert(model.currentSplitTree!.focusedID == source && model.currentSplitTree!.root != original.root)
        model.swapSplit(.down)
        unchanged()
        let survivorIDs = model.splitShells.map(\.id)
        assert(model.terminalHeaderShell?.id == survivorIDs.last)
        assert(model.terminalHeaderShell!.device.isLocal)
        model.focusTerminalLeaf(entry.id, group: entry.id)
        assert(model.terminalHeaderShell == nil) // focused attach still describes the agent
        let layoutBeforeFiles = model.layoutSplitTree
        model.isFileManagerActive = true
        assert(model.currentSplitTree == nil && !model.hasTerminalSplits)
        assert(model.layoutSplitTree == layoutBeforeFiles)
        model.isFileManagerActive = false
        model.closeTerminalLeaf("attach", group: "attach")
        assert(model.currentSplitTree!.leaves.count == 3)
        assert(model.splitShells.map(\.id) == survivorIDs)
        while model.splitTrees["attach"] != nil { model.closeFocusedSplit() }
        assert(model.attachSessions.count == 1 && model.selectedAttachedEntry?.id == "attach")
        assert(model.splitShells.isEmpty) // last sibling returns to server attach

        model.splitFocusedTerminal(.vertical)
        let sibling = model.splitShells[0].id
        model.preserveSplitSiblings(of: entry)
        model.preserveSplitSiblings(of: entry) // idempotent
        assert(model.shellSessions.count == 1)
        assert(model.currentSplitTree!.leaves == [sibling.uuidString])
        assert(model.splitShells[0].id == sibling)
        assert(model.splitShells[0].group == model.selectedShellID!.uuidString)
        model.closeFocusedSplit()
        assert(model.shellSessions.isEmpty && model.splitShells.isEmpty)

        model.selectedShellID = nil
        model.splitFocusedTerminal(.vertical)
        model.discardSplitGroup(entry.id) // explicit successful server close
        model.preserveSplitSiblings(of: entry)
        assert(model.shellSessions.isEmpty && model.splitShells.isEmpty)

        // Remote attach gets a local HOME shell, never remote cwd.
        model.selectedAttachedEntry = nil
        let remote = ShellSession(id: UUID(), title: "SSH", device: Device(isLocal: false))
        model.shellSessions = [remote]; model.selectedShellID = remote.id
        model.splitFocusedTerminal(.vertical)
        assert(model.splitShells[0].workingDirectory == nil)
        let remoteSibling = model.splitShells[0].id
        assert(model.terminalHeaderShell!.device.isLocal)
        let remoteTree = model.currentSplitTree!
        let remoteDrag = model.beginTerminalPaneDrag(remoteSibling.uuidString, group: remote.id.uuidString)!
        assert(model.dropTerminalPane(remoteDrag, token: remoteDrag.token, target: remote.id.uuidString, group: remote.id.uuidString))
        assert(model.shellSessions[0].id == remote.id && !model.shellSessions[0].device.isLocal)
        assert(model.splitShells[0].id == remoteSibling && model.splitShells[0].group == remote.id.uuidString)
        assert(model.swapTerminalLeaves(remoteSibling.uuidString, with: remote.id.uuidString, group: remote.id.uuidString))
        assert(model.currentSplitTree == remoteTree)
        model.focusTerminalLeaf(remote.id.uuidString, group: remote.id.uuidString)
        assert(!model.terminalHeaderShell!.device.isLocal)
        model.closeFocusedSplit()
        assert(model.selectedShellID == remote.id) // owner and surviving PTY identity do not change
        assert(model.selectedShell!.title == "SSH") // preserve a user's title
        assert(model.selectedShell!.device.isLocal)
        assert(model.currentSplitTree!.leaves == [remoteSibling.uuidString])
        assert(model.splitShells[0].id == remoteSibling)
        model.closeFocusedSplit()
        assert(model.shellSessions.isEmpty && model.splitShells.isEmpty)
        print("PASS: swaps across flat attach/local/remote collections, token/group/stale/closed rejection, focus/ownership, rapid unmounted cwd chain, leaf-only close/server boundary, owner migration/idempotency, explicit cleanup, remote isolation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='terminal-split-model-') as directory:
    swift = Path(directory) / 'Check.swift'
    binary = Path(directory) / 'check'
    swift.write_text(harness)
    subprocess.run(['swiftc', str(root / 'Sources/GooseAgent/TerminalSplitTree.swift'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
