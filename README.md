# CodeBar Pro

[中文说明](README.zh-CN.md)

CodeBar Pro is a native macOS menu bar app for tracking local AI coding assistant activity. It gives you a compact status item, a popover with provider usage, and settings for refresh cadence and display preferences.

## Features

- Native AppKit and SwiftUI menu bar experience.
- Tracks Codex and Claude Code activity from local JSONL logs.
- Shows today and last-30-days usage as token or event totals.
- Detects local CLI availability and version information.
- Supports manual refresh and automatic refresh intervals.
- Lets you enable or disable providers independently.
- Runs as an accessory app with no Dock icon.
- Keeps usage analysis local to your Mac.

## Requirements

- macOS 14.0 or later.
- Xcode 16 or later.
- Optional: `codex` and/or `claude` CLI installed if you want version detection.
- Local activity logs under `~/.codex` or `~/.claude/projects`.

## Build and Run

Open the project in Xcode:

```bash
open CodeBarPro.xcodeproj
```

Select the `CodeBarPro` scheme, then run it on `My Mac`.

You can also build from the command line:

```bash
xcodebuild build \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

## Test

```bash
xcodebuild test \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 30 \
  CODE_SIGNING_ALLOWED=NO
```

## Privacy

CodeBar Pro scans local usage logs on your machine and does not upload usage data. CLI version checks are executed locally through the installed command-line tools.

## Project Structure

- `CodeBarPro/` - macOS app source.
- `CodeBarProTests/` - unit tests for scanning, command execution, caching, and preferences.
- `CodeBarProUITests/` - UI test target scaffold.

## Notes

The app is designed for local development workflows where you want quick visibility into coding assistant activity without opening a terminal or dashboard.
