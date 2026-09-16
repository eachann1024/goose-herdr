#!/usr/bin/env python3
"""Exercise production layout placement without mounting SwiftUI or starting the app."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/GooseAgent/SplitContainer.swift').read_text()
layout = source[source.index('struct TerminalSplitLayout:'):source.index('struct TerminalSplitDividers:')]
layout = layout.replace(': Layout {', '{').replace('subviews: Subviews', 'subviews: [TestSubview]')
content = (root / 'Sources/GooseAgent/ContentView.swift').read_text()
assert 'TerminalSplitLayout(trees: model.splitTrees)' in content
assert 'TerminalSplitDividers(tree: model.layoutSplitTree' in content
harness = '''import Foundation
struct ProposedViewSize {
    let size: CGSize
    init(_ size: CGSize) { self.size = size }
    func replacingUnspecifiedDimensions() -> CGSize { size }
}
enum Anchor { case topLeading }
enum TerminalLeafLayoutKey {}
final class TestSubview {
    let id: String
    var frame = CGRect.zero
    init(_ id: String) { self.id = id }
    subscript(_ key: TerminalLeafLayoutKey.Type) -> String { id }
    func place(at origin: CGPoint, anchor: Anchor, proposal: ProposedViewSize) {
        frame = CGRect(origin: origin, size: proposal.size)
    }
}
''' + layout + '''
@main struct Check {
    static func main() {
        var a = TerminalSplitTree("a")
        a.insert("a2", beside: "a", axis: .vertical)
        var b = TerminalSplitTree("b")
        b.insert("b2", beside: "b", axis: .horizontal)
        let bounds = CGRect(x: 7, y: 11, width: 900, height: 600)
        let leaves = ["a", "a2", "b", "b2", "unsplit"].map(TestSubview.init)
        var cache: () = ()
        let layout = TerminalSplitLayout(trees: ["a": a, "b": b])
        // No selection or Files flag enters layout; both hidden and active groups
        // are always proposed their own tree's rectangles, never full-window size.
        for _ in 0..<3 {
            layout.placeSubviews(in: bounds, proposal: ProposedViewSize(bounds.size), subviews: leaves, cache: &cache)
            for view in leaves {
                let expected = a.geometry(in: bounds).panes[view.id]
                    ?? b.geometry(in: bounds).panes[view.id] ?? bounds
                assert(view.frame == expected)
            }
        }
        assert(leaves[0].frame.width < bounds.width)
        assert(leaves[2].frame.height < bounds.height)
        assert(leaves.last!.frame == bounds)
        let identities = leaves.map(ObjectIdentifier.init)
        let originalFrames = leaves.map(\\.frame)
        assert(a.swap("a2", with: "a"))
        TerminalSplitLayout(trees: ["a": a, "b": b]).placeSubviews(
            in: bounds, proposal: ProposedViewSize(bounds.size), subviews: leaves, cache: &cache)
        assert(leaves.map(ObjectIdentifier.init) == identities)
        assert(leaves[0].frame == originalFrames[1] && leaves[1].frame == originalFrames[0])
        assert(leaves[2].frame == originalFrames[2])
        print("PASS: swap moves frames without replacing flat views; every group's leaf retains its own split geometry independent of selection/Files")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='terminal-split-layout-') as directory:
    swift = Path(directory) / 'Check.swift'
    binary = Path(directory) / 'check'
    swift.write_text(harness)
    subprocess.run(['swiftc', str(root / 'Sources/GooseAgent/TerminalSplitTree.swift'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
