import './host/register.mjs';

// Upstream diagnostics may contain credential parse context; never forward them to logs.
console.log = console.warn = console.error = console.info = console.debug = () => {};
// One request per process; the native owner can terminate it when an Agent is disabled.
const provider = process.argv[2];
if (!['kimi', 'grok', 'claude', 'codex', 'opencode', 'cursor'].includes(provider)) throw new Error('Unsupported usage provider');
let result;
try {
  if (provider === 'cursor') {
    const module = await import('./host/cursor.mjs');
    result = await module.fetchCursorReadOnlyUsage({ authorized: process.env.GOOSE_CURSOR_USAGE_AUTHORIZED === '1' });
  } else if (provider === 'opencode') {
    result = { provider, session: null, weekly: null, updatedAt: Date.now(),
      status: 'unavailable', error: 'OpenCode Go session cookie is not configured in this host' };
  } else if (provider === 'claude') {
    const module = await import('./host/claude.mjs');
    result = await module.fetchClaudeReadOnlyUsage();
  } else if (provider === 'codex') {
    const module = await import('./host/codex.mjs');
    result = await module.fetchCodexReadOnlyUsage();
  } else {
    const module = await import(`./vendor/orca/src/main/rate-limits/${provider}-fetcher.ts`);
    result = await (provider === 'kimi' ? module.fetchKimiRateLimits() : module.fetchGrokRateLimits());
  }
} catch {
  result = { provider, session: null, weekly: null, updatedAt: Date.now(),
    status: 'error', error: 'Usage request failed' };
}
if (['claude', 'codex', 'opencode'].includes(provider)) {
  try {
    const { readHistory } = await import('./host/history.mjs');
    result.history = await readHistory(provider);
  } catch {
    result.historyError = true;
  }
}
// Native UI uses status/failureKind. Raw upstream errors can quote malformed credentials.
process.stdout.write(JSON.stringify({ ...result, error: result.error ? 'Usage unavailable' : null }) + '\n');
