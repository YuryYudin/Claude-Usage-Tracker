# Claude Usage Tracker v3.4.0 - YuryYudin fork

The first release from this fork combines additional providers, desktop widgets
and account migration safeguards with removal of upstream's automatic analytics
heartbeat.

## Highlights

- Kimi Code subscriptions: Kimi.ai/Kimi.com region selection, OpenCode key import, manual keys, five-hour and available weekly/monthly quotas.
- Z.ai GLM Coding Plan monitoring, including token/credit quota compatibility.
- Codex through local or SSH app-server connections, with per-account executables, homes and named quota selection. HTTP connections are also available.
- Large and Extra Large desktop widgets for up to eight accounts, including monthly Kimi labels and the desktop-focus appearance fix.
- Guarded migration and credential persistence that retain account IDs, settings, connection targets and history.
- Removed the automatic daily version heartbeat used by upstream for installation and geographic statistics. The README no longer embeds upstream's geographic, sponsor or donation banners.

## Privacy

No automatic usage analytics heartbeat is sent. Optional feedback and mobile-app
interest buttons still submit requests when clicked. Feedback sends the name,
role, email and message entered by the user. Normal provider APIs, status checks
and GitHub contributor/avatar requests remain; usage history stays local.

## Downloads and upgrade

`Claude-Usage-3.4.0.dmg` and `Claude-Usage.zip` contain the same universal app
for Apple Silicon and Intel, version **3.4.0, build 25**, requiring macOS 14+.
Use `SHA256SUMS` to verify the downloaded files.

The app and embedded widget are **ad-hoc signed, not Developer ID signed or
Apple-notarized**. If macOS blocks the app, use its per-app Open Anyway option
in System Settings > Privacy & Security.

Quit the old app, privately back up preferences/history and archive the old app
as a ZIP, then replace `/Applications/Claude Usage.app`. Preserve live CLI auth
files and SSH keys. The app keeps the existing bundle identifier and profile
store. Do not run incompatible legacy or upstream builds against migrated data.
The DMG includes detailed upgrade notes.

Automatic upstream updates remain disabled. Install future fork releases
manually from this repository. Upstream Homebrew/Nix packages contain upstream's
app rather than this fork.

## Validation

336 hosted tests passed with zero failures and two signing-dependent Keychain
skips. The optimized universal app/widget, matching metadata, signatures,
heartbeat removal, archive contents and checksums were verified. The seven-account
installation was previously verified against live Claude, Codex, Z.ai and Kimi accounts.

New Kimi and revised privacy strings use English fallback in other locales.

Based on upstream v3.3.0. Original authorship and the MIT license are preserved.
