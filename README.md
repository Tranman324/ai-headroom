# AI Headroom

A native macOS menu-bar app that shows how much of your **Claude** and **OpenAI Codex**
usage limits you have left, how fast you are burning them, and whether you will run out
before the window resets.

The app bundle is named **AI Usage Monitor**. Native Swift with no third-party dependencies, local-only storage, and 195 XCTest unit tests plus fixture-driven UI tests.

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

- **Claude:** Session (rolling 5h) and Week (all models), plus per-model weekly
  meters (Fable, Sonnet, Haiku) when Claude reports them, tagged with your plan.
- **Codex:** Session (rolling 5h) and Weekly, tagged with your plan
  (Plus, Pro 5x, Pro 20x, Business, Enterprise). Each window is labeled by its
  length, so a weekly-only plan shows a Weekly meter, not a Session one.

Each provider is polled independently. If one fails, the other keeps working and the
failed one keeps its last good values with a stale or error marker.

## How it gets the data

The app never reads tokens, Keychain items, or auth files, and never refreshes
credentials. It relies on each provider's own CLI and its own sign-in.

**Claude.** Each poll checks `claude auth status --json`, then starts a short-lived
`claude -p` in stream-json mode and sends it the `get_usage` control request. Claude
Code answers with your claude.ai plan limits using its own sign-in, without sending a
prompt. The run uses `--safe-mode` (no hooks, plugins, or MCP servers) and
`--no-session-persistence` (nothing added to your session history), and is stopped
after 30 seconds if it hangs. This works however you use Claude Code: desktop app,
VS Code, or terminal.

`get_usage` is marked experimental by Anthropic. As a fallback, the app also registers
a small bridge as the status-line command in `~/.claude/settings.json`. When Claude
Code runs in a terminal, the bridge caches the 5-hour and 7-day percentages. If you
already had a status-line command, the bridge forwards its input to it. If the live
request fails, the app uses that cache: under 15 minutes old is fresh, up to 24 hours
old is stale and shows why live data failed. With no usable cache, the failure is
shown as an error rather than an empty "no data" state.

**Codex.** The app starts `codex app-server --stdio` and asks it for the account plan
and rate limits over JSON-RPC (`account/read`, `account/rateLimits/read`). Signing in
uses the CLI's device-code flow. One slow answer is tolerated; if the app-server misses
two in a row, it is stopped (force-killed if it ignores the request) and restarted on the
next poll. If it exits at startup, the app retries once with `--listen stdio://`.

**Finding the CLIs.** Install locations are re-scanned every time a CLI is started, so
an update that moves a binary is picked up without relaunching. The app checks, in
order: a path you set (see below), the ChatGPT app (current and pre-26.1007 layouts,
plus any copy Launch Services knows about), standalone and Homebrew installs, the CLI
bundled with the Claude desktop app, then the copies bundled with the VS Code, Cursor,
and Windsurf extensions, newest first. A
binary is used only if its code signature matches the publisher (Anthropic or OpenAI),
including one set by you.

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
- `claude-usage.json`: the latest Claude reading from the status-line bridge (fallback)
- `backups/`: previous app versions saved by `scripts/install.sh`

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

To install into `/Applications`:

```sh
scripts/install.sh
```

The script runs the unit tests, builds Release, and runs `--diagnose` on the new build
against your real setup. It stops without touching the installed app if either provider
can't be read; pass `--force` to install anyway, for example when only one provider is
installed. Otherwise it backs up the installed app to `~/.ai-usage/backups/` (keeping
the five newest), swaps in the new one, and relaunches it.

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

## Troubleshooting and recovery

**See what's wrong.** Run the diagnostics from the installed app:

```sh
"/Applications/AI Usage Monitor.app/Contents/MacOS/AI Usage Monitor" --diagnose
```

It lists every CLI location checked and whether its signature is trusted, which
binary is used, the sign-in state, the live Claude `get_usage` result, the status-line
cache, and the meters the app would show. It prints only paths, plan names,
percentages, and reset times, never tokens or account details. It exits 0 when both
providers return meters.

**Roll back to the previous version.**

```sh
scripts/rollback.sh          # restore the newest backup
scripts/rollback.sh --list   # list backups
scripts/rollback.sh "$HOME/.ai-usage/backups/AI Usage Monitor <timestamp>.app"
```

Backups work like a stack: each rollback restores the newest backup saved by
`install.sh` and removes it from the list, so running it again goes one install further
back. The version being replaced is kept as `AI Usage Monitor replaced <timestamp>.app`;
pass that path to `rollback.sh` to roll forward again.
Usage history and settings are compatible both ways. To roll back the code instead,
check out an earlier commit and run `scripts/install.sh`.

**Fix things without rebuilding.** These settings take effect after you relaunch the
app:

```sh
# A CLI moved somewhere the app doesn't look (the signature is still checked):
defaults write com.jeremytran.aiusagemonitor CodexExecutablePath "/path/to/codex"
defaults write com.jeremytran.aiusagemonitor ClaudeExecutablePath "/path/to/claude"

# Stop calling `claude -p` and use only the status-line cache:
defaults write com.jeremytran.aiusagemonitor ClaudeUsageSource statusLine

# Undo any of these:
defaults delete com.jeremytran.aiusagemonitor CodexExecutablePath
defaults delete com.jeremytran.aiusagemonitor ClaudeExecutablePath
defaults delete com.jeremytran.aiusagemonitor ClaudeUsageSource
```

## How it was built

I wrote the product spec, the design brief, the architecture rules, and the acceptance
criteria. The code was written by AI coding agents working from that
spec under review. The original brief and design spec are in [`docs/`](docs/). The
brief predates one major change: authentication was moved off direct token reads and
onto the providers' own CLIs.

## License

MIT. See [LICENSE](LICENSE).
