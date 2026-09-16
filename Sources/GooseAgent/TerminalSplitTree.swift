import Foundation
import CoreGraphics

/// Geometry only: terminal ownership stays in the flat, stable view collection.
enum SplitAxis { case vertical, horizontal }
enum SplitDirection { case left, right, up, down }

struct TerminalSplitTree: Equatable {
    indirect enum Node: Equatable {
        case leaf(String)
        case split(UUID, SplitAxis, Double, Node, Node)

        var leaves: [String] {
            switch self {
            case .leaf(let id): return [id]
            case .split(_, _, _, let first, let second): return first.leaves + second.leaves
            }
        }

        func replacing(_ id: String, with replacement: Node?) -> Node? {
            switch self {
            case .leaf(let leaf): return leaf == id ? replacement : self
            case .split(let key, let axis, let ratio, let first, let second):
                let a = first.replacing(id, with: replacement)
                let b = second.replacing(id, with: replacement)
                if let a, let b { return .split(key, axis, ratio, a, b) }
                return a ?? b
            }
        }

        func swapping(_ source: String, _ target: String) -> Node {
            switch self {
            case .leaf(let id): return .leaf(id == source ? target : id == target ? source : id)
            case .split(let id, let axis, let ratio, let a, let b):
                return .split(id, axis, ratio, a.swapping(source, target), b.swapping(source, target))
            }
        }

        func settingRatio(_ id: UUID, to value: Double) -> Node {
            guard case .split(let key, let axis, let ratio, let a, let b) = self else { return self }
            return .split(key, axis, key == id ? min(0.8, max(0.2, value)) : ratio,
                          a.settingRatio(id, to: value), b.settingRatio(id, to: value))
        }

        // A perpendicular subtree occupies one column/row, not one per leaf.
        func weight(along axis: SplitAxis) -> Double {
            guard case .split(_, let ownAxis, _, let a, let b) = self else { return 1 }
            return ownAxis == axis ? a.weight(along: axis) + b.weight(along: axis) : 1
        }

        var equalized: Node {
            guard case .split(let key, let axis, _, let a, let b) = self else { return self }
            let first = a.weight(along: axis)
            return .split(key, axis, first / (first + b.weight(along: axis)), a.equalized, b.equalized)
        }

        func ancestor(of id: String, along axis: SplitAxis) -> (UUID, Double, Bool)? {
            guard case .split(let key, let ownAxis, let ratio, let a, let b) = self else { return nil }
            let inFirst = a.leaves.contains(id)
            guard inFirst || b.leaves.contains(id) else { return nil }
            return (inFirst ? a : b).ancestor(of: id, along: axis)
                ?? (ownAxis == axis ? (key, ratio, inFirst) : nil)
        }
    }

    struct Divider: Identifiable {
        let id: UUID
        let axis: SplitAxis
        let ratio: Double
        let container: CGRect
        let frame: CGRect
    }

    var root: Node
    var focusedID: String
    init(_ id: String) { root = .leaf(id); focusedID = id }
    var leaves: [String] { root.leaves }

    mutating func insert(_ id: String, beside source: String, axis: SplitAxis) {
        guard leaves.contains(source), !leaves.contains(id) else { return }
        root = root.replacing(source, with: .split(UUID(), axis, 0.5, .leaf(source), .leaf(id)))!
        focusedID = id
    }

    /// Returns false only for the last leaf; its owner applies the existing close policy.
    @discardableResult
    mutating func close(_ id: String) -> Bool {
        let old = leaves
        guard let index = old.firstIndex(of: id), let next = root.replacing(id, with: nil) else { return false }
        root = next
        if focusedID == id { focusedID = index + 1 < old.count ? old[index + 1] : leaves.last! }
        return true
    }

    /// Move geometry, not ownership; focus follows the moved terminal only on success.
    @discardableResult
    mutating func swap(_ source: String, with target: String) -> Bool {
        guard source != target, leaves.contains(source), leaves.contains(target) else { return false }
        root = root.swapping(source, target)
        focusedID = source
        return true
    }

    mutating func resize(along axis: SplitAxis, grow: Bool) {
        guard let (id, ratio, first) = root.ancestor(of: focusedID, along: axis) else { return }
        root = root.settingRatio(id, to: ratio + (grow == first ? 0.05 : -0.05))
    }

    func geometry(in bounds: CGRect, dividerWidth: Double = 1) -> (panes: [String: CGRect], dividers: [Divider]) {
        var panes: [String: CGRect] = [:]
        var dividers: [Divider] = []
        func visit(_ node: Node, _ rect: CGRect) {
            switch node {
            case .leaf(let id): panes[id] = rect
            case .split(let id, let axis, let ratio, let a, let b):
                let vertical = axis == .vertical
                let available = max(0, (vertical ? rect.width : rect.height) - dividerWidth)
                let length = available * ratio
                let first = CGRect(x: rect.minX, y: rect.minY,
                                   width: vertical ? length : rect.width, height: vertical ? rect.height : length)
                let divider = CGRect(x: vertical ? first.maxX : rect.minX, y: vertical ? rect.minY : first.maxY,
                                     width: vertical ? dividerWidth : rect.width, height: vertical ? rect.height : dividerWidth)
                let second = CGRect(x: vertical ? divider.maxX : rect.minX, y: vertical ? rect.minY : divider.maxY,
                                    width: vertical ? available - length : rect.width, height: vertical ? rect.height : available - length)
                dividers.append(Divider(id: id, axis: axis, ratio: ratio, container: rect, frame: divider))
                visit(a, first); visit(b, second)
            }
        }
        visit(root, bounds)
        return (panes, dividers)
    }

    func neighbor(_ direction: SplitDirection) -> String? {
        let panes = geometry(in: CGRect(x: 0, y: 0, width: 1, height: 1), dividerWidth: 0).panes
        guard let source = panes[focusedID] else { return nil }
        return leaves.filter { id in
            guard id != focusedID, let r = panes[id] else { return false }
            switch direction {
            case .left: return r.maxX <= source.minX + 0.000001 && r.maxY > source.minY && r.minY < source.maxY
            case .right: return r.minX >= source.maxX - 0.000001 && r.maxY > source.minY && r.minY < source.maxY
            case .up: return r.maxY <= source.minY + 0.000001 && r.maxX > source.minX && r.minX < source.maxX
            case .down: return r.minY >= source.maxY - 0.000001 && r.maxX > source.minX && r.minX < source.maxX
            }
        }.min { a, b in
            let x = panes[a]!, y = panes[b]!
            return hypot(x.midX - source.midX, x.midY - source.midY) < hypot(y.midX - source.midX, y.midY - source.midY)
        }
    }
}
