#!/usr/bin/env python3
"""Isolated Orca Kimi → Node helper → native Fetch smoke check (no accounts/network)."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'build/usage-fixture-bundle/UsageHelper'
NODE = BUNDLE / 'runtime/arm64/node'
assert NODE.is_file()
assert (BUNDLE / 'runtime/arm64/LICENSE').is_file()
assert (BUNDLE / 'vendor/orca/LICENSE').is_file()
VENDOR = ROOT / 'UsageHelper/vendor/orca'
manifest = json.loads((VENDOR / 'provenance.json').read_text())
assert manifest['commit'] == 'fbe7b194b8b6e05bf945aaef67ab3b3789f110fd'
for name, digest in manifest['files'].items():
    assert hashlib.sha256((VENDOR / name).read_bytes()).hexdigest() == digest, name

with tempfile.TemporaryDirectory(prefix='goose-usage-fixture-') as directory:
    home = Path(directory)
    credentials = home / 'credentials/kimi-code.json'
    credentials.parent.mkdir()
    credentials.write_text(json.dumps({'access_token': 'isolated-fixture-not-a-token',
                                      'expires_at': int(time.time()) + 3600}))
    before = credentials.read_bytes()
    payload = {'usage': {'limit': '100', 'remaining': '65'},
               'limits': [{'window': {'duration': 5, 'timeUnit': 'HOUR'},
                           'detail': {'limit': 100, 'used': 21}}]}
    # Fetch handles data URLs natively. The appended /usages is a URL fragment;
    # no mock transport, listening server, DNS or real credentials are involved.
    env = {'PATH': '/usr/bin:/bin', 'HOME': directory, 'KIMI_CODE_HOME': directory,
           'KIMI_CODE_BASE_URL': 'data:application/json,' + quote(json.dumps(payload)) + '#'}
    # Excluded providers must be rejected by the packaged entry point, not left
    # as disabled promises or routed through shared upstream type declarations.
    for provider in ['minimax', 'antigravity']:
        rejected = subprocess.run([str(NODE), str(BUNDLE / 'main.mjs'), provider],
                                  env=env, capture_output=True, text=True, timeout=15)
        assert rejected.returncode != 0
        assert rejected.stdout == ''
        assert 'Unsupported usage provider' in rejected.stderr
        assert credentials.read_bytes() == before
        assert not any(provider in name.lower() for name in manifest['files'])
    def run(provider='kimi'):
        process = subprocess.run([str(NODE), str(BUNDLE / 'main.mjs'), provider],
                                 env=env, capture_output=True, text=True, timeout=15)
        assert process.returncode == 0, 'helper failed (output suppressed)'
        assert 'isolated-fixture-not-a-token' not in process.stdout + process.stderr
        return json.loads(process.stdout)
    result = run()
    assert result['status'] == 'ok'
    assert result['session']['usedPercent'] == 21
    assert result['weekly']['usedPercent'] == 35
    assert credentials.read_bytes() == before
    credentials.unlink()
    assert run()['status'] == 'unavailable'
    grok = home / 'auth.json'
    grok.write_text(json.dumps({'https://auth.x.ai': {'key': 'isolated-fixture-not-a-token'}}))
    env['GROK_HOME'] = directory
    env['GROK_CLI_CHAT_PROXY_BASE_URL'] = 'data:application/json,' + quote(json.dumps({'creditUsagePercent': 42})) + '#'
    before = grok.read_bytes()
    result = run('grok')
    assert result['status'] == 'ok'
    assert result['weekly']['usedPercent'] == 42
    assert grok.read_bytes() == before
    grok.unlink()
    assert run('grok')['status'] == 'unavailable'

# Source integration contract: these guardrails must remain in the actual Swift owner.
source = (ROOT / 'Sources/GooseAgent/UsagePanel.swift').read_text()
assert all(provider not in source.lower() for provider in ['minimax', 'antigravity'])
for contract in ['self.gate.accepts(provider: provider, generation: revision)', '!AgentKindDisabled.load().contains(provider)',
                 'process.terminate()', 'snapshots.removeAll()',
                 'static let pollingInterval: TimeInterval = 300',
                 'Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true)',
                 'processes[provider] == nil', 'NSApplication.willTerminateNotification',
                 'UserDefaults.didChangeNotification',
                 'runtime/\\(arch)/node']:
    assert contract in source, contract
presentation = source.split('struct UsagePanelButton: View {', 1)[1]
assert 'ScrollView' not in presentation
assert '.frame(width: SheetLayout.usage)' in presentation
assert '.number.notation(.compactName)' in presentation
assert '.accessibilityValue(Text(value, format: .number))' in presentation
assert '.background(Theme.tooltipBackground)' in presentation
assert '.frame(width: SheetLayout.wide)' not in presentation
assert 'usage.cancel()' not in presentation
assert 'if visible { refresh() }' not in presentation
hover = presentation.split('private func hoverChanged()', 1)[1].split('private func openAgentSettings()', 1)[0]
assert 'refresh()' not in hover
app_source = (ROOT / 'Sources/GooseAgent/AppModel.swift').read_text()
assert 'let usage = UsagePanelModel()' in app_source
assert 'usage.start { [weak self]' in app_source
assert 'usage.configure()' in app_source
with tempfile.TemporaryDirectory(prefix='goose-usage-gate-') as directory:
    check = Path(directory) / 'gate.swift'
    check.write_text((ROOT / 'Sources/GooseAgent/UsageRequestGate.swift').read_text() + '''
var gate = UsageRequestGate()
gate.replace(enabled: ["kimi"])
let request = gate.generation
assert(gate.accepts(provider: "kimi", generation: request))
assert(!gate.accepts(provider: "grok", generation: request))
gate.replace(enabled: [])
assert(!gate.accepts(provider: "kimi", generation: request))
gate.replace(enabled: ["kimi"])
assert(!gate.accepts(provider: "kimi", generation: request))
assert(gate.accepts(provider: "kimi", generation: gate.generation))
''')
    subprocess.run(['swift', str(check)], check=True, timeout=60, capture_output=True)
with tempfile.TemporaryDirectory(prefix='goose-usage-polling-') as directory:
    check = Path(directory) / 'polling.swift'
    owner = source.split('/// Shares the application-owned cache', 1)[0].replace('import HerdrKit\n', '')
    check.write_text(owner + (ROOT / 'Sources/GooseAgent/UsageRequestGate.swift').read_text() + '''
enum AgentKindDisabled {
    static func visible(_ kinds: [String]) -> [String] { [] }
    static func load() -> Set<String> { [] }
}
extension UsagePanelModel {
    func verifyTimer() {
        assert(timer?.timeInterval == 300)
        let original = timer
        start(catalog: { [] })
        assert(timer === original)
        timer?.fire() // Uses the actual production timer callback; no enabled credentials.
        assert(timer?.isValid == true)
        stop()
        assert(timer == nil)
        assert(snapshots.isEmpty)
    }
}
MainActor.assumeIsolated {
    let owner = UsagePanelModel()
    owner.start(catalog: { [] })
    owner.verifyTimer()
}
''')
    subprocess.run(['swift', str(check)], check=True, timeout=60, capture_output=True)
print('PASS: 300-second owner timer and stop; hover/cache-only contracts; excluded providers rejected; original Orca hashes; packaged Node/Fetch/helper; Kimi/Grok windows; no writes; actual Swift gating/late response checks')
