# CodeBar Pro

![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift)
![Xcode](https://img.shields.io/badge/Xcode-16%2B-blue?logo=xcode)
![Privacy](https://img.shields.io/badge/privacy-local--first-brightgreen)

[中文说明](README.zh-CN.md)

CodeBar Pro is a polished native macOS menu bar app for keeping an eye on local AI coding assistant activity. It turns scattered local usage logs into a compact menu bar signal, a readable popover, and a small set of practical controls.

It is built for developers who want quick visibility without opening a terminal, digging through JSONL files, or switching into a dashboard.

## ✨ Highlights

- 🧭 **Menu bar first** - lives quietly in the macOS menu bar with no Dock icon.
- 📊 **Fast usage overview** - shows today and last-30-days activity for each provider.
- 📈 **Codex quota percentages** - surfaces 5-hour and weekly Codex usage percentages when rate limit data is available.
- 🔢 **Token-aware metrics** - prefers token counters when available and falls back to event counts.
- 🧩 **Multiple providers** - supports Codex and Claude Code activity sources.
- 🔍 **Local CLI detection** - checks installed command-line tools and shows version details.
- 🕒 **Flexible refresh** - choose manual refresh or automatic intervals.
- 🎛️ **Provider toggles** - enable or disable providers independently.
- 🛡️ **Local-first privacy** - scans local files only and does not upload usage data.
- ⚙️ **Native implementation** - AppKit status item, SwiftUI views, and no web wrapper.

## 🖥️ What You See

CodeBar Pro gives you three main surfaces:

| Surface | Purpose |
| --- | --- |
| Menu bar item | Shows the active provider name or current used amount. |
| Popover | Displays provider cards, status, quota percentages or usage totals, and refresh controls. |
| Settings window | Lets you configure providers, refresh cadence, and menu bar display behavior. |

## 📦 Requirements

- macOS 14.0 or later.
- Xcode 16 or later.
- Optional: `codex` and/or `claude` CLI installed for version detection.
- Local provider activity logs, when available:
  - `~/.codex`
  - `~/.claude/projects`

The app still opens when a CLI or log directory is missing. Missing providers are shown clearly in the UI instead of failing silently.

## 🚀 Run From Xcode

Open the project:

```bash
open CodeBarPro.xcodeproj
```

Then:

1. Select the `CodeBarPro` scheme.
2. Choose `My Mac` as the destination.
3. Press Run.

The app appears in the macOS menu bar as an accessory app.

## 🛠️ Build From Terminal

```bash
xcodebuild build \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

## ✅ Test

```bash
xcodebuild test \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 30 \
  CODE_SIGNING_ALLOWED=NO
```

Current test coverage focuses on:

- JSONL token scanning.
- Per-record date bucketing.
- Deduplication of nested log roots.
- Cache invalidation when files change.
- Command execution, timeout handling, large output draining, and non-zero exits.
- Preference persistence for refresh cadence and provider enablement.

## 🧠 How It Works

CodeBar Pro collects data through a small local pipeline:

1. Resolve provider CLIs from common shell paths and Node version manager paths.
2. Run version checks with bounded command timeouts.
3. Discover local JSONL activity logs.
4. Deduplicate discovered file paths.
5. Scan the most recent logs first.
6. Parse each JSONL record and bucket usage by record timestamp.
7. Extract Codex rate-limit percentages when present.
8. Publish provider snapshots back to the menu bar UI.

The scanner caps work to the most recent 1,500 JSONL files per provider to keep refreshes responsive.

## 🔐 Privacy Model

CodeBar Pro is designed around local inspection:

- It reads local usage logs from your Mac.
- It runs local CLI version checks.
- It does not send usage data to a server.
- It does not require an account, token, or network service.

If your local provider logs contain sensitive prompts or metadata, they remain on disk where those provider tools already stored them. CodeBar Pro only computes aggregate counts for display.

## ⚙️ Preferences

| Setting | Description |
| --- | --- |
| Providers | Turn Codex and Claude Code monitoring on or off independently. |
| Cadence | Pick manual, 1 minute, 2 minutes, 5 minutes, or 15 minutes. |
| Refresh Now | Immediately re-scan enabled providers. |
| Show used amount | Replace the menu bar provider label with the current usage value. |
| Open local folders | Jump directly to `.codex` or `.claude` in Finder. |

## 🧱 Project Structure

```text
CodeBarPro/
├── CodeBarPro.xcodeproj
├── CodeBarPro/
│   ├── AppPreferences.swift
│   ├── CodeBarProApp.swift
│   ├── MenuBarViews.swift
│   ├── ProviderProbe.swift
│   ├── SettingsView.swift
│   ├── StatusItemController.swift
│   ├── UsageModels.swift
│   └── UsageStore.swift
├── CodeBarProTests/
│   └── CodeBarProTests.swift
├── CodeBarProUITests/
└── README.zh-CN.md
```

## 🧰 Troubleshooting

### CLI Missing

Install the relevant command-line tool or make sure it is available from your shell `PATH`. CodeBar Pro checks common macOS shell paths and local Node version manager folders.

### No local JSONL activity logs found

Open the provider tool normally and run at least one session. CodeBar Pro can only summarize activity that exists in local logs.

### Usage looks lower than expected

Some logs may contain event records without token counters. In that case CodeBar Pro reports event totals instead of guessing token usage.

### Xcode opens but the app is not visible

CodeBar Pro is a menu bar utility. Look for the menu bar item near the right side of the macOS menu bar rather than in the Dock.

## 🗺️ Roadmap Ideas

- Optional screenshot assets for the README.
- Exportable usage summaries.
- More provider adapters.
- Custom log directory configuration.
- Signed release builds.

## 🤝 Contributing

Small, focused changes are easiest to review. Useful contributions include provider parsing improvements, test cases for new log formats, and UI refinements that preserve the lightweight menu bar workflow.
