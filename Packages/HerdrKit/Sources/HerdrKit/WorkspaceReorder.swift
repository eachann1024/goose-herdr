import Foundation

/// Computes a `workspace.move_block` call from a sidebar drop.
///
/// `orderedIDs` is one device's workspace list (herdr's `number` order). The
/// drop target is another id in that list; `placeAfter` is which half of the
/// row the pointer was in. Returns `nil` when the drop would not change order
/// (same row, already adjacent, unknown ids).
public enum WorkspaceReorder: Sendable {
    public struct Plan: Equatable, Sendable {
        public let workspaceIDs: [String]
        public let beforeWorkspaceID: String?

        public init(workspaceIDs: [String], beforeWorkspaceID: String?) {
            self.workspaceIDs = workspaceIDs
            self.beforeWorkspaceID = beforeWorkspaceID
        }
    }

    public static func plan(
        moving: String,
        onto: String,
        placeAfter: Bool,
        orderedIDs: [String]
    ) -> Plan? {
        guard orderedIDs.contains(moving), orderedIDs.contains(onto) else { return nil }

        let before: String?
        if placeAfter {
            guard let ontoIndex = orderedIDs.firstIndex(of: onto) else { return nil }
            let next = orderedIDs.index(after: ontoIndex)
            before = next < orderedIDs.endIndex ? orderedIDs[next] : nil
        } else {
            before = onto
        }

        if before == moving { return nil }
        if isAlreadyThere(moving: moving, before: before, orderedIDs: orderedIDs) {
            return nil
        }
        return Plan(workspaceIDs: [moving], beforeWorkspaceID: before)
    }

    /// The `workspace.move_block` call a local reorder still needs, or `nil` when
    /// herdr cannot see it. `isLive` marks the rows herdr still knows: a closed
    /// space kept as a sidebar placeholder holds a dead `workspace_id`, so moving
    /// it — or moving a live row across one — changes no live order and has to
    /// stay local. Herdr rejects the dead id with `workspace_not_found`.
    public static func liveMove(
        moving: String,
        previousOrder: [String],
        newOrder: [String],
        isLive: (String) -> Bool
    ) -> Plan? {
        guard isLive(moving) else { return nil }
        let before = previousOrder.filter(isLive)
        let after = newOrder.filter(isLive)
        guard before != after else { return nil }
        let next = after.drop { $0 != moving }.dropFirst().first
        return Plan(workspaceIDs: [moving], beforeWorkspaceID: next)
    }

    /// Applies a block move to a workspace array the same way herdr does:
    /// pull `workspaceIDs` out, then splice them in before `beforeWorkspaceID`
    /// (or at the end when that is nil).
    public static func applying<T>(
        _ items: [T],
        id: (T) -> String,
        plan: Plan
    ) -> [T] {
        let moving = Set(plan.workspaceIDs)
        var remaining = items.filter { !moving.contains(id($0)) }
        let block = plan.workspaceIDs.compactMap { wanted in items.first { id($0) == wanted } }
        let insertAt: Int
        if let before = plan.beforeWorkspaceID {
            insertAt = remaining.firstIndex { id($0) == before } ?? remaining.count
        } else {
            insertAt = remaining.count
        }
        remaining.insert(contentsOf: block, at: insertAt)
        return remaining
    }

    private static func isAlreadyThere(
        moving: String,
        before: String?,
        orderedIDs: [String]
    ) -> Bool {
        guard let movingIndex = orderedIDs.firstIndex(of: moving) else { return false }
        if let before {
            return orderedIDs.firstIndex(of: before) == orderedIDs.index(after: movingIndex)
        }
        return movingIndex == orderedIDs.index(before: orderedIDs.endIndex)
    }
}
