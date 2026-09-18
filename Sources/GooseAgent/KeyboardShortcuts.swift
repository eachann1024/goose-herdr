import AppKit
import SwiftUI

/// Remappable app shortcuts. Stored as JSON in UserDefaults; menus and help text read live.
enum AppShortcutID: String, CaseIterable, Identifiable {
    case newItem
    case quickNewTerminal
    case newSpace
    case search
    case settings
    case toggleSidebar
    case close
    case splitVertical
    case splitHorizontal
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case swapLeft
    case swapRight
    case swapUp
    case swapDown
    case widenPane
    case narrowPane
    case growPane
    case shrinkPane
    case equalizeSplits

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .newItem: return "New"
        case .quickNewTerminal: return "New Terminal"
        case .newSpace: return "New Space"
        case .search: return "Search"
        case .settings: return "Settings"
        case .toggleSidebar: return "Toggle Sidebar"
        case .close: return "Close"
        case .splitVertical: return "Split Vertically"
        case .splitHorizontal: return "Split Horizontally"
        case .focusLeft: return "Focus Left Pane"
        case .focusRight: return "Focus Right Pane"
        case .focusUp: return "Focus Top Pane"
        case .focusDown: return "Focus Bottom Pane"
        case .widenPane: return "Widen Active Pane"
        case .narrowPane: return "Narrow Active Pane"
        case .growPane: return "Grow Active Pane"
        case .shrinkPane: return "Shrink Active Pane"
        case .swapLeft: return "Swap with Left Pane"
        case .swapRight: return "Swap with Right Pane"
        case .swapUp: return "Swap with Top Pane"
        case .swapDown: return "Swap with Bottom Pane"
        case .equalizeSplits: return "Equalize Splits"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .newItem: return "Opens the New panel to choose a space and agent"
        case .quickNewTerminal: return "Opens a terminal in the current space; in Priority sessions or All Spaces, pick the space first"
        case .newSpace: return "Opens the New Space sheet"
        case .search: return "Opens the search sheet"
        case .settings: return "Opens the Settings window"
        case .toggleSidebar: return "Collapse or show the sidebar"
        case .close: return "Close split, terminal, agent, space, or window"
        case .splitVertical: return "Open a local terminal to the right of the focused pane"
        case .splitHorizontal: return "Open a local terminal below the focused pane"
        case .focusLeft: return "Move focus to the neighboring pane on the left"
        case .focusRight: return "Move focus to the neighboring pane on the right"
        case .focusUp: return "Move focus to the neighboring pane above"
        case .focusDown: return "Move focus to the neighboring pane below"
        case .widenPane: return "Increase the width of the focused pane"
        case .narrowPane: return "Decrease the width of the focused pane"
        case .growPane: return "Increase the height of the focused pane"
        case .shrinkPane: return "Decrease the height of the focused pane"
        case .swapLeft: return "Swap the focused terminal with the neighboring pane on the left"
        case .swapRight: return "Swap the focused terminal with the neighboring pane on the right"
        case .swapUp: return "Swap the focused terminal with the neighboring pane above"
        case .swapDown: return "Swap the focused terminal with the neighboring pane below"
        case .equalizeSplits: return "Give panes equal space along each split axis"
        }
    }

    var conflictLabel: String {
        switch self {
        case .newItem: return String(localized: "New")
        case .quickNewTerminal: return String(localized: "New Terminal")
        case .newSpace: return String(localized: "New Space")
        case .search: return String(localized: "Search")
        case .settings: return String(localized: "Settings")
        case .toggleSidebar: return String(localized: "Toggle Sidebar")
        case .close: return String(localized: "Close")
        case .splitVertical: return String(localized: "Split Vertically")
        case .splitHorizontal: return String(localized: "Split Horizontally")
        case .focusLeft: return String(localized: "Focus Left Pane")
        case .focusRight: return String(localized: "Focus Right Pane")
        case .focusUp: return String(localized: "Focus Top Pane")
        case .focusDown: return String(localized: "Focus Bottom Pane")
        case .widenPane: return String(localized: "Widen Active Pane")
        case .narrowPane: return String(localized: "Narrow Active Pane")
        case .growPane: return String(localized: "Grow Active Pane")
        case .shrinkPane: return String(localized: "Shrink Active Pane")
        case .swapLeft: return String(localized: "Swap with Left Pane")
        case .swapRight: return String(localized: "Swap with Right Pane")
        case .swapUp: return String(localized: "Swap with Top Pane")
        case .swapDown: return String(localized: "Swap with Bottom Pane")
        case .equalizeSplits: return String(localized: "Equalize Splits")
        }
    }

    var defaultChord: KeyChord {
        switch self {
        case .newItem: return KeyChord(key: "n", modifiers: [.command, .shift])
        case .quickNewTerminal: return KeyChord(key: "t", modifiers: .command)
        case .newSpace: return KeyChord(key: "n", modifiers: .command)
        case .search: return KeyChord(key: "k", modifiers: .command)
        case .settings: return KeyChord(key: ",", modifiers: .command)
        case .toggleSidebar: return KeyChord(key: "b", modifiers: .command)
        case .close: return KeyChord(key: "w", modifiers: .command)
        case .splitVertical: return KeyChord(key: "d", modifiers: .command)
        case .splitHorizontal: return KeyChord(key: "d", modifiers: [.command, .shift])
        case .focusLeft: return KeyChord(key: "\u{F702}", modifiers: [.command, .option])
        case .focusRight: return KeyChord(key: "\u{F703}", modifiers: [.command, .option])
        case .focusUp: return KeyChord(key: "\u{F700}", modifiers: [.command, .option])
        case .focusDown: return KeyChord(key: "\u{F701}", modifiers: [.command, .option])
        case .widenPane: return KeyChord(key: "\u{F703}", modifiers: [.command, .control])
        case .narrowPane: return KeyChord(key: "\u{F702}", modifiers: [.command, .control])
        case .growPane: return KeyChord(key: "\u{F701}", modifiers: [.command, .control])
        case .shrinkPane: return KeyChord(key: "\u{F700}", modifiers: [.command, .control])
        case .swapLeft: return KeyChord(key: "\u{F702}", modifiers: [.command, .option, .shift])
        case .swapRight: return KeyChord(key: "\u{F703}", modifiers: [.command, .option, .shift])
        case .swapUp: return KeyChord(key: "\u{F700}", modifiers: [.command, .option, .shift])
        case .swapDown: return KeyChord(key: "\u{F701}", modifiers: [.command, .option, .shift])
        case .equalizeSplits: return KeyChord(key: "=", modifiers: [.command, .control])
        }
    }
}

struct KeyChord: Codable, Equatable, Hashable {
    var key: String
    /// Raw value bits matching `EventModifiers` we care about.
    var modifierRaw: Int

    init(key: String, modifiers: EventModifiers) {
        self.key = key
        self.modifierRaw = Self.pack(modifiers)
    }

    var modifiers: EventModifiers { Self.unpack(modifierRaw) }

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(key))
    }

    var display: String {
        var parts: [String] = []
        let m = modifiers
        if m.contains(.control) { parts.append("⌃") }
        if m.contains(.option) { parts.append("⌥") }
        if m.contains(.shift) { parts.append("⇧") }
        if m.contains(.command) { parts.append("⌘") }
        let arrows = ["\u{F702}": "←", "\u{F703}": "→", "\u{F700}": "↑", "\u{F701}": "↓"]
        parts.append(arrows[key] ?? key.uppercased())
        return parts.joined()
    }

    static func pack(_ modifiers: EventModifiers) -> Int {
        var raw = 0
        if modifiers.contains(.command) { raw |= 1 << 0 }
        if modifiers.contains(.option) { raw |= 1 << 1 }
        if modifiers.contains(.shift) { raw |= 1 << 2 }
        if modifiers.contains(.control) { raw |= 1 << 3 }
        return raw
    }

    static func unpack(_ raw: Int) -> EventModifiers {
        var m: EventModifiers = []
        if raw & (1 << 0) != 0 { m.insert(.command) }
        if raw & (1 << 1) != 0 { m.insert(.option) }
        if raw & (1 << 2) != 0 { m.insert(.shift) }
        if raw & (1 << 3) != 0 { m.insert(.control) }
        return m
    }

    static func from(event: NSEvent) -> KeyChord? {
        guard let chars = event.charactersIgnoringModifiers, let ch = chars.lowercased().first else {
            return nil
        }
        // Ignore pure modifier taps.
        guard ch.asciiValue != nil || ch.isLetter || ch.isNumber || ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}"].contains(String(ch)) else { return nil }
        var mods: EventModifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        // Require at least one modifier so typing in fields isn't captured as a shortcut.
        guard !mods.isEmpty else { return nil }
        return KeyChord(key: String(ch), modifiers: mods)
    }
}

enum AppShortcuts {
    static let storageKey = "app.keyboardShortcuts"
    static let revisionKey = "app.keyboardShortcuts.revision"

    static func chord(for id: AppShortcutID, store: UserDefaults = .standard) -> KeyChord {
        loadAll(store: store)[id.rawValue] ?? id.defaultChord
    }

    static func set(_ chord: KeyChord, for id: AppShortcutID, store: UserDefaults = .standard) {
        var all = loadAll(store: store)
        all[id.rawValue] = chord
        saveAll(all, store: store)
    }

    static func reset(_ id: AppShortcutID, store: UserDefaults = .standard) {
        var all = loadAll(store: store)
        all.removeValue(forKey: id.rawValue)
        saveAll(all, store: store)
    }

    static func resetAll(store: UserDefaults = .standard) {
        store.removeObject(forKey: storageKey)
        bumpRevision(store: store)
    }

    static func display(for id: AppShortcutID, store: UserDefaults = .standard) -> String {
        chord(for: id, store: store).display
    }

    static func conflict(for chord: KeyChord, excluding: AppShortcutID, store: UserDefaults = .standard) -> AppShortcutID? {
        AppShortcutID.allCases.first { other in
            other != excluding && self.chord(for: other, store: store) == chord
        }
    }

    /// True if `chord` is already used by a general shortcut or an agent-kind shortcut.
    static func isChordTaken(_ chord: KeyChord, excludingGeneral: AppShortcutID? = nil, excludingAgentKind: String? = nil, store: UserDefaults = .standard) -> String? {
        if let other = AppShortcutID.allCases.first(where: {
            $0 != excludingGeneral && self.chord(for: $0, store: store) == chord
        }) {
            return other.conflictLabel
        }
        if let kind = AgentKindShortcuts.conflict(for: chord, excluding: excludingAgentKind, store: store) {
            return kind
        }
        return nil
    }

    private static func loadAll(store: UserDefaults) -> [String: KeyChord] {
        guard let data = store.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: KeyChord].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func saveAll(_ all: [String: KeyChord], store: UserDefaults) {
        if all.isEmpty {
            store.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(all) {
            store.set(data, forKey: storageKey)
        }
        bumpRevision(store: store)
    }

    static func bumpRevision(store: UserDefaults) {
        store.set(store.integer(forKey: revisionKey) + 1, forKey: revisionKey)
    }
}


/// Per detected agent-kind remappable shortcuts (Settings → Shortcuts → Agent).
enum AgentKindShortcuts {
    static let storageKey = "app.keyboardShortcuts.agentKinds"

    static func load(store: UserDefaults = .standard) -> [String: KeyChord] {
        guard let data = store.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: KeyChord].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ map: [String: KeyChord], store: UserDefaults = .standard) {
        if map.isEmpty {
            store.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(map) {
            store.set(data, forKey: storageKey)
        }
        AppShortcuts.bumpRevision(store: store)
    }

    static func defaultChord(for kind: String) -> KeyChord? {
        switch kind {
        case "pi": return KeyChord(key: "p", modifiers: .option)
        default: return nil
        }
    }

    static func chord(for kind: String, store: UserDefaults = .standard) -> KeyChord? {
        load(store: store)[kind] ?? defaultChord(for: kind)
    }

    static func set(_ chord: KeyChord?, for kind: String, store: UserDefaults = .standard) {
        var all = load(store: store)
        if let chord {
            all[kind] = chord
        } else {
            all.removeValue(forKey: kind)
        }
        save(all, store: store)
    }

    static func display(for kind: String, store: UserDefaults = .standard) -> String {
        chord(for: kind, store: store)?.display ?? String(localized: "Unbound")
    }

    static func conflict(for chord: KeyChord, excluding: String?, store: UserDefaults = .standard) -> String? {
        let stored = load(store: store)
        if let hit = stored.first(where: { kind, existing in
            kind != excluding && existing == chord
        })?.key {
            return hit
        }
        for kind in ["pi"] where kind != excluding && stored[kind] == nil {
            if defaultChord(for: kind) == chord { return kind }
        }
        return nil
    }

    static func resetAll(store: UserDefaults = .standard) {
        store.removeObject(forKey: storageKey)
        AppShortcuts.bumpRevision(store: store)
    }
}
