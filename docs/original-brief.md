> **Historical document.** This is the original build brief handed to the coding agent in July 2026.
> The shipped app diverged in one important way: it no longer reads Keychain items or `~/.codex/auth.json`
> and never refreshes tokens. Commit `d63225c` moved authentication to the providers' own CLIs
> (`claude auth`, `codex app-server`). See the [README](../README.md) for current behavior.
> Design files referenced below now live in [`docs/design/`](design/).

# AI Usage Monitor — Codex Handoff Brief

## What to Build
A **macOS-only native SwiftUI menu-bar app** that shows Claude Max and OpenAI Codex usage at a glance. No iOS. No server. No account switching. Pure visibility.

## Design Spec
The full visual spec is in `design/design-spec.html` (exported from Claude Design). Its companion files (`design/support.js`, `design/ios-frame.jsx`) must be co-located for it to render in a browser. Read the HTML top-to-bottom — it's the source of truth for every pixel. The relevant screens for macOS-only:

- **1a** — Menu bar status item (three states: normal, amber ≥70%, red ≥90%) + right-click context menu
- **1b** — Popover with all meters, sparklines, collapsible history chart
- **1c** — Popover with 7-day history expanded (multi-line per-model chart)
- **1d** — Meter detail drilldown (large %, burn rate, projection line, 24h/3d/7d range selector)

**Ignore screens 1e–1j** — those are iOS widgets and companion app. macOS only.

## Scope
- Native SwiftUI menu-bar app (no Electron, no web views)
- NSStatusItem with gauge icon + hottest meter %
- NSPopover for the main view
- Local data storage (JSONL history in `~/.ai-usage/`)
- launchd plist for Launch at Login
- No server, no dashboard, no network-facing anything

## Data Sources — Two API Calls

### 1. Anthropic Claude Max (OAuth usage)
```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
```

**Where the token lives (macOS):**
- Keychain: `security find-generic-password -s "Claude Code-credentials" -a "$USER" -w`
- Returns JSON: `{"claudeAiOauth":{"accessToken":"***","refreshToken":"***","expiresAt":<ms>,...},...}`
- Use `claudeAiOauth.accessToken` for the Bearer token

**Response shape:**
- `five_hour`: `{utilization: 0-100, resets_at: "ISO-8601"}` — rolling 5h session window
- `seven_day`: `{utilization: 0-100, resets_at: "ISO-8601"}` — weekly all-models
- `limits[]`: array of model-scoped weekly meters, each with:
  - `scope.model.display_name` (e.g., "Fable", "Sonnet", "Haiku")
  - `utilization: 0-100`
  - `resets_at: "ISO-8601"`

**This yields 5 meters:** Session 5h, Week All Models, Week Fable, Week Sonnet, Week Haiku

### 2. OpenAI Codex (ChatGPT plan usage)
```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access_token>
chatgpt-account-id: <account_id>
```

**Where the token lives:**
- File: `~/.codex/auth.json`
- Shape: `{"tokens":{"access_token":"***","refresh_token":"***","account_id":"***"},...}`

**Response shape:**
- `rate_limit.primary_window`: `{used_percent: 0-100, reset_at: <unix>, limit_window_seconds}`
- `rate_limit.secondary_window`: same shape (weekly)
- `plan_type`: `"plus"` | `"prolite"` (Pro 5x) | `"pro"` (Pro 20x) | `"business"`

**This yields 2 meters:** Session 5h, Weekly

**Token refresh for Codex** (access tokens expire):
```
POST https://auth.openai.com/oauth/token
{
  "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
  "grant_type": "refresh_token",
  "refresh_token": "<refresh_token>",
  "scope": "openid profile email"
}
```
Write rotated tokens back to `~/.codex/auth.json` atomically (temp file + rename, preserve all other keys).

**Plan type display names:** `plus` → Plus, `prolite` → Pro 5x, `pro` → Pro 20x, `business` → Business

## Architecture

```
AIUsageMonitor/
├── AIUsageMonitorApp.swift      # @main, MenuBarExtra
├── Models/
│   ├── UsageData.swift           # Data models for all 7 meters
│   └── MeterKind.swift           # Enum: session5h, weekAll, weekFable, weekSonnet, weekHaiku, codexSession, codexWeekly
├── Services/
│   ├── AnthropicPoller.swift     # Reads Keychain, polls usage, handles token refresh
│   ├── CodexPoller.swift         # Reads auth.json, polls usage, refreshes tokens
│   ├── UsageStore.swift          # JSONL history read/write in ~/.ai-usage/
│   └── AlertEngine.swift         # Threshold checks, burn rate calculation, projection
├── Views/
│   ├── StatusItemView.swift      # Gauge icon + % (three color states)
│   ├── PopoverView.swift         # Main view with all meters + collapsible history
│   ├── MeterRow.swift            # Single meter: label, bar, %, sparkline
│   ├── HistoryChart.swift        # 7-day multi-line chart (Charts framework)
│   ├── MeterDetailView.swift     # Drilldown: big %, burn rate, projection, range selector
│   └── SettingsView.swift        # Polling interval, alert threshold, launch at login
└── Resources/
    └── Assets.xcassets           # App icon
```

## Design Tokens
```swift
// Colors
static let bg       = Color(hex: "#262624")  // warm charcoal
static let card     = Color(hex: "#30302E")  // card surface
static let card2    = Color(hex: "#1F1E1D")  // inset surface
static let text     = Color(hex: "#ECECEA")  // primary text
static let muted    = Color(hex: "#8A867F")  // secondary text
static let accent   = Color(hex: "#D97757")  // Anthropic terracotta
static let openai   = Color(hex: "#10A37F")  // OpenAI green
static let warn     = Color(hex: "#E3B341")  // amber ≥70%
static let danger   = Color(hex: "#E5484D")  // red ≥90%
static let border   = Color(hex: "#3E3E3A")  // hairline borders

// Bar color logic
func barColor(for utilization: Double) -> Color {
    if utilization >= 90 { return .danger }
    if utilization >= 70 { return .warn }
    return isCodex ? .openai : .accent
}

// Typography: SF Pro (system default), SF Mono for numbers
// Font sizes from the design: 10-12px for meters, 28-54px for hero numbers
```

## Menu Bar States (from design 1a)
1. **Normal (all < 70%):** Monochrome gauge icon + hottest meter %. White text.
2. **Warning (any ≥ 70%):** Same icon, % text turns amber. Gauge needle angle tracks value.
3. **Critical (any ≥ 90%):** Tinted red capsule background behind icon + %. Icon and text turn red.

**Left-click** → popover. **Right-click** → context menu (Refresh Now ⌘R, Open AI Usage…, Pause Alerts 1hr, Launch at Login ✓, Quit ⌘Q).

## Popover Behavior (from designs 1b–1d)
- 320px wide, dark translucent background with vibrancy
- Header: gauge icon + "AI Usage" + refresh button + settings gear
- **Claude Max section:** terracotta dot, 5 meter rows (Session, All Models, Fable, Sonnet, Haiku)
  - Per-model rows indented/muted (subordinate hierarchy)
  - Each row: label + reset time | usage bar | % | mini sparkline (44×14px)
- **OpenAI Codex section:** green dot + plan badge, 2 meter rows
- **Collapsible "7-Day History"** section at bottom with multi-line chart
  - Lines: All Models (white), Fable (terracotta), Sonnet (gold), Haiku (steel blue)
  - Vertical dashed lines at weekly reset boundaries
- **Click any meter row** → pushes to MeterDetailView

## Meter Detail View (from design 1d)
- Back button → popover
- Model name as title, large hero % (54pt mono, colored by threshold)
- "Resets [day time]" + "in Xh · burning X%/h"
- **Projection alert** if on pace to hit 100% before reset: red banner with ETA
- **Range selector:** 24h / 3d / 7d segmented control
- **Trend chart:** area fill + line, dashed projection to 100%, red dot at projected exhaustion point
- **Stats row:** Used %, Burn rate, Resets in, Share of week

## Derived Calculations
- **Burn rate:** Δ utilization / Δ time from last N snapshots (smooth over ~30min window)
- **Projection:** current % + (burn_rate × time_to_reset). If projected > 100%, show alert with ETA.
- **Share of week:** Per-model utilization as proportion of all-models utilization (Fable 58% / Sonnet 31% / Haiku 11% in the mock). Compute from `model_util / sum(all_model_utils)`.
- **Sparklines:** Last 24h of snapshots for session meters, last 7d for weekly meters. Downsample to ~44 points.

## Polling & Storage
- Default: poll every 3 minutes (configurable 1–10 min in settings)
- Store snapshots as JSONL in `~/.ai-usage/history.jsonl`
- Each line: `{"t":"ISO-8601","source":"anthropic|codex","meters":{...}}`
- On failed poll: log error row `{"t":"...","source":"...","error":"..."}`, serve last-known-good to UI
- Retain 30 days by default (configurable), prune on launch
- File permissions: directory 0700, files 0600

## Security
- Never log or display raw tokens
- Keychain access via Security framework (not shelling out to `security` CLI)
- `~/.ai-usage/` directory: 0700
- No network listeners — this app only makes outbound GET requests
- Tokens read from their canonical locations; never copied or cached separately

## What NOT to Build
- ❌ No iOS anything (no WidgetKit, no companion app)
- ❌ No account switching or credential rotation
- ❌ No server, dashboard, or web UI
- ❌ No Cloudflare tunnel
- ❌ No notifications/ntfy (use the menu bar visual states instead)
- ❌ No WebAuthn/auth — it's a local app reading local files

## Build Requirements
- macOS 14+ (Sonoma) — for MenuBarExtra and Charts framework
- Swift 5.9+
- Xcode 15+
- Sign with local development certificate (no App Store, no notarization needed for personal use)

## Definition of Done
- [ ] App appears in menu bar with gauge icon + hottest meter %
- [ ] Three visual states work (normal, amber, red)
- [ ] Left-click opens popover with all 7 meters
- [ ] Right-click opens context menu
- [ ] Sparklines render from real history data
- [ ] 7-day collapsible history chart works with per-model lines
- [ ] Click any meter → detail view with burn rate + projection
- [ ] Polling runs on configured interval
- [ ] JSONL history accumulates in ~/.ai-usage/
- [ ] Launch at Login works via launchd or SMAppService
- [ ] Settings: polling interval, alert threshold, history retention
- [ ] No tokens in logs or UI
