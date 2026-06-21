# 更新日志（简体中文）

QuotaMonitor（前身为 CodexMonitor）的所有重要变更都记录在此。这是
`CHANGELOG.md` 的中文平行文件：两者的版本小节一一对应，发布脚本
（`tools/release-sparkle.sh`）会分别提取同一版本的中、英文小节，生成
appcast 中按系统语言切换的双语更新说明。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## 发布说明规范

每个合入的 PR 都应在合入前或随合入一起更新 `## [Unreleased]`。这些内容会成为 GitHub Release notes，也会进入 Sparkle 更新窗口。

- 每个发布小节必须先写 `#### Summary`：普通、用户能直接看懂的短 bullet。自动生成的 Sparkle 更新窗口会把这些摘要渲染成视觉卡片。这里要按普通用户视角写，只说更新后用起来哪里更好，不写实现、测试、CI、PR 或发版链路细节。
- 详情放在 `### 新增`、`### 变更`、`### 修复`、`### 移除` 或 `### 已知限制` 下。这些内容仍会进入 GitHub Release notes。
- 每条详情 bullet 以短加粗标题开头，然后用一句话说明变化和影响：`- **短标题。** 说明变化以及为什么重要。`
- 实现细节、提交考古和内部测试证据优先放在 PR body 或 docs 中；只有直接解释用户影响时才进入 changelog。
- 非 appcast PR 会由 PR CI 强制检查这条规则；自动生成的 appcast PR 只负责发布 release PR 中已经写好的说明，因此豁免。
- 发版前运行 `python3 tools/validate-release-notes.py X.Y.Z` 校验格式。

> **撰写约定**：本文件中每条 `- ` 列表项必须写在**同一行**（不要硬换行）。
> 发布脚本在拼接续行时会插入空格，对中文会造成字符之间出现多余空格。

## [Unreleased]

### 修复
- **更新后不会再让只保存过语言的老用户重复进入 Landing Page。** 已保存语言选择的现有安装，即使旧版本从未写入 Provider 引导标记，现在也会跳过 Landing Page。

## [0.2.34] — 2026-06-21

#### Summary
- Codex 现在会在菜单栏显示可用主动重置卡数量和过期时间
- Claude 实时配额卡片现在等待刷新时会保留上次数值
- 更新修复现在会保留已有设置，不会覆盖已配置的 Provider 和菜单栏偏好
- Claude 凭据磁盘缓存现在会在未设置时默认开启，减少本地重建后反复出现的钥匙串提示
- 历史和会话页面现在优先显示真实会话标题，没有标题时再回退显示项目名

### 新增
- **Codex 主动重置卡可见性。** 菜单栏现在会显示 Codex 当前还有几张主动重置卡可用，以及可用卡片的过期时间。
- **Mac App Store 准备预检。** 项目现在有一条文档化的本地预检路径，用来先评估 App Store 友好的构建形态，而不需要改动账号或发布凭据。

### 变更
- **Claude 凭据磁盘缓存会在未设置时默认开启。** 全新安装和已有用户如果尚未保存过该偏好，现在都会默认开启并持久化 Claude 凭据磁盘缓存，减少本地重建后反复出现的 macOS 钥匙串提示；用户手动关闭后，会在后续更新中保留这个显式选择。

### 修复
- **更新修复会保留设置。** 已配置过 Provider 或菜单栏偏好的现有安装，在应用修复旧版引导状态时会继续保留这些选择。
- **Claude 实时配额刷新更清楚。** 当 Claude 暂时延迟实时配额刷新时，菜单栏会继续显示上次成功获取的配额，并标明下次重试时间。
- **会话行标题更清晰。** 历史、会话和会话详情页面现在会把项目文件夹名作为次要信息展示，优先使用真实会话标题；如果没有标题，则显示项目名而不是“未命名会话”。

## [0.2.33] — 2026-06-15

#### Summary
- 新下载可以正常打开，已安装用户也能继续在应用内更新
- 开发者诊断现在使用更清晰的结构化等级，排查问题时更容易先看错误
- 日志查看文档现在使用正确的 macOS 错误过滤条件
- 应用图标现在放在深色 Dock 和 Finder 背景上也不会露出白色方底
- 今天的用量和花费现在会立即显示在仪表盘里，不再要等到第二天
- 长期使用也能保持流畅——用量记录不再越积越多、拖慢应用
- 临近午夜的用量在夏令时切换前后也会归到正确的本地日期和月份

### 新增
- **架构审查待办清单。** 新增 `docs/architecture-review-2026-06-14.md`，系统梳理已知的正确性、性能、并发与可维护性问题，便于后续逐项处理与修复。

### 变更
- **可信发布链路。** 公开版本现在使用 Apple Developer ID 分发，同时保持原有 Sparkle 更新身份不变，因此已安装副本仍可继续使用应用内更新。
- **结构化开发者日志。** 开发者诊断现在会把 info、warning 和 error 事件同步写入 macOS unified logging，并保留稳定的事件名、Provider、结果、触发来源和 reason 字段；开启 Developer Mode 后，本地 JSONL 文件仍保留同样的结构化记录，便于本机排查。

### 修复
- **Unified log 错误查询。** README 现在使用 `logType == "error"` 过滤 macOS unified logging，不再使用 `log show --level error` 这个不支持的参数。
- **应用图标透明度。** 已提交的应用图标现在保留透明圆角，在深色背景上不会再显示白色方块。
- **今天的用量立即计入。** 仪表盘的用量构成、燃尽预测，以及用量和限额图表现在都会包含今天稍早的记录，不再要等到第二天才显示。
- **月度统计计入你所在时区的当月第一天。** 月度用量图表不再漏掉那些 UTC 时刻落在上个月的月初记录，因此在 UTC 以东时区里，最早一个月的合计也会完整。
- **限额历史不再无限增长。** Codex 和 Claude 的实时用量采样现在只保留最近 7 天（并始终保留每个窗口的最新一条快照），本地数据库不再无限膨胀，长期运行后冷启动和刷新依旧流畅。
- **每日、每月和历史图表按本地时区分桶（含夏令时切换）。** 临近午夜的用量现在全年都会归到正确的本地“当天/当月”，不再因为事件落在夏令时的另一半年而偶尔串到相邻的一天。

## [0.2.32] — 2026-06-12

#### Summary
- 仪表盘工具筛选器仍在标题栏里，但不再挤到窗口按钮旁边
- Claude 设置现在隐藏凭据来源选择器，只在自动刷新被停用时提供恢复入口
- Claude 5 小时配额重置后会保留上次百分比，而不是变成空闲占位
- Claude Code 模型统计更准确，Claude Fable 5 使用记录也能计入费用

### 新增
- **产品手册。** 新的中文指南配合截图说明初始引导、菜单栏弹窗、Dashboard、History、Sessions、Settings、更新和卸载流程。

### 变更
- **Claude 凭据设置。** 高级设置现在默认使用自动 Claude 凭据刷新，不再把仅文件/钥匙串选择器作为常规选项；只有已保存的仅文件模式可能停止实时配额刷新时，才显示恢复按钮。
- **QA 启动命名。** 本地测试版检查现在默认指向真实数据影子 QA，固定夹具入口改名为 fixture-smoke，避免和真实数据回归混淆。

### 修复
- **仪表盘筛选布局。** 标题栏里的工具筛选器现在使用尺寸稳定的带标签菜单，避免打开或移动窗口后变成很小的控件，或与窗口标题重叠。
- **本地 QA 偏好隔离。** QA 运行现在会拒绝使用已安装应用的偏好域，避免仅用于 QA 的 defaults 泄漏到已安装应用设置。
- **Claude 重置配额行。** 当 Claude 当前 5 小时窗口已经重置，而下一次 `/usage` 只返回 7 天配额时，弹窗会继续显示上次 5 小时百分比并置灰，同时提示窗口已重置。
- **Claude Code 模型统计。** Claude 导入现在会保留每条流式消息的最终 usage 快照，模型统计和费用估算不再低估输出 tokens；Claude Fable 5 使用记录也有内置价格种子。

## [0.2.31] — 2026-06-08

#### Summary
- 窗口打开和切换更稳定，设置、仪表盘和帮助页面更容易回到刚刚查看的位置
- 更新提示更清楚，安装前就能快速看懂这次改进了什么
- 配额读数更可靠，暂时取不到实时数据时也会尽量保留可用的信息
- 刷新更顺手，点击手动刷新会立即更新，后台自动刷新也减少重复打扰

### 变更
- **AppKit 窗口所有权。** Dashboard、Settings、onboarding 和菜单栏恢复指南现在共用一个 AppKit 窗口管理器，使窗口打开和聚焦行为更一致。
- **Codex usage 刷新节流。** 自动 Codex 实时配额刷新现在会在短时间窗口内跳过重复请求，而手动刷新仍会绕过这个短窗口节流。
- **静态 QA 默认入口。** `qa/run-all.sh` 现在转发到 `qa/run-static.sh`，不再启动新的 QuotaMonitor 实例。
- **Computer Use 负责可见 app 验证。** 标准可见 QA 路径是 `qa/prepare-computer-use-fixture.sh` 或 `qa/prepare-computer-use-real-data.sh`，然后使用 Computer Use。
- **真实数据 QA 保留可见偏好。** `qa/prepare-computer-use-real-data.sh` 现在会把当前 QuotaMonitor UserDefaults 复制到隔离 QA suite，同时继续覆盖凭据敏感设置。
- **测试链路文档。** `docs/local-qa.md`、`docs/computer-qa.md` 和项目 QA skill 现在用同一套职责描述：静态门禁、Computer Use 准备、Computer Use 走查和 artifact 复核。
- **macOS CI 按需运行。** 必需的 `swift-test` 检查现在先跑快速汇总 job，只有 ready PR 触及 app、测试、QA、资源、Package、工具或 workflow 时才启动 macOS Swift 套件。

### 新增
- **隔离的本地 QA harness。** 本地 QA 现在会用隔离 profile、fixture 数据、重定向后的 Codex/Claude home 启动 QuotaMonitor，并产出 app 状态、数据库计数、日志、截图和辅助功能快照等可机器检查的 artifacts。
- **Computer Use QA 工作流。** 交互式 fixture 和真实数据影子运行现在会生成包含精确 QA app 路径的 run brief，让 Dashboard、History、Sessions、Settings 和帮助窗口的可见检查可以复跑，并避免误操作已安装 app。
- **PR 更新日志强制检查。** 非 appcast PR 的 CI 现在要求同时更新英文和简体中文 changelog，并校验会展示在更新窗口中的小节。

### 修复
- **菜单栏读数跟随设置。** 当已选择的工具暂时没有 live 配额样本时，菜单栏现在会继续显示配置的文字读数，并用短横占位或 Dashboard 配额快照回填，而不是退回表盘图标。
- **Codex 弹窗配额回填。** 当 live CLI 配额获取不可用时，Codex 菜单栏卡片现在会使用 Dashboard 配额快照，避免真实数据 QA 中出现误导性的登录提示。
- **升级后的设置窗口布局。** 由 AppKit 承载的 Settings 现在会复用旧 Settings 窗口的 frame key，同时保持与原本分组式设置页面一致的 pane 宽度。
- **更新窗口关闭后的 Dock 清理。** Sparkle 更新窗口关闭后，如果没有其他 app 窗口打开，QuotaMonitor 现在会回到纯菜单栏模式。
- **Codex 配额来源隔离。** Codex 配额卡片和历史曲线现在会忽略同一存储表中的 Claude OAuth 样本，避免不同 provider 的视图互相串数据。
- **Codex 刷新诊断。** Codex rate-limit 刷新的 poller 路径现在会保留超时保护，失败操作会正确关闭 developer-log 操作记录，活跃的 429 冷却也会优先显示冷却原因而不是普通自动轮询节流原因，并且只有真正的 HTTP 429 才会进入冷却（不再因为无关错误里恰好含有数字 429 而误判）。
- **QA 清理后恢复已安装 app。** QA 清理现在会记录 `/Applications/QuotaMonitor.app` 运行前状态，只关闭 QA 启动的进程，并在需要时恢复已安装 app。
- **更新窗口不再因空发布说明而空白。** 当 appcast 条目没有附带说明时，更新窗口现在会显示简短占位并保持“安装”可用，而不是渲染空白网页视图；此前的判空逻辑作用在恒不为空的包壳 HTML 上，因此从未生效。

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
