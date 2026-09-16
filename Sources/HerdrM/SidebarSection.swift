import SwiftUI

/// Primary sidebar blocks that can be persistently hidden.
enum SidebarSectionID: String, CaseIterable, Identifiable {
    case actions
    case spaces
    case agents
    case terminals

    var id: String { rawValue }

    static let actionsHiddenKey = "sidebar.actionsHidden"
    static let spacesHiddenKey = "sidebar.spacesHidden"
    static let agentsHiddenKey = "sidebar.agentsHidden"
    static let terminalsHiddenKey = "sidebar.terminalsHidden"

    static let spacesExpandedKey = "sidebar.spacesExpanded"
    static let agentsExpandedKey = "sidebar.agentsExpanded"
    static let terminalsExpandedKey = "sidebar.terminalsExpanded"

    var title: LocalizedStringKey {
        switch self {
        case .actions: return "Actions"
        case .spaces: return "Spaces"
        case .agents: return "Agents"
        case .terminals: return "Terminals"
        }
    }

    var icon: String {
        switch self {
        case .actions: return "bolt"
        case .spaces: return "folder"
        case .agents: return "person.2"
        case .terminals: return "terminal"
        }
    }

    var hiddenKey: String {
        switch self {
        case .actions: return Self.actionsHiddenKey
        case .spaces: return Self.spacesHiddenKey
        case .agents: return Self.agentsHiddenKey
        case .terminals: return Self.terminalsHiddenKey
        }
    }

    var hideHelp: LocalizedStringKey {
        switch self {
        case .actions: return "Hide Actions"
        case .spaces: return "Hide Spaces"
        case .agents: return "Hide Agents"
        case .terminals: return "Hide Terminals"
        }
    }
}
