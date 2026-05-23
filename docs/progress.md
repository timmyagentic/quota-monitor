# CodexMonitor → QuotaMonitor — 进度跟踪

跨会话持久化的项目进度档案。每次完成一个里程碑就更新本文件。
最近更新：2026-05-23（Day-29 配额进度条复查 + app-only fallback）

---

## 里程碑总览

| Day | 主题 | 状态 |
| --- | --- | --- |
| 1 | 项目脚手架 + codex CLI 探活 | ✅ 已完成 |
| 2 | 菜单栏 UI + 配额展示 + JSONL 导入 | ✅ 已完成 |
| 3 | 定价层 + 主窗口 Dashboard | ✅ 已完成 |
| 4 | 会话钻取页 + 主窗口 Tab 化 | ✅ 已完成 |
| 5 | 后台轮询 rate limits + 历史曲线 + 阈值通知 | ✅ 已完成 |
| 6 | Settings + 价格表可编辑 + CSV 导出 | ✅ 已完成 |
| 7 | 打磨 + 打包发布 | ✅ 已完成 |
| 8 | History tab（按天钻取）+ fetchDaily SQL bug fix | ✅ 已完成 |
| 9 | LiteLLM 实时价格同步（Phase 1） | ✅ 已完成 |
| 10 | Claude Code 数据源 + Provider 顶层 Tab（Phase 2） | ✅ 已完成 |
| 11 | 5 小时计费窗口引擎 + Dashboard 面板 + 菜单栏小组件（Phase 3a） | ✅ 已完成 |
| 12 | Subagent 解析（forked_from_id / thread_spawn）+ Sessions UI | ✅ 已完成 |
| 13 | AppIcon（Core Graphics 渲染 + iconutil 打包） | ✅ 已完成 |
| 14 | 模型推断 fallback：legacy 会话不再静默 0 元（unknown → gpt-5 + UI 标记） | ✅ 已完成 |
| 15 | archived_sessions/ 扫描 + import_state orphan 清理 | ✅ 已完成 |
| 16 | Codex 配额卡（5h primary + weekly secondary）+ reset 倒计时 | ✅ 已完成 |
| 17 | Recent blocks 列表（last 3 days，挂在 active block 下） | ✅ 已完成 |
| 18 | Subscription payoff KPI（API value ÷ monthly cost） | ✅ 已完成 |
| 19 | Codex quota burn rate + 推断耗尽时间（least-squares 斜率） | ✅ 已完成 |
| 20 | Notarization 脚本 + entitlements（待 Apple 证书激活） | ✅ 已完成 |
| 21 | Monthly tab（last 12 months bar + MoM%） | ✅ 已完成 |
| 22 | 菜单栏视觉清理（折叠 0% limits + plan tooltip + scan errors popover） | ✅ 已完成 |
| 23 | 菜单栏重构：双 provider block + Claude last 7d 行 | ✅ 已完成 |
| 24 | Claude OAuth `/api/oauth/usage` 接入（CodexBar 借鉴） | ✅ 已完成 |
| 25 | 配额行人话化 pace 文案 + Keychain 策略设置 | ✅ 已完成 |
| 26 | 0.2.0 修复打包 + Claude refresh 委派给 CLI | ✅ 已完成 |
| 27 | 重命名 CodexMonitor → QuotaMonitor（bundle id + DB + UserDefaults 自动迁移） | ✅ 已完成 |
| 28 | Developer Mode 持久化日志 + refresh fan-out 对齐 | ✅ 已完成 |
| 29 | 配额进度条复查 + Codex/Claude app-only fallback + 发版文档 | ✅ 已完成 |

---

## Day-1 — 脚手架 + CLI 探活 ✅

- SwiftPM 工程 + 手工 `.app` 包装 + ad-hoc 签名（无需 Xcode）
- `Resources/Info.plist`：`LSUIElement=YES`、bundle id `dev.tjzhou.CodexMonitor`、minOS 14
- `build.sh`：`swift build` → 组装 `.app` → `codesign --force --deep --sign -`
- `AppServerClient` actor：spawn `codex app-server`、stdio JSON-RPC、按 id 解复用
  - binary 发现链：`CODEX_BINARY` → 常见 bin 目录候选 → `$SHELL -ilc 'command -v codex'`
  - `salvageBodyFromErrorMessage`：花括号深度扫描，从 error.message 救回 JSON body
- 三个 RPC 跑通：`initialize`、`account/read`、`account/rateLimits/read`
- 探活结果 + CLI 怪癖归档于 `docs/findings.md`

## Day-2 — 菜单栏 + JSONL 导入 ✅

- `MenuBarExtra(.window)`：5h / 7d / Additional 配额条 + paceRatio 颜色编码
- 错误展示可复制（`textSelection(.enabled)` + `fixedSize`）
- GRDB 数据库 + 迁移 v1：`sessions` / `usage_events` / `import_state` / `rate_limit_samples` / `pricing_catalog`
- WAL + foreign_keys + busy_timeout=10000；DB 路径 `~/Library/Application Support/CodexMonitor/codexmonitor.sqlite`
- `RolloutParser`：cumulative `total_token_usage` → delta、计数器倒退视为 reset、嵌入式 rate limit 抽样
- `ImportEngine` actor：`(size, mtime)` 差分检测变化文件、整事务持久化
- 真实数据验证：317 sessions / 10,556 events / 33,132 samples 全量导入

## Day-3 — 定价层 + Dashboard ✅

- `PricingService`：12 个模型种子表、`seedCatalog` (INSERT ON CONFLICT)、`backfillAllValues` (一条 UPDATE 子查询)
  - 公式：`((input - cached) * input_price + cached * cached_price + (output + reasoning) * output_price) / 1M`
  - 每次扫描后都重跑 backfill，价格表改动下次 Scan 自动生效
- `Aggregator`：三个查询
  - `fetchOverview`：合计价值 / token / sessions / events / 时间区间
  - `fetchDaily(days:)`：按本地日历日分桶，零填充缺失日（时区偏移由 SQL 处理）
  - `fetchModelShares`：按 `model_id` 聚合，LEFT JOIN `pricing_catalog` 取 display_name
- `DashboardView`：4 张 KPI 卡 + 14 天 Swift Charts BarMark（货币 Y 轴）+ 模型占比行
- `AppEnvironment`：新增 `dashboardSnapshot` / `isLoadingDashboard` / `refreshDashboard()` / `activateForWindow()`
  - 后者把 `NSApp.setActivationPolicy(.regular)`，让窗口能拿到焦点
- `CodexMonitorApp`：增加 `Window("Codex Monitor", id: "dashboard")` 场景
- 菜单栏：顶部 API 价值 KPI + Open Dashboard 按钮（⌘D）；菜单首次打开自动 refresh

## Day-4 — 会话钻取页 + 主窗口 Tab 化 ✅

- `Aggregator` 增加 `SessionRow` / `SessionDetail` DTO 与三个查询：
  `fetchSessions(sort:search:limit:)`、`fetchSessionDetail(sessionId:)`，含按 model 拆分的子聚合
- `SessionSort` 枚举（recent / value / tokens），SQL `ORDER BY` 子句直接由它生成
- 搜索同时匹配 title / agent_nickname / last_model_id / session_id（LOWER + LIKE %x%）
- `MainWindowView` 取代直接挂 `DashboardView`：顶部 segmented Picker 切 Dashboard / Sessions tab，工具栏 Reload 按钮上移
- `SessionsView`：NavigationSplitView，左边 List 用 `selection:` 绑定，输入框 200ms 防抖避免连续 SQL；切换排序 / 选中失效时清掉 detail
- `SessionDetailView`：标题 + 关键 stats（value/tokens/events/started）+ 多模型时显示 breakdown + 事件 LazyVStack（每条带 in/cache/out/reason token chip + USD）
- 修复 Day-3 遗留：`MainWindowView.onDisappear` 调 `env.demoteToAccessory()`，关窗后回到 `.accessory`，Dock icon 不再残留

---

## Day-5 — 后台轮询 + 历史曲线 + 阈值通知 ✅

- `RateLimitPoller` actor：自带 Task 主循环，2 秒预热 + 每 5 分钟一次 `account/rateLimits/read`
  - 错误吞掉（网络抖动正常），下一周期重试，不污染前台 lastError
  - 写库时把 top-level + 每个 additional limit 都拆成 primary/secondary 行，`source_kind='live'`
  - 实测：单次 poll 写入 4 行（top × 2 + GPT-5.3-Codex-Spark × 2）
- `QuotaNotifier`（@MainActor 单例）：每次 snapshot 检查 `usedPercent ≥ 85`，按 `(bucket, limit_name, resetAt)` 去重，跨 reset 才会再次提醒
  - 首次需要时才请求 `UNUserNotificationCenter` 授权；用户拒绝后静默
  - `center` 用 `nonisolated computed property` 绕开 strict concurrency 报警
- `Aggregator.fetchRateLimitHistory(hours:)`：返回 `RateLimitHistoryPoint`，过滤 `limit_name IS NULL` 只取 top-level，timestamps 兼容三种 SQLite/ISO 格式
- `DashboardView`：在 14 天柱图与模型分占之间插入 24h 折线图，按 `series` ("primary (live)" / "secondary (jsonl)" 等) 着色，Y 轴固定 0–100%
- **关键修复**：原本想用 `MenuBarExtra` 的 `.task` 触发轮询启动，但 MenuBarExtra body 在用户首次点击之前不实例化 → 改到 `AppEnvironment.init()` 用 `Task` + `MainActor.run` 立即引导，与 UI 生命周期解耦

---

## Day-6 — Settings + 价格表可编辑 + CSV 导出 ✅

- `SettingsStore`（@Observable @MainActor 单例 + UserDefaults 后端）
  - 字段：codex binary 覆盖、CODEX_HOME 覆盖、poll 间隔、通知阈值
  - 提供 `nonisolated static func snapshot()` 让 actor / 后台线程能直接读
- `AppServerClient.resolveBinary()` 与 `SessionScanner.defaultCodexHome()` 都先查 SettingsStore，再走环境变量与默认路径
- `RateLimitPoller.interval` 改成 var + `updateInterval(_:)`，每次 sleep 前重新读 → 热生效
- `QuotaNotifier.threshold` 改成 computed property 读 SettingsStore（每次 evaluate 取最新值）
- `AppEnvironment.applySettings()`：UI 改完 stepper 后立刻把新间隔传给 poller
- `AppEnvironment.updatePricing(...) / restorePricingDefaults() / loadPricingCatalog() / exportUsageEventsCSV(to:)`
  - 编辑后立即 `PricingService.backfillAllValues` 把所有事件价格回填 → `refreshDashboard()`
  - CSV 用 `Row.fetchCursor` 流式写，含基础引号转义
- `Settings { ... }` SwiftUI 场景，三个 tab：
  - **General**：路径输入框 + Choose / Clear 按钮 + Stepper(60–3600s) + Slider(50–100%)
  - **Pricing**：Table 列出 12 个模型，本地编辑过的会标橙色 pencil；下方编辑面板 + Save / Restore Defaults
  - **Data**：DB 路径 + Reveal in Finder + Export CSV (NSSavePanel)
- 菜单栏新增 "Settings…" 按钮（⌘,），用 `NSApp.sendAction(showSettingsWindow:)` 调起标准设置窗口
- 路径覆盖需重启才生效，已写在 General tab 注释里

---

## Day-7 — 打磨 + 打包发布 ✅

- `Core/Log.swift`：集中定义 `Log.subsystem = "dev.tjzhou.CodexMonitor"` + 五个分类 logger（`appserver` / `importer` / `poller` / `pricing` / `ui`）
  - `RateLimitPoller.pollOnce` 每次落库写一行 info（含 primary/secondary 百分比）
  - `ImportEngine.performScan` 收尾打一条 info（scanned/changed/sessions/events/samples/errors），前 5 条错误打 error
  - `AppServerClient` 进程启动打 debug，启动失败打 error
  - 实时观测：`log stream --predicate 'subsystem == "dev.tjzhou.CodexMonitor"' --level info`
- `docs/parity.md`：与 codex-pacer 的功能对照表（25+ 行 area 表 + 架构差异表 + 1.0 前的 closure 列表）
  - 标注 prolite 救援与 `account/rateLimits/read` 是 ahead，AppIcon / notarization / subagent UI / 订阅表是 gap
- `tools/make-dmg.sh`（chmod +x）：`./build.sh` → 把 `.build/CodexMonitor.app` + `/Applications` symlink 拷到 staging → `hdiutil create -format UDZO`，输出 `dist/CodexMonitor-<ver>.dmg`
  - 注释里写明 notarize 路径（`xcrun notarytool submit` + `stapler staple`），但本脚本不跑——需要 Apple Developer 账号
  - 真机验证：`CONFIG=debug ./tools/make-dmg.sh` → 3.2 MB DMG，`hdiutil attach` 后挂载点同时含 Applications 软链与 CodexMonitor.app
- `README.md` 重写：删除过时的 "Bootstrap into Xcode" 段，改为 `./build.sh` / `./tools/make-dmg.sh` 工作流；补 Tech stack 表 / 布局树 / 日志查看 / 1.0 前 known gaps 段
- 已知遗留缺口（不阻塞 v0.1）：自定义 AppIcon、notarization、subagent rollup UI

---

## Day-8 — History tab（按天钻取） ✅

用户反馈："以天为单位的调用历史查看"完全缺失，dashboard 的 14 天柱图只能看汇总，点不进去。

- `Aggregator` 新增三个查询：
  - `fetchDays(limit:)` → `[DaySummary]`：按本地日历日聚合的所有有数据的天，倒序
  - `fetchDayDetail(day:)` → `DayDetail`：当天的 KPI + per-model 拆分 + sessions（值仅算当天事件）
  - `fetchEventsForSessionOnDay(sessionId:day:)`：行内展开 session 时拉那天的事件
- `Features/History/HistoryView.swift`：NavigationSplitView，左 sidebar 列每一天（日期 + value + tokens + sessions count），右 detail 展示 KPI 4 卡 + 模型占比 + 会话列表（每行可展开成事件 timeline，复用 `EventRow`）
- `MainWindowView` segmented picker 增加 "History" tab
- `AppEnvironment` 加三个对应的 wrapper 方法

**顺手修一个隐藏 bug**：`Aggregator.fetchDaily` 里的 SQLite datetime 修饰符写成了 `"+(28800) seconds"`，括号让 SQLite 静默返回 NULL —— 14 天柱图实际一直在显示零填充的空 bar。改成 `String(format: "%+d seconds", offset)` 后所有按天查询都正确。

**Dashboard 14 天柱图交互**：加 `@State selectedDay`，柱图绑定 `.chartXSelection(value:)`；选中那根柱子高亮（不选中的灰一档），并通过 `RuleMark.annotation` 在柱顶上方浮一个 tooltip 显示 `Wed Apr 28 / $1.23 / 4.5K tokens`，背景用 `.regularMaterial` + 轻阴影。

**计费公式 bug 修复**：原公式把 `reasoning_output_tokens` 当作独立项加到 output 上（`(output + reasoning) * output_price`）。但用 300 条真实 token_count 抽样验证：所有样本都满足 `total = input + output`，没有任何样本满足 `total = input + output + reasoning`——也就是说 OpenAI 的 `output_tokens` 已经把推理 token 包含在内（参考 `completion_tokens` 与 `completion_tokens_details.reasoning_tokens` 的关系），再加一遍就是双重计费。同时用 pacer 的 `calculate_value_usd` 做 cross-reference，pacer 也只用 `output_tokens`，未加 reasoning。

修正后公式：`value_usd = max(input - cached, 0) * input_price/M + cached * cached_price/M + output * output_price/M`。`MAX(...,0)` 防御 cached > input 的边界。

实测影响：已有 10568 条 events 在 modal 修复前合计 \$786.92，修复后 \$739.55——约 **6% 的虚高**。直接对 SQLite 跑一次新公式 backfill 把存量数据校正了。

### Day-9 — LiteLLM 实时价格同步（Phase 1）

**动机**：之前 `pricing_catalog` 全靠 `PricingSeed` 硬编码，模型一更新就要改代码。借鉴 ccusage：从 `BerriAI/litellm` 拉 `model_prices_and_context_window.json`（2688 个模型）做权威源。

**Schema v2**：`Migrations.swift` 新增 7 列 — `cache_creation_price_per_million`（Claude 5x 缓存写入；OpenAI 默认 0）、`above_200k_input/output_price_per_million`（>200k context tier，先存不计算）、`price_source`（`'seed'` / `'litellm'` / `'local'`）、`fetched_at`、`max_input_tokens`、`max_output_tokens`。

**LiteLLM 取数**：`Core/Pricing/LiteLLMPricingSource.swift` actor，`URLSession` 拉 raw JSON，`JSONSerialization` 解析（dict-of-dicts 用 `Decodable` 反而冗）。两个坑：
1. 第一个 key `sample_spec` 是文档占位，必须跳过
2. LiteLLM 用 **per-token** 单位（`1.25e-6`），我们存 per-million，apply 时 `×1_000_000`

模型别名也处理了：`openai/gpt-4o` 和 `gpt-4o` 都建索引，匹配时优先精确再 fallback。

**应用规则**（`PricingService.applyLiteLLMUpdate`）：
- 只 update 已存在的 catalog 行；未知模型留给 Phase 2
- `price_source = 'local'` 的行**永远跳过**（用户编辑优先），编辑器里 `updatePricing` 会主动写入 `'local'`
- 命中后写 LiteLLM 字段并打 `price_source='litellm'` + `fetched_at=now`
- 任意行被改后 → 立刻 `backfillAllValues` 重算 `usage_events.value_usd`

**自动刷新**：`AppEnvironment.refreshPricingIfStale(maxAge: 24h)` 在 init 时跑一次；最旧 `fetched_at` 超过 24h 或为 nil 触发 fetch。失败静默写到 `lastError`，不阻塞启动。

**UI**：Settings → Pricing
- 顶部 banner：`Last refreshed 2h ago` + `Refresh from LiteLLM` 按钮
- Model 列前加彩色 badge：`live`（绿）/ `seed`（灰）/ `local`（橙）
- 多一列 `Cache create $/M`（OpenAI 行显示 `—`，Claude 行显示 5x 价格）
- 状态栏显示 `Updated 12 models from LiteLLM` 或错误

### Day-10 — Claude Code 数据源 + Provider 顶层 Tab（Phase 2）

**Schema v3**：`Migrations.swift` 新增 v3：
- `sessions.provider TEXT NOT NULL DEFAULT 'codex'`
- `usage_events.provider TEXT NOT NULL DEFAULT 'codex'`
- `usage_events.cache_creation_tokens INTEGER NOT NULL DEFAULT 0`
- 索引 `(provider, timestamp)` 给 dashboard 过滤用

历史 Codex 行通过 DEFAULT 自动归到 `'codex'`，无需 backfill。

**ClaudeImportEngine + ClaudeRolloutParser**（`Core/Importer/ClaudeImportEngine.swift`）：
- 扫描 `~/.claude/projects/**/*.jsonl`（兼容新路径 `~/.config/claude/projects/`，支持 Settings 覆盖）
- 每个文件名 stem 即 sessionId（实测 126 个文件 100% 命中）
- 只处理 `type=='assistant'` 行，按 `message.id` 跨快照去重
- 跳过 `model == "<synthetic>"`、零 token 占位
- Claude 的 usage 是**每条消息独立结算**（不是累计），所以一条消息 = 一行 usage_event，不做 delta

`runScan` 改成 `async let` 并行跑 Codex + Claude 两个 engine，最后再统一 `backfillAllValues` 一次（避免 Claude 行落表晚于 Codex backfill）。`ScanReport` 直接相加合并。

**Provider 计费分支**（`PricingService.backfillAllValues`）：
- Codex/OpenAI：`max(input - cached, 0) * input + cached * cached + output * output`（`input_tokens` 是 gross，含 cached）
- Claude：`input * input + cache_read * cached + cache_creation * cache_creation_5x + output * output`（`input_tokens` 已是 uncached，分项分开计费）

SQL 用 `CASE provider` 分支一次 UPDATE 完成。

**Pricing 种子**（`PricingSeed`）：补 Claude Opus 4.7/4.6、Sonnet 4.6、Haiku 4.5 兜底价；`PricingEntry` 加 `cacheCreationPricePerMillion` 字段（默认 0），种子 SQL 也写入 `cache_creation_price_per_million`。`seedCatalog` 改成只覆盖 `price_source = 'seed'` 的行——这样 LiteLLM 同步过的或者本地编辑过的不会被启动种子覆写。

**Provider 顶层 Tab**：`ProviderFilter` 三态枚举（`all` / `codex` / `claude`），`AppEnvironment.providerFilter` 在 didSet 触发 dashboard 重算。`MainWindowView` 在 Dashboard/History/Sessions 三段 picker 之上多加一段 `Picker(ProviderFilter)` 当总开关，下面所有视图通过 `.id(env.providerFilter)` 在切换时重置内部状态。Aggregator 全部读端查询加 `provider: ProviderFilter = .all` 参数，rate-limit history 在 `.claude` 下直接返回空（Claude 不暴露 rate limits）。

**Settings**：General 页加「Claude home」目录选择器，写到 `SettingsStore.claudeHomeOverride`。`ClaudeImportEngine.defaultRoots()` 顺序：override → `~/.claude/projects` → `~/.config/claude/projects`，去重后存在的目录都扫。

**实测预期**（本机数据）：
- 126 个 Claude jsonl，扫出 3586 个 assistant usage 事件
- 模型分布：`claude-opus-4-7` × 1448、`glm-5.1` × 1304、`claude-sonnet-4-6` × 609、`claude-opus-4-6` × 198、`claude-haiku-4-5-20251001` × 19、其他 GLM 少量
- GLM 系列没有公开 LiteLLM 价格，会留 `value_usd = 0`（如实记录），后续如果用户手动编辑就会变成 `local` 行

---

### Day-11 — 5 小时计费窗口引擎 + Dashboard 面板 + 菜单栏小组件（Phase 3a）

借鉴 ccusage `_session-blocks.ts` 的核心算法，把 Anthropic 5h 计费窗口落到 CodexMonitor。

**`Core/Analytics/BillingBlocks.swift`**：算法直接从 ccusage 端口过来，行为对齐：
- block 起点 = 第一个事件时间向下取整到 UTC 整点（`floorToHour`），end = start + 5h
- 划分规则：`time_since_block_start > 5h` 或 `time_since_last_entry > 5h` → 关闭当前 block 开新 block；后者还会插一个 gap block
- gap block 仅当连续静默超过 5h 才生成，区间 `[lastActivity + 5h, nextActivity)`
- `isActive = (now - lastEntryAt < 5h) AND (now < endTime)`
- burn rate：`(lastEntry - firstEntry)` 分钟数为分母；同时输出 `tokensPerMinute` 和 `nonCacheTokensPerMinute`（保留 indicator 阈值兼容）；`costPerHour = (cost / minutes) * 60`
- projection：`active && !gap` 才计算；`projectedTokens = current + tokensPerMinute * remainingMinutes`，`projectedCost = current + costPerHour/60 * remainingMinutes`

DB 入口 `loadSnapshot(db:provider:now:recentDays:)` 一次拉所有 Claude `usage_events` 行（按 timestamp ASC），跑一遍算法，返回 `Snapshot { currentBlock, burnRate, projection, recentBlocks }`。`recentBlocks` 默认 3 天 + 永远包含 active。

**ProviderFilter 公开度调整**：`clause(table:)` 和 `whereClause(table:)` 从 `fileprivate` 提到默认（internal），让分析层多文件共用。

**AppEnvironment**：加 `billingBlocks: BillingBlocks.Snapshot?`，`refreshDashboard` 在 dashboard 快照之后再读一次 block snapshot；`providerFilter == .codex` 时直接置 nil（5h 窗口是 Anthropic 概念）。

**Dashboard 面板**（`DashboardView.billingBlockSection`）：放在 KPI 行下方、daily chart 上方。
- 顶部 Live/idle 标签
- 4 个 KPI：Spent so far / Tokens / Projected end-of-block / Remaining
- 进度条：`elapsed / 5h`，60% 以下绿、85% 以下橙、85%+ 红
- 底部行显示 burn rate（`X tok/min · $Y/h`）+ 当前 block 用到的模型列表
- `paceAccent`：projected/current 比值 <1.5 绿、<3 橙、>=3 红，提示当前燃烧速度是否过激

**菜单栏小组件**（`MenuBarContentView.BillingBlockMini`）：320pt 宽度受限，做了精简版。
- 一行 header（Active/Last 5h block + 当前花费）
- 进度条（同色阶）
- 一行 metadata（projected / 剩余 / token 总量）

**算法验证**：跑 Python 镜像版对 `~/.claude/projects/**` 实测，6538 events → 91 real blocks + 48 gap blocks + 1 active block（96 events，运行中 ~1h，剩余 ~3.9h）。算法和 ccusage 行为一致。

`swift build` 2.24s clean。

---

- **AppIcon.icns**：Cmd-Tab / Dock 目前是默认占位
- **Notarization**：`xcrun notarytool submit` + `stapler staple` 流程，需要 Apple Developer 账号
- **Subagent UI**：schema 已有 `contains_subagents`，需要在 Sessions tab 加列或单独 tab
- **首启 onboarding**（可选）：当前用自动发现 + 空态文案兜底，但有需要可以补一个 wizard

---

## 维护约定

- 每完成一个 Day 里程碑 → 在「里程碑总览」改 ✅、补一节实现要点。
- 中途出现的非显然决策（比如 prolite 救援、价格表 UPDATE 时机）记到对应小节。
- 路线图里的 Day 编号只是顺序占位，不代表自然日。

---

### Day-12 — Subagent 解析 + UI 落地

补 `parity.md` 里挂着的最后一个功能 gap。之前 `ImportEngine` 把 `contains_subagents` 写死成 `false`，且 `RolloutParser` 只读 `parent_session_id` 字段，漏掉 pacer 也会 fallback 取的两个 fallback 字段。实测本机 28 个 Codex jsonl 含 `thread_spawn` 标记，但 DB 里 `SUM(contains_subagents) = 0` 验证了这个 dead code 路径。

**`SessionMetaPayload`（`Core/Importer/RolloutEvent.swift`）**：补 `forked_from_id` 字段；新增三个 computed property `resolvedParentSessionId / resolvedAgentNickname / resolvedAgentRole`，按 pacer 的优先级 fallback：
1. top-level (`parent_session_id` / `agent_nickname` / `agent_role`)
2. `forked_from_id`（仅 parent）
3. `source.subagent.thread_spawn.{parent_thread_id, agent_nickname, agent_role}`

`RolloutParser` 切到这三个 resolved 字段，其它逻辑不动。

**`ImportEngine.reconcileSessionTree()`**：所有文件落库后跑一次。一条 SQL 拉所有 codex sessions 的 `(session_id, parent_session_id)`，内存里：
- 算 `hasChildren` 集合（出现在 parent_session_id 列里的）
- 对每个 session 跑 `resolveRoot`：沿 parent 链最多走 64 跳，带 cycle 检测
- 一条 UPDATE 写回 `root_session_id` + `contains_subagents`

镜像 pacer 的 `recompute_conversation_links`，但不维护单独的 `conversation_links` 表 —— `sessions.root_session_id` + `contains_subagents` 已经够用。

**Aggregator**：`SessionRow` 加 `containsSubagents: Bool` + `subagentCount: Int?`（list 查询填 nil，detail 才填）；`SessionDetail` 加 `subagents: [SessionRow]`；新查询 `fetchSubagents(parentSessionId:)` 按 `updated_at DESC` 列直接子节点。所有 4 处 `SessionRow(...)` 构造点同步加新字段。

**UI**：
- `SessionsView` row：在 nickname capsule 旁边加紫色 `person.2.fill` 徽标，hover 提示 "This session spawned subagent threads"
- `SessionDetailView`：breakdown 之后插 `subagentsSection`，紫色 header + 直接子 session 列表（title / nickname capsule / model / events / value），hover 后续可以做点击钻入（暂未做导航联动，因为 `SessionsView` 的 selection 不在这一层）

`swift build` clean (4.83s)，验证子代理数据：原 DB `SUM(contains_subagents)=0`；改完后下次 scan 会回填。

---

### Day-13 — AppIcon

`docs/parity.md` 上倒数第二个 gap，纯打包/资源问题，没动 Swift 代码。

**`tools/make-icon.sh`**：一次性脚本（脚本内嵌 Swift 单文件 via `swift -`），用 Core Graphics 在 1024² bitmap context 上画：
- 824/1024 squircle（macOS Big Sur+ 标准 mask），暗色 navy 渐变
- 3/4 圈 dial（淡灰底 + indigo→teal active arc 到 70%）
- 9 个 tick dots
- 三角形指针（白色实心，30° 半角）
- 中央 hub 双层圆盘

然后 `sips` 一次性出 10 个尺寸进 `.iconset/`，`iconutil -c icns` 合成 `Resources/AppIcon.icns`（973 KB）。

**接线**：
- `Resources/Info.plist`：加 `CFBundleIconFile = AppIcon`
- `build.sh`：在拷 `Info.plist` 之后，把 `Resources/AppIcon.icns` 拷到 `Contents/Resources/`，缺失则 warn 不 fail（开发时可以暂时跳过 make-icon）

**验证**：`./build.sh` 完，`Contents/Resources/AppIcon.icns` 存在，`PlistBuddy -c 'Print :CFBundleIconFile'` 输出 `AppIcon`。
后续要改图，编辑 `tools/make-icon.sh` 里那段 Swift 然后重跑 `./tools/make-icon.sh` 即可。

**1.0 还差**：notarization（需 Apple Developer 账号 + `xcrun notarytool` + `stapler`）。

---

### Day-14 — 模型推断 fallback（修真 bug）

**问题**：`RolloutParser` 在 `token_count` 事件遇不到 `turn_context` 模型时硬编码 `"unknown"`。`pricing_catalog` 没有 `unknown` 行 → `backfillAllValues` 的 `WHERE EXISTS` 短路 → 这些事件 `value_usd = 0`，永远不计费。 pacer 也有同样的 `unknown` 字串（`importer.rs:543`），但 ccusage（`apps/codex/src/data-loader.ts:105`）选择 fallback 到 `gpt-5`，匹配 OpenAI 当前默认。本地 DB 检查暂时没有 `unknown` 行，但任意 legacy 会话或第三方 jsonl recorder 都可能触发，是 silent bug。

**Parser 改造（`Core/Importer/RolloutParser.swift`）**：
- 新增 `LegacyFallbackModel = "gpt-5"` 顶层常量
- `UsageDelta` 加 `modelInferred: Bool`
- 解析状态加 `currentModelIsFallback: Bool`，跟踪当前 model 是否来自 fallback
- token_count 分支决议顺序：
  1. payload 上的显式 model（`extractPayloadModel` 扫 `info.model` / `info.model_name` / `info.metadata.model` / `payload.model` / `payload.metadata.model` —— 镜像 ccusage 的 `extractModel`，今天 Codex CLI 不写这些字段，是防御未来）
  2. 最近一次 `turn_context` 设的 `currentModel`
  3. fallback 到 `LegacyFallbackModel`，标记 `inferred = true`，并把 `currentModelIsFallback` 设 true（同会话后续 token_count 也带 inferred 标记）

**`RolloutEvent.swift`**：`TokenCountPayload` 加 `model` / `metadata` 字段，`TokenCountInfo` 加 `model` / `model_name` / `metadata` 字段，纯防御性，不影响今天的 wire 格式。

**Schema v4（`Migrations.swift`）**：
- `usage_events.model_inferred BOOLEAN NOT NULL DEFAULT 0`
- 同时跑两条数据修复：把 v3 之前留下的 `model_id = 'unknown'` 行回填成 `gpt-5` + `model_inferred = 1`；`sessions.last_model_id = 'unknown'` 同样改 `gpt-5`。这样老 DB 升级后历史数据立刻有合理估值。

**Pricing seed**：在 `PricingSeed.entries` 顶端加 vanilla `gpt-5` 行（input 1.25 / cached 0.125 / output 10.00，匹配 openai.com 当前 gpt-5 价目，标 `note = "Used for sessions that lack turn_context model metadata."`）。

**Aggregator**：
- `SessionRow` 加 `hasInferredModel: Bool`，所有 4 处构造点同步
- 三条 SQL（list / detail / day-detail / subagents）的 SELECT 加 `COALESCE(MAX(ue.model_inferred), 0) AS has_inferred_model` 聚合
- `SessionDetail.Event` 加 `modelInferred: Bool`，两处 SELECT（detail timeline、day timeline）补字段

**UI**：
- `SessionsView` 行末金额：`hasInferredModel` 时附 `*` 后缀 + hover tooltip "Cost is approximate — model was inferred"
- `SessionDetailView` header：在 cpu label 之后插一个橙色 `questionmark.circle` "inferred model" Label，hover 解释 "uses gpt-5 pricing"

**`ClaudeImportEngine`**：构造 `UsageEventRecord` 时显式传 `modelInferred: false`（Claude 的 model id 永远来自 message header，不会缺）。

`swift build` clean (4.04s)。下次 app 启动会自动应用 v4 migration，把历史 `unknown` 行升级成有定价的 inferred 行。

---

### Day-15 — archived_sessions/ 扫描 + import_state orphan 清理（数据漂移 bug）

**问题**：`SessionScanner` 只走 `~/.codex/sessions/`，漏 `~/.codex/archived_sessions/`。Codex CLI 的 archive 命令把 rollout 从前者搬到后者，搬完之后这些会话在 dashboard 里消失。本机实测：14 个 archived 文件 vs 333 个 active 文件 —— 4% 的历史数据被静默丢弃。pacer 一直两路都扫（`importer.rs:337`），是我们漏的。

**`SessionScanner.scan(codexHome:)`**：
- 拆出 `walk(root:bucket:)` helper，外层循环 `[("sessions", "active"), ("archived_sessions", "archived")]` 各调一次
- `bucket` 字段语义改成 `"active" | "archived"`（之前是相对路径 `YYYY/MM/DD`，没人读）
- 目录不存在时 `walk` 直接返回空数组（archived_sessions/ 在新装系统上可能没有）

**`SessionFile.bucket`** 字段保留，注释改成 "Currently informational only"。`ImportEngine` 暂不基于 bucket 分流（pacer 也只是塞进 `import_state.source_bucket` 列做 audit）。

**Orphan 清理（`ImportEngine.persist`）**：archive 操作会让同一 session 出现两条 `import_state`：旧的 `sessions/...path`（mtime 不再变 → 永远 stale）和新的 `archived_sessions/...path`。每次 persist 后追加一条：
```sql
DELETE FROM import_state
WHERE session_id = ? AND source_path != ?
```
镜像 pacer 的 `importer.rs:784`。session_id 唯一索引确保只删 orphan，新写入的 row 永远保留。

**没动**：UI 不区分 active vs archived（pacer 也不区分）；session 表无 archived 列（`bucket` 只在内存态流转）。如果以后要加 "归档" 过滤再补 schema。

`swift build` clean (2.23s)。下次 scan 会自动把 14 个 archived rollouts 拉进 DB。

---

### Day-16 — Codex 配额卡 + reset 倒计时（数据已存在，纯 UI）

**起因**：`rate_limit_samples` 表里已经有最新 primary（5h）/secondary（weekly）窗口数据（live API + jsonl 两路），Dashboard 只画了 24h 的 used% 折线图，没人把"现在还剩多少"展示出来。pacer 在 menu-bar popup 里画 quota5h / quota7d 卡（`MenuBarPopup.tsx:247`），有 `formatRemainingDuration` 倒计时，是用户最常看的一项数据。

**Aggregator 新增**（`Core/Analytics/Aggregator.swift`）：
- `CodexQuotaSnapshot { primary, secondary }`，每个窗口是 `CodexQuotaWindow`，含 `bucket / sourceKind / planType / sampleAt / windowStart / resetsAt / usedPercent / remainingPercent`
- `secondsUntilReset(now:)` 和 `remainingTimePercent(now:)`（镜像 pacer 的 `computeRemainingTimePercent`，`MenuBarPopup.tsx:24`）
- `fetchCodexQuota(db:)` 用 `JOIN (SELECT bucket, MAX(sample_timestamp) ...)` 取每个 bucket 最新一行；不区分 source_kind，让 live 数据自然胜过 jsonl（最新的赢）
- 抽出 `parseTimestamp(_:)` helper 处理 ISO8601 fractional / plain / SQLite "yyyy-MM-dd HH:mm:ss" 三种格式，`fetchRateLimitHistory` 也改用，少 8 行重复
- `DashboardSnapshot` 加 `codexQuota: CodexQuotaSnapshot?`，`loadDashboard` 在 `provider != .claude` 时调用

**DashboardView**（`Features/Dashboard/DashboardView.swift`）：
- 在 KPI 行和 5h billing block 之间插 `codexQuotaSection`（gate：`providerFilter != .claude` 且 quota 至少有一个窗口）
- `quotaCard(window:title:)` 用 `TimelineView(.periodic(from: .now, by: 60))` 包裹，倒计时每分钟自动刷新（pacer 也是分钟分辨率，不用秒级抖动）
- `quotaTint(usedPercent:)` 三档：<50% 绿 / <80% 橙 / ≥80% 红
- `formatRemainingDuration(seconds:)` 紧凑格式：`1d 4h` / `3h 12m` / `47m` / `—`（已过期）
- 卡片底部小字 `Sample: live · 3m ago` 让用户看到数据新鲜度（live 还是 jsonl，多久前采样）

**为什么不直接用 BillingBlocks**：那是 Anthropic 5h 计费窗口（按消费聚合），跟 OpenAI 的 quota 窗口（按 plan 配额）是两个概念。Codex 没有"按消费 5h 重置"语义，只有"plan 配额按 sample 给的 resets_at 重置"。所以新做卡而不是复用 billing block UI。

**没动**：`BillingBlocks` 仍然只跑 Claude；live API 轮询不变；rate-limit history line chart 不变。

`swift build` clean (1.91s)。本机现成数据：primary 70% used，01:21 后 reset；secondary 31% used，下周 reset。

---

### Day-17 — Recent blocks list（数据已存在，纯 UI）

`BillingBlocks.Snapshot.recentBlocks` 早就 populated（last 3 days，去 gap，newest first），但 Dashboard 只渲染 currentBlock，剩下的全丢了。这次在 active block 卡下面挂一个紧凑列表（最多 8 行），每行：日期+模型 / cost / 总 token / 实际持续时间（first→last，不是 nominal 5h）/ event count。`recentHistory()` 把 currentBlock 滤掉避免重复。镜像 ccusage 的 `blocks` CLI 输出。

`swift build` clean。

### Day-18 — Subscription payoff KPI

`Core/Settings/SettingsStore.swift` 新增两个 scalar：`codexMonthlyUSD` / `claudeMonthlyUSD`（默认 0 = 隐藏 KPI）。`Snapshot` 同步加字段。Settings UI 加 "Subscription cost" section，两个数字框。

Dashboard `kpiRow` 第四格条件渲染：当当前 `providerFilter` 对应的 monthly 设置 >0，把 "Events" 替换成 "Payoff"（API value ÷ subscription cost，% 显示）。Color：<50% 灰、<100% 橙、≥100% 绿（已回本）。`provider == .all` 时把两边 monthly 加起来当分母。

镜像 pacer 的 `payoff_ratio`（`queries.rs:257`），但我们不持久化 subscription_profile 表，直接走 UserDefaults——pacer 那张表只有一行，schema 复杂度不值。

### Day-19 — Codex quota burn rate + 推断耗尽时间

Quota card 现在能告诉你"按这个速度多久烧到 100%"。`Aggregator.fetchBurnRates` 对每个 bucket 跑最近 60 min 样本的 least-squares 回归（`used_percent` vs minutes），返回 `%/min` 斜率。`CodexBurnRate.minutesUntilExhaustion(currentPercent:)` 线性外推到 100%。

UI 三档：
- ETA < 自然 reset → 红色 `flame.fill` + "Hits 100% in ~Xh at current pace"（这才是真要警觉的情况）
- ETA ≥ reset 但 burn 仍 >0.001%/min → 灰色 "Burn: +X.X%/h (n=N)"（信息不报警）
- 没有数据 / 斜率 ≈ 0 → 啥都不显示

pacer 没做这个（只有 quota_trend 折线图），算 ahead。需要至少 2 个间隔 30s 的样本才算，避免单点噪声。

### Day-20 — Notarization 流程

`Resources/CodexMonitor.entitlements`：hardened-runtime 必备（network.client + dyld-environment-variables，因为 shell out 到 codex CLI）。

`tools/notarize.sh`：先 re-sign（`--options runtime --timestamp --entitlements`），ditto 打包，`xcrun notarytool submit --wait`，stapler staple，`spctl --assess` 验。要求 keychain profile（`xcrun notarytool store-credentials codexmonitor-notary ...` 一次性配置）+ Developer ID Application 证书 + release build。

`build.sh` 没改，仍 ad-hoc——开发者本地构建不需要 Apple 账户。CI / release 走 `tools/notarize.sh`。`parity.md` notarization 行从 gap 升级 partial（脚本就绪、等证书）。

### Day-21 — Monthly tab（12-month 趋势 + MoM%）

`Aggregator.fetchMonthly(months:provider:)` 用 `strftime('%Y-%m', timestamp, ?)` 按本地月分桶，zero-fill 到 `months` 行。`MonthlyPoint { month, valueUSD, tokens, sessionCount }`，`session_count = COUNT(DISTINCT session_id)` 让跨月 session 在每个月各算一次。

DashboardView 新 `monthlySection`：纯 BarMark（绿色 70% opacity）+ X 轴 `.month(.narrow)` 标签 + 顶部 KPI 条显示当月 cost / sessions + MoM% delta badge（绿降橙升）。`monthOverMonthDelta` 当上月 0 时返回 nil 避免 +∞%。

ccusage `monthly.ts` 和 pacer `subscription_month` 都做了类似的事。我们只视化、不锚定订阅周期（pacer 用 billing_anchor_day 算自然月；我们用本地日历月，对个人用户够用）。

`swift build` clean (3.44s)。

### Day-22 — Menu bar 视觉清理 + scan errors 可点击

Day-21 build 后用户实测截图发现：

1. **0% used 的 additional limit 占整行**（截图里 GPT-5.3-Codex-Spark 一行 0%/绿/pace 0.00x）。`codexCLISection` 现在过滤 `usedPercent > 0.5` 才显示，剩下的折叠成 `"N idle limits (0% used)"` 灰色一行，hover 显示具体名字 list（`.help`）。
2. **`prolite` plan badge 没说自己是啥**，加了 `.help("OpenAI plan type reported by the rate-limit API")` tooltip。
3. **`50 error(s)` 红字看不到**。改成按钮 + popover：第一行解释（"多半是 pre-CLI-0.40 truncated header，没事"），下面 ScrollView 列前 100 个 error message（textSelection enabled，可复制），>100 显示 "... +N more"。`@State private var showingErrors = false` 触发。
4. **本来要修 Active 5h block / 5-hour 撞名 + 顶部 KPI 单行**——发现 binary 是 17:29 的旧版（源码已经到 17:38 但 .app 没重打），直接 `./build.sh debug` 重打包搞定。这俩问题在 Day-12 / Day-11 就修了，只是没 ship。

教训：每次 source 改完要么改进 build.sh 加 mtime 比较，要么在本地装个 fswatch 自动 rebuild。下次 release tooling 一起做。

`swift build` clean (2.36s)。`.build/CodexMonitor.app` 已重打包。

### Day-23 — 菜单栏重构：双 provider block

Day-22 build 后用户反馈：(1) 看不到 Claude 的 5h/7d 限额，(2) 整体凌乱（7 个独立 card 横排）。

**问题分析**：Claude 没有像 OpenAI `/account/rate_limits` 那种 API（Anthropic 只在 response header 里返回 `anthropic-ratelimit-*`，需要 SDK 拦截），所以无法显示真正的 "% used"。但能显示 (a) 5h **billing block** 进度（按消费滚动 5h 窗口，已有数据）+ (b) **last 7d 消费**（一句 SQL）作为 OpenAI 7d quota 的对位。

**重构**：菜单栏从 7 个并排 card 改成 **2 个 provider 大块**，每块自带 KPI 头 + quota 行：

- **Codex block（蓝）**：$total / sessions / tokens + plan badge + 5-hour / 7-day quota rows + idle limits 折叠行
- **Claude block（橙）**：$total / sessions / tokens + 5h block 行（complete with progress / projection）+ Last 7 days 行

**新增 SQL**（`Aggregator.fetchPerProviderStats`）：第二个查询 `WHERE timestamp >= datetime('now', '-7 days')` 按 provider 汇总 last7d cost/tokens，塞进 `ProviderStats.last7dValueUSD / last7dTokens`。两条 SQL 并行（一次 read tx 内）。

**UI 重构**（`MenuBarContentView`）：
- `providerBlock(label/accent/stats/tail)` 共享 chrome（圆角 + provider tint background）
- 顶部 KPI 行：左 `$total`（title2 monospaced bold），右 `N ses · M tokens`
- `tail: AnyView` 注入 provider 专属内容
- `codexQuotaInner`：plan capsule + QuotaRow × N + idle 折叠
- `claudeQuotaInner`：`Claude5hRow` + Last 7d 行
- `Claude5hRow` 取代 `AnthropicBlockMini`（去掉独立卡片背景，与 QuotaRow 视觉对齐：title + % 右对齐 / progress / footer 一行）
- `QuotaRow` 加 `accent` 参数（默认 `.accentColor`），% 数字现在用 tintColor 高亮（之前是 secondary 灰），footer 把 "pace 0.99x" 改成 "0.99x pace"
- 主体 width 从 340 → 360（双 block 内容更密）

**为什么不给 Claude 伪造 7d quota %**：用户之前问"Claude 没数字"，但 Anthropic Pro / Max 的额度是按"月度 message 数 + 月度独立 5h block 数"算的，跟 OpenAI 的 token quota 不同范式。用 measured spend（USD）当对位是诚实的：用户能直接判断 "我这周烧了多少钱"。Settings 里已有的 monthly subscription cost 可以将来推一个 "本周占月度 X%" 衍生指标，先不做。

`swift build` clean (4.66s)。`.app` 重打包，PID 84734。

## Day-24 — Claude OAuth `/api/oauth/usage` 接入 ✅

**触发**：用户提交 https://github.com/steipete/codexbar 作为新参考项目，要求"先思考一下，有什么是值得参考的"。分析后发现 CodexBar 调用 Anthropic 一个未公开但 `claude` CLI 在用的 OAuth 端点 `https://api.anthropic.com/api/oauth/usage`，能直接拿到 Pro/Max 计划的 5h / 7d / per-model 用量百分比 + extra_usage 溢出额。这直接推翻了我 Day-23 的设计前提（"Anthropic 没有 quota API"）。

**新增组件**：

- `Core/Claude/ClaudeUsageSnapshot.swift`：domain model（`fiveHour` / `sevenDay` / `sevenDayOpus` / `sevenDaySonnet` / `extraUsage` + tier 字符串）。每个 Window 都暴露 `paceRatio()` + `paceLabel()`，与 `RateLimitSnapshot.Window` 同形。
- `Core/Claude/ClaudeUsageClient.swift`：actor，凭据查找顺序 `~/.claude/.credentials.json` → Keychain `Claude Code-credentials`。HTTP 请求 header 带 `anthropic-beta: oauth-2025-04-20`。错误细分为 `noCredentials` / `unauthorized` / `insufficientScope` / `http` / `malformed` / `transport`，UI 据此给具体的修复提示。
- `Core/Claude/ClaudeUsagePoller.swift`：与 `RateLimitPoller` 同形（start/stop/updateInterval），auth-class 错误后退避到 30 分钟避免 keychain prompt 风暴。所有窗口都写入 `rate_limit_samples` 表，`source_kind = "claude_oauth"`，limit_name 区分 model（"opus" / "sonnet"）—— 复用现有 schema，零迁移。

**接线**：
- `AppEnvironment` 新增 `latestClaudeUsage` + `lastClaudeUsageError` 两个 `@Observable` 字段；`startBackgroundPolling()` 启动两个 poller；`refreshRateLimits()` 同时触发 Codex `readRateLimits` + Claude `pollOnce`。
- `MenuBarContentView.claudeQuotaInner` 重写为两条路径：有 OAuth 数据走 `claudeOAuthInner`（与 Codex block 完全对称：tier badge + QuotaRow × N + extra_usage 行），否则走 `claudeFallbackInner`（保留 Day-23 的 Claude5hRow + last 7d，外加一行用户可读的错误提示）。
- `QuotaRow` 重构：从绑定 `RateLimitSnapshot.Window` 改成接受原始 primitives（`usedPercent` / `resetAt` / `paceLabel`），并提供两个 convenience init 分别给 Codex / Claude，避免协议化。

**关键决定**：

1. **凭据优先级**：文件 → Keychain（不是反过来），因为文件读取无 prompt，对 99% 的 Claude Code 用户无感知。
2. **复用 `rate_limit_samples`**：不新建 `claude_usage_samples` 表，未来如果要做"两 provider 配额历史对比"直接 GROUP BY source_kind 即可。
3. **错误暴露**：Anthropic 403 + body 里含 "scope" 才标记为 `insufficientScope`，避免误诊；其他 403 当成普通 HTTP 错。

**已知限制**：
- 不刷新过期 token —— 那是 `claude` CLI 的活，过期 token 会触发 `unauthorized`，UI 提示用户 `claude login`。
- Free tier 的 `/usage` 响应字段大都缺失，OAuth 路径会 fallthrough 到 measured-spend 路径（这是设计内）。

---

## Day-25 — Pace 文案 + Keychain 策略 ✅

**触发**：CodexBar 借鉴清单的第二条。把"0.99x pace"这种工程师术语换成"On pace / X% in deficit / X% in reserve"，并给 Keychain 访问加一个用户可控的开关（防止 prompt 滋扰）。

**新增组件**：

- `Core/Models/QuotaPaceLabel.swift`：纯函数，输入 `usedPercent` + `paceRatio` + `timeUntilReset`，输出 `(text, severity)`：
  - `usedPercent < 3` → 返回 nil（冷启动信号不足，不打扰用户）
  - 0.85 ≤ ratio ≤ 1.15 → "On pace" + neutral
  - ratio > 1.15 → "X% in deficit · Runs out in 47m"（ETA 由 elapsed/used 反推 window 长度推算，落在 reset 之后则不显示 ETA），warning 或 danger
  - ratio < 0.85 → "X% in reserve" + good
- `RateLimitSnapshot.Window.paceLabel()` + `ClaudeUsageSnapshot.Window.paceLabel()`：两个 wrapper，统一调用上面的纯函数。
- `QuotaRow` 用 `paceLabel.text` 替代之前的 `String(format: "%.2fx pace", pace)`，颜色按 severity 选（`.secondary` / `.green` / `.orange` / `.red`）。

**Keychain 策略**：

- `SettingsStore.KeychainPolicy` 枚举：`.fallback`（默认，先文件再 Keychain）/ `.never`（完全不碰 Keychain）。持久化在 UserDefaults。
- `ClaudeUsageClient.loadAccessToken()` 在 fallback 前 check 这个策略。
- Settings → General → Claude Code 段新增 "Live quotas" Picker。说明文字解释了"我们先读文件、Keychain 是 GUI 应用的兜底（首次可能弹 prompt）"。

**未做的（CodexBar 借鉴清单的剩余项）**：

- A 级：浏览器 cookie 兜底、`extra_usage` 单独 KPI、Sparkle 自动更新 —— 暂缓。
- B 级：WidgetKit、status menu 轮询、多账号 —— 暂缓。
- 跳过：18-provider 范围、SwiftMacros、PTY runner、Linux CLI（与本项目"macOS menu bar，看自己的 Codex/Claude 用量"目标无关）。

## Day 26 — 2026-04-29 — Decoder snapshot tests + dropping `extra_usage`

**触发**：Day-25 之后菜单栏 Claude 数字一夜变成 5h=6000% / 7d=1200%。根因是 Anthropic 的 `/api/oauth/usage` 现在把 `utilization` 当百分数返回（60.0 = 60%），decoder 仍然 `*100` 当 0..1 比率处理，再加上 `extra_usage` 在线上一直 `is_enabled:false`，最近的兼容代码 silent 飘了一圈没人知道。审计完决定：把 `extra_usage` 整条路径砍掉（产品决定不展示按美元的溢出额）+ 给 decoder 上 snapshot test。

**做了什么**
- 新建 SPM testTarget `CodexMonitorTests` (`Tests/CodexMonitorTests/`)。`Package.swift` 加 `.testTarget` + `.copy("Fixtures")`。toolchain 是 CLT，没有 XCTest，用 `import Testing`（swift-testing）写。`swift test` 直接跑。
- `Tests/CodexMonitorTests/Fixtures/ClaudeUsage/` 五份 fixtures：
  - `live_pro_2026-04-29.json`：今天 curl 拿到的真实响应（已确认无 token / PII），`utilization` 是 0..100 的百分数。这就是 6000% 的金本位 fixture。
  - `synthetic_max5x.json`：Max5x tier，per-model Opus + Sonnet 都填满，验证 tier badge + per-model 路径。
  - `legacy_used_percent.json`：CodexBar 早期用 `used_percent` + `reset_at` 的老 shape。
  - `legacy_ratio.json`：更早期的 0..1 ratio shape（0.42 → 42%），固定 `<=1.5 → ratio` 启发式。
  - `free_tier_minimal.json`：只有 5h 的最小响应，验证 graceful degradation。
- `ClaudeUsageDecoderTests.swift` 11 个测试覆盖：percent vs ratio、ISO8601 with/without fractional、unknown 字段不报错、`extra_usage` 出现也被忽略、garbage JSON → `.malformed`、`{}` → 空 snapshot、null `resets_at` 安全降级。
- 验证有效性：临时把 decoder 改成 `raw * 100`（重现 6000% bug），跑 `swift test`，5/11 失败，错误消息直接打印 "abs((snap.fiveHour?.usedPercent ?? 0) - 60.0) → 5940.0"，回归会被立刻抓住。改回去再跑，11/11 通过。
- 删除 `extra_usage` 全链路：`ClaudeUsageClient.Wire.extra_usage` 字段、`ExtraWire` 内嵌 struct、`extra` 计算闭包、`ClaudeUsageSnapshot.Extra` 类型、`ClaudeUsageSnapshot.extraUsage` 字段、`MenuBarContentView` 里的 Pay-as-you-go 行（`Image(systemName: "creditcard")` 那块）。decoder 里加注释解释为什么不再 decode（产品决定 + 未来想加回来很容易）。

**为什么不写 XCTest**：CLT 不带 XCTest framework，`import XCTest` 直接 "no such module"。Swift 6 自带的 swift-testing 在 CLT 里有 `Testing.framework`，写出来的 `@Test` 函数同语义、跑得更快、Apple 推荐的新形态。

**TODO**：
- 加 CI 钩子让 `swift test` 在每次 push 跑（GitHub Actions 单文件就够，但还没启）。
- Anthropic 一旦真的把 `extra_usage` 接到 Claude Code 里展示，再开一个新 fixture + 重新接 wire。当前架构留了空，30 行代码就能补回来。

## Day 27 — 2026-04-29 — i18n: English + 简体中文，运行时热切

**触发**：用户要求支持中英文，默认英文，首次安装强制选语言。

**架构选择**
- `LocalizationStore`（@MainActor @Observable，单例）持 `language: Language?`，`nil` = 未完成 onboarding。`set(_:)` 同步写 UserDefaults `app.language` + bump `tickForceRedraw`。
- `L10n` enum 是全部可见字符串的注册表，~180 个键。每个键都是 `static var foo: String { t(en:..., zh:...) }`，参数化的写成 `static func bar(...) -> String`。`t()` 通过 `OSAllocatedUnfairLock` 守的 nonisolated 缓存读取，可以被任意 isolation 的代码（包括 View 初始化器）调用。
- 运行时热切的关键：所有顶层 Scene 都加 `.id(localization.tickForceRedraw)`。SwiftUI 看不到 `L10n.foo` 这种静态读，必须给它一个可观察的依赖才会重新求值整个 view tree。代价是切换瞬间会丢一次 view 内部的 `@State`（acceptable — 切语言不是高频操作）。
- 首启 onboarding：`MenuBarContentView.sheet(isPresented: .constant(loc.needsOnboarding))`。Sheet 没有关闭按钮，必须点 EN 或 中文 才能继续。两个按钮 / 标题都同时用本身的语言显示，避免"看不懂当前 UI 的人也找不到自己的语言"的反讽。

**为什么不用 String Catalog (.xcstrings)**
- 开发盒只有 CLT，没有完整 Xcode。`.xcstrings` 可以手编 JSON 但 SPM resource 流水线在 CLT-only 下不稳。
- Swift dict 类型安全：拼错 `L10n.refesh` 是编译错误。Find references 也能跑。
- 翻译面 ~180 字符串、单人翻译，没必要上 String Catalog 那套基建。如果以后真要上 App Store + 找翻译团队，把 `L10n.t` 实现替换成 String Catalog lookup 即可，调用点不动。

**为什么不改 `AppleLanguages`**
- `AppleLanguages` 是系统级的 NSLocalizedString 调度，需要重启进程才能生效。产品规格是"切换立刻见效，不重启菜单栏"，所以必须自己拉一套。

**改动范围**
- 新增：`Core/Localization/LocalizationStore.swift` (~80 行)、`Core/Localization/L10n.swift` (~360 行)、`Features/Onboarding/LanguageOnboardingView.swift` (~70 行)。
- `App/CodexMonitorApp.swift`：三个 Scene 全部注入 `localization` + `\.locale` + `.id(tick)`，MenuBar Scene 加 `.sheet`。
- 7 个视图全过：`MenuBarContentView` / `Dashboard` / `Sessions` / `SessionDetail` / `History` / `Settings` / `MainWindow`。SettingsView 重写过（顶部新增 Language section）。
- 三个 enum 的 `label` 属性也 i18n 了：`ProviderFilter`（Aggregator.swift）、`SessionSort`、`SettingsStore.KeychainPolicy`。
- `RelativeDateTimeFormatter` 在多处显式设 `f.locale = LocalizationStore.activeLanguage.locale`，否则系统会用进程的初始 locale，切语言不会刷新相对时间字符串。

**未译的部分（故意）**
- 专有名词：Codex / Claude / Anthropic / OpenAI / GPT / Opus / Sonnet / 模型 ID / Plan tier 字符串（Pro / Max5x / Free）/ "USD" / "USD/mo"。
- 短系统单位 token："h" "m" "d"（duration formatter 的 fragment）—— 在中文里也读得通，没必要做 if-else。
- 动态字符串：`Text(modelId)` / `Text(formatter.string(...))` / `Text(error.localizedDescription)` 等用户数据，本来就由数据源决定语言。

**TODO**
- 中文翻译是我手译的，有些术语（Token / 配额 / 套餐）可以再校一遍。
- LiteLLM 的 "live" / "local" / "seed" badge 翻译成 "实时 / 本地 / 内置" 后比英文窄了一点点，table 列宽可能要微调。看实际渲染再说。

---

## Day-26 — 0.2.0 修复打包 + Claude refresh 委派给 CLI ✅

**为什么这天单独成章**：今天连改了五个独立 bug，其中一个（Claude OAuth refresh）走错了路线、回滚后改成了完全不同的实现。这两段值得分开记，否则将来回头看 git log 会以为是一气呵成的。

### 上午：0.2.0 收尾的五个 bug

挨个列，因为每一个都是真的会让用户看不到数据的等级：

1. **codex 0.128 静默改 wire format**：`account/rateLimits/read` 从 snake_case 翻成了 camelCase（`rate_limit` → `rateLimits`、`primary_window` → `primary`、`limit_window_seconds` → `windowDurationMins`、`additional_rate_limits: [...]` → `rateLimitsByLimitId: {...}`）。所有 `Optional` 解码为 nil → snapshot 非 nil 但空 → 菜单栏永远显示"Sign in via codex CLI to see live quotas"。修法是 `RateLimitsPayload` / `RateLimitGroup` / `RateLimitWindow` 都加 custom `init(from:)` 同时吃两套字段。fixture 在 `Tests/.../Fixtures/RateLimits/` 里锁住。
2. **Claude CLI ≥ 2.1.x 不再把 refresh 写到磁盘**：老 CLI 每次刷 token 都改写 `~/.claude/.credentials.json`，新 CLI 只写 Keychain，文件冻在最后一次 `claude login`。`loadAccessToken` 优先读文件 → 拿到几周前过期的 token → 401 → 清 cache → 下次 poll 又读同一个文件 → 死循环。修法是 `readCredentialsFile` 解析 `expiresAt` (ms 时间戳，60s skew 容忍)，过期就返回 nil 让流程 fall through 到 Keychain 路径。
3. **GUI 启动的 codex 子进程拿不到 PATH**：launchd 给 GUI 进程的 `PATH` 是空的，`codex` 这种 `#!/usr/bin/env node` 的 npm 脚本起不来，只在 `Log.appServer` 里留下 `stream ended before id=init`。`AppServerClient.runSession` 改用 `augmentedEnvironment()` 显式拼 `/opt/homebrew/bin:/usr/local/bin:~/.npm-global/bin:~/.local/bin:~/.cargo/bin:~/.bun/bin` 在前面。
4. **codex stderr 之前是被静默吞掉的**：`Pipe` 创建了但从来没人读 → 所有 codex 崩溃 / shebang 失败 / 鉴权报错都进了黑洞。`runSession` 现在 spawn 一个 `Task.detached` 行行读 stderr 写到 `Log.appServer.error("stderr: …")`。
5. **`utilization` 单位混乱**：旧 CodexBar 抓包 `utilization` 是 0..1 ratio，新 Anthropic 已经返回百分比（60.0 = 60%）。decoder 加了启发式：`<=1.5` 当 ratio 乘 100，否则当百分比照搬。Day-25 一度出现 6000% 的乌龙就是这个。

`./build.sh` 自动注入 `Resources/VERSION`（0.2.0）+ git short SHA 进 Info.plist。源 plist 故意留 `0.0.0/0` 占位，让没经过 build.sh 的裸构建一眼就错。`tools/release.sh` 全流程检查 → swift test → release build → DMG → SHA-256 → 自检通过。`dist/CodexMonitor-0.1.0.dmg` 旧 artifact 也清掉了。

仓库今天才第一次 git init（之前 build.sh 的 `git rev-parse --short HEAD` fallback 永远是 "1"），初始 commit `999d6fa` 把 0.2.0 全部快照下来。`Package.resolved` 也提交了（lockfile，之前误 ignore），`dist/` 加进 ignore。

### 下午：Claude OAuth refresh 走错了路线又回头

**原始诉求**：用户报告"菜单栏一直说 Claude token rejected，但 `claude` CLI 自己跑得好好的"。原因是 CLI ≥ 2.1.x 不写文件、Keychain 里的 access token 也过期了 / RT 还在但没人去刷。

**第一版（错误的方向）—— 在 app 里自己 refresh 并写回两个 store**

- 加了 `performTokenRefresh`（POST `platform.claude.com/v1/oauth/token`，JSON body，`client_id=9d1c250a-…`）
- 加了 `writeCredentialsFile` + `writeKeychainCredentials`，refresh 成功后双写
- actor 内 `refreshInFlight: Task` 去重并发刷新
- `fetch()` 401 一次性重试

逻辑跑通了，57 → 62 测试全绿。但**真实运行时炸了两次**：

a) **测试代码 trample 了真实凭据**。`performTokenRefresh` 在 async Task 里读 `UserDefaults.standard["settings.claudeHome"]` 决定写哪里，测试在 `defer` 里清这个 override，race condition 让生产路径也吃了一次写 → 用户的 `~/.claude/.credentials.json` 被覆成测试数据 (`accessToken="shared"` 之类)。修法：把路径解析挪到任何 async boundary 之前，加 `claudeHomeOverride` 和 `skipKeychainWriteback` 显式参数注入。

b) **Refresh token 轮换的本质冲突无解**。Anthropic 的 OAuth 每次 refresh 都返回新 RT 并立刻吊销旧 RT。我们在 app 里 refresh 一次，CLI 持有的 RT 就死了；CLI 自己 refresh 一次，我们的 RT 就死了。谁先 poll 谁赢，输家坏 N 小时。今天的"重复 Keychain item"问题就是这个冲突的一个症状（之前的 in-app refresh 留下了 stale 副本）。

去查 [steipete/CodexBar](https://github.com/steipete/CodexBar) 的做法：他们也不写回 CLI 的 store，但是他们会自己 refresh CLI-owned 的 token；这个还是在抢 RT，只是比我们克制一点。**没有同时让两边都 refresh 又不抢 RT 的方案**。

**第二版（最终方向）—— 完全不 refresh，spawn `claude` 让 CLI 去 refresh**

- 删掉 `performTokenRefresh` / `refreshAccessToken` / `writeCredentialsFile` / `writeKeychainCredentials` / `mirrorTokenToFile` / `bestRefreshToken` / `OAuthRefreshResponse` / `refreshInFlight` / `fetchInternal(retryAfterRefresh:)` 的 401 retry 分支 / 整个 `ClaudeOAuthRefreshTests.swift`（5 测试）。
- 新增 `Core/Claude/ClaudeCLIRefreshTrigger.swift`：actor，spawn `claude --version`（augmented PATH），监听 `Claude Code-credentials` Keychain item 的 `kSecAttrModificationDate` ≤ 8s 看是否变化。in-flight Task 去重并发调用，5min → 1h 指数退避。
- `loadAccessToken` 现在双读 file + Keychain，谁不过期用谁；都过期就 await trigger，refresh 完再读一次。`fetch()` 401 也走同一条路。
- `readKeychainTokenOutcome` 借了 CodexBar 的"按 mdat 取最新"逻辑（`kSecMatchLimitAll` + `kSecAttrModificationDate` 排序 + 用 persistent ref 重新 fetch data），修了同名重复项 bug。
- 新增 `Tests/.../ClaudeCLIRefreshTriggerTests.swift` 4 测试：cooldown 触发、退避指数 + 1h 上限、coalescing、success-vs-mdat-no-change 语义。生产上的 `runClaudeCLI` 走真 Process，不在单测覆盖（real-machine smoke test 兜）。

最终 61/61 测试绿。

**收益**

- CLI 永远是 RT 的唯一持有者，再也没有 split-brain。
- 删了一大块代码 + 一类很难测的并发 bug。
- Keychain 只读没有写，ad-hoc cdhash 改了也只是多弹一次 Always Allow，不会把自己的 ACL 锁死。
- 用户报告 `claude CLI 还能用但 CodexMonitor 不行` 时，唯一原因只可能是 RT 真的死了 → 让用户跑 `claude login`，不可能是我们的代码问题。

**代价**

- 需要 `claude` CLI 在 PATH 上。但用户既然装了 Claude Code，CLI 本来就在；augmentedEnvironment 把常见 npm/homebrew 路径都拼上了。
- spawn `claude --version` 耗时几秒。Claude poll 是 2h 节奏，无所谓。
- 万一 CLI 卡住 / 挂掉，退避 5min → 1h 后才会再试。可接受。

**踩到的 trap & 留给将来**

- 测试用 `UserDefaults.standard` 重定向 home 是雷区。任何对 `UserDefaults.standard` 的 mutation 都必须在测试 actor 之外做、必须 `.serialized`，或者干脆改成显式参数注入（这次最终选了后者）。
- 如果 Anthropic 改 client_id / 切 PKCE-only，整套 OAuth 都得重写。但因为现在只有 CLI 在做这件事，我们零代码改动。
- 如果将来有用户机器上没装 `claude` CLI（只用 web 版），refresh trigger 会一直退避 1h。需要 UI 提示"装 CLI"，但目前数据来源本来就要求 CLI 给 `~/.claude/sessions/` 喂数据，所以这个场景大概率不存在。

### 文档 / 测试同步

- `CHANGELOG.md` 0.2.0 段落改写了"Added: Delegated Claude refresh to CLI"，删掉旧的"Automatic refresh"。
- `MEMORY.md`：`Claude OAuth refresh in-app` 改成 `Claude OAuth refresh delegated to CLI`；删掉 `test isolation` 那条；新增 `Keychain duplicate-item disambiguation`；老的 `mirrorTokenToFile` 那条 mark 为 deprecated 的描述。
- 测试数：57（0.2.0 修复后）→ 62（in-app refresh 阶段）→ 57（删掉 5 测试）→ 61（加回 4 trigger 测试）。

---

## Day-27 — 重命名 CodexMonitor → QuotaMonitor ✅

**触发**：0.2.0 收尾后做了一轮"项目里有什么"的全功能梳理，这名字已经不准了——产品早就同时支持 Codex 和 Claude，叫 Codex Monitor 容易让人以为只看 Codex。试了几轮（TokenMeter / AgentMeter / Folio / TokenBar 等），最后定 **QuotaMonitor**（菜单显示带空格 "Quota Monitor"），bundle id 改成 `dev.tjzhou.QuotaMonitor`。

**改动范围**

代码：
- `Package.swift` name + target + path + 测试 target 全改名。
- 10 个 `Tests/.../*Tests.swift` 的 `@testable import CodexMonitor` → `QuotaMonitor`。
- `App/CodexMonitorApp.swift`：`struct` 改名 + 两个 Scene 的 visible title（"Codex Monitor" → "Quota Monitor"）。**注意 init 顺序**：`@State` 默认表达式在 `init()` body 之前求值，所以把 store 们改成 `_xxx = State(wrappedValue: ...)` 形式，确保 `UserDefaultsMigration.runIfNeeded()` 第一个跑，再让 `LocalizationStore.shared` 等 singleton 去读 UserDefaults。否则迁移就赶不上 trunk。
- `Core/Log.swift`：subsystem 改 + 顺手加了 `storage` category（DB 迁移的日志走它）。
- `Core/Storage/DatabaseManager.swift`：默认路径从 `CodexMonitor/codexmonitor.sqlite` 改成 `QuotaMonitor/quotamonitor.sqlite`，新增 `migrateLegacyDatabaseIfNeeded`：先检查新文件是否已存在（幂等闸），不在就把旧的 `.sqlite + -wal + -shm` 三件套依次 `moveItem`，最后试着把空目录删掉。注意顺序——先搬 .sqlite 再搬 wal/shm，万一中途崩了 WAL 留在原地是无害的（没有主 DB 它谁都解读不了）。
- `Core/Settings/UserDefaultsMigration.swift`（新文件）：用 `CFPreferencesCopyKeyList(legacyBundleID, …)` 列出旧 plist 所有 key，逐个 `CFPreferencesCopyAppValue` 抄到新 domain，前提是新 domain 还没值（不覆盖用户在新版本里手动改过的设置）。一次性 guard key 写在新 domain，下次启动直接 short-circuit。
- 几个零散字符串：`ScanController` NSError domain、`L10n.settingsTitle`、`MenuBarContentView` 顶部 logo、Onboarding "Welcome to" 双语行、`ClaudeUsageClient` User-Agent header、`LocalizationStore` 注释里的 `defaults delete` 命令示例。

资源 & 脚本：
- `Resources/Info.plist`：`CFBundleExecutable` / `CFBundleIdentifier` / `CFBundleName` / `CFBundleDisplayName` 全换。
- `Resources/CodexMonitor.entitlements` → `QuotaMonitor.entitlements`（git mv，注释里的产品名顺手改）。
- `build.sh` `APP_NAME`、`tools/notarize.sh`（APP_BUNDLE/PROFILE/ENTITLEMENTS 默认值）、`tools/make-dmg.sh`（APP/NAME/VOLNAME + AppleScript 里的 icon 引用）、`tools/make-dmg-bg.swift`（installer 标题文案）、`tools/release.sh`（DMG_PATH/APP_BUNDLE/INSIDE_APP/sha 文件名/release notes title）。

文档：
- `README.md` 顶部加 rename banner，下面 s/CodexMonitor/QuotaMonitor/g（含 Layout 树里的 `App/QuotaMonitorApp.swift`、`Resources/QuotaMonitor.entitlements`、subsystem、log categories +storage）。
- `CHANGELOG.md` 顶上加 `[Unreleased]` 段说明改名 + 自动迁移；0.2.0 段保持原样（历史是 CodexMonitor 出厂的）。
- `docs/parity.md` 表头列名 + entitlements 文件名引用。
- `docs/progress.md`（本文件）：里程碑表加 Day-27 行；header 改名加箭头。
- `docs/findings.md` / `docs/project-survey-2026-04-30.md`：作为历史快照不动。

目录：
- `git mv CodexMonitor QuotaMonitor`、`git mv QuotaMonitor/App/CodexMonitorApp.swift QuotaMonitorApp.swift`、`git mv Tests/CodexMonitorTests Tests/QuotaMonitorTests`、`git mv Resources/CodexMonitor.entitlements Resources/QuotaMonitor.entitlements`。
- 外层（git 仓之外）：`mv codexmonitor/CodexMonitor codexmonitor/QuotaMonitor` → `mv codexmonitor quotamonitor`。

**踩到的 trap**

- SwiftUI `@State private var foo = X.shared` 的默认值表达式比 `init()` body 早跑。第一次写迁移调用就直接放在 init 里，结果意识到 LocalizationStore singleton 已经被构造了——读到的还是空 plist。改成在 init 里手动 `_foo = State(wrappedValue: ...)` 才对。
- 旧 `/Applications/CodexMonitor.app` 还在跑（pgrep 显示 PID 43320）。如果不先 pkill 就改 DB 路径，迁移 helper 会去搬一个 SQLite 还在 hold 的 WAL，得到的新文件会 corrupt。pre-flight 第一步必须 kill。

**收益**

- 名字终于和功能匹配，Anthropic + OpenAI 双 provider 不再被 Codex 一家代言。
- `dev.tjzhou.QuotaMonitor` 是个干净 bundle id，Keychain ACL 清空、UserDefaults 是新 plist——一切起点都是显式的。
- 顺带加了 `Log.storage` category，DB 操作日志独立一档。

**用户手动收尾（agent 不替代做）**

- `rm -rf /Applications/CodexMonitor.app`（旧装的菜单栏 app，已被 pkill；自动迁移把数据搬走了，删了无害）。
- 等确认新 app 跑稳后：`defaults delete dev.tjzhou.CodexMonitor`（旧 plist 留着也只是占几 KB）。
- `cp -R .build/QuotaMonitor.app /Applications/` 把新 app 装回 /Applications。

---

## Day-28 — Developer Mode + refresh fan-out 对齐 ✅

**触发**：0.2.15 把首启扫描和大 JSONL 解析路径补强后，运行期问题还缺一个低摩擦取证面。普通 `OSLog` 适合实时 `log stream`，但不适合用户复现后把一段本地运行轨迹交给开发者分析。

**Developer Mode**

- 新增 `Core/DeveloperFileLogger.swift`：actor 串行追加纯文本日志，默认路径 `~/Library/Application Support/QuotaMonitor/Logs/quotamonitor-dev.log`。默认关闭；只有 Settings → Advanced → Developer Mode 开启后才写，切换动作本身强制写一行，方便确认开关确实生效。
- Settings → Advanced 新增 Developer Mode section：开关、说明、可复制日志路径、Reveal Log File 按钮。文件不存在时按钮会先创建父目录并打开目录。
- `SettingsStore` 增加 `developerModeEnabled` 持久化键和 `snapshot(defaults:)` 测试入口；新增 `DeveloperModeTests` 覆盖默认值、UserDefaults round-trip、snapshot 携带字段、关闭时不建文件、开启时创建父目录并追加、换行转义。
- 记录面覆盖 app lifecycle、poller start/stop、Codex/Claude refresh、Claude CLI token refresh、scan progress、LiteLLM pricing、query facade、legacy DB/UserDefaults migration、CSV export、uninstall target/recycle、window activation policy。

**Refresh fan-out / UI 行为**

- `AppEnvironment.refreshAll(throttle:)` 成为唯一 fan-out：Codex rate limits、Claude usage、本地 JSONL scan 同一路径。Popover-open 传 `throttle: true`，Refresh 按钮和 cold launch 传 `false`。
- `QuotaMonitorApp` cold launch 现在直接跑 `refreshAll(false)`，再额外 `refreshDashboard()` 暖缓存；老用户不需要先点开菜单栏才会扫描最新本地数据。
- `MenuBarContentView` 从 `scenePhase` 改成 `.onAppear` 触发自动刷新。`MenuBarExtra(.window)` 每次打开都会重挂内容；`scenePhase` 是全 app 级别，之前不会随菜单弹窗开合变化。
- Refresh 按钮不再因为被动 auto-refresh 的 `isScanning || isRefreshingRateLimits` 状态而变成 "Refreshing..." 或禁用；扫描进度统一由 `ScanStatusView` 的线性进度条表达，底层方法各自保留 re-entrancy guard。
- MainWindow toolbar Reload 改成 bump `reloadToken` 并折进 inner view `.id(...)`，Dashboard / History / Sessions 当前 tab 都会重挂并重新跑自己的 `.task`，不再只有 Dashboard 有效。

**文档同步**

- README：Settings、Layout、日志分类、Developer Mode 路径、当前限制标题同步。
- CHANGELOG：`[Unreleased]` 补 Developer Mode、refresh fan-out、popover-open hook、Reload 行为。
- `docs/parity.md`：logging / settings 行补持久化 Developer Mode。
- `docs/project-survey-2026-04-30.md`：追加当前状态，避免继续引用旧的 CodexMonitor 路径、旧测试数、旧 refresh 触发点。

---

## Day-29 — 配额进度条复查 + app-only fallback + 发版文档 ✅

**触发**：用户反馈菜单栏 quota progress bar 一直不更新，并追问 Claude 是否也有类似问题、如果用户没有安装 CLI 只装桌面 App 能不能解决。修复过程分成三类：Codex 二进制解析、Claude 凭据/刷新路径、以及菜单栏/构建稳定性。

**Codex 根因与修复**

- 真实问题不是 progress bar UI 本身，而是 live quota poller 没拿到新样本。GUI 启动的 App 先选到了 `/opt/homebrew/bin/codex`，这个 shim 可执行但内部 vendor binary 已缺失；用户终端里的工作版本其实在 nvm 路径下。
- `AppServerClient.resolveBinary` 现在顺序为：`CODEX_BINARY` → login shell 的 `command -v codex` → 用户目录常见 bin → `~/Applications/Codex.app/Contents/Resources/codex` → `/Applications/Codex.app/Contents/Resources/codex` → Homebrew / `/usr/local` fallback。
- 本机额外验证了 Codex desktop app-only 路径：`/Applications/Codex.app/Contents/Resources/codex` 报 `codex-cli 0.133.0-alpha.1`，直接 `app-server` 调 `account/rateLimits/read` 成功，返回 `planType=pro`、5h/7d used percent。

**Claude 根因与修复**

- Claude CLI 本身不是坏 binary；问题在 Keychain 路径。直接用 Security.framework 读 `Claude Code-credentials` 的 data 时，后台 poller 可卡在 `SecItemCopyMatching`，表现就是 UI 一直等不到新 quota。
- `ClaudeUsageClient` 的生产 Keychain fallback 改成 `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`，带 2 秒 timeout；如果需要交互，就把 Keychain 视为 unavailable，而不是让 poller 挂死。
- `ClaudeCLIRefreshTrigger` 现在和 Codex 一样优先用 login-shell `claude`，再看用户目录安装；如果没有独立 CLI，会查 Claude Desktop 下载的原生 Claude Code helper：
  `~/Library/Application Support/Claude/claude-code/<version>/claude.app/Contents/MacOS/claude`。
- 重要边界：纯 Claude Desktop 登录不等于 Claude Code OAuth 凭据。Claude Desktop 自己的 `oauth:tokenCache` 在 `~/Library/Application Support/Claude/config.json`，由 Electron safeStorage 加密并依赖 `"Claude Safe Storage"` Keychain item。当前 QuotaMonitor 不解这个 cache，也不把它算成 live quota 来源。

**菜单栏与构建**

- `MenuBarExtra(.window)` 加 `.windowResizability(.contentSize)`，`MenuBarContentView` 加 `.fixedSize(horizontal:false, vertical:true)`，避免 macOS 保留旧高度导致空白带。
- `build.sh` 在有 Swiftly 时先 source `~/.swiftly/env.sh`，并给 SwiftPM 加 `--disable-keychain`，规避 CLT-only manifest/toolchain mismatch 和公开依赖解析时的 Keychain stall。

**文档同步**

- `CHANGELOG.md`：把 0.2.25 发版说明补全，包括 app-only fallback、非交互 Keychain、菜单栏尺寸、构建稳定性和 Claude Desktop auth 边界。
- `README.md`：新增 Provider data sources，明确 Codex app-only 支持、Claude Code 凭据要求、纯 Claude Desktop safeStorage cache 不读取；Current limitations 里删掉过时的 "No auto-update"。
- `docs/findings.md`：追加 2026-05-23 desktop app-only probes、Keychain hang 结论和新的风险项。
- `docs/parity.md` / `docs/release.md` / `docs/project-survey-2026-04-30.md`：同步最新 resolver、Sparkle/release 流程和测试数量。

**验证**

- `swift test --disable-keychain`：160 tests / 22 suites passed。
- `git diff --check`：通过。
- `./build.sh debug`：通过，已重装并启动 `/Applications/QuotaMonitor.app`。
- DB 验证：`rate_limit_samples` 有新的 Codex live 样本（北京时间 2026-05-23 15:01:32，5h=16%、7d=52%）；Claude latest oauth 样本保持 2 小时 cadence，符合设计。
