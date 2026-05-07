import Foundation

/// All UI-visible strings, keyed by terse English identifiers.
///
/// **Read this before adding a new string.**
///
/// Call site: `Text(L10n.refresh)` (NOT `Text("Refresh")`). This is
/// enforced by review, not by the compiler — there's no way to make
/// SwiftUI's `Text(verbatim:)` reject English literals at build time.
///
/// **How to add a new string.**
/// 1. Add a static property below in the right `MARK` group.
/// 2. Translate it on the same line via the `t(en:zh:)` helper.
/// 3. If the string takes runtime values, make it a static `func`
///    returning `String` and use Swift string interpolation. Translators
///    can reorder placeholders by writing the args in any position.
///
/// **Why a Swift dict, not String Catalog.** See `LocalizationStore.swift`.
///
/// **Mistyping `L10n.refesh` is a compile error.** That's the whole point.
enum L10n {

    // MARK: - generic actions / verbs

    static var refresh: String { t(en: "Refresh", zh: "刷新") }
    /// In-progress label for the unified Refresh button: covers both the
    /// rate-limit fetch and the local file rescan that run as one action.
    static var refreshing: String { t(en: "Refreshing…", zh: "刷新中…") }
    static var reload: String { t(en: "Reload", zh: "重新加载") }
    static var openDashboard: String { t(en: "Open Dashboard", zh: "打开仪表盘") }
    static var settingsMenuItem: String { t(en: "Settings…", zh: "设置…") }
    static var quit: String { t(en: "Quit", zh: "退出") }
    static var copy: String { t(en: "Copy", zh: "复制") }
    static var copyAll: String { t(en: "Copy all", zh: "全部复制") }
    static var copied: String { t(en: "Copied", zh: "已复制") }
    static func copyTooltip(lines: Int) -> String {
        t(en: "Copies all \(lines) line(s) to the clipboard",
          zh: "将全部 \(lines) 行复制到剪贴板")
    }
    static func errorCount(_ n: Int) -> String { t(en: "\(n) error(s)", zh: "\(n) 个错误") }
    static var loading: String { t(en: "Loading…", zh: "加载中…") }
    static var loadingDashboard: String { t(en: "Loading dashboard…", zh: "正在加载仪表盘…") }
    static var noData: String { t(en: "No data yet", zh: "暂无数据") }
    static var noDataLower: String { t(en: "no data yet", zh: "暂无数据") }
    static var clear: String { t(en: "Clear", zh: "清除") }
    static var choose: String { t(en: "Choose…", zh: "选择…") }

    // MARK: - menu bar

    static var codex: String { "Codex" }                 // proper noun
    static var claudeCode: String { "Claude Code" }      // proper noun
    static var claude: String { "Claude" }               // proper noun

    static var quotaCardTitle5h: String { t(en: "5-hour", zh: "5 小时") }
    static var quotaCardTitle7d: String { t(en: "7-day", zh: "7 天") }
    static var quotaCardTitle7dOpus: String { t(en: "7-day · Opus", zh: "7 天 · Opus") }
    static var quotaCardTitle7dSonnet: String { t(en: "7-day · Sonnet", zh: "7 天 · Sonnet") }

    static var helpClaudeTierBadge: String {
        t(en: "Claude plan tier reported by /api/oauth/usage",
          zh: "由 /api/oauth/usage 报告的 Claude 套餐等级")
    }
    static var codexSignInPrompt: String {
        t(en: "Sign in via codex CLI to see live quotas",
          zh: "通过 codex CLI 登录以查看实时配额")
    }
    static var claudeStartTracking: String {
        t(en: "Run a Claude Code session to start tracking",
          zh: "运行 Claude Code 会话以开始跟踪")
    }
    static var no5hBlockActive: String {
        t(en: "No active 5h block", zh: "当前无活跃的 5 小时窗口")
    }
    static var last7Days: String { t(en: "Last 7 days", zh: "近 7 天") }
    /// Caption above the menu bar's headline $ — clarifies the figure is a
    /// rolling N-day API-equivalent total, not the user's actual bill.
    /// User picks the window (7 vs 30 days) in Settings → General.
    static func headlineApiEquivalent(_ window: HeadlineWindow) -> String {
        switch window {
        case .last7d:
            return t(en: "Last 7 days · API equivalent",
                     zh: "近 7 天 · 按 API 计费")
        case .last30d:
            return t(en: "Last 30 days · API equivalent",
                     zh: "近 30 天 · 按 API 计费")
        }
    }
    /// Tooltip on the same headline, in case "API equivalent" is unclear.
    /// Wording is window-agnostic — only the period in the caption changes.
    static var headlineApiEquivalentHelp: String {
        t(en: "What these tokens would have cost if billed at API list price. Not what you actually paid for your subscription.",
          zh: "如果按 API 标价计费，这些 Token 会花掉的金额。并不是你订阅实际支付的费用。")
    }
    /// Settings UI: section header + picker label + per-option labels for
    /// the rolling-window switch that drives the menu bar's headline KPI.
    static var sectionMenuBar: String { t(en: "Menu bar", zh: "菜单栏") }
    static var menuBarHeadlineWindowLabel: String {
        t(en: "Headline window", zh: "汇总时间窗口")
    }
    static var menuBarHeadlineWindowHelp: String {
        t(en: "Time horizon for the headline $ + tokens line and the session count on each provider block.",
          zh: "每个 Provider 卡片上金额、Token 数与会话数所采用的时间范围。")
    }
    static func headlineWindowLabel(_ window: HeadlineWindow) -> String {
        switch window {
        case .last7d:  return t(en: "Last 7 days",  zh: "近 7 天")
        case .last30d: return t(en: "Last 30 days", zh: "近 30 天")
        }
    }

    static var errClaudeNoCreds: String {
        t(en: "Sign in with `claude login`, or disable live quotas in Settings",
          zh: "请运行 `claude login` 登录，或在设置中关闭实时配额")
    }
    static var errClaudeMissingScope: String {
        t(en: "Claude token missing `user:profile` scope — re-run `claude login`",
          zh: "Claude token 缺少 `user:profile` 权限 — 请重新运行 `claude login`")
    }
    static var errClaudeUnauthorized: String {
        t(en: "Claude token rejected — re-run `claude login`",
          zh: "Claude token 被拒绝，请重新运行 `claude login`")
    }
    static var errClaudeUnavailable: String {
        t(en: "Live Claude quotas unavailable (hover for details)",
          zh: "实时 Claude 配额不可用（悬停查看详情）")
    }
    /// Shown when Anthropic returns HTTP 429. The poller is already
    /// backing off — this is purely informational so the user knows it
    /// will auto-recover, not a misconfig they need to fix.
    static var errClaudeRateLimited: String {
        t(en: "Anthropic rate-limited the /usage endpoint — backing off, will retry automatically",
          zh: "Anthropic 对 /usage 接口限速了，已自动延迟下次轮询")
    }

    // Provider summary chip rendered in the top-right of each provider
    // block. Sessions only — token count moved into the headline next
    // to USD on 2026-05-06.
    static func providerSessionCount(_ n: Int) -> String {
        t(en: "\(n) sessions", zh: "\(n) 会话")
    }
    /// Headline secondary chip: "· 725M tokens" / "· 725M Token"
    /// rendered next to the USD figure. Compact-name notation handled
    /// by the caller (so the digits + scale suffix sit in one Text and
    /// stay monospaced together).
    static func headlineTokensSuffix(_ formattedCount: String) -> String {
        t(en: "· \(formattedCount) tokens",
          zh: "· \(formattedCount) Token")
    }
    static var lastScan: String { t(en: "Last scan", zh: "上次扫描") }
    static func scanSummary(scanned: Int, changed: Int, events: Int) -> String {
        t(en: "\(scanned) files · \(changed) changed · \(events) events",
          zh: "\(scanned) 文件 · \(changed) 变更 · \(events) 事件")
    }
    static var noScanYet: String { t(en: "No scan yet", zh: "尚未扫描") }
    static var scanErrors: String { t(en: "Scan errors", zh: "扫描错误") }
    static func errorTotal(_ n: Int) -> String {
        t(en: "\(n) total", zh: "共 \(n) 条")
    }
    static var scanErrorsExplain: String {
        t(en: "Files that failed to import on the last scan. Most are pre-CLI-0.40 rollouts with truncated headers — safe to ignore unless they correspond to active sessions.",
          zh: "上次扫描中导入失败的文件。大多数是 CLI 0.40 之前的旧 rollout（头部被截断）— 除非对应活跃会话，否则可以忽略。")
    }
    static func moreTruncated(_ n: Int) -> String {
        t(en: "… +\(n) more (truncated)", zh: "… 还有 \(n) 条（已截断）")
    }
    static func fiveHBlockState(active: Bool) -> String {
        active ? t(en: "5h block · active", zh: "5 小时窗口 · 活跃")
               : t(en: "5h block · last",   zh: "5 小时窗口 · 上次")
    }
    static func minutesLeft(_ formatted: String) -> String {
        t(en: "· \(formatted) left", zh: "· 剩余 \(formatted)")
    }
    static func burnPerHour(_ rate: Double) -> String {
        t(en: String(format: "· $%.2f/h", rate),
          zh: String(format: "· $%.2f/小时", rate))
    }
    /// Quota row label shown when the snapshot's window has already
    /// passed its `resets_at` but the next poll hasn't fired yet (Claude
    /// background poller is on a 2h cadence with a 30 min minimum gap, so
    /// a 5h window can sit on a stale 100% reading for almost 2 hours
    /// after it actually reset). We don't fake new numbers — we just
    /// gray out the row and tell the user fresh data is on the way.
    static var quotaRowStaleLabel: String {
        t(en: "Refreshing — window reset",
          zh: "已重置 · 等待刷新")
    }

    // MARK: - pace verdict (used by QuotaPaceLabel)
    //
    // The pace label sits next to each quota row and translates burn-rate
    // into one short sentence. Three shapes (EN / ZH):
    //   - "On pace"                              / "节奏正常"
    //   - "27% in deficit · Runs out in 47m"     / "超出节奏 27% · 预计 47分后耗尽"
    //   - "39% in reserve"                       / "慢于节奏 39%"
    // Numbers are integers (already rounded at the call site). The deficit
    // template exists in two variants because the ETA suffix is optional.

    static var paceOnPace: String { t(en: "On pace", zh: "节奏正常") }
    static func paceDeficit(percent: Int) -> String {
        t(en: "\(percent)% in deficit", zh: "超出节奏 \(percent)%")
    }
    static func paceDeficitRunsOut(percent: Int, eta: String) -> String {
        t(en: "\(percent)% in deficit · Runs out in \(eta)",
          zh: "超出节奏 \(percent)% · 预计 \(eta)后耗尽")
    }
    static func paceReserve(percent: Int) -> String {
        t(en: "\(percent)% in reserve", zh: "慢于节奏 \(percent)%")
    }

    // MARK: - duration units (single-letter, used inline like "2d 14h")
    //
    // Kept as separate L10n keys (not hard-coded) so Chinese can use the
    // CJK forms 天/小时/分 instead of the English-style "d/h/m" letters.
    // Composed by `QuotaPaceLabel.formatDuration` and any other place that
    // wants a compact "Nd Nh Nm" rendering.

    static var unitDayShort: String { t(en: "d", zh: "天") }
    static var unitHourShort: String { t(en: "h", zh: "小时") }
    static var unitMinuteShort: String { t(en: "m", zh: "分") }
    static func resetsRelative(_ relative: String) -> String {
        // The `relative` argument comes from `RelativeDateTimeFormatter`
        // which produces locale-native chrome ("in 23 min" / "23 分钟后").
        // The English template prepends "Resets" to "in 23 min" → reads
        // naturally. The Chinese template appends "重置" after the
        // already-suffixed "后" → reads naturally. Don't combine these
        // into a fixed-position template — the relative string carries
        // its own preposition direction.
        t(en: "Resets \(relative)", zh: "\(relative)重置")
    }

    // MARK: - dashboard

    static var dashboardTitle: String { t(en: "Dashboard", zh: "仪表盘") }
    static var sessions: String { t(en: "Sessions", zh: "会话") }
    static var history: String { t(en: "History", zh: "历史") }
    static var providerAll: String { t(en: "All providers", zh: "全部 Provider") }
    static var providerCodex: String { "Codex" }
    static var providerClaude: String { "Claude" }

    // MARK: - dashboard / forecast section

    static var forecastSectionTitle: String { t(en: "Forecast", zh: "预测") }
    static var forecastNoCodexQuota: String {
        t(en: "Sign in via codex CLI to see live 5h / 7d quota.",
          zh: "通过 codex CLI 登录以查看实时 5 小时 / 7 天配额。")
    }
    static var forecastNoClaudeQuota: String {
        t(en: "Run a Claude Code session to see the active 5h block.",
          zh: "启动一个 Claude Code 会话以查看活跃的 5 小时窗口。")
    }
    /// Compact pace line for Claude (we have $/hr and tokens/min).
    static func forecastPaceClaude(costPerHr: Double, tokensPerMin: Double) -> String {
        t(en: String(format: "Pace ~$%.2f/hr · ~%@ tok/min",
                     costPerHr, formatCompact(tokensPerMin)),
          zh: String(format: "节奏 ~$%.2f/小时 · ~%@ Token/分",
                     costPerHr, formatCompact(tokensPerMin)))
    }
    /// Compact pace line for Codex (we only have %/h).
    static func forecastPaceCodex(percentPerHr: Double) -> String {
        t(en: String(format: "Pace ~%+.1f%%/hr", percentPerHr),
          zh: String(format: "节奏 ~%+.1f%%/小时", percentPerHr))
    }
    static func forecastHits100In(_ relative: String) -> String {
        t(en: "hits 100% in ~\(relative)", zh: "~\(relative)将达 100%")
    }
    static func forecastResetsIn(_ relative: String) -> String {
        t(en: "resets in \(relative)", zh: "\(relative)后重置")
    }

    private static func formatCompact(_ v: Double) -> String {
        v.formatted(.number.notation(.compactName))
    }

    static var kpiSessions: String { t(en: "Sessions", zh: "会话数") }
    static var kpiTokens: String { t(en: "Tokens", zh: "Token 数") }
    static var kpiEvents: String { t(en: "Events", zh: "事件数") }

    /// Dashboard headline statline: "Last N days · $X · Yk tokens · Z sessions"
    /// Window matches the menu bar's headline window so the user sees one
    /// consistent period across the whole app.
    static func dashboardHeadlineStatline(window: HeadlineWindow,
                                          usd: String,
                                          tokens: String,
                                          sessions: Int) -> String {
        let period = headlineWindowLabel(window)
        return t(en: "\(period) · \(usd) · \(tokens) tokens · \(sessions) sessions",
                 zh: "\(period) · \(usd) · \(tokens) Token · \(sessions) 会话")
    }
    static func dashboardHeadlineStatlineEmpty(window: HeadlineWindow) -> String {
        let period = headlineWindowLabel(window)
        return t(en: "\(period) · no usage yet",
                 zh: "\(period) · 暂无使用记录")
    }

    static var clickScanHint: String {
        t(en: "Click Scan in the menu bar to import sessions.",
          zh: "在菜单栏点击 Scan 以导入会话。")
    }

    static var modelsInSession: String { t(en: "Models in this session", zh: "本会话使用的模型") }
    static var modelsUsedToday: String { t(en: "Models used today", zh: "今日使用的模型") }

    static var last30Days: String { t(en: "Last 30 days", zh: "近 30 天") }

    // MARK: - dashboard / trends section

    static var trendsSectionTitle: String { t(en: "Trends", zh: "趋势") }
    static func trendsTodayShort(_ usd: String) -> String {
        t(en: "Today \(usd)", zh: "今日 \(usd)")
    }
    static func trends7dShort(_ usd: String) -> String {
        t(en: "7d \(usd)", zh: "近 7 天 \(usd)")
    }
    static func trends30dShort(_ usd: String) -> String {
        t(en: "30d \(usd)", zh: "近 30 天 \(usd)")
    }
    /// "(Δ vs prior 30d +12%)" / "(Δ vs prior 30d -8%)"
    static func trendsDeltaPriorMonth(percent: Double) -> String {
        let sign = percent >= 0 ? "+" : ""
        return t(en: String(format: "(Δ vs prior 30d %@%.0f%%)", sign, percent),
                 zh: String(format: "（环比近 30 天 %@%.0f%%）", sign, percent))
    }

    // MARK: - dashboard / composition section

    static var compositionSectionTitle: String { t(en: "Composition", zh: "构成") }
    static var compositionTopModels: String {
        t(en: "Top models · last 30 days", zh: "Top 模型 · 近 30 天")
    }
    static var compositionByProvider: String {
        t(en: "By provider · last 30 days", zh: "按 Provider · 近 30 天")
    }
    static var compositionNoSpend: String {
        t(en: "No spend recorded in the last 30 days.",
          zh: "近 30 天未记录到任何花费。")
    }
    /// Auto-insight sentence shown beside the donut. We surface it only
    /// when the dominant model has both >0 current spend and a defined
    /// prior-period baseline. `pp` is the percentage-point delta of the
    /// model's share-of-spend vs the prior 30 days.
    static func compositionInsightWithDelta(model: String, percent: Double, pp: Double) -> String {
        let sign = pp >= 0 ? "+" : ""
        return t(en: String(format: "%@ = %.0f%% of spend, %@%.0fpp vs prior 30d",
                            model, percent, sign, pp),
                 zh: String(format: "%@ 占花费 %.0f%%，环比 %@%.0fpp",
                            model, percent, sign, pp))
    }
    static func compositionInsightFlat(model: String, percent: Double) -> String {
        t(en: String(format: "%@ = %.0f%% of spend over the last 30 days",
                     model, percent),
          zh: String(format: "%@ 近 30 天占花费 %.0f%%",
                     model, percent))
    }
    static func eventsCount(_ n: Int) -> String {
        t(en: "\(n) events", zh: "\(n) 事件")
    }
    static func tokensCount(_ s: String) -> String {
        t(en: "\(s) tokens", zh: "\(s) Token")
    }

    // MARK: - chart axis labels (visible in tooltips/legends)
    static var chartAxisDay: String { t(en: "Day", zh: "日") }
    static var chartAxisApiValue: String { t(en: "API value", zh: "API 价值") }

    // MARK: - sessions

    static var sessionsTitle: String { t(en: "Sessions", zh: "会话") }
    static var searchSessionsPlaceholder: String {
        t(en: "Search title, agent, or model", zh: "搜索标题、代理或模型")
    }
    static var sortBy: String { t(en: "Sort", zh: "排序") }
    static var sortRecent: String { t(en: "Most recent", zh: "最近") }
    static var sortValue: String { t(en: "Highest value", zh: "金额最高") }
    static var sortTokens: String { t(en: "Most tokens", zh: "Token 最多") }
    static var noMatchingSessions: String { t(en: "No matching sessions", zh: "没有匹配的会话") }
    static var selectSessionToInspect: String {
        t(en: "Select a session to inspect its events",
          zh: "选择一个会话以查看其事件")
    }
    static var untitledSession: String { t(en: "Untitled session", zh: "未命名会话") }
    static var untitledSubagent: String { t(en: "Untitled subagent", zh: "未命名子代理") }
    static var subagents: String { t(en: "Subagents", zh: "子代理") }
    static var helpSpawnedSubagents: String {
        t(en: "This session spawned subagent threads",
          zh: "此会话生成了子代理线程")
    }
    static var helpCostApproxInferred: String {
        t(en: "Cost is approximate — model was inferred (legacy session with no model metadata).",
          zh: "费用为估算值 — 模型为推断（旧会话无模型元数据）。")
    }
    static var inferredModel: String { t(en: "inferred model", zh: "推断的模型") }
    static var helpInferredModel: String {
        t(en: "This session has no turn_context model metadata. Cost is estimated using gpt-5 pricing.",
          zh: "此会话没有 turn_context 模型元数据。费用按 gpt-5 价格估算。")
    }
    static var statValue: String { t(en: "Value", zh: "价值") }
    static var statStarted: String { t(en: "Started", zh: "开始") }
    static func subagentsCount(_ n: Int) -> String {
        t(en: "Subagents (\(n))", zh: "子代理（\(n)）")
    }
    static func evShort(_ n: Int) -> String {
        t(en: "\(n) ev", zh: "\(n) 事件")
    }
    static func eventsTimelineCount(_ n: Int) -> String {
        t(en: "Events (\(n))", zh: "事件（\(n)）")
    }
    static var noEventsForSession: String {
        t(en: "No usage events recorded for this session",
          zh: "该会话没有记录用量事件")
    }
    static var chipIn: String { t(en: "in", zh: "入") }
    static var chipCache: String { t(en: "cache", zh: "缓存") }
    static var chipOut: String { t(en: "out", zh: "出") }
    static var chipReason: String { t(en: "reason", zh: "推理") }

    // MARK: - history

    static var historyTitle: String { t(en: "History", zh: "历史") }
    static var daysHeader: String { t(en: "Days", zh: "天数") }
    static var noUsageHistory: String { t(en: "No usage history yet", zh: "暂无使用历史") }
    static var selectDayPrompt: String {
        t(en: "Select a day to inspect its calls",
          zh: "选择一天以查看其调用")
    }
    static func sessionsOnDay(_ n: Int) -> String {
        t(en: "Sessions on this day (\(n))", zh: "当日会话（\(n)）")
    }
    static var noSessions: String { t(en: "No sessions", zh: "无会话") }
    static var noEvents: String { t(en: "No events", zh: "无事件") }

    // MARK: - settings

    static var settingsTitle: String { t(en: "Quota Monitor Settings", zh: "Quota Monitor 设置") }
    static var settingsTabGeneral: String { t(en: "General", zh: "通用") }
    static var settingsTabPricing: String { t(en: "Pricing", zh: "计费") }
    static var settingsTabAdvanced: String { t(en: "Advanced", zh: "高级") }

    // sections
    static var sectionLanguage: String { t(en: "Language", zh: "语言") }
    static var sectionCodexCLI: String { "Codex CLI" }
    static var sectionClaudeCode: String { "Claude Code" }
    static var sectionRateLimitPolling: String { t(en: "Codex polling", zh: "Codex 轮询") }
    static var sectionNotifications: String { t(en: "Notifications", zh: "通知") }
    /// Explainer under the Codex polling stepper. Calls out two things
    /// new users get wrong: (1) this only drives the Codex CLI quota
    /// fetch, not Claude; (2) Claude's interval is fixed at 2 h to avoid
    /// Anthropic's HTTP 429 throttle.
    static var codexPollingHelp: String {
        t(en: "How often Codex's local rate-limit quota is fetched. Claude's quota is polled separately every 2 hours and isn't affected by this.",
          zh: "多久从本地 Codex 拉取一次速率限制配额。Claude 的配额由独立的 2 小时间隔拉取，不受此设置影响。")
    }
    static var sectionDatabase: String { t(en: "Database", zh: "数据库") }
    static var sectionExport: String { t(en: "Export", zh: "导出") }

    // language
    static var languagePickerLabel: String { t(en: "Display language", zh: "显示语言") }
    static var languagePickerHelp: String {
        t(en: "Switches immediately. No restart needed.",
          zh: "立即生效，无需重启。")
    }

    // codex / claude paths
    static var binaryPath: String { t(en: "Binary path", zh: "可执行文件路径") }
    static var autoDetectPrompt: String { t(en: "Auto-detect (leave blank)", zh: "自动检测（留空）") }
    static var codexHomePrompt: String { "~/.codex (default)" }
    static var pathOverrideHint: String {
        t(en: "Path overrides take effect on next app launch.",
          zh: "路径覆盖将在下次启动应用时生效。")
    }
    static var claudeHomeLabel: String { t(en: "Claude home", zh: "Claude 主目录") }
    static var claudeHomePrompt: String { "~/.claude or ~/.config/claude (default)" }
    static var claudePathOverrideHint: String {
        t(en: "Path override takes effect on next app launch. The scanner looks at both legacy and new layouts automatically.",
          zh: "路径覆盖将在下次启动应用时生效。扫描器会自动检查旧布局和新布局。")
    }
    static var claudeOAuthExplanation: String {
        t(en: "Anthropic's `/api/oauth/usage` endpoint requires the Claude Code OAuth token. We read `~/.claude/.credentials.json` first; the Keychain item is a fallback for macOS GUI apps (may prompt the first time).",
          zh: "Anthropic 的 `/api/oauth/usage` 端点需要 Claude Code OAuth token。我们优先读取 `~/.claude/.credentials.json`；Keychain 项是 macOS GUI 应用的兜底（首次可能弹窗）。")
    }
    static var keychainPolicyLabel: String { t(en: "Live quotas", zh: "实时配额") }
    static var keychainPolicyFallback: String {
        t(en: "Use Keychain when needed", zh: "需要时使用 Keychain")
    }
    static var keychainPolicyNever: String {
        t(en: "Never prompt (file only)", zh: "从不弹窗（仅文件）")
    }

    // polling / notify
    static var interval: String { t(en: "Interval", zh: "间隔") }
    static func minutesShort(_ n: Int) -> String { t(en: "\(n) min", zh: "\(n) 分钟") }
    static var notifyAt: String { t(en: "Notify at", zh: "通知阈值") }

    // pricing
    static var colModel: String { t(en: "Model", zh: "模型") }
    static var colInputPerM: String { t(en: "Input $/M", zh: "输入 $/M") }
    static var colCachedPerM: String { t(en: "Cached $/M", zh: "缓存 $/M") }
    static var colOutputPerM: String { t(en: "Output $/M", zh: "输出 $/M") }
    static var colCacheCreatePerM: String { t(en: "Cache create $/M", zh: "缓存创建 $/M") }
    static var helpLocallyEdited: String {
        t(en: "Locally edited — LiteLLM refresh will skip this row",
          zh: "本地已编辑 — LiteLLM 刷新会跳过此行")
    }
    static var pricingRestoreDefaults: String { t(en: "Restore Defaults", zh: "恢复默认") }
    static var pricingFetchLiteLLM: String { t(en: "Sync from LiteLLM", zh: "从 LiteLLM 同步") }
    static var livePricesViaLiteLLM: String { t(en: "Live prices via LiteLLM", zh: "通过 LiteLLM 获取实时价格") }
    static var neverRefreshed: String {
        t(en: "Never refreshed — click to fetch the live catalog.",
          zh: "尚未刷新 — 点击以获取实时目录。")
    }
    static func lastRefreshed(_ relative: String) -> String {
        t(en: "Last refreshed \(relative)", zh: "上次刷新 \(relative)")
    }
    static var badgeLive: String { t(en: "live", zh: "实时") }
    static var badgeLocal: String { t(en: "local", zh: "本地") }
    static var badgeSeed: String { t(en: "seed", zh: "内置") }
    static var restoredSeedPrices: String {
        t(en: "Restored seed prices.", zh: "已恢复内置价格。")
    }
    static var litellmNoMatch: String {
        t(en: "LiteLLM responded but matched no catalog rows.",
          zh: "LiteLLM 已响应但未匹配任何目录行。")
    }
    static func litellmUpdated(_ n: Int) -> String {
        t(en: "Updated \(n) model\(n == 1 ? "" : "s") from LiteLLM.",
          zh: "已通过 LiteLLM 更新 \(n) 个模型。")
    }
    static func litellmRefreshFailed(_ err: String) -> String {
        t(en: "LiteLLM refresh failed: \(err)",
          zh: "LiteLLM 刷新失败：\(err)")
    }

    // data
    static var location: String { t(en: "Location", zh: "位置") }
    static var revealInFinder: String { t(en: "Reveal in Finder", zh: "在 Finder 中显示") }
    static var exportUsageEventsCsv: String {
        t(en: "Export usage events as CSV…", zh: "导出用量事件为 CSV…")
    }
    static func exportedEventsTo(_ n: Int, fileName: String) -> String {
        t(en: "Exported \(n) events to \(fileName)",
          zh: "已将 \(n) 个事件导出至 \(fileName)")
    }
    static func exportFailed(_ err: String) -> String {
        t(en: "Export failed: \(err)", zh: "导出失败：\(err)")
    }

    // MARK: - private
    private static func t(en: String, zh: String) -> String {
        switch LocalizationStore.activeLanguage {
        case .english: return en
        case .simplifiedChinese: return zh
        }
    }
}
