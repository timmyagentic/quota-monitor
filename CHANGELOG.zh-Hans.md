# 更新日志（简体中文）

QuotaMonitor（前身为 CodexMonitor）的所有重要变更都记录在此。这是
`CHANGELOG.md` 的中文平行文件：两者的版本小节一一对应，发布脚本
（`tools/release-sparkle.sh`）会分别提取同一版本的中、英文小节，生成
appcast 中按系统语言切换的双语更新说明。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## 发布说明规范

每个合入的 PR 都应在合入前或随合入一起更新 `## [Unreleased]`。这些内容会成为 GitHub Release notes，也会进入 Sparkle 更新窗口。

- 每个发布小节必须先写 `#### Summary`：1-4 条普通、用户能直接看懂的短 bullet。更新窗口会默认展示这些内容。
- 详情放在 `### 新增`、`### 变更`、`### 修复`、`### 移除` 或 `### 已知限制` 下。
- 每条详情 bullet 以短加粗标题开头，然后用一句话说明变化和影响：`- **短标题。** 说明变化以及为什么重要。`
- 实现细节、提交考古和内部测试证据优先放在 PR body 或 docs 中；只有直接解释用户影响时才进入 changelog。
- 非 appcast PR 会由 PR CI 强制检查这条规则；自动生成的 appcast PR 只负责发布 release PR 中已经写好的说明，因此豁免。
- 发版前运行 `python3 tools/validate-release-notes.py X.Y.Z` 校验格式。

> **撰写约定**：本文件中每条 `- ` 列表项必须写在**同一行**（不要硬换行）。
> 发布脚本在拼接续行时会插入空格，对中文会造成字符之间出现多余空格。

## [Unreleased]

#### Summary
- 发布和 PR 检查更严格，同时默认本地 QA 路径保持静态
- 测试链路现在明确拆分静态检查、Computer Use 准备、可见 UI 走查和 artifact 复核
- 交互式 QA 清理不再误关用户已安装的 QuotaMonitor
- App 窗口现在通过统一的 AppKit 窗口管理器负责打开、聚焦和回到纯菜单栏模式

### 变更
- **AppKit 窗口所有权。** Dashboard、Settings、onboarding 和菜单栏恢复指南现在共用一个 AppKit 窗口管理器，使窗口打开和聚焦行为更一致。
- **静态 QA 默认入口。** `qa/run-all.sh` 现在转发到 `qa/run-static.sh`，不再启动新的 QuotaMonitor 实例。
- **Computer Use 负责可见 app 验证。** 标准可见 QA 路径是 `qa/prepare-computer-use-fixture.sh` 或 `qa/prepare-computer-use-real-data.sh`，然后使用 Computer Use。
- **真实数据 QA 保留可见偏好。** `qa/prepare-computer-use-real-data.sh` 现在会把当前 QuotaMonitor UserDefaults 复制到隔离 QA suite，同时继续覆盖凭据敏感设置。
- **测试链路文档。** `docs/local-qa.md`、`docs/computer-qa.md` 和项目 QA skill 现在用同一套职责描述：静态门禁、Computer Use 准备、Computer Use 走查和 artifact 复核。

### 新增
- **隔离的本地 QA harness。** 本地 QA 现在会用隔离 profile、fixture 数据、重定向后的 Codex/Claude home 启动 QuotaMonitor，并产出 app 状态、数据库计数、日志、截图和辅助功能快照等可机器检查的 artifacts。
- **Computer Use QA 工作流。** 交互式 fixture 和真实数据影子运行现在会生成包含精确 QA app 路径的 run brief，让 Dashboard、History、Sessions、Settings 和帮助窗口的可见检查可以复跑，并避免误操作已安装 app。
- **PR 更新日志强制检查。** 非 appcast PR 的 CI 现在要求同时更新英文和简体中文 changelog，并校验会展示在更新窗口中的小节。

### 修复
- **菜单栏读数跟随设置。** 当已选择的工具暂时没有 live 配额样本时，菜单栏现在会继续显示配置的文字读数，并用短横占位或 Dashboard 配额快照回填，而不是退回表盘图标。
- **Codex 弹窗配额回填。** 当 live CLI 配额获取不可用时，Codex 菜单栏卡片现在会使用 Dashboard 配额快照，避免真实数据 QA 中出现误导性的登录提示。
- **升级后的设置窗口布局。** 由 AppKit 承载的 Settings 现在会复用旧 Settings 窗口的 frame key，同时保持与原本分组式设置页面一致的 pane 宽度。
- **更新窗口关闭后的 Dock 清理。** Sparkle 更新窗口关闭后，如果没有其他 app 窗口打开，QuotaMonitor 现在会回到纯菜单栏模式。
- **QA 清理后恢复已安装 app。** QA 清理现在会记录 `/Applications/QuotaMonitor.app` 运行前状态，只关闭 QA 启动的进程，并在需要时恢复已安装 app。

### 移除
- **旧的 app E2E 入口。** `qa/run-local.sh` 已移除，因此 QA 架构不再在 Computer Use 之外保留单独的可见 app 测试层。

## [0.2.30] — 2026-06-01

#### Summary
- Dashboard 和 Settings 现在可以通过右上角工具栏按钮互相跳转
- 纯图标导航按钮现在会更快显示悬浮提示，让用户不用等待太久就能理解图标含义

### 新增
- **Dashboard 和 Settings 互相跳转入口。** Dashboard 右上角现在提供 Settings 快捷入口，Settings 右上角也提供 Dashboard 快捷入口，用户无需回到菜单栏即可在两个窗口之间切换。
- **新导航图标的快速悬浮提示。** 这些工具栏快捷入口使用比系统默认 tooltip 更短的悬浮延迟，让纯图标操作更容易被理解。

## [0.2.29] — 2026-05-31

#### Summary
- 更新窗口现在会显示内嵌 HTML 更新日志，不再是空白面板

### 修复
- **自定义 Sparkle 更新窗口现在能正常加载发布说明 HTML。** 当前 macOS 的 WebKit 会把 `loadHTMLString(..., baseURL: nil)` 识别为一次初始 `about:blank` 导航，因此更新器现在允许这次初始文档加载，同时继续阻止外部导航。

## [0.2.28] — 2026-05-31

### 新增
- **为新出现的 Claude 和 GLM 模型补充内置价格种子。** QuotaMonitor 现在内置 `claude-opus-4-8`、`claude-sonnet-4-5-20250929`、`glm-4.7`、`glm-5.1` 的价格目录行，因此这些 model ID 的历史使用记录在首次启动时即可计价，不会继续显示为 `$0`。

### 修复
- **Sparkle 更新签名现在与实际发布的 DMG 字节一致。** 发布 workflow 会对 GitHub Actions 构建并发布的 DMG 直接签名，然后自动打开 appcast PR，避免之前“本地签名的 DMG 与 Sparkle 下载的文件不同”导致更新被判定为签名错误的问题。
- **修复已有 0.2.26 和 0.2.27 appcast 条目。** 这些条目的签名和长度已基于 CI 构建出的 release 资产重新生成，Sparkle 可以正确校验这些更新。

## [0.2.27] — 2026-05-31

### 修复
- **Sparkle 现在会在中文 macOS 上选择中文更新说明。** 在 Info.plist 中添加了 `CFBundleLocalizations`（en + zh-Hans），使 Sparkle 的 appcast 解析器知道应用支持简体中文，从而正确选择 `<description xml:lang="zh-Hans">`。

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
