# Automatic heartbeat removed

The upstream automatic daily analytics heartbeat is removed in commit `a15cf50`.
`HeartbeatService.swift` and its startup call are deleted. Build 24's executable
contains neither the service name nor its `type=heartbeat` endpoint. Local widget
freshness updates remain in place; these write the local snapshot and do not
send analytics.

README, SECURITY, and the support screen now describe the actual behavior.
Optional feedback and mobile-app interest requests remain user-triggered;
feedback includes the name, role, email and message entered by the user.
The two revised support-screen strings use English fallback in all 14 locales.
Expected provider APIs, status requests and GitHub contributor/avatar requests
remain. Incompatible upstream automatic updates remain disabled.

Validation: hosted Debug suite passed with **336 tests, zero failures and two
signing-dependent Keychain skips**. Optimized Release app/widget built for both
arm64 and x86_64. Localization parity, project metadata, app/widget version parity,
signatures and installer integrity passed. Removing this service does not change
the account or widget snapshot formats.

**3.3.0/build 24** is installed and running at `/Applications/Claude Usage.app`.
After restart, all seven account IDs/order/settings and the active account were
compared with the pre-upgrade backup and retained. The historical last-heartbeat
timestamp was unchanged; its leftover preference is inert. The widget snapshot
contains all seven accounts. One searchable app remains.

Private recovery backup:
`~/Library/Application Support/Claude Usage Recovery/20261102-203008-no-heartbeat-build24.noindex/`.
It contains the previous build-23 app ZIP, preferences and Application Support,
including history. Temporary uncompressed app staging copies were removed.

Local installer:
`release/Claude-Usage-3.3.0-integration-build24-no-heartbeat-local.dmg`, with its
adjacent SHA-256 file. It is locally ad-hoc signed. Build and test logs are under
`/private/tmp/claude-usage-build24-*.log`.

The fork's earlier main has three Codex commits whose implementation has been
superseded by the tested provider integration. Promotion to main retains that
history through a merge commit while keeping the integration source tree intact.
No force push is required.
