import { fetchCodexRateLimitsViaBackend } from '../vendor/orca/src/main/rate-limits/codex-backend-usage-client.ts';
import { supplementCodexRateLimitResetCredits } from '../vendor/orca/src/main/rate-limits/codex-reset-credit-client.ts';

// Only the upstream read-only backend branch. CLI/RPC recovery is not silently simulated.
export async function fetchCodexReadOnlyUsage() {
  const result = await fetchCodexRateLimitsViaBackend(globalThis.fetch);
  return result ? supplementCodexRateLimitResetCredits(result, globalThis.fetch) : {
    provider: 'codex', session: null, weekly: null, updatedAt: Date.now(),
    status: 'unavailable', error: 'Backend usage unavailable'
  };
}
