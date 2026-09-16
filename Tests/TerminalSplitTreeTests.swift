// Run: swiftc Sources/GooseAgent/TerminalSplitTree.swift Sources/GooseAgent/TerminalProcess.swift Tests/TerminalSplitTreeTests.swift -o /tmp/terminal-split-tests && /tmp/terminal-split-tests
import Foundation
import CoreGraphics

@main struct TerminalSplitTreeTests {
    static func main() throws {
        var tree = TerminalSplitTree("attach")
        tree.insert("b", beside: tree.focusedID, axis: .vertical)
        tree.insert("c", beside: tree.focusedID, axis: .vertical)
        assert(tree.leaves == ["attach", "b", "c"] && tree.focusedID == "c")
        assert(tree.neighbor(.right) == nil && tree.neighbor(.up) == nil && tree.neighbor(.down) == nil)
        assert(tree.neighbor(.left) == "b")
        tree.root = tree.root.equalized
        let equal = tree.geometry(in: CGRect(x: 0, y: 0, width: 900, height: 600), dividerWidth: 0).panes
        for rect in equal.values { assert(abs(rect.width - 300) < 0.001) }
        tree.insert("d", beside: "c", axis: .horizontal)
        assert(tree.focusedID == "d" && tree.neighbor(.up) == "c" && tree.neighbor(.left) == "b")
        tree.resize(along: .horizontal, grow: true)
        let resized = tree.geometry(in: CGRect(x: 0, y: 0, width: 900, height: 600)).panes
        assert(resized["d"]!.height > resized["c"]!.height)
        let beforeSwap = tree
        let beforeGeometry = tree.geometry(in: CGRect(x: 0, y: 0, width: 900, height: 600))
        assert(tree.swap("attach", with: "d"))
        assert(tree.leaves == ["d", "b", "c", "attach"] && tree.focusedID == "attach")
        let afterGeometry = tree.geometry(in: CGRect(x: 0, y: 0, width: 900, height: 600))
        assert(Set(tree.leaves) == Set(beforeSwap.leaves))
        assert(afterGeometry.panes["attach"] == beforeGeometry.panes["d"])
        assert(afterGeometry.panes["d"] == beforeGeometry.panes["attach"])
        for (a, b) in zip(beforeGeometry.dividers, afterGeometry.dividers) {
            assert(a.id == b.id && a.axis == b.axis && a.ratio == b.ratio && a.frame == b.frame)
        }
        assert(tree.swap("d", with: "attach") && tree == beforeSwap)
        assert(!tree.swap("missing", with: "d") && tree == beforeSwap)
        assert(!tree.swap("attach", with: "missing") && tree == beforeSwap)
        assert(!tree.swap("d", with: "d") && tree == beforeSwap)
        assert(tree.close("c") && tree.leaves == ["attach", "b", "d"])
        assert(tree.close("attach") && tree.leaves == ["b", "d"])
        assert(tree.close("d") && tree.focusedID == "b")
        assert(!tree.close("b")) // owner restores attach; never issues pane.close

        // Exercise real independent PTYs in a test-owned process table, including
        // live cwd with trailing whitespace. Tree edits do not touch this table;
        // this does not verify SwiftUI/NSView or Ghostty lifecycle behavior.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("split-\(UUID()) ")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var live: [String: TerminalProcess] = [:]
        let output = DispatchSemaphore(value: 0)
        for id in ["a", "b", "c"] {
            let process = TerminalProcess()
            process.onOutput = { data in
                if String(decoding: data, as: UTF8.self).contains("SESSION-\(id)") { output.signal() }
            }
            assert(process.start(executable: "/bin/sh", args: ["-i"], environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color"]))
            live[id] = process
        }
        defer { for process in live.values { process.terminate() } }
        let pids = live.mapValues(\.shellPid)
        assert(Set(pids.values).count == 3)
        var sessions = TerminalSplitTree("a")
        sessions.insert("b", beside: "a", axis: .vertical)
        sessions.insert("c", beside: "b", axis: .horizontal)
        assert(sessions.swap("a", with: "c") && sessions.focusedID == "a")
        assert(live.mapValues(\.shellPid) == pids)
        assert(sessions.swap("c", with: "a") && sessions.focusedID == "c")
        assert(sessions.close("b"))
        live.removeValue(forKey: "b")?.terminate()
        for id in sessions.leaves {
            assert(live[id]!.shellPid == pids[id])
            live[id]!.write(Data("printf 'SESSION-\(id)\\n'\n".utf8))
            assert(output.wait(timeout: .now() + 3) == .success)
        }
        let quoted = directory.path.replacingOccurrences(of: "'", with: "'\\''")
        live["c"]!.write(Data("cd '\(quoted)'\n".utf8))
        let deadline = Date().addingTimeInterval(3)
        while live["c"]!.currentWorkingDirectory != directory.path && Date() < deadline { usleep(10_000) }
        // /var aliases /private/var on macOS.
        let actual = live["c"]!.currentWorkingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        assert(actual == directory.resolvingSymlinksInPath().path)
        assert(sessions.swap("c", with: "a") && sessions.focusedID == "c")
        assert(live["c"]!.shellPid == pids["c"])
        assert(live["c"]!.currentWorkingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == actual)
        live["c"]!.write(Data("printf 'SESSION-c\\n'\n".utf8))
        assert(output.wait(timeout: .now() + 3) == .success)
        print("PASS: mixed-tree swap/inverse/no-ops, branch identity/geometry, focus, test-owned PTY table and live cwd/output, split/resize/close")
    }
}
