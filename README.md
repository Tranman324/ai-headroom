# AI Headroom

A native macOS menu-bar app that shows how much of your **Claude** and **OpenAI Codex**
usage limits you have left, how fast you are burning them, and whether you will run out
before the window resets.

The app bundle is named **AI Usage Monitor**. Native Swift with no third-party dependencies, local-only storage, and 140 XCTest unit tests plus fixture-driven UI tests.

## Why it exists

Both providers enforce rolling 5-hour and weekly limits, and both bury the numbers.
Hitting a weekly cap mid-task means losing the session context you built up. This
app keeps the number in the menu bar and turns it into a forecast: at the current
pace, do you hit 100% before reset?

## What it shows

- **Menu-bar gauge** for the hottest meter. Normal below 70%, amber at 70%, red at 90%.
- **Popover** with each provider's meters, reset countdowns, and a 7-day history chart.
- **Meter detail** with a 30-minute burn rate, a projection line to 100%, and
  24h / 3d / 7d ranges.

Meters:

- **Claude:** Session (rolling 5h) and Week (all models), tagged with your plan.
- **Codex:** Session (rolling 5h) and Weekly, tagged with your plan
  (Plus, Pro 5x, Pro 20x, Business, Enterprise).

Each provider is polled independently. If one fails, the other keeps working and the
failed one keeps its last good values with a stale or error marker.

## How it gets the data

The app never reads tokens, Keychain items, or auth files, and never refreshes
credentials. It relies on each provider's own CLI and its own sign-in.

**Claude.** Claude Code passes rate-limit data to its status-line command. On connect,
the app checks `claude auth status --json`, then registers a small bridge as the
status-line command in `~/.claude/settings.json`. If you already had a status-line
command, the bridge forwards its input to it, so your existing status line keeps
working. The bridge writes only the 5-hour and 7-day percentages and reset times to a
local cache. Readings under 15 minutes old are fresh, readings up to 24 hours old are
stale, and anything older shows as no data.

**Codex.** The app starts `codex app-server --stdio` and asks it for the account plan
and rate limits over JSON-RPC (`account/read`, `account/rateLimits/read`). Signing in
uses the CLI's device-code flow. The app looks for the `codex` binary inside the
ChatGPT app and in the usual install locations.

The app makes no network requests of its own. It uses `NWPathMonitor` only to pause
polling while offline.

## Architecture

```text
AIUsageMonitor/
  Domain/        meters, status bands, burn-rate and projection math, settings, history records
  Services/      provider adapters (Claude CLI + status-line bridge, Codex app-server),
                 local persistence, platform adapters (clock, connectivity, launch at login)
  Composition/   dependency wiring, observable store, polling coordinator
  UI/            NSStatusItem controller, gauge renderer, SwiftUI popover, fixture launcher
  Fixtures/      deterministic snapshots for tests and screenshots
```

- **AppKit + SwiftUI.** An `NSStatusItem` hosts a SwiftUI popover. The gauge is custom
  drawn. Charts are hand-built rather than Swift Charts.
- **Everything external sits behind a protocol.** Clock, connectivity, filesystem
  root, provider CLIs, and launch-at-login registration are all injected, so every test
  runs against fakes.
- **Safe local writes.** Files are written atomically (temp file, then rename). The
  data folder is owner-only (`0700`) and files are `0600`. One bad history line is
  skipped, not fatal.
- **Fixture mode.** `--fixture-scenario <name>` launches the real UI on canned data
  (normal, warning, critical, stale, error, projections, and more) and can write a
  PNG plus a text description of what rendered. UI tests use the same path.

## Local data

Everything lives in `~/.ai-usage/`:

- `usage-history.jsonl`: append-only history of sanitized meter readings and failures
- `settings.json`: your settings
- `claude-usage.json`: the latest Claude reading from the status-line bridge

No tokens or account IDs are written anywhere. To reset, quit the app and delete the folder.

## Settings

- Polling interval: 1 to 10 minutes, default 3
- Alert threshold: 50% to 95% in steps of 5, default 80%
- History retention: 1 to 365 days, default 30. Older history is pruned on launch.
- Launch at login: registered through `SMAppService`

## Requirements

- macOS 14 (Sonoma) or later
- Xcode to build (developed with Xcode 26; older versions untested)
- Claude Code CLI signed in with a Claude account, for the Claude meters
- Codex CLI or the ChatGPT desktop app, for the Codex meters

You need only one provider. The other shows as not connected.

## Build and run

```sh
xcodebuild build \
  -project "AI Usage Monitor.xcodeproj" \
  -scheme "AI Usage Monitor" \
  -destination platform=macOS \
  -configuration Debug
```

Or open `AI Usage Monitor.xcodeproj` in Xcode and press Run. Ad-hoc signing is enough
for local use. No Developer ID or notarization is needed.

On first launch, open **Settings → Connections** and connect each provider.

## Tests

```sh
# Unit tests
xcodebuild test \
  -project "AI Usage Monitor.xcodeproj" \
  -scheme "AI Usage Monitor" \
  -destination platform=macOS \
  -only-testing:"AI Usage MonitorTests"

# Unit + UI tests
xcodebuild test \
  -project "AI Usage Monitor.xcodeproj" \
  -scheme "AI Usage Monitor" \
  -destination platform=macOS
```

Tests run against in-memory fakes and a temporary storage root. They never touch your
credentials or `~/.ai-usage/`.

## How it was built

I wrote the product spec, the design brief, the architecture rules, and the acceptance
criteria. The code was written by AI coding agents working from that
spec under review. The original brief and design spec are in [`docs/`](docs/). The
brief predates one major change: authentication was moved off direct token reads and
onto the providers' own CLIs.

## License

MIT. See [LICENSE](LICENSE).
