#!/usr/bin/env python3
"""Runnable settings order + Cursor consent/cancellation gate checks; isolated defaults, no accounts."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
settings = (root / 'Sources/GooseAgent/GooseAgentApp.swift').read_text().split('struct AgentsSettingsView:', 1)[1].split('struct TerminalSettingsView:', 1)[0]
usage = (root / 'Sources/GooseAgent/UsagePanel.swift').read_text()
assert '.onChange(of: drafts)' not in settings
assert '.onDisappear(perform: commit)' not in settings
assert '.onSubmit { commit(row.kind) }' in settings
assert 'saved[kind] = path' in settings
assert 'Self.knownKinds.map(\\.kind)' in settings
assert 'selectedKind' not in settings
assert 'agentCatalogWidth' not in settings
assert 'inspector(' not in settings
assert settings.count('ScrollView {') == 1
assert 'if expandedKind == row.kind {' in settings
assert 'rowDetails(row)' in settings
assert 'expandedKind = expandedKind == row.kind ? nil : row.kind' in settings
assert 'self.expandedKind = nil' in settings
assert 'hoveredKind == row.kind || focusedControl?.hasPrefix(row.kind + ".") == true' in settings
assert '.opacity(showTools ? 1 : 0)' in settings
assert r'Toggle("Enable \(row.label)", isOn: enabledBinding(row.kind))' in settings
assert 'CursorUsageAccountView(usage: model.usage, enabled: !disabled.contains(row.kind))' in settings
assert '.frame(height: 1)' in settings
assert '.onDrag' in settings and 'Self.dragType' in settings
assert '.onMove(' not in settings  # Only the dedicated handle starts a drag.
assert 'Move Agent up' in settings and 'Move Agent down' in settings
assert 'Image(systemName: "arrow.up")' not in settings
assert 'Image(systemName: "arrow.down")' not in settings
assert 'or use the arrow buttons' not in settings
assert 'AgentKindOrder.save(orderedRows.map(\\.kind))' in settings
assert 'if !orderedRows.isEmpty { return }' in settings
assert 'if cursorAuthorized && !AgentKindDisabled.load().contains("cursor")' in usage
assert 'provider != "cursor" || self.cursorAuthorized' in usage
assert 'environment["GOOSE_CURSOR_USAGE_AUTHORIZED"] = "1"' in usage

order = (root / 'Sources/GooseAgent/SidebarSection.swift').read_text().split('enum AgentKindOrder {', 1)[1]
owner = usage.split('/// Shares the application-owned cache', 1)[0].replace('import HerdrKit\n', '')
# Every UserDefaults access in this harness goes to an ephemeral suite.
owner = owner.replace('UserDefaults.standard', 'fixtureDefaults')
with tempfile.TemporaryDirectory(prefix='goose-inspector-check-') as directory:
    script = Path(directory) / 'check.swift'
    script.write_text(owner + '\n' + (root / 'Sources/GooseAgent/UsageRequestGate.swift').read_text() + '''
let fixtureSuite = "goose.inspector.fixture." + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: fixtureSuite)!
''' + 'enum AgentKindOrder {' + order + '''
struct Row { let kind: String }
var orderedRows = ["claude", "cursor", "codex"].map { Row(kind: $0) }
func moveRows(from source: IndexSet, to destination: Int) {
    orderedRows.move(fromOffsets: source, toOffset: destination)
    AgentKindOrder.save(orderedRows.map(\\.kind), store: fixtureDefaults)
}
moveRows(from: IndexSet(integer: 0), to: 3)
assert(orderedRows.map(\\.kind) == ["cursor", "codex", "claude"])
moveRows(from: IndexSet(integer: 2), to: 0)
assert(orderedRows.map(\\.kind) == ["claude", "cursor", "codex"])
assert(AgentKindOrder.sorted(["codex", "claude", "cursor", "pi"], store: fixtureDefaults) == ["claude", "cursor", "codex", "pi"])
assert(AgentKindOrder.sorted(["codex", "cursor"], store: fixtureDefaults) == ["cursor", "codex"])

extension UsagePanelModel {
    func verifyConsentGate() {
        catalog = { ["cursor"] }
        configure()
        assert(!gate.enabled.contains("cursor"))
        fixtureDefaults.set(true, forKey: Self.cursorAuthorizationKey)
        configure()
        assert(gate.enabled.contains("cursor"))
        let revision = gate.generation
        assert(gate.accepts(provider: "cursor", generation: revision))
        // Use a harmless process to exercise the production termination branch.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["10"]
        try! sleeper.run()
        processes["cursor"] = sleeper
        disconnectCursor()
        sleeper.waitUntilExit()
        assert(sleeper.terminationStatus != 0)
        assert(!cursorAuthorized)
        assert(!gate.accepts(provider: "cursor", generation: revision))
        assert(snapshots.isEmpty && cursorUpdatedAt == nil && cursorFailure == nil)
        fixtureDefaults.set(true, forKey: Self.cursorAuthorizationKey)
        gate.replace(enabled: ["cursor"])
        let next = gate.generation
        // Agent disable revokes consent even before a late response arrives.
        AgentKindDisabled.save(["cursor"], store: fixtureDefaults)
        configure()
        assert(!cursorAuthorized)
        assert(!gate.accepts(provider: "cursor", generation: next))
        stop()
    }
}
MainActor.assumeIsolated { UsagePanelModel().verifyConsentGate() }
fixtureDefaults.removePersistentDomain(forName: fixtureSuite)
'''.replace('store: UserDefaults = .standard', 'store: UserDefaults = fixtureDefaults'))
    # Route the real disabled-kind helpers to the ephemeral suite too.
    text = script.read_text().replace('store: UserDefaults = .standard', 'store: UserDefaults = fixtureDefaults')
    script.write_text(text)
    result = subprocess.run(['swift', str(script)], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr
print('PASS: A native list/inline disclosure contracts, stable persisted kind order, no per-keystroke detection, actual Cursor consent/disable/disconnect cancellation and late-result gate')
