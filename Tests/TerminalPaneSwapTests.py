#!/usr/bin/env python3
"""Compile the native swap controls; check source authority and localization seams.
No window is opened and no application build/install is performed.
"""
from pathlib import Path
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = root / 'Sources/GooseAgent'
model = (sources / 'AppModel.swift').read_text()
native = (sources / 'SplitContainer.swift').read_text()
content = (sources / 'ContentView.swift').read_text()
methods = model[model.index('    struct TerminalPaneDrag {'):model.index('    func resizeSplit(')]
# The native boundary must establish authority before asking the model to swap.
authority = native[native.index('    private func source(for sender:'):native.index('    private func updateTarget(')]
for check in [
    'sender.draggingSource as? TerminalPaneDragNSView',
    'source.window === window', 'source.model === model', 'source.activeDrag',
    'sender.draggingPasteboard.string(forType: Self.pasteboardType)',
    'model.canDropTerminalPane(drag, token: token, target: leaf, group: group)',
]:
    assert check in authority
assert 'registerForDraggedTypes([Self.pasteboardType])' in native
assert 'writer.setString(drag.token, forType: Self.pasteboardType)' in native
assert 'NSPasteboard.PasteboardType("dev.eachann.goose-herdr.pane-swap")' in native
assert '.fileURL' not in native and '.onDrag' not in content
assert 'static let height: CGFloat = 24' in native
assert 'static let width: CGFloat = 32' in native
assert '.padding(.top, paneHandleInset(group: group))' in content
assert '.padding(.top, paneHandleInset(group: session.id))' in content
update = native.split('    func updateNSView(', 1)[1].split('    static func dismantleNSView(', 1)[0]
assert 'view.leaf = leaf' in update and 'view.validateActiveDrag()' in update
assert update.index('view.leaf = leaf') < update.index('view.validateActiveDrag()')
dismantle = native.split('    static func dismantleNSView(', 1)[1].split('\n}', 1)[0]
assert 'view.activeDrag = nil' in dismantle and 'view.onTarget = nil' in dismantle
menu = native.split('    private func showSwapMenu() {', 1)[1].split('    @objc private func runSwap', 1)[0]
assert 'makeFirstResponder' not in menu  # cancellation preserves mouse/keyboard entry focus
assert 'item.target = self' in menu and 'menu.popUp(' in menu
assert 'override func draggingEnded' in native  # callback is wired; system delivery is not exercised
assert 'override func accessibilityCustomActions()' in native
assert 'window?.selectPreviousKeyView(self)' in native and 'window?.selectNextKeyView(self)' in native
catalog = json.loads((root / 'Resources/Localizable.xcstrings').read_text())['strings']
for text in ["Drag to another pane's top strip to swap. Click for swap actions.",
             'Rearrange Terminal Pane', 'Release to Swap Panes']:
    for language in ['en', 'zh-Hans']:
        assert catalog[text]['localizations'][language]['stringUnit']['value']

# Real AppKit/SwiftUI APIs and real model swap methods, with only unrelated model
# and theme dependencies stubbed. Full app compilation remains the final gate.
stub = '''import SwiftUI
import AppKit
@MainActor final class AppModel: ObservableObject {
    var terminalGroupID: String? = "a"
    var currentSplitTree: TerminalSplitTree? { splitTrees["a"] }
    var splitTrees: [String: TerminalSplitTree] = [:]
    func restoreTerminalFocus() {}
''' + methods + '''}
enum Theme {
    static let hairline = Color.gray
    static let textSecondary = Color.primary
    static let itemWash = Color.secondary
}
'''
with tempfile.TemporaryDirectory(prefix='terminal-pane-swap-') as directory:
    swift = Path(directory) / 'Stubs.swift'
    swift.write_text(stub)
    subprocess.run(['swiftc', '-typecheck', str(sources / 'TerminalSplitTree.swift'),
                    str(sources / 'SplitContainer.swift'), str(sources / 'KeyboardShortcuts.swift'),
                    str(swift)], check=True)
print('PASS: native swap controls typecheck, authority/lifecycle seams, reserved strip, accessibility, en/zh-Hans')
