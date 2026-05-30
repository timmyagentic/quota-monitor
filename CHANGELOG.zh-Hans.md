# 更新日志（简体中文）

QuotaMonitor（前身为 CodexMonitor）的所有重要变更都记录在此。这是
`CHANGELOG.md` 的中文平行文件：两者的版本小节一一对应，发布脚本
（`tools/release-sparkle.sh`）会分别提取同一版本的中、英文小节，生成
appcast 中按系统语言切换的双语更新说明。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **撰写约定**：本文件中每条 `- ` 列表项必须写在**同一行**（不要硬换行）。
> 发布脚本在拼接续行时会插入空格，对中文会造成字符之间出现多余空格。

## [Unreleased]

## [0.2.26] — 2026-05-30

#### Summary
- 仪表盘新增使用画像：累计 Tokens、单日峰值、连续活跃天数、GitHub 风格热力图
- 更新通知全新改版：动画发布说明 + 深色模式支持

### 新增
- **仪表盘「使用画像」一节。** 四格统计条（累计 Tokens、单日峰值、当前连续、最长连续）+ GitHub 风格的 Token 活跃度热力图。所有数字跟随当前 Provider 过滤，完全由本地历史推导，不额外采集数据、不改数据库结构。
- **自定义 Sparkle 更新界面。** 替换系统默认更新弹窗，使用 SwiftUI 窗口 + `WKWebView` 展示带动画的发布说明，支持深色模式和 `prefers-reduced-motion` 无障碍。发布说明现在以 HTML 编写，支持图片、CSS 动画等富媒体内容。
- **HTML 发布说明流水线。** `tools/release-sparkle.sh` 现在优先从 `ReleaseNotes/<version>.{en,zh-Hans}.html` 读取 HTML 内容，给予更新弹窗完整的视觉控制权。无 HTML 文件时回退到 `changelog-to-html.py` 转换。

## [0.2.25] — 2026-05-23

### 新增
- **Codex 桌面应用安装现在无需在 PATH 中单独提供 CLI 即可工作。** QuotaMonitor 仍优先使用显式的 `CODEX_BINARY` 覆盖项以及用户登录 shell 中的 `codex`，但现在会回退到第一方 `Codex.app` 内置的二进制文件 `/Applications/Codex.app/Contents/Resources/codex`（以及对应的 `~/Applications` 路径）。这让仅安装了 Codex 桌面应用的用户也能更新实时 Codex 配额行。
- **自动发现 Claude Desktop 内置的 Claude Code 构建。** 当没有独立的 `claude` 二进制可用时，刷新触发器现在会探测 `~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude` 并选择最新的可执行 bundle。这覆盖了已下载原生 Claude Code 助手的 Claude Desktop 安装，同时不触碰纯 Claude Desktop 的 Web 会话 token 缓存。
- **解析器测试现在覆盖仅安装应用的场景。** 新增测试固定了 Codex 二进制解析、Claude 二进制解析、Claude Desktop bundle 发现，以及非交互式 Claude Keychain 查询的构造。

### 变更
- **菜单栏弹窗现在仅在扫描进行时显示扫描状态。** 一直可见的“上次扫描 / 文件 / 变更 / 事件”摘要再次被隐藏，让紧凑菜单聚焦于配额状态与主要操作。手动刷新时仍会显示实时扫描进度条。
- **Claude Keychain 回退明确为非交互式。** 设置文案现在说明：仅当 macOS 允许静默读取一个已授权的 `Claude Code-credentials` 项时才使用 Keychain。QuotaMonitor 不再把这条路径描述为可能从后台轮询弹出系统提示。

### 修复
- **实时配额进度条可从损坏的包管理器 shim 中恢复。** 二进制解析器现在会在硬编码的 Homebrew 位置之前优先使用用户登录 shell 的路径，因此一个过期的可执行 shim 不再阻塞本可正常工作的 nvm/asdf/bun 安装。
- **Claude 实时配额轮询不再卡死在 Security.framework 内部。** 生产环境的 Keychain 读取现在通过 `/usr/bin/security` 以较短超时执行，并可解码 JSON 凭据封装或旧式裸 token。如果该项需要交互，QuotaMonitor 会将凭据来源记录为不可用，而不是让轮询一直挂起。
- **菜单栏窗口高度固定为内容高度。** `MenuBarExtra(.window)` 现在采用内容尺寸的窗口可调整性，加上固定的垂直内容尺寸，避免在隐藏 provider 区块后 macOS 可能保留的空白条带。
- **在仅装有命令行工具（CLT）的机器上本地构建更可靠。** `build.sh` 在可用时会 source Swiftly，并向 SwiftPM 传入 `--disable-keychain`，使公共依赖解析不会卡在 macOS Keychain 访问上。

### 已知限制
- **不直接读取纯 Claude Desktop 的认证。** Claude Desktop 把自己的 `oauth:tokenCache` 存储在 `~/Library/Application Support/Claude/config.json` 下的 Electron safeStorage 中。QuotaMonitor 不会解密或复用该缓存；实时 Claude 配额仍需来自 `~/.claude/.credentials.json`、`Claude Code-credentials` 或上文所述内置 Claude Code 助手的 Claude Code OAuth 凭据。
