import SwiftUI

/// Sidebar blocks / quick-action rows that can be persistently hidden one by one.
enum SidebarSectionID: String, CaseIterable, Identifiable {
    case spaces
    case agents
    case terminals

    var id: String { rawValue }

    static let spacesHiddenKey = "sidebar.spacesHidden"
    static let agentsHiddenKey = "sidebar.agentsHidden"
    static let terminalsHiddenKey = "sidebar.terminalsHidden"

    static let spacesExpandedKey = "sidebar.spacesExpanded"
    static let agentsExpandedKey = "sidebar.agentsExpanded"
    static let terminalsExpandedKey = "sidebar.terminalsExpanded"

    var title: LocalizedStringKey {
        switch self {
        case .spaces: return "Spaces"
        case .agents: return "Agents"
        case .terminals: return "Terminals"
        }
    }

    var hideHelp: LocalizedStringKey {
        switch self {
        case .spaces: return "Hide Spaces"
        case .agents: return "Hide Agents"
        case .terminals: return "Hide Terminals"
        }
    }

    var hiddenKey: String {
        switch self {
        case .spaces: return Self.spacesHiddenKey
        case .agents: return Self.agentsHiddenKey
        case .terminals: return Self.terminalsHiddenKey
        }
    }
}

/// Top quick-action rows — each hidden independently.
enum SidebarActionID: String, CaseIterable, Identifiable {
    case newAgent
    case newTerminal
    case newSpace
    case files
    case search

    var id: String { rawValue }

    var hiddenKey: String { "sidebar.action.\(rawValue)Hidden" }

    var title: LocalizedStringKey {
        switch self {
        case .newAgent: return "New Agent"
        case .newTerminal: return "New Terminal"
        case .newSpace: return "New Space"
        case .files: return "Files"
        case .search: return "Search"
        }
    }

    var hideHelp: LocalizedStringKey {
        switch self {
        case .newAgent: return "Hide New Agent"
        case .newTerminal: return "Hide New Terminal"
        case .newSpace: return "Hide New Space"
        case .files: return "Hide Files"
        case .search: return "Hide Search"
        }
    }

    var systemImage: String {
        switch self {
        case .newAgent: return "square.and.pencil"
        case .newTerminal: return "terminal"
        case .newSpace: return "folder.badge.plus"
        case .files: return "folder"
        case .search: return "magnifyingglass"
        }
    }
}

/// Which agent kinds appear in the New Agent sheet. Missing key = enabled.
enum AgentKindVisibility {
    static let defaultsKey = "agents.kindVisibility"

    static func isEnabled(_ kind: String, store: UserDefaults = .standard) -> Bool {
        let map = store.dictionary(forKey: defaultsKey) as? [String: Bool] ?? [:]
        return map[kind] ?? true
    }

    static func setEnabled(_ kind: String, _ enabled: Bool, store: UserDefaults = .standard) {
        var map = store.dictionary(forKey: defaultsKey) as? [String: Bool] ?? [:]
        map[kind] = enabled
        store.set(map, forKey: defaultsKey)
    }
}
