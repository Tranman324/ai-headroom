# AI Usage Monitor

A native macOS menu-bar app that shows your **Claude Max** and **OpenAI Codex**
usage at a glance. It reads the credentials already on your Mac, polls each
provider's usage endpoint on an interval, and keeps a local history so you can
see burn rate and projected exhaustion before you hit a limit. No server, no
account, no data leaves your machine.

It surfaces up to **7 meters**:

- **Claude Max (up to 5):** Session (rolling 5h), Week (all models), and
  per-model weekly meters (Fable, Sonnet, Haiku). The per-model rows appear only
  for the models your account currently has an active weekly limit for, so you
  may see fewer than five.
- **OpenAI Codex (2):** Session (rolling 5h) and Weekly, tagged with your plan
  (Plus / Pro 5x / Pro 20x / Business).

## Prerequisites

- **macOS 14 (Sonoma) or later** — required for `MenuBarExtra`, Swift Charts,
  and `SMAppService`.
- **Xcode 15 or later** (Swift 5.9+) to build.
- **Claude Code credentials** present in the login Keychain as a generic-password
  item named `Claude Code-credentials` (created when you log in with the Claude
  Code CLI).
- **Codex CLI credentials** present at `~/.codex/auth.json` (created when you log
  in with the Codex CLI).

You do not need both providers — a provider with no usable credentials is shown
as "no data" and the other still works.

## Build and run (personal use)

Local development signing is sufficient — no App Store, notarization, or
Developer ID is required.

```sh
xcodebuild build \
  -project "AI Usage Monitor.xcodeproj" \
  -scheme "AI Usage Monitor" \
  -destination platform=macOS \
  -configuration Debug

open "$(xcodebuild -project 'AI Usage Monitor.xcodeproj' -scheme 'AI Usage Monitor' \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/AI Usage Monitor.app"
```

Or open `AI Usage Monitor.xcodeproj` in Xcode and Run. If you have no signing
certificate configured, the default ad-hoc signature is enough to run the app
locally.

### First run: Keychain approval

The first time the app polls Claude, macOS asks whether "AI Usage Monitor" may
read the `Claude Code-credentials` Keychain item. Click **Always Allow** so the
app can keep polling without re-prompting. Codex credentials are read directly
from `~/.codex/auth.json` and need no prompt.

## Where your data is stored

Everything lives under `~/.ai-usage/` with restrictive permissions:

| Path | Mode | Contents |
|---|---|---|
| `~/.ai-usage/` | `0700` | data directory (owner-only) |
| `~/.ai-usage/usage-history.jsonl` | `0600` | append-only history, one JSON record per line |
| `~/.ai-usage/settings.json` | `0600` | your settings (written when you change one) |

Each history line is a self-describing record (`combinedSnapshot`,
`providerSnapshot`, or `providerFailure`) with a timestamp, the provider, and
sanitized meter values. **No tokens or account IDs are ever written to disk,
logs, or the UI** — credentials are read from their canonical locations per poll
and never copied elsewhere.

## Using it

The menu-bar item shows a small gauge glyph plus the **hottest** meter's
percentage. Its appearance tracks your usage:

- **Normal** (all meters < 70%): monochrome gauge, white percentage.
- **Warning** (any meter ≥ 70%): percentage turns amber.
- **Critical** (any meter ≥ 90%): red capsule background, red icon and text.

- **Left-click** the item to open the popover with all provider sections, meter
  bars, sparklines, and a collapsible 7-day history chart. Click any meter row
  to drill into its detail view (large %, burn rate, reset countdown, and a
  projection to 100% if you're on pace to exhaust it before reset).
- **Right-click** the item for the context menu:
  - **Refresh Now** (⌘R) — poll immediately.
  - **Open AI Usage…** — open the popover.
  - **Pause Alerts for 1 Hour** — hold the menu-bar color state steady for an
    hour (useful when you're knowingly running hot).
  - **Launch at Login** — toggle auto-start (registers via `SMAppService`).
  - **Quit AI Usage** (⌘Q).

You can also refresh from the refresh button in the popover header.

## Settings

Open the popover and click the gear. All values are validated and clamped to the
ranges below:

| Setting | Range | Default |
|---|---|---|
| Polling interval | 1–10 minutes | 3 minutes |
| Alert threshold | 50–95% (steps of 5) | 80% |
| History retention | 1–365 days | 30 days |
| Launch at login | on / off | off |

History older than the retention window is pruned on launch. Launch-at-login
registration state is shown live in Settings and reflects the real
`SMAppService` status.

## Troubleshooting

- **Codex token expired.** Handled automatically: the app refreshes the access
  token via OpenAI's OAuth endpoint and writes the rotated tokens back to
  `~/.codex/auth.json` atomically (preserving all other fields). No action
  needed. If the refresh token itself is dead, re-login with the Codex CLI.
- **Claude token expired.** The app does **not** refresh Claude tokens (by
  design — it never rotates Claude credentials). Re-authenticate with the Claude
  Code CLI to refresh the `Claude Code-credentials` Keychain item, then the next
  poll succeeds.
- **A provider shows an error or stale value while the other is fine.** Providers
  are polled independently. On a failed poll the app keeps showing the last
  known-good values with a staleness/error indicator instead of blanking out,
  and records a sanitized error row in the history. The healthy provider is
  unaffected.
- **Claude shows an error even though your token is valid.** The app maps the
  Anthropic usage response into up to 5 meters: Session, Week (all models), and a
  per-model weekly row for each model your account has an active limit for.
  Differing sets of per-model weekly limits are tolerated — unrecognized models
  are skipped and absent known models are simply omitted, so the meter count can
  vary without failing the poll. Only a genuinely malformed response — a missing
  `five_hour` or `seven_day` window, a malformed timestamp, or an out-of-range
  utilization value — is treated as a provider error ("Claude usage data was
  malformed."). Codex is unaffected. If this persists, the response contract has
  drifted and the Claude mapping needs updating.
- **Reset the history.** Quit the app and delete
  `~/.ai-usage/usage-history.jsonl` (and `settings.json` to reset settings). The
  directory and files are recreated on next launch.

## Running the tests

```sh
# Unit tests only
xcodebuild test \
  -project "AI Usage Monitor.xcodeproj" \
  -scheme "AI Usage Monitor" \
  -destination platform=macOS \
  -only-testing:"AI Usage MonitorTests"

# Full suite (unit + UI)
xcodebuild test \
  -project "AI Usage Monitor.xcodeproj" \
  -scheme "AI Usage Monitor" \
  -destination platform=macOS
```

The test host runs against in-memory fixtures and a temporary storage root, so
running the tests never reads your real credentials and never touches
`~/.ai-usage/`.
