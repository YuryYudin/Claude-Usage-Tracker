**Upstream compatibility review — 8 October 2026**

Implementation and subsequent validation are documented in [the provider integration report](2026-10-08-provider-integration.md). The validation limits below describe the initial review phase.

The recommended direction is to adopt upstream's provider registry and shared UI,
while retaining the fork's Codex app-server connections, Z.ai quota support,
desktop widgets, and account refresh safeguards. A direct switch to the official
v3.3.0 build is unsafe for profiles written by this fork. This review reproduces
the format incompatibility with synthetic profiles; it does not launch either
app, read real credentials, alter installed applications, or migrate live data.

At the initial review stage, the migration below was proposed work. The subsequent
integration is documented separately and still awaits production acceptance.

**The revisions and PR status are pinned, so these findings can be revisited.**

| Item | Reviewed state |
|---|---|
| Current working branch | `feat/zai-usage-monitoring`, `97712e75ee60ab87da1da30453ded54bcd5d4950` |
| Published feature branch | `origin/feat/zai-usage-monitoring`, `9d7075a`; three additional commits exist locally |
| Shared ancestor | `574eb3720c9b793ed9d1477861187f7c9c23b6e2` — 12 July 2026, just after v3.2.0 |
| Upstream main after fetching | `588775e4540757443691fa1bcb33457315e05f86` — 31 August 2026 |
| Divergence | 17 fork-only commits; 52 upstream-only commits, including merges |
| Latest published release | v3.3.0, published 29 August 2026 |
| Codex [PR #300](https://github.com/hamed-elfayome/Claude-Usage-Tracker/pull/300) | Closed 29 August, unmerged; superseded by the independently developed registry implementation |
| Z.ai [PR #307](https://github.com/hamed-elfayome/Claude-Usage-Tracker/pull/307) | Closed 29 August, unmerged; maintainer explicitly invited a smaller registry-based provider PR |
| Desktop widget [PR #304](https://github.com/hamed-elfayome/Claude-Usage-Tracker/pull/304) | Still open, unmerged; head remains `d03cfd351ba18dec3f4cc02c0d24e281700cb4b0` |
| Codex [PR #342](https://github.com/hamed-elfayome/Claude-Usage-Tracker/pull/342) | Still open, unmerged; proposes hiding five-hour tracking for Pro profiles |

The maintainer called #304 the canonical desktop-widget PR and placed it in the
next review cycle. Its comment distinguishes it from #307, which incorporated
the widget work. #297 concerns a SwiftBar widget and #324 concerns phone widgets;
neither replaces #304's macOS WidgetKit extension.

**Most upstream changes arrived together in v3.3.0, rather than through a long
series of subsequent released architectures.**

The architectural change is commit `52bc240`: `Provider`, `ProviderDescriptor`,
`ProviderCapabilities`, `UsageProviderService`, and `ProviderRegistry`. It routes
provider fetches through one contract returning `ClaudeUsage`. Session and weekly
percentages/reset dates become shared fields; providers without token counts use
zero token values. Optional plan/credit fields were added, and history snapshots
can identify their provider and suppress inappropriate token counts in exports.

Other changes worth taking with that architecture are:

- Claude terminal launchers (`7061028`): stable per-profile config directories,
  launcher slugs that survive renames, and automatic Keychain pinning after the
  launcher's own login. They deliberately do not copy a refresh-token lineage
  into another config directory. Existing custom Keychain pins remain useful;
  adopting upstream does not require recreating every account through launchers.
- Keychain fallback (`551faa6`, `7c5c799`, `c66e0d9`): Developer ID builds without
  the data-protection entitlement can use the login Keychain. The fallback is
  restricted to builds with a stable Team ID; unsigned/ad-hoc builds retain the
  existing plist fallback. This is material to credential retention across
  signing/distribution modes, not just an internal refactor.
- Multi-profile status-item crash fixes (`5af720b`, `753539f`): coarse fixed item
  widths during creation and updates avoid macOS 26 layout recursion.
- Claude credential ownership (`ecb28dd`, `5042efc`): background reads avoid
  rotating externally owned, unpinned token lineages; explicit activation can
  refresh before applying credentials. Cached usage is allowed when a live
  credential is unavailable. Preserve the original `lastUpdated` in this case.
- Cloudflare handling (`80f5f4a`): clearance cookies accompany requests, and
  challenges are distinguished from expired credentials. Statusline scripts are
  refreshed on launch.
- Full-screen popover placement (`2a3cc70`), built-in-notch display targeting
  (`53068bc`), and bounded hook parsing with a larger body allowance (`27fd885`).
- Auto-start uses a live reset date to avoid restarting an already open, unused
  session; auto-start/auto-switch notifications honor per-profile toggles.
- Vietnamese is the 14th language. Peak-hours UI and related keys were removed.
  Release publishing now deterministically triggers appcast/Homebrew updates.
- A monthly support-reminder window was added. Include its existing user
  preference when comparing the eventual upgraded application's behavior.

Upstream main has no application-code changes after the v3.3.0 merge: subsequent
commits concern release workflows and the README. See the pinned
[v3.3.0 changelog](https://github.com/hamed-elfayome/Claude-Usage-Tracker/blob/588775e/CHANGELOG.md)
and [provider guide](https://github.com/hamed-elfayome/Claude-Usage-Tracker/blob/588775e/docs/ADDING_A_PROVIDER.md).

**The profile-format incompatibility is a release blocker, with a reproduced
failure rather than just a theoretical concern.**

Both trees store an encoded profile array under the same `profiles_v3` defaults
key and use the same app bundle identifier, `HamedElfayome.Claude-Usage`. An
official build therefore encounters the fork's existing storage. In both trees,
`ProfileStore.loadProfiles()` returns an empty array after an array decode
failure. `ProfileManager.loadProfiles()` interprets an empty array as first
launch, creates one default profile, and saves it over the existing array.

The failure chain is:

1. The fork's `MenuBarMetricType` contains `codex` and `zai`. Its ordinary default
   appearance config includes both as disabled metrics; its decoder also adds
   them to older appearance configs. This affects Claude profiles as well as
   the new providers.
2. Upstream's metric enum contains only `session`, `week`, and `api`. Its strict
   metrics-array decoder throws on `codex` or `zai`, even when the metric is
   disabled. `Profile.iconConfig` does not catch that error.
3. One incompatible profile rejects the entire array. Normal upstream startup
   then has the code path to overwrite it with a new default profile.

The codec experiment observes steps 1–2 and array rejection; step 3 is established
by reading the storage/startup code. The experiment deliberately does not execute
that live persistence path. Loss here concerns the stored account list and its
settings/references; it does not demonstrate that the old Keychain items or
history files are physically deleted. Orphaned secrets are still not a usable
multi-account setup.

Fixing the metrics alone is insufficient:

- Fork `claude` becomes upstream `anthropic` through upstream's unknown-provider
  fallback. This happens to preserve the intended Claude provider, but it is
  implicit rather than an explicit migration.
- Fork `zai` also becomes `anthropic`, which changes its identity incorrectly.
  Upstream does not hydrate its `zaiAPIKey` or retain its quota configuration.
- Fork `codex` remains `codex`, but upstream ignores `codexConfiguration` and
  `codexUsage`. Saving removes the SSH host, executable, per-profile home,
  selected bucket, email-display preference, and that cache. It imports no
  per-profile Codex credentials. An active profile can then read the machine's
  default auth.json instead of its originally selected account.
- Rollback is incompatible too: the fork's provider decoder throws on upstream's
  `anthropic` raw value. Reinstalling the old binary alone is not a rollback plan.
- Unknown fields are generally dropped by decode/re-encode. Future unsupported
  providers should remain identifiable and inactive, rather than silently
  becoming Anthropic or being discarded.

The fork's Z.ai secret identity is
`com.claudeusagetracker.profile-credentials` / `<UUID>.zai-api-key`. Retain that
service/account naming, the existing profile UUID, and hydrate/persist/delete
support while adopting upstream's expanded Keychain implementation. Preserve
Claude's existing secret identifiers and custom source-service pins as well.

**Upstream Codex replaces shared presentation, but does not replace the fork's
connection modes or all its data.**

| Behavior | Fork | Upstream `588775e` | Recommended treatment |
|---|---|---|---|
| Shared provider UI | Many provider-specific branches | Registry/capability gates | Adopt upstream |
| Authentication owner | Codex CLI through app-server | Tracker reads and refreshes OAuth/auth.json | Keep app-server for existing connections |
| Multiple local homes | Explicit per-profile `codexHome` | One process-environment `CODEX_HOME`, plus pasted per-profile credentials | Preserve explicit account targets |
| Custom executable | Per profile | No corresponding connection setting | Preserve |
| SSH accounts | Standard SSH aliases/agent over stdio | No remote transport | Preserve |
| Usage transport | Long-lived JSON-RPC `codex app-server --stdio` | Direct ChatGPT backend HTTP usage endpoint | Put both behind the registry if both are retained |
| Short/long windows | Stored per named rate-limit bucket | Normalized to session/weekly by duration | Adopt shared fields, preserve bucket selection |
| Additional named limits | Supported and selectable | DTO explicitly ignores `additional_rate_limits` | Retain provider details |
| Lifetime/daily token summary | Optional app-server surface | No equivalent mapping | Retain as optional diagnostics, not quota token counts |
| Account/plan/credits | Provider details | Plan/credits in shared usage; email in credential UI | Reuse shared fields and preserve email preference |
| Service status | Dedicated OpenAI status service | Status URL in descriptor | Adopt descriptor routing after parity review |
| Request lifecycle | Per-profile service, request token, target validation, timeout/process cleanup | Direct network calls; simpler profile handling | Retain safeguards in a shared refresh coordinator |

Upstream Codex has worthwhile behavior: duration-based window classification,
tolerant field decoding, stable reset fallbacks using previous usage, one forced
refresh/retry on auth failure, and in-process refresh deduplication. It also
restricts fallback to shared auth.json to the active profile, preventing a
credential-less inactive profile from silently reporting that account.

Those protections are not equivalent to the fork's account isolation. Its
`authFileExists()` credential predicate can still advertise an inactive profile
as connected even when the fetch subsequently rejects shared-file fallback.
It has no per-profile target or CLI keychain-auth discovery path equivalent to
delegating authentication to app-server.

The upstream release notes and #300 maintainer comment explicitly say Codex
shipped against mocks, without live-account verification. This review does not
claim to establish current live endpoint or CLI compatibility. Keep the working
transport until a candidate has been compared against the real account matrix.
Treat #342 as pending related work: it is not already included in upstream main.
Its proposal also illustrates why a missing window must be distinguishable from
a real zero-percent window across icons, history, alerts, and widgets.

**Several account safeguards must be added or retained when moving to the
registry. These are source-review findings, not live race reproductions.**

| Finding | Evidence / consequence | Required adaptation |
|---|---|---|
| Active-account refresh race | Upstream `MenuBarManager.refreshUsage()` captures a profile, awaits its request, then saves to the current active UUID and updates visible state/notifications without checking the source UUID | Capture source UUID/provider/account revision; save only to that source if still valid; update active UI only if it remains active; reject deleted/changed-account responses |
| Late manual-Codex token persistence | `CodexAuthService.persistRefreshed()` asynchronously finds a profile by UUID and patches its credentials without comparing the current credential lineage with the request's original lineage | Revalidate provider/source credentials before persistence; await the guarded save |
| Shared-refresh persistence | Deduplicated refresh task persists for its first caller's profile; joining callers receive the result without independently persisting it to their own manual profile | Share the network operation, then guarded persistence for each still-valid credential owner; test CLI coexistence separately |
| Inactive displayed accounts in single mode | Upstream refreshes only the active profile in single display mode; no equivalent of fork commit `65c080b` | Restore an immediate startup refresh plus a five-minute displayed-inactive cycle through the registry |
| Mixed-provider auto-switch | Upstream auto-switch has no source-provider gate and its candidate loop accepts any provider with usage credentials; a Claude limit can select a Codex account | Preserve the fork's Claude-only behavior initially; add a deliberate capability and provider-compatible candidate rule before generalizing |
| Notification identity/parity | Shared upstream alerts track state by profile name and inspect session usage; multi-profile refresh does not call the alert checker | Use UUID + bucket/window + reset identity, preserving selected-quota alerts and duplicate-name/rename behavior; define background-alert behavior deliberately |

The fork is not a proof that every race is solved. Its Claude path retains fewer
account-revision checks than its Codex/Z.ai paths. The new coordinator should
make source/profile/account validation consistent for all providers, including
API billing, service status, error banners, history, and loading state.

Keep upstream's read-only policy for externally owned Claude credentials when
restoring the background cycle. Polling must not force token rotation just to
make a widget look fresh. A returned cached snapshot keeps its original age;
publishing a new heartbeat must not relabel it as freshly fetched.

**Z.ai should be rebuilt as a small provider implementation, with an explicit
decision about preserving the third quota window.**

The reusable pieces are `ZAIAPIService`, the quota DTOs, `ZAIUsage` and its
window classification, API-key settings UI, tests, translations, and the existing
Keychain field. Preserve HTTPS/Bearer authentication to the quota monitor,
HTTP/body error handling, and injectable transport tests. Window classification
must continue using `unit` (3: five-hour; 6: weekly; 5: monthly tool calls), since
both token-based and credit-based response generations are already covered.
This review verifies the implementation and fixtures, not the current live
behavior of that undocumented endpoint.

Add `Provider.zai`, a descriptor/service registration, the secret hydration and
persistence, credential-section routing, and onboarding routing. Set capability
flags deliberately: no Claude CLI sync, billing console, per-model Claude
breakdown, token counts, auto-start, or overage calls. A Coding Plan credit quota
is not the prepaid credit balance represented by upstream's `credits` capability.
Map actual five-hour and weekly windows to shared usage fields with zero token
counts. Keep raw credits/tool-call quantities in provider details.

Mapping only to `ClaudeUsage` loses monthly tool calls, selected-quota icon and
alert behavior, and full quota rows. For a no-regression fork, add a generic
optional quota-details model/presentation seam instead of reintroducing dozens
of `provider == .zai` branches. It should express window/bucket identity,
availability, labels, duration, reset date, used percentage, raw unit, and optional
counts. Keep actual session/weekly history semantics independent of whichever
window is selected for a tray icon. This seam also serves Codex named buckets.

Translate legacy selected-limit IDs into a stable window identity: persisted
`TOKENS_LIMIT-6` does not match a future `CREDIT_LIMIT-6`, and the existing fallback
can quietly select the five-hour quota. Preserve the user's weekly selection by
semantic window role rather than relying exclusively on the provider's type
string. Do not fabricate monthly reset dates as fixed 30-day periods when the
provider supplies an actual reset time or leaves it unknown.

The provider guide's stated goal of needing no core edits is useful but not
fully achieved in this revision: onboarding has an exhaustive provider switch,
and descriptor window-label keys are defined but not consumed by the dashboard.
Settings and wizard routing will need small explicit additions. Third-window
support and selected-window notifications need a real shared extension; simply
setting flags will not create those missing behaviors.

**The desktop widget work can be retained with less architectural change than
the fork's complete provider stack.**

The canonical #304 tree merges with current upstream without textual conflicts.
An isolated no-commit merge also passes `build-for-testing`, including the widget
extension. Its publisher reads `profile.claudeUsage`; upstream now uses that same
field for Codex. Basic session/weekly values therefore have a natural shared path
without bringing the fork's old Codex branches back into the widget publisher.
That is a code/build result, not a signed desktop runtime validation.

Port the fork's additions on top of that base:

- `fee1d38`: bounded snapshot loading, validation, private directory/file
  permissions, a read-only entitlement scoped to the exact snapshot file,
  provider metadata, optional resets, and related regression coverage.
- `55673b0`: desktop legibility under macOS's greying treatment. Preserve the
  verified drawing/contrast behavior; do not assume `widgetRenderingMode`
  identifies this treatment.
- `65c080b`: displayed-inactive refresh and an honest 15-minute stale horizon,
  with row-age information. It supersedes the earlier six-hour masking of stale
  data in `9d7075a`; do not cherry-pick the intermediate stale-threshold change as
  the final behavior.
- The Z.ai schema/version changes and selectable-window behavior from `29fc8ad`,
  adapted to the new generic quota representation.

Keep no-App-Group sharing, real-home resolution, sanitized names, active-profile
inclusion even when not displayed, overview display filtering, empty snapshots,
heartbeat writes, deferred/throttled reloads, timeline stale/reset boundaries,
and signing the embedded extension before the outer application. Existing small
widgets show the active profile; overview widgets show up to four/six selected
profiles for medium/large sizes. The fork snapshot itself caps at 64 profiles;
validate or deliberately handle that cap for larger account collections rather
than letting a failed write leave an older snapshot on disk.

The fork currently projects the selected Z.ai quota into the widget's session
slot and picks another token quota for its weekly slot. If the weekly quota is
selected, that can invert the labels; selecting monthly calls mixes different
units. The adapted widget needs real labels/window roles and optional availability,
not hardcoded five-hour/weekly captions over whichever values are selected.
Missing Codex windows must also stay absent rather than acquire synthetic values.

Schema 3 belongs to the fork; #304's original format is older. Publish the app and
extension together with a deliberate version strategy. Keep widget IDs/bundle
identity stable to avoid unnecessary re-adding of desktop widgets. Add new keys
for Vietnamese and check all 14 locales: #304/fork localization additions covered
only the original 13.

Widget strings live in the extension's own `ClaudeUsageWidget/Resources`, not the
main app's resource directory. The existing localization script checks only the
app, so it will pass even while Vietnamese widget strings are absent. A separate
key comparison confirms parity for the current 13 widget locales (seven keys
each), but a 14th locale and checks for both targets must be added.

**A staged migration provides a safer and smaller route than rebasing the whole
feature stack and resolving conflicts mechanically.**

The whole-fork dry merge reports 26 content conflicts: three menu-bar/UI files,
13 translations, Profile/Keychain/ProfileManager/storage files, and settings/
wizard routes. A clean textual result would still not settle schema, account
identity, credential ownership, or UI parity. Prefer a new branch based on pinned
upstream, leaving `97712e7` and its three local-only commits intact.

1. Build a compatibility layer first. Snapshot the actual defaults domain and
   per-profile history privately before any live migration, retain source
   credentials in their original stores, and record profile counts/UUIDs and
   non-secret settings. A defaults backup alone cannot restore Keychain-held
   secrets; preserve access under the signing identity and retain original
   items rather than exporting credentials into a general review artifact.
2. Decode the fork's provider values and metrics explicitly. Preserve UUIDs,
   ordering, active selection, display flags/mode, appearance, notification
   settings, refresh intervals, custom Claude service pins, and Codex/Z.ai
   configurations. Map `claude` to `anthropic`; retain a supported `zai` provider;
   convert `codex`/`zai` icon settings to shared metrics without blindly dropping
   the user's enabled/style/order/quota choice. Preserve excluded API settings
   for future editing even when the provider cannot display them.
3. Stage and validate the entire converted array before replacing any live key.
   An invalid profile must produce recoverable diagnostics and leave the
   original array intact, not trigger first-launch overwrite. Retain unsupported
   records or refuse migration; never silently normalize another provider to
   Anthropic. Verify secret writes by read-back and mark migration complete only
   after all required state succeeds. Repeat execution must be idempotent.
4. Adopt upstream's shared services and UI, plus a generic refresh coordinator
   that retains source/revision guards, background freshness, provider-compatible
   auto-switch, and notification identity. Preserve cached timestamps and usage
   history UUIDs/files. The fork did not record Codex/Z.ai through upstream's
   history pipeline, so new chart support need not imply that historical records
   for those providers already exist.
5. Adapt app-server as the Codex registry service for legacy local/SSH profiles.
   If upstream HTTP mode is retained, expose it as an explicit connection source
   for new profiles; do not silently convert all existing connections or copy
   CLI-managed refresh tokens into pasted-profile storage. Preserve optional
   diagnostics and named limits through the shared details seam.
6. Add Z.ai independently of widgets and the Codex adaptation. Then integrate
   #304 and the fork improvements in a separate change. Retain removed-account
   and changed-credential snapshot clearing events when porting observers.
7. Exercise migration and rollback against synthetic or isolated copied stores.
   Then compare a signed candidate against the working build account by account.
   Keep the production installation and original state until those comparisons
   pass. Rollback must restore the old store format as well as the old binary;
   changed token lineages need deliberate handling, not restoration of obsolete
   refresh tokens over currently valid CLI credentials.

Suggested upstream submissions: a generic account-refresh/isolation fix; a small
Z.ai provider PR with its necessary shared quota extension; a separate Codex
connection-mode enhancement; and improvements to canonical #304 coordinated with
its author. The fork-to-upstream storage adapter can remain a separate migration
change. Do not recreate #307 as a PR containing Codex and widgets again.

The fork still points Sparkle at upstream's appcast. Its updater starts on launch.
Before distributing an adapted fork, define an update channel that cannot offer a
binary lacking its migration/features. This review leaves the user's live update
preferences untouched and does not establish their currently installed value.

**Validation completed in this review is narrower than a production acceptance
test, and the remaining gates are explicit.**

| Check | Result |
|---|---|
| Remote history and PR/release state | Refetched and checked through Git/GitHub on 8 October |
| Actual profile/appearance codecs with synthetic fixtures | Fork round-trip passes; all three fork provider profiles fail unchanged upstream decode; field loss/provider fallback and reverse incompatibility reproduced |
| Current fork Debug `build-for-testing` | Pass, app/test/widget targets compile |
| Upstream Debug `build-for-testing` | Pass, app and test targets compile |
| Canonical #304 + current upstream, isolated no-commit merge | Zero textual conflicts; Debug `build-for-testing` passes |
| Full fork + upstream, `git merge-tree --write-tree` | 26 content conflicts; production branch untouched |
| Fork localization parity | Pass: English plus 12 translations, 852 keys |
| Upstream localization parity | Pass: English plus 13 translations, 820 keys |
| Widget-target localization parity | Existing 13 locales match their seven English keys; Vietnamese absent; app-only validation script does not detect this gap |
| Hosted XCTest execution / real account calls / signed release / installed widgets | Not performed in this review |

The first concurrent package resolution hit a shared Sparkle-cache race; the
fork build passed when retried using the already resolved package directory.
Both trees emit existing compiler warnings, including actor-isolation warnings;
the successful builds do not establish Swift 6 strict-concurrency readiness.

Hosted tests launch the application target, whose startup accesses normal
storage/services. They were built but not executed against this actively used
installation. The standalone compatibility harness stubs unrelated usage-cache
and service types; it compiles the real `Profile`, appearance, provider/config,
and notification-settings source from the pinned commits and never launches the
application. It is not a replacement for migration integration tests.

Reproduce the codec check from the repository root:

```sh
python3 docs/reviews/check_profile_compatibility.py
```

The migration acceptance matrix must cover:

- Multiple Claude accounts using web cookies, cached CLI OAuth, custom Keychain
  pins, and per-profile launchers; expired externally owned credentials must stay
  read-only during background polling.
- Multiple local Codex homes, default-home connections, custom executables, SSH
  aliases, and named buckets; request failure/restart, expired auth, and optional
  metadata missing must not affect another profile.
- Several Z.ai keys with token/credit response variants; all three windows,
  selected weekly/monthly limits, missing resets, invalid keys/no plan, and
  changing keys while an old response is in flight.
- Switching A → B during usage/status/billing/token refresh; deleting/recreating
  accounts, renaming duplicate-name accounts, changing providers/targets/keys,
  and overlapping manual/background refreshes. Verify cache, history, banners,
  notifications, and statusline attribution by UUID/account revision.
- Single/multi display transitions, active-but-unselected profiles, startup and
  wake, a failed background account, and long periods with unchanged usage. Stale
  rows must remain stale even while another account keeps the snapshot alive.
- Small/medium/large widgets, light/dark and macOS greying, zero credentials,
  removed profiles, schema mismatch, corrupt/oversized snapshots, missing usage
  windows, and large profile lists. A timeline reload request is not a guaranteed
  immediate desktop update, so verify actual WidgetKit behavior separately.
- Signing/credential availability across the intended Developer ID identity and
  development builds; nested extension signing and sandbox snapshot readability.
- v3.2 baseline profiles, current fork profiles, early app-wide Codex settings,
  already-migrated upstream profiles, a malformed profile among valid accounts,
  interrupted migration, Keychain write failure, repeat migration, and rollback.

The two temporary review worktrees are under `/tmp/claude-usage-upstream-review-588775e`
and `/tmp/claude-usage-widget-upstream-review`. The second contains an intentionally
uncommitted merge for the compile probe. Build logs/results use
`/tmp/claude-usage-review-*`; they are local review artifacts, not deployment
outputs. The original branch and installed account state remain unchanged.
