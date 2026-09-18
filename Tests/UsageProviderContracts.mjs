// Offline fixtures exercise original provider request/parser files. Never loads real homes.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const home = await mkdtemp(join(tmpdir(), 'goose-provider-fixture-'));
process.env.HOME = home;
process.env.CODEX_HOME = join(home, '.codex');
process.env.XDG_DATA_HOME = join(home, '.local/share');
try {
  await import('../UsageHelper/host/register.mjs');
  const nativeFetch = globalThis.fetch;
  // Fixed-endpoint providers cannot point at a fixture server. Adapt only the
  // transport in this test; native Fetch reads data URLs and all upstream parsing runs.
  const routes = new Map();
  globalThis.fetch = async (url, options) => {
    assert(routes.has(String(url)), 'Unexpected outbound request blocked');
    const { payload, method } = routes.get(String(url));
    assert.equal(options?.method ?? 'GET', method ?? 'GET');
    return nativeFetch('data:application/json,' + encodeURIComponent(JSON.stringify(payload)));
  };
  routes.set('https://api.anthropic.com/api/oauth/usage', { payload: {
    five_hour: { utilization: 17 }, seven_day: { utilization: 41 },
    fable_weekly: { utilization: 9 }
  }});
  const claude = await import('../UsageHelper/vendor/orca/src/main/rate-limits/claude-oauth-usage-request.ts');
  const usage = await claude.fetchClaudeOAuthUsage('fixture-only');
  assert.equal(usage.session.usedPercent, 17);
  assert.equal(usage.weekly.usedPercent, 41);
  assert.equal(usage.fableWeekly.usedPercent, 9);

  await mkdir(process.env.CODEX_HOME, { recursive: true });
  const codexAuth = join(process.env.CODEX_HOME, 'auth.json');
  await writeFile(codexAuth, JSON.stringify({ tokens: { access_token: 'fixture-only', account_id: 'fixture-account' } }));
  const originalAuth = await readFile(codexAuth, 'utf8');
  routes.set('https://chatgpt.com/backend-api/wham/usage', { payload: {
    plan_type: 'plus', rate_limit: { primary_window: { used_percent: 23, limit_window_seconds: 18000 },
      secondary_window: { used_percent: 51, limit_window_seconds: 604800 } },
    rate_limit_reset_credits: { available_count: 2, total_earned_count: 3,
      credits: [{ status: 'available', expires_at: '2030-01-01T00:00:00Z' }] }
  }});
  const codex = await import('../UsageHelper/host/codex.mjs');
  const credits = await codex.fetchCodexReadOnlyUsage();
  assert.equal(credits.session.usedPercent, 23);
  assert.equal(credits.weekly.usedPercent, 51);
  assert.equal(credits.rateLimitResetCredits.availableCount, 2);
  assert.equal(await readFile(codexAuth, 'utf8'), originalAuth);

  await mkdir(join(home, '.gemini'), { recursive: true });
  const geminiAuth = join(home, '.gemini/oauth_creds.json');
  await writeFile(geminiAuth, JSON.stringify({ access_token: 'fixture-only', refresh_token: 'fixture-refresh', expiry_date: Date.now() + 3600000 }));
  const originalGemini = await readFile(geminiAuth, 'utf8');
  routes.set('https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist', { method: 'POST', payload: { cloudaicompanionProject: 'fixture-project' } });
  routes.set('https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota', { method: 'POST', payload: { buckets: [{ remainingFraction: 0.7, resetTime: '2030-01-01T00:00:00Z', modelId: 'gemini-fixture' }] } });
  const gemini = await import('../UsageHelper/vendor/orca/src/main/rate-limits/gemini-usage-fetcher.ts');
  const quota = await gemini.fetchGeminiRateLimits(true);
  assert.equal(quota.status, 'ok');
  assert(quota.buckets.length > 0);
  assert.equal(await readFile(geminiAuth, 'utf8'), originalGemini);

  // Original history scanner and projection, with empty isolated homes only.
  const history = await import('../UsageHelper/host/history.mjs');
  for (const provider of ['claude', 'codex', 'opencode']) {
    const summary = await history.readHistory(provider);
    assert.equal(summary.sessions, 0);
    assert.equal(summary.inputTokens, 0);
  }
  const transcriptDir = join(home, '.claude/projects/fixture');
  await mkdir(transcriptDir, { recursive: true });
  await writeFile(join(transcriptDir, 'session.jsonl'), JSON.stringify({
    type: 'assistant', sessionId: 'fixture-session', timestamp: '2026-04-09T10:00:00.000Z',
    cwd: home, message: { model: 'claude-sonnet-4-6', usage: { input_tokens: 100, output_tokens: 25 } }
  }) + '\n');
  const historySummary = await history.readHistory('claude');
  assert.equal(historySummary.inputTokens, 100);
  assert.equal(historySummary.outputTokens, 25);

  const { DatabaseSync } = await import('node:sqlite');
  const databasePath = join(home, 'history-fixture.db');
  const fixture = new DatabaseSync(databasePath);
  fixture.exec(`CREATE TABLE fixture(value); INSERT INTO fixture VALUES(7);
    CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, title TEXT, model TEXT, cost REAL,
    tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER,
    time_created INTEGER, time_updated INTEGER);`);
  fixture.prepare('INSERT INTO session VALUES(?,?,?,?,?,?,?,?,?,?,?)').run('fixture-session', home, 'Fixture',
    JSON.stringify({ providerID: 'anthropic', id: 'claude-sonnet-4-5' }), 0.01, 100, 25, 0, 0, 1777777700000, 1777777800000);
  fixture.close();
  process.env.OPENCODE_DB = databasePath;
  const opencodeHistory = await history.readHistory('opencode');
  assert.equal(opencodeHistory.inputTokens, 100);
  assert.equal(opencodeHistory.outputTokens, 25);
  const beforeDatabase = await readFile(databasePath);
  const { default: ReadOnlyDatabase } = await import('../UsageHelper/host/readonly-sqlite.mjs');
  const reader = new ReadOnlyDatabase(databasePath, { readonly: true, fileMustExist: true });
  assert.equal(reader.prepare('SELECT value FROM fixture').get().value, 7);
  assert.throws(() => reader.exec('INSERT INTO fixture VALUES(8)'));
  reader.close();
  assert.deepEqual(await readFile(databasePath), beforeDatabase);
  await assert.rejects(readFile(databasePath + '-wal'));
  await assert.rejects(readFile(databasePath + '-shm'));
  await writeFile(databasePath + '-wal', 'uncheckpointed-fixture');
  assert.throws(() => new ReadOnlyDatabase(databasePath, { readonly: true, fileMustExist: true }));
  console.log('PASS: readonly SQLite, no sidecars, WAL refused; Claude windows/Fable; Codex windows/credits; Gemini quota; original empty history scans; no real credentials/network');
} finally {
  await rm(home, { recursive: true, force: true });
}
