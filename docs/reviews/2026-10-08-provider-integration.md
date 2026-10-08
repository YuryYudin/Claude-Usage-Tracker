# Codex GLM and widget integration

The integration on `integration/upstream-providers` adopts upstream's provider
registry while retaining the fork's local and SSH Codex accounts, GLM keys, and
widget behavior. Source and synthetic migration checks pass. Deployment still
requires a signing identity with access to the existing credentials and an
account-by-account comparison with the working app.

The implementation lives in
`/Users/ggtest/Work/Claude/Claude-Usage-Tracker-integration`. The original worktree
remains on `feat/zai-usage-monitoring` at `97712e7`; its source commits and installed
application were not replaced. Hosted tests use isolated preferences, history,
and profile secrets. They do not start the production refresh or updater services.

The architecture and PR findings are in
[the upstream compatibility review](2026-10-08-upstream-compatibility.md).
The upstream baseline is `588775e`, and widget PR #304 is integrated from its
reviewed `d03cfd3` head. This is a local integration of that open PR, not a claim
that upstream merged it. No PR or release has been published.

## Provider behavior

| Feature | Result |
|---|---|
| Upstream provider registry and capability flags | Used for fetches, status, credentials, dashboard rows, history, and auto-switch eligibility |
| Existing Codex local and SSH profiles | Retain their executable, home, SSH alias, selected bucket, UUID, and appearance |
| Codex app-server | Runs as a registry service, with a separate client per profile and connection cleanup |
| Upstream Codex HTTP | Available as an explicit alternative connection source; existing CLI profiles are not silently switched |
| App-server metadata | Named buckets, account/plan details, optional diagnostics and token statistics remain available; optional endpoints can fail without discarding usage |
| Z.ai GLM | Registered independently, with per-profile Keychain credentials and token/credit response compatibility |
| Quota windows | Preserve window identity, optional resets, consumption/budget units, and session/weekly/tool roles |
| Selected tray quota | Uses the current selection when a request finishes; session and weekly history keep their actual values |
| OpenAI status | Retains the fork's summary/feed handling, including protection against a misleading green status |

Upstream HTTP remains useful for pasted credentials or its active-account auth
file fallback. App-server retains benefits for several local Codex homes, custom
executables, SSH connections, named limits, and CLI-owned authentication. The
connection settings make that choice explicit.

The shared contract remains `ClaudeUsage` to match upstream. `UsageQuota` carries
extra windows, and `UsageProviderResult` carries a guarded provider cache update
and projection through current display settings. Provider services own response
mapping; the refresh pipeline handles the resulting shared data.

## Account preservation

`ProfileStore` accepts legacy `claude` identities and the fork's `codex` and `zai`
metrics. It converts the provider metric to the shared session metric while
retaining its enabled state, style, order, and display settings. Profile IDs,
ordering, active selection, custom Claude Keychain pins, launcher metadata,
notification settings, refresh intervals, and connection/quota choices remain
attached to the same records.

An unreadable array, duplicate UUID, malformed provider, failed backup, or external
store change blocks replacement. Unknown string providers remain unsupported
records, and unknown top-level profile fields survive saving. The app stops
startup with a storage message when loading cannot safely complete. Profile edits
and deletions must persist before the manager commits their account changes;
a rejected deletion cannot remove the profile's secrets or history.

Before the first compatibility save, production creates:

```text
~/Library/Application Support/Claude Usage/migration/
  before-provider-integration.plist
  history/*.json
```

The defaults file contains the original app domain and a backup format marker.
History files are copied without changing their contents. The complete backup is
staged and published together; directory permissions are `0700` and file
permissions are `0600`. Legacy history held in preferences is included in the
defaults snapshot. This backup is retained across repeated migrations.

Non-nil secrets are omitted from preferences only after successful read-back.
Unavailable Keychain writes retain the existing inline fallback and do not mark
those writes complete. Missing hydration never authorizes deleting a Keychain
item. An explicit credential removal must succeed before its profile change can
be saved. Original Keychain service names and UUID-based item names remain in use.
The preferences/history backup does not export Keychain-held secrets.

Compatibility backup creation is implemented and tested against isolated stores;
no migration or backup has been run against the user's production accounts.

## Refresh and credential ownership

Usage responses are attributed by UUID, provider, and credential/connection
identity. Changing keys, targets or providers, deleting an account, or starting a
newer refresh supersedes an old result. Switching the active account does not
redirect another account's valid response, history, or billing cache.

Failures and credential banners belong to the displayed account. A clicked
account's popover reads its current cache and refreshes that account. Provider
status links use the appropriate status service. Auto-switch stays within a
compatible provider and does not apply Claude CLI behavior to Codex or GLM.

Inactive display-selected accounts refresh every five minutes in single-account
tray mode. Cache age remains the original fetch age: a fallback cache is not
reported as a fresh sample, and repeated cached results do not generate new usage
samples or threshold alerts.

OAuth refreshes share a request per token and retain successful rotations for
late callers. Write-back checks the initiating credential source before replacing
CLI credentials. Claude cache updates patch the current managed profile, and
profile activation uses the record after refresh rather than restoring a stale
snapshot. These checks reduce races between this app's requests. They do not make
independent external CLI processes participate in one atomic rotation transaction;
real account switching and externally owned credentials remain part of rollout
validation.

## Widget behavior

The canonical widget target uses normalized shared usage. The integration retains
the fork's contrast treatment under macOS greying, fifteen-minute stale handling,
per-profile fetch timestamps, private bounded snapshots, and reload throttling.
Schema version 4 adds labels for the selected quota and its secondary window.
A named Codex bucket's secondary window comes from that same bucket; GLM's monthly
tool quota is labelled as tools. Missing quotas are excluded rather than presented
as zero usage, and missing reset times remain absent.

Meaningful label changes and a stale profile becoming fresh trigger reloads even
when percentages stay flat. Empty credential sets clear the snapshot. The shared
file uses the existing read-only sandbox exception without App Groups.

The snapshot includes at most 64 accounts, retaining the active account if it
falls outside that prefix. This limit affects widget snapshots; profile storage
has no corresponding account-count limit. Actual desktop layout and sandbox reads
still need verification with a signed installed extension.

App and widget locale coverage now both include fourteen locales, including
Vietnamese. The validator checks both targets, syntax, duplicate keys, and locale
coverage. Five existing duplicate app keys were removed without changing their
parsed values. Some newly introduced integration/recovery strings use English
fallback text across locales; key parity does not establish native translation
quality for those additions.

## Validation

| Check | Result |
|---|---|
| Hosted Debug XCTest | 317 tests executed, zero failures, two Keychain tests skipped |
| Migration and persistence | Legacy metrics, UUIDs/targets/settings, malformed arrays, unknown providers, external changes, backup failure, secret fallback, rejected deletion/creation, and repeated migration covered |
| Quota and refresh tests | Named buckets, weekly-only HTTP, monthly tools, token/credit selection, missing resets, stale responses, deleted accounts, overlap, and current display selection covered |
| OAuth tests | Concurrent/late callers, token chains, failed-request retry, and changed credential sources covered with synthetic data |
| Widget tests | Bounds/corruption/privacy, selected bucket, heartbeat, labels, stale/fresh transitions, and reload behavior covered |
| Actual source codec harness | Original fork records load in the integration; re-encoding preserves fixture identities/configurations; restoring original bytes loads through the actual old fork codec |
| Universal Release build | App and embedded widget compile for `arm64` and `x86_64`, without a distribution signing identity |
| Localization validator | App: fourteen locales and 917 keys; widget: fourteen locales and nine keys |
| Live credentials and desktop widgets | Require the signed comparison below |

The two skipped tests require data-protection Keychain access that is unavailable
under this test signing context. `/usr/bin/security find-identity -v -p codesigning`
reported zero valid signing identities. Swift actor-isolation and build
warnings remain, including adopted service helpers; this branch does not establish Swift 6 language-mode readiness.
A Swift 6.3.3 optimizer crash in synthesized generic coordinator destruction was
resolved with an explicit nonisolated deinitializer; the normal optimized universal
build succeeds with that adjustment.

Reproduce from the integration worktree:

```sh
python3 scripts/validate_localizations.py
python3 docs/reviews/check_profile_compatibility.py --integration-ref HEAD

xcodebuild -project 'Claude Usage.xcodeproj' -scheme 'Claude Usage' \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO test

xcodebuild -project 'Claude Usage.xcodeproj' -scheme 'Claude Usage' \
  -configuration Release -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
```

Local artifacts are under `/tmp/claude-usage-integration-*`. The final XCTest log
is `claude-usage-integration-verified-tests.log`; optimized Release validation is
in `claude-usage-integration-release-optimizer-fix.log`. The release bundle is under
`claude-usage-integration-release-derived/Build/Products/Release/Claude Usage.app`.
It is a build artifact, not an installed or distribution-signed release.

## Production rollout and rollback

Sparkle is disabled for this candidate through
`ProviderIntegrationUpdatesEnabled=false`. The guard covers startup, manual
checks, and toggling automatic checks without changing the working app's
preferences. Enabling it requires configuring a feed and verification key for
releases that retain these providers and migration support.

Before replacing the working installation:

1. Sign the app and nested widget with an identity that can read the existing
   profile credentials. Verify every account UUID and its credential source;
   unavailable hydration is not proof that an account has no credentials.
2. Privately preserve the current defaults and history while the working app is
   stopped. Keep the working binary and original Keychain items. Preserve any
   existing migration backup separately; the candidate does not overwrite it.
3. Compare all accounts against the working build: Claude cookies and pinned CLI
   sources; each Codex local home and SSH target; and each GLM key and selected
   quota. Verify cache age, selected tray limits, history, alerts, and account
   switching. Exercise token refresh deliberately rather than by restoring stale
   refresh tokens.
4. Verify the installed widgets in all sizes, light/dark mode and macOS greying,
   including fresh/stale accounts, credential removal, and multiple named buckets.
5. Confirm rollback before keeping the candidate installed. The old fork cannot
   decode the integration's `anthropic` provider value, so replacing only the
   binary is insufficient.

Rollback must restore the compatible original profile/preferences format and,
where necessary, its history. Preserve the newest valid credential values by
UUID when reconciling that original snapshot: copying old inline OAuth tokens
over newer Keychain or CLI credentials can invalidate access. Do not overwrite
`auth.json`, Claude's live credential files, SSH keys, or current Keychain items
with frozen token snapshots. New/deleted profiles or changed account sources
require reconciliation before restoring the earlier metadata.

The isolated tests prove metadata restoration and codec compatibility. They do
not establish production credential reconciliation or a signed rollback. Those
remain acceptance requirements for installation, which has not been performed.
