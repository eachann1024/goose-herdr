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

/// Display names for agent kinds in Settings, menus, and the New panel.
enum AgentKindDisplay {
    static func name(for kind: String) -> String {
        switch kind {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "gemini": return "Gemini"
        case "grok": return "Grok"
        case "hermes": return "Hermes"
        case "kimi": return "Kimi"
        case "opencode": return "OpenCode"
        case "pi": return "Pi"
        case "omp": return "Oh My Pi"
        case "copilot": return "Copilot"
        default: return kind.capitalized
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

    /// Settings list order minus kinds the user unchecked.
    static func visibleSorted(_ kinds: [String], store: UserDefaults = .standard) -> [String] {
        AgentKindDisabled.visible(sorted(kinds, store: store), store: store)
    }
}

/// Kinds hidden from the Agent menu after the user unchecks them in Settings.
enum AgentKindDisabled {
    static let defaultsKey = "agents.disabledKinds"
    static let revisionKey = "agents.disabledKinds.revision"

    static func load(store: UserDefaults = .standard) -> Set<String> {
        Set(store.stringArray(forKey: defaultsKey) ?? [])
    }

    static func save(_ kinds: Set<String>, store: UserDefaults = .standard) {
        let values = kinds.sorted()
        if values.isEmpty {
            store.removeObject(forKey: defaultsKey)
        } else {
            store.set(values, forKey: defaultsKey)
        }
        store.set(store.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }

    static func visible(_ kinds: [String], store: UserDefaults = .standard) -> [String] {
        let disabled = load(store: store)
        return kinds.filter { !disabled.contains($0) }
    }
}
