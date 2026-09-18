// Adapted from openusage-opencode's Cursor plugin (MIT); see vendor/openusage-cursor.
// Only the existing IDE access token + modern usage RPC are used. No refresh/writeback,
// browser cookies, enterprise REST fallback, account identifiers or raw responses leave here.
import { DatabaseSync } from 'node:sqlite';
import { openSync, closeSync, readSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const usageURL = 'https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage';
const failure = kind => ({ provider: 'cursor', status: 'unavailable', usageMetadata: { failureKind: kind } });
const finite = value => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const percent = value => finite(value) && value <= 100 ? value : null;
const dollars = value => finite(value) ? value / 100 : null;
const timestamp = value => {
  if (!(typeof value === 'number' || (typeof value === 'string' && /^\d+$/.test(value)))) return null;
  const number = Number(value);
  return Number.isSafeInteger(number) && number > 0 && number <= 8640000000000000 ? number : null;
};

export function parseCursorUsage(body) {
  const plan = body?.planUsage;
  if (body?.enabled !== true || !plan || typeof plan !== 'object') return failure('unsupported-response');
  const summary = {
    autoPercent: percent(plan.autoPercentUsed), apiPercent: percent(plan.apiPercentUsed),
    totalPercent: percent(plan.totalPercentUsed),
    planSpentUSD: dollars(plan.totalSpend), includedSpentUSD: dollars(plan.includedSpend),
    planLimitUSD: dollars(plan.limit),
    cycleStart: timestamp(body.billingCycleStart), cycleEnd: timestamp(body.billingCycleEnd),
  };
  // Never infer a spent amount from absent remaining, or turn a missing cap into zero.
  if (summary.cycleStart === null || summary.cycleEnd === null || summary.cycleEnd <= summary.cycleStart) {
    summary.cycleStart = summary.cycleEnd = null;
  }
  if ([summary.autoPercent, summary.apiPercent, summary.totalPercent, summary.planSpentUSD,
       summary.includedSpentUSD, summary.planLimitUSD].every(value => value === null)) return failure('unsupported-response');
  // ponytail: only plan metrics; add separately labelled personal/team on-demand when required.
  return { provider: 'cursor', status: 'ok', cursor: summary, updatedAt: Date.now() };
}

export function readCursorAccessToken(home = homedir()) {
  const path = join(home, 'Library/Application Support/Cursor/User/globalStorage/state.vscdb');
  let db;
  try {
    // Do not create a database or WAL sidecar. For a WAL database require Cursor's
    // existing WAL/SHM pair; normal SQLite readonly then sees a consistent live snapshot.
    const header = Buffer.alloc(20);
    const fd = openSync(path, 'r');
    try { readSync(fd, header, 0, header.length, 0); } finally { closeSync(fd); }
    if (header[18] === 2) {
      try {
        if (!statSync(path + '-wal').isFile() || !statSync(path + '-shm').isFile()) return { error: 'storage-unavailable' };
      } catch { return { error: 'storage-unavailable' }; }
    }
    db = new DatabaseSync(path, { readOnly: true, timeout: 1000, enableExtension: false });
    const value = db.prepare("SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1").get()?.value;
    if (typeof value !== 'string' || !value || value.length > 32768 || /[\s\x00-\x1f\x7f]/.test(value)) {
      return { error: 'no-session' };
    }
    // Expiry is only a local preflight, not proof of authentication. Never refresh it.
    try {
      const payload = JSON.parse(Buffer.from(value.split('.')[1], 'base64url').toString());
      if (finite(payload.exp) && payload.exp * 1000 <= Date.now()) return { error: 'session-expired' };
    } catch { /* Opaque access tokens are verified by Cursor, not guessed locally. */ }
    return { token: value };
  } catch (error) {
    return { error: error.code === 'ENOENT' ? 'no-session' : 'storage-unavailable' };
  } finally { db?.close(); }
}

export async function fetchCursorReadOnlyUsage({ authorized = false, readToken = readCursorAccessToken, request = fetch } = {}) {
  if (!authorized) return failure('not-connected');
  const credentials = readToken();
  if (credentials.error) return failure(credentials.error);
  try {
    const response = await request(usageURL, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(15000),
      headers: { Authorization: `Bearer ${credentials.token}`, 'Content-Type': 'application/json', 'Connect-Protocol-Version': '1' },
      body: '{}',
    });
    if (response.status === 401) return failure('session-expired');
    if (response.status === 403) return failure('authentication-failed');
    if (!response.ok) return failure('request-failed');
    try { return parseCursorUsage(await response.json()); }
    catch { return failure('unsupported-response'); }
  } catch { return failure('network-failed'); }
  finally { credentials.token = undefined; }
}
