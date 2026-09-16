import AppKit
import SwiftUI

/// Remappable app shortcuts. Stored as JSON in UserDefaults; menus and help text read live.
enum AppShortcutID: String, CaseIterable, Identifiable {
    case quickNewTerminal
    case newSpace
    case close

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .quickNewTerminal: return "New Terminal"
        case .newSpace: return "New Space"
        case .close: return "Close"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .quickNewTerminal: return "Opens a terminal in the current space"
        case .newSpace: return "Opens the New Space sheet"
        case .close: return "Close split, terminal, agent, or window"
        }
    }

    var conflictLabel: String {
        switch self {
        case .quickNewTerminal: return String(localized: "New Terminal")
        case .newSpace: return String(localized: "New Space")
        case .close: return String(localized: "Close")
        }
    }

    var defaultChord: KeyChord {
        switch self {
        case .quickNewTerminal: return KeyChord(key: "t", modifiers: .command)
        case .newSpace: return KeyChord(key: "n", modifiers: .command)
        case .close: return KeyChord(key: "w", modifiers: .command)
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
        parts.append(key.uppercased())
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
        guard ch.asciiValue != nil || ch.isLetter || ch.isNumber else { return nil }
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
