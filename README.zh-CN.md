# CodeBar Pro

![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift)
![Xcode](https://img.shields.io/badge/Xcode-16%2B-blue?logo=xcode)
![Privacy](https://img.shields.io/badge/privacy-local--first-brightgreen)

[English README](README.md)

CodeBar Pro 是一个精致的原生 macOS 菜单栏应用，用来查看本机 AI 编程助手的活动情况。它把分散在本地日志里的使用数据整理成一个清晰的菜单栏状态、弹出面板和少量实用设置。

它适合希望快速了解使用情况的开发者：不用打开终端，不用手动翻 JSONL 文件，也不用切到 dashboard。

## ✨ 亮点

- 🧭 **菜单栏优先** - 安静地常驻 macOS 菜单栏，不显示 Dock 图标。
- 📊 **快速用量概览** - 展示每个 provider 的今日用量和最近 30 天用量。
- 📈 **Quota 百分比** - 可展示 Codex 5 小时/weekly 百分比，以及 Claude Code session、weekly、Sonnet/Opus、Designs、Daily Routines、Extra usage 等指标。
- 🔢 **优先展示 token** - 如果日志里存在 token 计数就展示 token，否则回退到事件数。
- 🧩 **多 provider 支持** - 支持 Codex 和 Claude Code 活动数据。
- 🔍 **本机 CLI 检测** - 检查命令行工具是否可用，并展示版本信息。
- 🕒 **灵活刷新** - 支持手动刷新和自动刷新间隔。
- 🎛️ **独立开关** - 每个 provider 都可以单独启用或禁用。
- 🛡️ **本地优先隐私** - 默认扫描本机文件，仅在支持 quota 百分比时访问 provider usage endpoint。
- ⚙️ **原生实现** - 使用 AppKit 状态栏、SwiftUI 界面，不是网页壳。

## 🖥️ 你会看到什么

CodeBar Pro 主要由三部分组成：

| 界面 | 用途 |
| --- | --- |
| 菜单栏项目 | 显示当前 provider 名称，或直接显示已使用量。 |
| 弹出面板 | 展示 provider 卡片、状态、quota 百分比或用量总数，以及刷新按钮。 |
| 设置窗口 | 配置 provider、刷新频率和菜单栏显示方式。 |

## 📦 系统要求

- macOS 14.0 或更高版本。
- Xcode 16 或更高版本。
- 可选：安装 `codex` 或 `claude` CLI，用于版本检测。
- 可选：存在 Claude Code OAuth 凭据、Chrome/Edge/Brave/Arc 中可读取的 `claude.ai` 浏览器会话，或可用的 `claude` CLI，用于 Claude Code quota 百分比和补充用量窗口。
- 本机存在可读取的 provider 活动日志：
  - `~/.codex`
  - `~/.claude/projects`

即使某个 CLI 或日志目录不存在，应用也能正常打开。缺失状态会在界面里明确展示，不会静默失败。

## 🚀 用 Xcode 运行

打开项目：

```bash
open CodeBarPro.xcodeproj
```

然后：

1. 选择 `CodeBarPro` scheme。
2. 目标设备选择 `My Mac`。
3. 点击 Run。

应用会以 accessory app 的形式出现在 macOS 菜单栏。

## 🛠️ 命令行构建

```bash
xcodebuild build \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

## ✅ 测试

```bash
xcodebuild test \
  -project CodeBarPro.xcodeproj \
  -scheme CodeBarPro \
  -destination 'platform=macOS' \
  -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 30 \
  CODE_SIGNING_ALLOWED=NO
```

当前测试重点覆盖：

- JSONL token 扫描。
- 按每条记录的时间戳进行日期分桶。
- 嵌套日志目录去重。
- 文件变化后的缓存失效。
- 命令执行、超时处理、大输出读取、非零退出。
- 刷新频率和 provider 启用状态的偏好保存。
- Claude Code quota 的 OAuth、浏览器会话和 CLI 兜底解析路径，包括模型专属和补充用量窗口。

## 🧠 工作方式

CodeBar Pro 的本地数据流程很小：

1. 从常见 shell 路径和 Node 版本管理器路径里查找 provider CLI。
2. 用有超时保护的命令执行版本检测。
3. 查找本地 JSONL 活动日志。
4. 对发现的文件路径去重。
5. 优先扫描最近的日志。
6. 解析每条 JSONL 记录，并按记录时间戳统计用量。
7. 如果存在 Codex rate limit 数据，则提取使用百分比。
8. 如果存在 Claude Code OAuth 凭据，则获取 Claude Code usage 百分比。
9. 如果来源提供对应数据，则映射 Claude session、weekly、Sonnet/Opus、Designs、Daily Routines 和 Extra usage。
10. 如果 Claude OAuth 被 rate limit 或不可用，则使用本机 `claude.ai` 浏览器会话查询 Claude Web usage 和 Extra usage spend。
11. 如果浏览器会话路径不可用，则尝试 Claude CLI `/usage` 兜底，解析 session、weekly 和模型专属百分比。
12. 把 provider 快照发布回菜单栏界面。

为了保持刷新流畅，扫描器会限制每个 provider 最多处理最近 1,500 个 JSONL 文件。

## 🔐 隐私模型

CodeBar Pro 围绕本地检查设计：

- 读取你 Mac 上已有的本地用量日志。
- 在本机执行 CLI 版本检测。
- 为了展示 Claude Code quota 百分比，可能读取 Keychain 或 `~/.claude/.credentials.json` 中的 Claude Code OAuth 凭据，并调用 Anthropic usage endpoint。
- 如果 Claude OAuth endpoint 临时 rate limit 或不可用，可能从 Chrome、Edge、Brave 或 Arc 读取本机 `claude.ai` 浏览器会话 cookie，并调用 Claude Web usage 和 overage endpoint。
- 如果浏览器会话 usage 不可用，可能在一个短生命周期 PTY 会话中运行本地 `claude` CLI 并解析 `/usage`。
- 不上传本地 JSONL 日志、prompt 或 transcript 内容。
- 如果所有 Claude quota 来源都失败，会自动回退到本地 token 总数。

如果本地 provider 日志里包含敏感 prompt 或元数据，它们仍保留在原本的磁盘位置。CodeBar Pro 只计算聚合后的数量并用于展示。

## ⚙️ 偏好设置

| 设置 | 说明 |
| --- | --- |
| Providers | 单独开启或关闭 Codex 和 Claude Code 监控。 |
| Cadence | 选择手动、1 分钟、2 分钟、5 分钟或 15 分钟刷新。 |
| Refresh Now | 立即重新扫描已启用的 provider。 |
| Show used amount | 在菜单栏中显示当前用量，而不是 provider 名称。 |
| Open local folders | 在 Finder 中直接打开 `.codex` 或 `.claude`。 |

## 🧱 项目结构

```text
CodeBarPro/
├── CodeBarPro.xcodeproj
├── CodeBarPro/
│   ├── AppPreferences.swift
│   ├── ClaudeUsageProbe.swift
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
└── README.md
```

## 🧰 常见问题

### CLI Missing

安装对应命令行工具，或确认它在 shell `PATH` 中可用。CodeBar Pro 会检查常见 macOS shell 路径和本地 Node 版本管理器目录。

### No local JSONL activity logs found

正常打开 provider 工具并至少运行一次会话。CodeBar Pro 只能汇总已经存在于本机日志里的活动。

### 用量看起来比预期少

部分日志可能只有事件记录，没有 token 计数。这种情况下 CodeBar Pro 会展示事件数，而不是猜测 token 用量。

### Claude quota 百分比不可用

Claude Code quota 百分比需要至少一种可用来源：可读取的 Claude Code OAuth 凭据、Chrome/Edge/Brave/Arc 中可读取的 `claude.ai` 浏览器会话，或可用的本地 `claude` CLI `/usage` 面板。OAuth 和 Web 来源可以提供 Sonnet/Opus、Designs、Daily Routines、Extra usage 等补充窗口；CLI 兜底只能展示 `/usage` 面板实际打印出来的内容。如果 OAuth endpoint 返回 HTTP 429，CodeBar Pro 会记录 `Retry-After` 窗口，在退避期内跳过重复 OAuth 请求，接着通过浏览器会话尝试 Claude Web usage，再尝试 CLI 兜底，最后才展示本地 token 总数。

### Xcode 运行后没看到应用窗口

CodeBar Pro 是菜单栏工具。请查看 macOS 菜单栏右侧，而不是 Dock。

## 🗺️ 后续方向

- 为 README 添加真实截图。
- 支持导出用量摘要。
- 增加更多 provider adapter。
- 支持自定义日志目录。
- 提供签名后的发布构建。

## 🤝 参与改进

更推荐小而聚焦的改动。适合贡献的方向包括：provider 解析逻辑、更多日志格式测试用例、以及保持轻量菜单栏体验的 UI 改进。
