# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
# Build (no signing — works on any Mac)
xcodebuild build \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

# Full test suite (unit + UI). Bounded timeouts because some tests exercise PTY/subprocess paths.
xcodebuild test \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 30 \
  CODE_SIGNING_ALLOWED=NO

# Run a single test (Swift Testing identifiers use dot notation):
xcodebuild test \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  -only-testing:CodeBarProTests/CodeBarProTests/codexScannerCapturesLatestRateLimitPercentages \
  CODE_SIGNING_ALLOWED=NO
```

Targets: `CodeBarPro` (app), `CodeBarProTests` (unit, Swift Testing), `CodeBarProUITests` (UI, XCTest). macOS 14.0+, Swift 5, Xcode 16+. App is `LSUIElement=YES` (menu bar only, no Dock icon) — after `xcodebuild build`, the binary lives under `~/Library/Developer/Xcode/DerivedData/.../CodeBarPro.app`.

## Architecture

The app is a **single-process, local-first usage probe** with a deliberate three-layer split: SwiftUI views observe `UsageStore`, the store delegates I/O to a `ProviderProbing`, and probes never touch UI state.

### Entry point and lifecycle

`CodeBarProApp` (SwiftUI `@main`) declares only the **Settings** scene. The actual menu bar UI is built in `AppDelegate.applicationDidFinishLaunching` via `NSApp.setActivationPolicy(.accessory)` + a `StatusItemController` that owns an `NSStatusItem` and an `NSPopover` hosting the SwiftUI `MenuContentView`. `AppDelegate.configure(store:)` is called from `App.init` so the same `UsageStore` instance backs both the popover and the Settings window.

`AppDelegate` skips `store.startAutoRefresh()` when `ProcessInfo.isRunningTests` is true — important when adding test-time setup.

### UsageStore — the only `@MainActor` orchestrator

`UsageStore` (`UsageStore.swift`) is the single source of truth for snapshots and the only component that mutates UI-visible state. Two concurrency rules to preserve:

- **Refresh debouncing**: `refresh()` checks `isRefreshing`; concurrent calls set `needsRefreshAfterCurrent` and the in-flight call re-runs after it finishes. Don't bypass this — adding a parallel refresh path will cause snapshot flicker.
- **Auto-refresh is one self-rescheduling Task** keyed on `preferences.refreshCadence.interval`. Setting cadence to `.manual` returns `nil` and the loop exits cleanly. `restartAutoRefresh()` (called from `observePreferences`) cancels and replaces the task on cadence changes.

Per-provider work happens in a `withTaskGroup` so Codex and Claude scan in parallel.

### Probe pipeline

`ProviderProbing.snapshot(for:enabled:)` is the seam. `LocalProviderProbe.snapshot` runs four steps:

1. `CommandLocator.resolve(commandName)` — finds the CLI in env `PATH` + `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`, `~/.local/bin`, and every `~/.nvm/versions/node/*/bin` sorted newest-first. Adding a new provider means extending only `UsageProvider` and `LocalUsageScanner.logRoots`.
2. `CommandRunner.run(executable:arguments:timeout:)` — bounded subprocess with a `PipeCapture` that drains stdout/stderr **concurrently** to avoid pipe-buffer deadlocks. SIGTERM then SIGKILL on timeout.
3. **In parallel**: `ClaudeUsageProbe.fetchRateLimits` (Claude only) and `LocalUsageScanner.scan(provider:)` (JSONL).
4. `LocalProviderProbe.makeSnapshot` merges the two — **external rate-limits override local ones when present**, and the `notes` field surfaces failure reasons or scan caveats.

### LocalUsageScanner — the JSONL engine

Lives in `ProviderProbe.swift`. Roots are `~/.codex` and `~/.claude/projects`. Important behaviors:

- **1,500-file cap** (`maxScannedFiles`) sorted by mtime, newest first. Truncation count is reported in `summary.truncatedFileCount` and surfaced in the UI.
- **Symlink-resolved dedup** prevents nested roots from double-counting.
- **`SummaryCache`** keyed on `"<provider>:<resolved path>"` and invalidated by `(modifiedAt, byteCount)` — re-validates the file's stats *after* parsing to detect concurrent writes. Cache scope is per-provider because token extraction differs.
- **Streaming line parser**: 64 KB chunked read with manual `\n`/`\r` splitting (avoids slurping multi-MB JSONL files into memory).

**Token extraction is provider-aware**, and this is load-bearing:
- `codexTokenTotal` reads `payload.info.last_token_usage` only — the per-turn delta, not the running total. Summing `total_token_usage` across records would double-count.
- `claudeTokenTotal` reads `message.usage` only — Claude transcripts also include `toolUseResult.totalTokens` which is **not** session-billable.
- Generic fallback (`tokenTotal(in:)`) sums known token keys: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `cache_creation_tokens`, `cache_read_tokens`, `cached_input_tokens`, `reasoning_output_tokens`. Key matching normalizes by lowercasing and stripping underscores.

### Claude quota cascade (`ClaudeUsageProbe.swift`, ~1.6kloc)

Quota percentages come from one of three sources, tried in this order:

1. **OAuth** — `https://api.anthropic.com/api/oauth/usage` with the access token from Keychain (`Claude Code-credentials`) or `~/.claude/.credentials.json`. On HTTP 429, the `Retry-After` window is persisted to `UserDefaults["claudeOAuthUsageRetryAfterUntil"]` and OAuth is skipped until expiry.
2. **CLI `/usage`** (`ClaudePTYUsageRunner`) — launches `claude` through `openpty` with `--setting-sources project --strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-chrome`, waits for the prompt (`❯` / "welcome back"), sends `/usage\r`, then strips ANSI and parses percentages by label (`Current session`, `Current week`, `Current week (Sonnet/Opus)`) with a positional-fallback heuristic. The flag set is what makes the CLI launch deterministically inside a non-interactive PTY — don't change it casually.
3. **Web** — reads Chromium-family cookies (Chrome/Edge/Brave/Arc) via a sandboxed `sqlite3` query, decrypts AES-128-CBC `v10`/`v11` values using the per-browser Keychain Safe Storage password, and calls `claude.ai/api/organizations` + `/usage` + `/overage_spend_limit`. The `sessionKey` cookie must start with `sk-ant-`.

Fallback order is `appFallbackSourcesAfterOAuth = [.cli, .web]`. The supplemental metrics list (Sonnet/Opus weekly, Designs, Daily Routines, Extra usage) is keyed off both presence and source-key sentinels, so adding a new dimension means updating both `ClaudeOAuthUsageResponse.init(from:)` and `extraRateWindowMetrics`.

### Concurrency conventions

Everything outside `UsageStore` and `StatusItemController` is `nonisolated` and `Sendable`-conforming. The probe protocol is `Sendable`, value types use `nonisolated` accessors, and shared mutable state (`SummaryCache`, `PipeCapture`) uses `NSLock` + `@unchecked Sendable`. Don't introduce `@MainActor` outside the UI layer — it'll force the parallel scanning into a serial path.

### Tests

- **Unit tests use Swift Testing** (`@Test`, `#expect`, `#require`) — *not* XCTest. The `@testable import CodeBarPro` exposes internal types like `LocalUsageScanner`, `ClaudeUsageProbe`, `CommandRunner`, `AppPreferences`.
- UI tests under `CodeBarProUITests/` use XCTest and are largely placeholders.
- Tests covering the JSONL scanner write fixture files into a temp directory and set `modificationDate` explicitly so the time-window logic is reproducible — follow that pattern for new scanner tests.
- The `AppDelegate.isRunningTests` check (`environment["XCTestConfigurationFilePath"] != nil`) gates auto-refresh during test runs.

## Conventions

- **Commit subjects are short, imperative, no Conventional Commits prefix** (e.g., `Align Claude fallback behavior`, `Show app name in menu bar`).
- **No new files for transient docs** — README.md and README.zh-CN.md are kept in lockstep; if you change one, mirror the change in the other.
- **Privacy invariant**: probes only read local state and call provider-owned usage endpoints. Never upload or persist transcript content.
