// Scan and summarize with Orca's original implementations. No usage store/cache is written.
export async function readHistory(provider) {
  if (provider === 'opencode') {
    const { scanOpenCodeUsageDatabases } = await import('../vendor/orca/src/main/opencode-usage/scanner.ts');
    const { buildOpenCodeUsageSummary } = await import('../vendor/orca/src/main/opencode-usage/snapshot-rollups.ts');
    const scanned = await scanOpenCodeUsageDatabases([], []);
    return buildOpenCodeUsageSummary('all', 'all', scanned.dailyAggregates, scanned.sessions);
  }
  if (!['claude', 'codex'].includes(provider)) throw new Error('Unsupported history source');
  const scanner = await import(`../vendor/orca/src/main/${provider}-usage/scanner.ts`);
  const scanned = await (provider === 'claude'
    ? scanner.scanClaudeUsageFiles([], []) : scanner.scanCodexUsageFiles([], []));
  const projections = await import(provider === 'claude'
    ? '../vendor/orca/src/main/claude-usage/claude-usage-report-aggregation.ts'
    : '../vendor/orca/src/main/codex-usage/codex-usage-rollup-projections.ts');
  return projections.buildSummary(scanned, 'all', 'all');
}
