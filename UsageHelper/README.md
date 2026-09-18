# Internal usage helper — partial migration

Source: https://github.com/stablyai/orca at `fbe7b194b8b6e05bf945aaef67ab3b3789f110fd`.
`vendor/orca/provenance.json` records SHA256 for byte-identical upstream files;
`vendor/orca/LICENSE` preserves MIT / Copyright (c) 2026 Lovecast Inc.

`host/` contains only native-host entry points and runtime adaptations. Node
24.8.0 is downloaded from the official distribution with fixed architecture
checksums by `scripts/package-usage-helper.sh`. Its full LICENSE (including
bundled third-party notices) is copied beside the executable. No Node from PATH
is used by the application. No Electron, HTTP server, daemon or new database.

The application-owned usage model refreshes enabled local Agents at startup,
on selection changes, and every 300 seconds, without overlapping a provider's
running process. Hover displays cached snapshots; closing the popover does not
stop polling. Disabling an Agent clears snapshots and rejects late responses;
application termination stops the timer/processes. The compact native panel has
no internal scrolling and retains the connected metrics/reset/history fields.

Cursor uses an explicit, revocable read-only authorization in Agent settings.
`host/cursor.mjs` adapts the modern IDE-token Connect usage RPC from
`Noisemaker111/openusage-opencode` at `b9a595f96f976ebf262a2e3d8f94377238925ca5`;
`vendor/openusage-cursor` preserves its MIT notice and provenance. This is an
adaptation, not a byte-identical transplant. It reads only Cursor's existing
`cursorAuth/accessToken`, never refreshes/writes back authentication, constructs
cookies, scans browsers, follows redirects, or exports raw responses. Metrics
are optional validated numbers; plan cents become USD and percentage points
remain percentage points. Enterprise legacy and team/on-demand fallbacks are
not enabled. Normal native SQLite readonly reads an existing WAL/SHM pair for a
consistent live snapshot; missing sidecars cause an explicit unreadable status,
not a copy/checkpoint or an immutable read of a live database.

Implemented executable paths: Cursor modern plan usage, Kimi, Grok, Claude OAuth, Codex backend/credits;
Claude/Codex/OpenCode history scanners and summary projections. History has no
persistent cache. The original recovery/PTY modules are retained but not enabled:
credential-writing recovery still requires approval. Gemini is fixture-tested
only. OpenCode Go requires an existing web session cookie setting which this
host does not have.

MiniMax and Antigravity are excluded from this integration by product decision,
not pending providers. Neither has an executable entry point, UI row, credential
setting or dedicated vendored provider module. Their names remain only in Orca's
unchanged shared `rate-limit-types.ts` contract to preserve upstream byte identity;
those shared declarations do not enable either provider.

Runtime adaptations:
- Node module hooks resolve extensionless TypeScript imports and transform types
  with Node's bundled transformer; upstream files stay unchanged.
- `electron.net.fetch` delegates to Node Fetch. Only the default environment
  proxy session is supported. Isolated Chromium cookie sessions and managed
  account storage explicitly throw, not simulated success.
- Kimi home adapter is macOS-only; no WSL runtime probing.
- Raw upstream errors/logs are not exported (credential parse errors may quote
  secrets); UI receives statuses and failure metadata.
- Existing Orca/history SQLite opens an existing file as immutable read-only. Active WAL is refused;
  supporting existing WAL/SHM safely is an adapter limitation, not a product
  prohibition. No sidecars, migrations or new database files are created.

Checks (fixtures only): `python3 Tests/UsageHelperTests.py` after packaging into
`build/usage-fixture-bundle/UsageHelper`; run `Tests/UsageProviderContracts.mjs`
with the verified Node executable. Cursor checks: run `Tests/CursorUsageTests.mjs`
with that Node executable and `python3 Tests/AgentSettingsInspectorTests.py`.
Tests never use real credentials or paid APIs.
Coverage of the remaining in-scope providers, CLI/native addon runtime, history detail UI, real-account
and native interaction validation are not complete; this is not a full delivery.
