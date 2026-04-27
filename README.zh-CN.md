# CodeBar Pro

[English README](README.md)

CodeBar Pro 是一个原生 macOS 菜单栏应用，用来查看本机 AI 编程助手的使用情况。它提供紧凑的菜单栏状态、包含各 provider 用量的弹出面板，以及刷新频率和显示偏好的设置项。

## 功能

- 使用 AppKit 和 SwiftUI 构建的原生菜单栏体验。
- 从本地 JSONL 日志统计 Codex 和 Claude Code 活动。
- 展示今日和最近 30 天的 token 或事件总量。
- 检测本机 CLI 是否可用，并展示版本信息。
- 支持手动刷新和自动刷新间隔。
- 可以单独启用或禁用不同 provider。
- 以 accessory app 方式运行，不显示 Dock 图标。
- 用量分析保留在本机完成。

## 系统要求

- macOS 14.0 或更高版本。
- Xcode 16 或更高版本。
- 可选：如果需要 CLI 版本检测，请安装 `codex` 或 `claude` 命令行工具。
- 本机存在 `~/.codex` 或 `~/.claude/projects` 下的活动日志。

## 构建和运行

用 Xcode 打开项目：

```bash
open CodeBarPro.xcodeproj
```

选择 `CodeBarPro` scheme，然后在 `My Mac` 上运行。

也可以用命令行构建：

```bash
xcodebuild build \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

## 测试

```bash
xcodebuild test \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 30 \
  CODE_SIGNING_ALLOWED=NO
```

## 隐私

CodeBar Pro 只扫描本机用量日志，不上传使用数据。CLI 版本检测也只会在本机调用已安装的命令行工具。

## 项目结构

- `CodeBarPro/` - macOS 应用源码。
- `CodeBarProTests/` - 覆盖扫描、命令执行、缓存和偏好设置的单元测试。
- `CodeBarProUITests/` - UI 测试 target 脚手架。

## 说明

CodeBar Pro 面向本地开发工作流，让你无需打开终端或 dashboard，也能快速查看编程助手活动。
