// Run with build/usage-fixture-bundle/UsageHelper/runtime/arm64/node Tests/CursorUsageTests.mjs
// Synthetic credentials and mocked transport only; no real accounts, browser or network.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { parseCursorUsage, readCursorAccessToken, fetchCursorReadOnlyUsage } from '../UsageHelper/host/cursor.mjs';

for (const body of [{}, { enabled: true }, { enabled: true, planUsage: {} },
  { enabled: true, planUsage: { totalSpend: '1200', limit: null, totalPercentUsed: Infinity } },
  { enabled: false, planUsage: { totalSpend: 0 } }]) {
  assert.equal(parseCursorUsage(body).usageMetadata.failureKind, 'unsupported-response');
}
const parsed = parseCursorUsage({ enabled: true, planUsage: {
  totalSpend: 1240, includedSpend: 1200, limit: 2000, autoPercentUsed: 0.36,
  apiPercentUsed: 61, totalPercentUsed: 105,
}, billingCycleStart: '1700000000000', billingCycleEnd: '1701000000000',
spendLimitUsage: { pooledLimit: 999999 } });
assert.equal(parsed.status, 'ok');
assert.equal(parsed.cursor.planSpentUSD, 12.4);
assert.equal(parsed.cursor.includedSpentUSD, 12);
assert.equal(parsed.cursor.planLimitUSD, 20);
assert.equal(parsed.cursor.autoPercent, 0.36); // Already percentage points, NOT 36%.
assert.equal(parsed.cursor.apiPercent, 61);
assert.equal(parsed.cursor.totalPercent, null);
assert.equal(parsed.cursor.cycleStart, 1700000000000);
const missing = parseCursorUsage({ enabled: true, planUsage: { apiPercentUsed: 0 }, billingCycleEnd: '' }).cursor;
assert.equal(missing.apiPercent, 0);
assert.equal(missing.autoPercent, null);
assert.equal(missing.planSpentUSD, null);
assert.equal(missing.planLimitUSD, null);
assert.equal(missing.cycleEnd, null);
assert.equal(parseCursorUsage({ enabled: true, planUsage: { totalSpend: 0 }, billingCycleStart: '50', billingCycleEnd: '2' }).cursor.cycleEnd, null);

let calls = 0;
assert.equal((await fetchCursorReadOnlyUsage({ readToken() { calls++; throw Error(); } })).usageMetadata.failureKind, 'not-connected');
assert.equal(calls, 0);
const token = 'synthetic-fixture-only';
const readToken = () => ({ token });
for (const [status, kind] of [[401, 'session-expired'], [403, 'authentication-failed'], [500, 'request-failed'], [302, 'request-failed']]) {
  const result = await fetchCursorReadOnlyUsage({ authorized: true, readToken, request: async (url, options) => {
    calls++;
    assert.equal(url, 'https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage');
    assert.equal(options.redirect, 'error');
    assert.equal(options.headers.Authorization, `Bearer ${token}`);
    assert.equal(options.body, '{}');
    return { status, ok: false, json() { throw Error('must not read authentication error body'); } };
  } });
  assert.equal(result.usageMetadata.failureKind, kind);
  assert(!JSON.stringify(result).includes(token));
}
assert.equal(calls, 4); // No refresh/retry fallback.
assert.equal((await fetchCursorReadOnlyUsage({ authorized: true, readToken, request() { throw Error(token); } })).usageMetadata.failureKind, 'network-failed');
assert.equal((await fetchCursorReadOnlyUsage({ authorized: true, readToken, request: async () => ({ ok: true, status: 200, json: async () => ({ secret: token }) }) })).usageMetadata.failureKind, 'unsupported-response');
assert.equal((await fetchCursorReadOnlyUsage({ authorized: true, readToken: () => ({ error: 'no-session' }), request() { throw Error('unexpected request'); } })).usageMetadata.failureKind, 'no-session');

const home = mkdtempSync(join(tmpdir(), 'goose-cursor-fixture-'));
try {
  assert.equal(readCursorAccessToken(home).error, 'no-session');
  const directory = join(home, 'Library/Application Support/Cursor/User/globalStorage');
  mkdirSync(directory, { recursive: true });
  const path = join(directory, 'state.vscdb');
  const writer = new DatabaseSync(path);
  writer.exec('PRAGMA journal_mode=WAL; CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)');
  writer.prepare('INSERT INTO ItemTable VALUES (?, ?)').run('cursorAuth/accessToken', token);
  const before = readFileSync(path);
  const walBefore = readFileSync(path + '-wal');
  const files = readdirSync(directory);
  assert.equal(readCursorAccessToken(home).token, token); // Reads uncheckpointed WAL, not stale main DB.
  assert.deepEqual(readFileSync(path), before);
  assert.deepEqual(readFileSync(path + '-wal'), walBefore);
  assert.deepEqual(readdirSync(directory), files);
  const expired = 'fixture.' + Buffer.from(JSON.stringify({ exp: 1 })).toString('base64url') + '.fixture';
  writer.prepare('UPDATE ItemTable SET value = ?').run(expired);
  assert.equal(readCursorAccessToken(home).error, 'session-expired');
  writer.close();
  // Closed WAL DB has no existing sidecars; refuse rather than create them or use immutable.
  const closedFiles = readdirSync(directory);
  assert.equal(readCursorAccessToken(home).error, 'storage-unavailable');
  assert.deepEqual(readdirSync(directory), closedFiles);
} finally { rmSync(home, { recursive: true, force: true }); }
console.log('PASS: Cursor consent, strict fields/units/cycles, redaction, auth/network failures, no refresh/redirect, consistent readonly WAL without DB/WAL writes');
