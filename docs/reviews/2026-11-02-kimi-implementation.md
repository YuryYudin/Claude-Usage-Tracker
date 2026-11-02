# Kimi Code implementation and production verification

Completed 2026-11-02 in the resumed integration checkout.

## Delivered

Kimi Code is a registered provider with a per-profile subscription key, global
Kimi.ai / China Kimi.com selection, manual key entry, and targeted OpenCode
credential import. Import fills a draft; Test and Save validates the endpoint
before committing credentials. Changing OpenCode's active login does not change
an existing Tracker account. Setup and settings share the connection editor;
the provider chooser now uses a two-column grid for four providers.

The API service reads only the selected coding `/v1/usages` endpoint, identifies
this app honestly, blocks redirects, and applies per-key/region retry backoff
including Retry-After. It parses named quota ratios and legacy allowance counts,
accepts numeric strings, rejects booleans/nonfinite values, and omits unavailable
windows. Failed refreshes retain the prior cache. Five-hour, optional weekly,
monthly total and monthly code-share windows keep their identities and reset
timestamps. Code share is part of the total and is never added to it. Monthly
windows do not receive an invented duration. Token counts remain unavailable.

The key uses the existing verified Keychain persistence and ad-hoc inline fallback
policy. Identity includes key and region; selection/name edits remain independent
of an in-flight refresh. Kimi does not rewrite CLI credentials or enable the
Anthropic-only integrations. The widget supports seven/eight accounts and labels
monthly data explicitly. Shared snapshot schema is now 5.

Implementation: `bc28603`. The live installation exposed an omitted monthly-label
allowlist entry in snapshot validation. `371bfd2` fixes that entry and adds an
actual snapshot write/load regression, including monthly code-share selection.
The corrected app/widget are **3.3.0, build 23**. Intermediate build 22 was
replaced, and its generated installer was removed.

## Validation

- Hosted Debug XCTest: **336 tests, zero failures, two signing-dependent
  data-protection Keychain tests skipped**. Coverage includes modern/legacy
  payloads, missing/malformed fields, month/weekly distinctions, key import
  selection and ambiguity, subprocess timeout, API headers, Retry-After,
  credential-change races, secure-store fallback/removal, and real snapshot
  validation. The new snapshot regression failed before the allowlist fix.
- Actual-source profile codec compatibility harness passed, including legacy
  account identities, Codex SSH/home/buckets, and metadata rollback. The harness
  now includes the real Kimi configuration model.
- Optimized Release app and embedded widget built for arm64 and x86_64 on
  Xcode 16.4 / Swift 6.1.2. Both advertise matching build-23 metadata.
- Localization syntax/key coverage passed for all 14 app/widget locales.
  New strings use English fallback; native translations are outstanding.
- A standalone executable using the actual Kimi auth/API/parser sources
  successfully imported the real OpenCode global login and fetched all three
  quota windows. Unrelated app presentation/error types were stubbed in this
  probe; hosted tests exercise the full app model and persistence.
- Rendered 72 synthetic previews: 6/7/8 accounts, four families, three rendering
  modes, light/dark. Inspected the seven-account extra-large layout with Kimi
  and the eight-account large layout. These previews inject host environment
  values and omit the host-only background; installed-host evidence follows.

[Seven-account preview](evidence/2026-11-02-kimi/7-extraLarge-full-dark.png)
and [eight-account large preview](evidence/2026-11-02-kimi/8-large-full-light.png).

## Production installation

The full app bundle was replaced at `/Applications/Claude Usage.app` after a
consistent private backup. The active global Kimi key from OpenCode was added
as a seventh profile using metadata encoded by the actual Profile model.
Existing profile records were retained and compared before launch. After
launch, the original six IDs, ordering, settings and active selection were
verified again. Usage caches may update and CLI OAuth credentials may refresh;
no old tokens were restored over newer ones. OpenCode auth files and SSH keys
were not changed.

All seven profiles have fresh usage caches within five minutes of verification:
three Anthropic, two Codex, Z.ai, and Kimi. The Kimi cache contains
`limit_5h`, `limit_month_total`, and `limit_month_code`; weekly usage is absent
and hidden. All seven history files exist, including Kimi's newly created file.

The schema-5 widget snapshot includes seven displayed accounts, with Kimi's
session/monthly labels. WidgetKit's actual large and extra-large timelines both
reloaded successfully at 18:27:28 UTC. Their cached `.chrono-timeline` archives
contain all seven sanitized account names, including Kimi. Timeline entry count
is distinct from account count. The medium widget retains its four-account cap.

Installed app/extension signatures and installer SHA-256 were verified. One
searchable tracker remains. Temporary replaced app bundles were removed after
verification; previous app recovery copies remain compressed to avoid duplicate
launch targets. The corrected installer is:

`release/Claude-Usage-3.3.0-integration-build23-kimi-local.dmg`

It remains locally ad-hoc signed, with incompatible automatic upstream updates
disabled. Source changes are committed locally; nothing was pushed or published.

## Recovery and limits

Private recovery directory:

`~/Library/Application Support/Claude Usage Recovery/20261102-182252-kimi-build22.noindex/`

Its name records the first installation attempt. It contains the previous
working build-20 app ZIP, original preferences and Application Support/history,
the reconciled seven-profile preferences before build 23, and validation logs.
These files can contain credentials and must remain private. The source backup
branch is `backup/pre-kimi-20261102` at `96d87a1`.

Build/test/render evidence is under
`/private/tmp/claude-usage-kimi-20261102.noindex/`, with associated logs under
`/private/tmp/claude-usage-kimi-*.log`.

Native UI automation returned `Computer Use server error -10005: timeoutReached`
on both attempts. The live backend, stored profile continuity, and actual widget
archive content were verified; visual appearance of the new settings/setup
screen, account switching, desktop focus transition, and agreement with Kimi's
console percentages remain user checks. The app is running for those checks.
