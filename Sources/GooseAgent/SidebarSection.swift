import SwiftUI

enum SidebarSectionID {
    static let spacesHiddenKey = "sidebar.spacesHidden"
    static let spacesExpandedKey = "sidebar.spacesExpanded"
}

/// Top quick-action rows — each hidden independently.
enum SidebarActionID: String, CaseIterable, Identifiable {
    case newTerminal
    case newSpace
    case files
    case search

    var id: String { rawValue }

    var hiddenKey: String { "sidebar.action.\(rawValue)Hidden" }

    var title: LocalizedStringKey {
        switch self {
        case .newTerminal: return "New Terminal"
        case .newSpace: return "New Space"
        case .files: return "Files"
        case .search: return "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .newTerminal: return "terminal"
        case .newSpace: return "plus"
        case .files: return "folder"
        case .search: return "magnifyingglass"
        }
    }
}

/// Display order for agent kinds in Settings and the Agent menu.
enum AgentKindOrder {
    static let defaultsKey = "agents.kindOrder"

    static func load(store: UserDefaults = .standard) -> [String] {
        store.stringArray(forKey: defaultsKey) ?? []
    }

    static func save(_ order: [String], store: UserDefaults = .standard) {
        if order.isEmpty {
            store.removeObject(forKey: defaultsKey)
        } else {
            store.set(order, forKey: defaultsKey)
        }
    }

    /// Saved order first; kinds missing from the save keep their relative input order at the end.
    static func sorted(_ kinds: [String], store: UserDefaults = .standard) -> [String] {
        let saved = load(store: store)
        var result: [String] = []
        for kind in saved where kinds.contains(kind) && !result.contains(kind) {
            result.append(kind)
        }
        for kind in kinds where !result.contains(kind) {
            result.append(kind)
        }
        return result
    }
}
