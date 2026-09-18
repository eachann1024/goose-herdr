// Run: swiftc Sources/GooseAgent/KeyboardShortcuts.swift Tests/KeyboardShortcutsCheck.swift -o /tmp/goose-shortcuts-check && /tmp/goose-shortcuts-check
import Foundation

@main
struct KeyboardShortcutsCheck {
    static func main() {
        let name = "KeyboardShortcutsCheck.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }

        assert(AppShortcuts.chord(for: .newItem, store: store) == KeyChord(key: "t", modifiers: .command))
        assert(AppShortcuts.chord(for: .quickNewTerminal, store: store) == KeyChord(key: "t", modifiers: [.command, .shift]))
        assert(Set(AppShortcutID.allCases.map(\.defaultChord)).count == AppShortcutID.allCases.count)

        let custom = KeyChord(key: "t", modifiers: .control)
        AppShortcuts.set(custom, for: .newItem, store: store)
        assert(AppShortcuts.chord(for: .newItem, store: store) == custom)
        AppShortcuts.set(AppShortcutID.newItem.defaultChord, for: .search, store: store)
        assert(AppShortcuts.isChordTaken(AppShortcutID.newItem.defaultChord, excludingGeneral: .newItem, store: store) != nil)
        AppShortcuts.reset(.search, store: store)
        assert(AppShortcuts.isChordTaken(AppShortcutID.newItem.defaultChord, excludingGeneral: .newItem, store: store) == nil)

        AgentKindShortcuts.set(AppShortcutID.newItem.defaultChord, for: "codex", store: store)
        assert(AppShortcuts.isChordTaken(AppShortcutID.newItem.defaultChord, excludingGeneral: .newItem, store: store) == "codex")
        AppShortcuts.set(AgentKindShortcuts.defaultChord(for: "pi")!, for: .search, store: store)
        assert(AppShortcuts.isChordTaken(AgentKindShortcuts.defaultChord(for: "pi")!, excludingAgentKind: "pi", store: store) != nil)
        print("Keyboard shortcut checks passed")
    }
}
