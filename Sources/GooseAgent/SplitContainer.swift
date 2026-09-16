import AppKit
import SwiftUI

struct TerminalLeafLayoutKey: LayoutValueKey {
    static let defaultValue = ""
}

/// Flat children never change parents when the geometry tree changes. Inserting a
/// recursive SwiftUI container here would dismantle existing NSViews and kill PTYs.
struct TerminalSplitLayout: Layout {
    let trees: [String: TerminalSplitTree]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Every group keeps its own geometry, including behind Files or another group.
        let panes = trees.values.reduce(into: [String: CGRect]()) { result, tree in
            result.merge(tree.geometry(in: bounds).panes) { _, new in new }
        }
        for view in subviews {
            // Hidden sessions retain a useful viewport while not selected.
            let rect = panes[view[TerminalLeafLayoutKey.self]] ?? bounds
            view.place(at: rect.origin, anchor: .topLeading, proposal: ProposedViewSize(rect.size))
        }
    }
}

struct TerminalSplitDividers: View {
    let tree: TerminalSplitTree?
    let onRatio: (UUID, Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            if let tree {
                ForEach(tree.geometry(in: CGRect(origin: .zero, size: proxy.size)).dividers) { divider in
                    TerminalSplitDivider(divider: divider, onRatio: onRatio)
                }
            }
        }
    }
}

private struct TerminalSplitDivider: View {
    let divider: TerminalSplitTree.Divider
    let onRatio: (UUID, Double) -> Void
    @State private var startRatio: Double?

    var body: some View {
        Rectangle().fill(Theme.hairline)
            .frame(width: divider.frame.width, height: divider.frame.height)
            .overlay {
                Rectangle().fill(.clear)
                    .frame(width: divider.axis == .vertical ? 9 : divider.frame.width,
                           height: divider.axis == .horizontal ? 9 : divider.frame.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { value in
                        let length = divider.axis == .vertical ? divider.container.width : divider.container.height
                        guard length > 1 else { return }
                        let start = startRatio ?? divider.ratio
                        startRatio = start
                        let delta = divider.axis == .vertical ? value.translation.width : value.translation.height
                        onRatio(divider.id, start + delta / (length - 1))
                    }.onEnded { _ in startRatio = nil })
                    .onHover { hovering in
                        (hovering ? (divider.axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown) : NSCursor.arrow).set()
                    }
            }
            .position(x: divider.frame.midX, y: divider.frame.midY)
            .accessibilityLabel(Text("Resize Split"))
            .accessibilityAdjustableAction { direction in
                onRatio(divider.id, divider.ratio + (direction == .increment ? 0.05 : -0.05))
            }
    }
}

// Only split groups reserve this strip; terminal text never shares its hit area.
enum TerminalPaneHandleMetrics {
    static let height: CGFloat = 24
    static let width: CGFloat = 32
}

struct TerminalPaneHandles: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            if let group = model.terminalGroupID, let tree = model.currentSplitTree, tree.leaves.count > 1 {
                let panes = tree.geometry(in: CGRect(origin: .zero, size: proxy.size)).panes
                ForEach(tree.leaves, id: \.self) { leaf in
                    if let rect = panes[leaf] {
                        TerminalPaneHandle(model: model, group: group, leaf: leaf)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                .id(group)
            }
        }
    }
}

private struct TerminalPaneHandle: View {
    @ObservedObject var model: AppModel
    let group: String
    let leaf: String
    @State private var targeted = false

    var body: some View {
        ZStack(alignment: .top) {
            if targeted {
                Rectangle().strokeBorder(Theme.textSecondary, lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TerminalPaneDragHandle(model: model, group: group, leaf: leaf, onTarget: { targeted = $0 })
                .frame(height: TerminalPaneHandleMetrics.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct TerminalPaneDragHandle: NSViewRepresentable {
    let model: AppModel
    let group: String
    let leaf: String
    let onTarget: (Bool) -> Void

    func makeNSView(context: Context) -> TerminalPaneDragNSView {
        TerminalPaneDragNSView(frame: NSRect(x: 0, y: 0, width: 1, height: TerminalPaneHandleMetrics.height))
    }

    func updateNSView(_ view: TerminalPaneDragNSView, context: Context) {
        view.model = model
        view.group = group
        view.leaf = leaf
        view.onTarget = onTarget
        view.validateActiveDrag()
    }

    static func dismantleNSView(_ view: TerminalPaneDragNSView, coordinator: ()) {
        view.activeDrag = nil
        view.onTarget = nil
    }
}

/// The pasteboard is not authority: only a live source view in this window/model
/// can authorize a swap. No terminal text, paths or session IDs leave on the board.
private final class TerminalPaneDragNSView: NSView, NSDraggingSource {
    private static let pasteboardType = NSPasteboard.PasteboardType("dev.eachann.goose-herdr.pane-swap")
    weak var model: AppModel?
    var group = ""
    var leaf = ""
    var onTarget: ((Bool) -> Void)?
    var activeDrag: AppModel.TerminalPaneDrag?
    private var downEvent: NSEvent?
    private var tracking: NSTrackingArea?
    private var hovering = false
    private var targeted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.pasteboardType])
        toolTip = String(localized: "Drag to another pane's top strip to swap. Click for swap actions.")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Rearrange Terminal Pane"))
        setAccessibilityHelp(toolTip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var handleRect: NSRect {
        NSRect(x: (bounds.width - TerminalPaneHandleMetrics.width) / 2, y: 0,
               width: TerminalPaneHandleMetrics.width, height: TerminalPaneHandleMetrics.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || window?.firstResponder === self || activeDrag != nil || targeted {
            NSColor(Theme.itemWash).setFill()
            NSBezierPath(roundedRect: targeted ? bounds : handleRect, xRadius: 4, yRadius: 4).fill()
        }
        NSColor(Theme.textSecondary).set()
        if targeted {
            let text = String(localized: "Release to Swap Panes") as NSString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            text.draw(in: bounds.insetBy(dx: 4, dy: 4), withAttributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor(Theme.textSecondary), .paragraphStyle: style
            ])
        } else if let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [NSColor(Theme.textSecondary)])) {
            image.draw(in: NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: handleRect, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(handleRect, cursor: .openHand) }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func mouseDown(with event: NSEvent) {
        downEvent = handleRect.contains(convert(event.locationInWindow, from: nil)) ? event : nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, activeDrag == nil, let model else { return }
        guard hypot(event.locationInWindow.x - down.locationInWindow.x,
                    event.locationInWindow.y - down.locationInWindow.y) >= 4,
              let drag = model.beginTerminalPaneDrag(leaf, group: group) else { return }
        activeDrag = drag
        let writer = NSPasteboardItem()
        writer.setString(drag.token, forType: Self.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(handleRect, contents: NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil))
        NSCursor.closedHand.set()
        needsDisplay = true
        beginDraggingSession(with: [item], event: down, source: self)
        downEvent = nil
    }

    override func mouseUp(with event: NSEvent) {
        if downEvent != nil, handleRect.contains(convert(event.locationInWindow, from: nil)) { showSwapMenu() }
        downEvent = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { showSwapMenu() }
        else if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else { super.keyDown(with: event) }
    }

    private var swapActions: [(SplitDirection, AppShortcutID)] {
        [(.left, .swapLeft), (.right, .swapRight), (.up, .swapUp), (.down, .swapDown)]
    }

    private func neighbor(_ direction: SplitDirection) -> String? {
        guard model?.terminalGroupID == group, var tree = model?.currentSplitTree,
              tree.leaves.contains(leaf) else { return nil }
        tree.focusedID = leaf
        return tree.neighbor(direction)
    }

    private func swap(_ direction: SplitDirection) {
        guard let target = neighbor(direction) else { return }
        model?.swapTerminalLeaves(leaf, with: target, group: group)
    }

    private func showSwapMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, action) in swapActions.enumerated() {
            let chord = AppShortcuts.display(for: action.1)
            let item = menu.addItem(withTitle: "\(action.1.conflictLabel)  \(chord)", action: #selector(runSwap(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = neighbor(action.0) != nil
        }
        menu.popUp(positioning: nil, at: NSPoint(x: handleRect.minX, y: bounds.maxY), in: self)
    }

    @objc private func runSwap(_ sender: NSMenuItem) { swap(swapActions[sender.tag].0) }
    override func accessibilityPerformPress() -> Bool { showSwapMenu(); return true }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        swapActions.compactMap { direction, shortcut in
            guard neighbor(direction) != nil else { return nil }
            return NSAccessibilityCustomAction(name: shortcut.conflictLabel) { [weak self] in
                guard let self, self.neighbor(direction) != nil else { return false }
                self.swap(direction)
                return true
            }
        }
    }

    func validateActiveDrag() {
        if let drag = activeDrag,
           model?.terminalGroupID != drag.group || model?.currentSplitTree?.root != drag.root {
            activeDrag = nil
        }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { activeDrag = nil }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        activeDrag = nil
        downEvent = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    private func source(for sender: NSDraggingInfo) -> TerminalPaneDragNSView? {
        guard let source = sender.draggingSource as? TerminalPaneDragNSView,
              let window, source.window === window, let model, source.model === model,
              let drag = source.activeDrag,
              let token = sender.draggingPasteboard.string(forType: Self.pasteboardType),
              model.canDropTerminalPane(drag, token: token, target: leaf, group: group) else { return nil }
        return source
    }

    private func updateTarget(_ sender: NSDraggingInfo) -> NSDragOperation {
        let valid = source(for: sender) != nil
        targeted = valid
        onTarget?(valid)
        needsDisplay = true
        return valid ? .move : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateTarget(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateTarget(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearTarget() }
    override func draggingEnded(_ sender: NSDraggingInfo) { clearTarget() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { source(for: sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearTarget() }
        guard let source = source(for: sender), let drag = source.activeDrag else { return false }
        let success = model?.dropTerminalPane(drag, token: drag.token, target: leaf, group: group) == true
        source.activeDrag = nil
        return success
    }

    private func clearTarget() {
        targeted = false
        onTarget?(false)
        needsDisplay = true
    }
}
