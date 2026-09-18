import { readClaudeOAuthCredentials } from '../vendor/orca/src/main/rate-limits/claude-oauth-credentials.ts';
import { fetchClaudeOAuthUsage } from '../vendor/orca/src/main/rate-limits/claude-oauth-usage-request.ts';

// The upstream recovery/PTY graph is retained separately, but not invoked while
// credential-writing recovery awaits approval. This entry only reads active OAuth usage.
export async function fetchClaudeReadOnlyUsage() {
  const credentials = await readClaudeOAuthCredentials();
  if (!credentials.token) return {
    provider: 'claude', session: null, weekly: null, updatedAt: Date.now(),
    error: 'No readable OAuth token', status: 'unavailable',
    usageMetadata: { source: 'oauth', failureKind: credentials.hasRefreshableCredentials
      ? 'refreshable-credentials-without-token' : 'missing-credentials' }
  };
  return fetchClaudeOAuthUsage(credentials.token);
}
