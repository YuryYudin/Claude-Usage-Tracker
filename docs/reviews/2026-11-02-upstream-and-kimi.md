# Upstream check, eight-account widgets, and Kimi Code assessment

Checked on 2026-11-02 in `/Users/jjb/Work/Claude/Claude-Usage-Tracker-integration-resumed`.
The original `Claude-Usage-Tracker` checkout remains on its historical fork branch.

## Upstream and source preservation

Fetched all upstream branches and tags from
https://github.com/hamed-elfayome/Claude-Usage-Tracker.
`main` is still `588775e4540757443691fa1bcb33457315e05f86`
(2026-08-31, “Update README”), the base already used by this integration.
`next-release` is six commits behind `main`. No additional mainline changes
needed replaying. `git rebase --rebase-merges upstream/main` completed and
retained the existing integration commit IDs and merge topology.

The previously uncommitted, user-accepted build-20 widget appearance fix,
matching app/widget version metadata, and packaging version guard are now
commit `038be09`. Backup branches preserve both the earlier source HEAD
(`backup/pre-upstream-check-20261102`, `5311f61`) and this build-20 source
(`backup/build20-20261102`, `038be09`). The bundle-backed `origin` was retained;
a GitHub `upstream` remote was added. Nothing was pushed.

Canonical widget PR #304 remains open, unmerged, at the same integrated head
`d03cfd351ba18dec3f4cc02c0d24e281700cb4b0`. Neither upstream branch contains
Kimi/Moonshot support, and the latest 100 PRs contained no Kimi/Moonshot match.
Upstream's provider enum still lists Anthropic and Codex only.

## Local build compatibility

The full app was originally compiled on a newer Swift toolchain. This Mac has
Xcode 16.4 / Swift 6.1.2, which does not apply the project's newer default
MainActor-isolation setting. Its first full build exposed missing explicit
actor annotations and unsupported `nonisolated deinit` syntax.

Commit `7dd07fc` explicitly annotates the UI and provider/account operations
that already require the main actor, constructs default API services inside
their isolated initializers, and gates the Swift 6.3 optimizer workaround on
compiler >= 6.2. The provider registry's descriptor lookup remains synchronous
and independent of the actor-isolated service factory. Network requests remain
asynchronous. This is a compatibility change, with no credential-format change.

The hosted Debug suite passed: **320 tests, zero failures, two signing-dependent
data-protection Keychain tests skipped**. The synthetic actual-source codec
harness also passed, preserving account UUIDs, SSH/home/bucket configuration,
and provider identities. It reconfirmed that unmodified upstream remains an
unsafe replacement for these fork profiles. Localization parity and project
plist syntax passed. Existing concurrency/build warnings remain; this does not
establish Swift 6 language-mode conformance.

Build/test evidence is under
`/private/tmp/claude-usage-upstream-20261102.noindex/`.
The test scheme uses isolated defaults, temporary Application Support, and
test-mode startup. Build products are under a `.noindex` directory.

## Eight-account widget change

Large and extra-large overview widgets now select up to eight displayed
accounts. Medium retains its four-account limit. Large uses slightly tighter
compact-row spacing above six accounts. Extra-large uses two columns of four;
at seven/eight accounts, compact labels/bars and reduced spacing preserve reset
times and stale indicators. The six-account presentation is retained.
Both app and widget build metadata advance together to build 21.
The implementation is commit `a062be3`.

Standalone render checks use synthetic accounts, including a long name, a stale
account, and an account with only one quota. The harness injects host-only
family/rendering-mode values into a temporary source copy and omits the
host-only container background. These previews exercise layout and foreground
contrast; they do not simulate the macOS tint compositor or prove installed
WidgetKit-host behavior. The user confirmed the installed build-20 focus fix
in the previous session.

All 72 previews rendered successfully. Inspected examples:
[extra-large, eight accounts](evidence/2026-11-02-widget-eight/8-extraLarge-full-dark.png),
[large, eight accounts](evidence/2026-11-02-widget-eight/8-large-full-light.png),
and [extra-large tinted foreground](evidence/2026-11-02-widget-eight/8-extraLarge-accented-light.png).
The optimized Release app and widget both built for arm64 and x86_64, with
matching 3.3.0/build-21 metadata. The local ad-hoc installer is
`release/Claude-Usage-3.3.0-integration-build21-local.dmg` with an adjacent SHA-256
file. Packaging verifies nested signatures, version parity, the preferences
domain, disabled incompatible updates, and image integrity. Build 21 remains
uninstalled; `/Applications/Claude Usage.app` is the working build 20.

## Kimi: confirmed local integration and live read-only result

The user confirmed a direct Kimi Code subscription. OpenCode **v2.2.5** lists
the active `kimi-code-plan-global` integration, with a key credential.
Its active credentials are in OpenCode's SQLite store; the older
`~/.local/share/opencode/auth.json` omits this integration and is insufficient
for discovery. A targeted `opencode auth export kimi-code-plan-global` works
and returns an array containing integration identity, active status, and the
credential value. Production auth was inspected in memory and never printed
or saved in this repository.

A single authenticated, read-only request to
`GET https://api.kimi.ai/coding/v1/usages` succeeded with HTTP 200, using this
app's own identifying User-Agent. No inference request was made. The response
contained `usages.limit_5h`, `usages.limit_month_total`, and
`usages.limit_month_code`, each with `used_ratio` and `reset_time`. It also
contained a legacy `limits` block with numeric strings. There was no weekly
quota in this account's response. Successful authentication and response shape
were verified; displayed percentages have not been compared with Kimi's console.

Kimi's own CLI implements this endpoint and parser:

- [Managed usage source, pinned to the inspected revision](https://github.com/MoonshotAI/kimi-code/blob/fc3b521b8b68468268bb4cfe7f45008ce08b2b99/packages/oauth/src/managed-usage.ts)
- [Quota display and monthly breakdown](https://github.com/MoonshotAI/kimi-code/blob/fc3b521b8b68468268bb4cfe7f45008ce08b2b99/apps/kimi-code/src/utils/usage/usage-format.ts)
- [Membership documentation](https://www.kimi.com/code/docs/en/kimi-code/membership.html)

The CLI recognizes both `api.kimi.com` and global `api.kimi.ai` coding endpoints.
Its parser supports optional five-hour, weekly, monthly total, and monthly code
ratios. Its formatter treats monthly code as a share of the monthly total;
the other Kimi share is the nonnegative difference. Those pools must not be
added together as independent consumed budgets. OpenCode Go and Moonshot's
pay-as-you-go platform are separate credential/billing sources.

## Proposed Kimi implementation

Add a first-class `.kimi` provider through the existing registry. Implement
`KimiAuthService`, a fixture-tested `KimiAPIService`/DTO mapper, and
`KimiUsageProvider`. Keep the work separate from the completed upstream rebase.

1. Offer manual key entry and **Import from OpenCode**. Prefer targeted CLI
   export over coupling production code to OpenCode's internal database schema.
   Parse the selected integration and active record explicitly. Support legacy
   `auth.json` only as a compatibility fallback, without mistaking OpenCode Go
   or a Moonshot platform key for Kimi Code. Execute the CLI asynchronously with
   a timeout and capture stdout privately. Use a configured/discovered absolute
   executable path because the app's GUI PATH differs from a login shell.
2. Save the chosen credential per profile, with the existing verified Keychain
   write and ad-hoc inline fallback rules. Extend `Profile`, the secret-field
   enum, hydration/persistence/removal paths, and account-refresh identity.
   Import creates a stable profile binding; changing OpenCode's active account
   must not silently replace the Tracker account or its history.
3. Select the global or China endpoint from a fixed supported-host choice.
   Send Bearer authorization to that selected coding endpoint only. Preserve
   last-known data on timeouts, auth failures, and rate limits; honor
   Retry-After/backoff and use the existing refresh-generation guards.
4. Prefer valid named `usages` ratios, accepting finite numbers or numeric
   strings. Map five-hour usage to session and weekly usage to weekly only
   when present. Put monthly total/code data in named `UsageQuota` windows
   with their actual reset dates and optional breakdown. Missing/malformed
   windows stay unavailable. Do not fabricate weekly quotas, token counts,
   monthly reset dates, or a fixed 30-day duration. Decode legacy limits as
   a fallback for missing windows, with checks for invalid/zero denominators
   and disagreement between formats. Never sum overlapping monthly pools.
5. Add the Kimi credential section/setup path, quota selection, branding and
   localization. Reuse the shared quota popover. Set token counts, per-model
   details, console billing, CLI account switching, auto-start and overage
   features false initially. Wallet support can follow when separately tested.
6. Add Kimi to the shared widget provider identity, app snapshot mapper and
   widget icon switch. Make the second displayed quota explicit so monthly
   data is labeled monthly rather than weekly. Validate app/widget snapshot
   compatibility together and retain the packaging version guard.
7. Test modern and legacy payloads, monthly-only/5h+monthly/weekly accounts,
   unknown fields, malformed ratios, missing resets, auth import variants,
   stale requests after credential changes, ad-hoc persistence and migration.
   Verify the eventual installed app against the Kimi console and exercise
   seven/eight-account widgets, including desktop focus transitions.

Kimi support is assessed and has a working authenticated data source. No Kimi
provider or seventh production profile has been created by this assessment.
