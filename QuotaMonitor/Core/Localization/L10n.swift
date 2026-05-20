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
    /// Window title for the Settings scene. Distinct from `settingsMenuItem`
    /// because window titles don't take the trailing ellipsis (which is a
    /// macOS HIG convention reserved for menu items that open further UI).
    static var settingsWindowTitle: String { t(en: "Settings", zh: "设置") }
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
    // MARK: - menu bar

    static var codex: String { "Codex" }                 // proper noun
    static var claudeCode: String { "Claude Code" }      // proper noun
    static var claude: String { "Claude" }               // proper noun

    static var quotaCardTitle5h: String { t(en: "5-hour", zh: "5 小时") }
    static var quotaCardTitle7d: String { t(en: "7-day", zh: "7 天") }
    static var quotaCardTitle7dOpus: String { t(en: "7-day · Opus", zh: "7 天 · Opus") }
    static var quotaCardTitle7dSonnet: String { t(en: "7-day · Sonnet", zh: "7 天 · Sonnet") }

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
    /// Placeholder caption when Anthropic's /api/oauth/usage response
    /// includes `seven_day` but omits `five_hour` — happens after the 5h
    /// window resets and before the user prompts Claude again. We render
    /// a quiet "5h · idle" row instead of hiding the slot entirely so the
    /// 7d-only state doesn't read like a regression vs. Codex.
    static var claude5hWindowIdle: String {
        t(en: "No activity in current window", zh: "当前窗口空闲")
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
    static var quotaDisplayModeLabel: String {
        t(en: "Quota percentage", zh: "配额百分比")
    }
    static var quotaDisplayModeUsed: String {
        t(en: "Used", zh: "已用")
    }
    static var quotaDisplayModeRemaining: String {
        t(en: "Remaining", zh: "剩余")
    }
    static var quotaDisplayModeHelp: String {
        t(en: "Choose whether quota rows show the percent already used or the percent still remaining. Progress bars follow the same direction.",
          zh: "选择配额行显示已用百分比还是剩余百分比。用量条也会按同一方向显示。")
    }
    static var showDockIconLabel: String {
        t(en: "Show Dock icon when windows are open",
          zh: "窗口打开时显示程序坞图标")
    }
    /// Caption under the toggle. Spells out the Cmd+Tab side effect
    /// of the default-OFF behaviour so users don't think their
    /// windows are broken when they can't ⌘Tab back into them.
    static var showDockIconHelp: String {
        t(en: "When off, QuotaMonitor stays in the menu bar only. The Dashboard and Settings windows will not appear in Cmd+Tab.",
          zh: "关闭后 QuotaMonitor 完全只占菜单栏，但 Cmd+Tab 将切换不到 Dashboard 与设置窗口。")
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

    /// Inline cooldown notice rendered on the Claude block while the
    /// 429 cooldown is active. `\(remaining)` is a short duration
    /// label like "5 min" / "45s" produced by `cooldownDurationLabel`
    /// — this string just supplies the "rate limited, retry in X"
    /// frame and lets the duration helper pick the right unit.
    static func claudeRateLimitedRetryIn(_ remaining: String) -> String {
        t(en: "Claude usage rate limited, retry in \(remaining)",
          zh: "Claude usage 限速中，约 \(remaining) 后可重试")
    }
    /// Duration unit suffixes for the cooldown countdown. We render
    /// these via the app's own L10n (not Foundation's locale-based
    /// formatter) so they hot-swap when the user changes the language
    /// picker at runtime.
    static func cooldownSeconds(_ n: Int) -> String {
        t(en: "\(n)s", zh: "\(n) 秒")
    }
    static func cooldownMinutes(_ n: Int) -> String {
        t(en: "\(n) min", zh: "\(n) 分钟")
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
    static var scanIndexingTitle: String {
        t(en: "Scanning local history", zh: "正在扫描本地记录")
    }
    static func scanProgressSummary(completed: Int, total: Int) -> String {
        if total > 0 {
            return t(en: "\(completed)/\(total) files processed",
                     zh: "已处理 \(completed)/\(total) 个文件")
        }
        return t(en: "\(completed) files processed",
                 zh: "已处理 \(completed) 个文件")
    }
    static func scanCurrentFile(_ file: String) -> String {
        t(en: "Current file: \(file)", zh: "当前文件：\(file)")
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
    static func forecastRunsOutIn(_ relative: String) -> String {
        t(en: "runs out in ~\(relative)", zh: "~\(relative)后耗尽")
    }
    static func forecastResetsIn(_ relative: String) -> String {
        t(en: "resets in \(relative)", zh: "\(relative)后重置")
    }

    private static func formatCompact(_ v: Double) -> String {
        v.formatted(.number.notation(.compactName)
            .locale(SettingsStore.tokenFormatLocaleNonisolated))
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

    static var settingsTabGeneral: String { t(en: "General", zh: "通用") }
    static var settingsTabPricing: String { t(en: "Pricing", zh: "计费") }
    static var settingsTabAdvanced: String { t(en: "Advanced", zh: "高级") }

    // sections
    static var sectionAppearance: String { t(en: "Appearance", zh: "外观") }
    static var sectionLanguage: String { t(en: "Language", zh: "语言") }
    static var sectionCodexCLI: String { "Codex CLI" }
    static var sectionClaudeCode: String { "Claude Code" }
    /// Explainer under the Codex polling stepper. Calls out two things
    /// new users get wrong: (1) this only drives the Codex CLI quota
    /// fetch, not Claude; (2) Claude's interval is fixed at 2 h to avoid
    /// Anthropic's HTTP 429 throttle.
    static var codexPollingHelp: String {
        t(en: "How often Codex's local rate-limit quota is fetched. Claude's quota is polled separately every 2 hours and isn't affected by this.",
          zh: "多久从本地 Codex 拉取一次速率限制配额。Claude 的配额由独立的 2 小时间隔拉取，不受此设置影响。")
    }
    // Codex Fast-Mode billing — Codex CLI's JSONL doesn't surface tier
    // per turn, so the user toggles their account-wide billing mode
    // here. Help copy intentionally hides the per-model multipliers;
    // users only need to know the toggle is global because per-call
    // tier isn't observable.
    static var sectionCodexBilling: String {
        t(en: "Codex Billing", zh: "Codex 计费")
    }
    static var codexFastModeBillingLabel: String {
        t(en: "Codex Bill as Fast Mode", zh: "Codex 按 Fast Mode 计费")
    }
    static var codexFastModeBillingHelp: String {
        t(en: "Codex doesn't tag each request with its billing tier, so this toggle applies to your whole account — including history. Turn it on if you regularly use Fast Mode.",
          zh: "Codex 不会标记每次请求的计费档位，所以这里只能按账户整体估算费用，切换后历史记录会同步重算。如果长期使用 Fast Mode 就打开。")
    }
    static var sectionDatabase: String { t(en: "Database", zh: "数据库") }
    static var sectionExport: String { t(en: "Export", zh: "导出") }
    static var sectionDeveloperMode: String { t(en: "Developer Mode", zh: "开发者模式") }
    static var developerModeLabel: String {
        t(en: "Write diagnostics to a local file",
          zh: "将诊断日志写入本地文件")
    }
    static var developerModeHelp: String {
        t(en: "For troubleshooting only. Writes detailed JSONL diagnostics with operation IDs, triggers, durations, skip reasons, and errors. The log rotates at 20 MB; turning this off deletes developer logs.",
          zh: "仅用于排查问题。会写入详细 JSONL 诊断日志，包含操作 ID、触发来源、耗时、跳过原因与错误。日志达到 20 MB 会轮转；关闭时会删除开发者日志。")
    }
    static var developerLogFileLabel: String { t(en: "Log file", zh: "日志文件") }
    static var revealLogFile: String { t(en: "Reveal Log File", zh: "显示日志文件") }

    // language
    static var languagePickerLabel: String { t(en: "Display language", zh: "显示语言") }
    static var languagePickerHelp: String {
        t(en: "Switches immediately. No restart needed.",
          zh: "立即生效，无需重启。")
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

    // polling
    static var interval: String { t(en: "Interval", zh: "间隔") }
    static func minutesShort(_ n: Int) -> String { t(en: "\(n) min", zh: "\(n) 分钟") }

    // pricing
    static var pricingRestoreDefaults: String { t(en: "Restore Defaults", zh: "恢复默认") }
    static var pricingFetchLiteLLM: String { t(en: "Sync from LiteLLM", zh: "从 LiteLLM 同步") }
    // Pricing catalog sheet (Advanced → Pricing → View catalog)
    static var pricingViewCatalog: String { t(en: "View Catalog…", zh: "查看价目表…") }
    static var pricingSheetTitle: String { t(en: "Pricing Catalog", zh: "价目表") }
    static var pricingSheetUnit: String {
        t(en: "USD per million tokens", zh: "美元 / 百万 token")
    }
    static var colModel: String { t(en: "Model", zh: "模型") }
    static var colInputPerM: String { t(en: "Input", zh: "输入") }
    static var colCachedPerM: String { t(en: "Cached", zh: "缓存读取") }
    static var colOutputPerM: String { t(en: "Output", zh: "输出") }
    static var colCacheCreatePerM: String { t(en: "Cache create", zh: "缓存创建") }
    static var badgeLive: String { t(en: "LIVE", zh: "实时") }
    static var badgeLocal: String { t(en: "LOCAL", zh: "本地") }
    static var badgeSeed: String { t(en: "SEED", zh: "内置") }
    static var helpLocallyEdited: String {
        t(en: "This row was edited locally.", zh: "该行已被本地修改。")
    }
    static var done: String { t(en: "Done", zh: "完成") }
    static var neverRefreshed: String {
        t(en: "Never refreshed — click to fetch the live catalog.",
          zh: "尚未刷新 — 点击以获取实时目录。")
    }
    static func lastRefreshed(_ relative: String) -> String {
        t(en: "Last refreshed \(relative)", zh: "上次刷新 \(relative)")
    }
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

    // MARK: - settings · tracked tools

    static var sectionTrackedTools: String {
        t(en: "Tracked tools", zh: "已跟踪的工具")
    }
    /// Help text under the Codex/Claude toggle pair. Frames the choice
    /// in terms of the practical outcome (no API errors, smaller UI)
    /// rather than just "what the toggle does", because the latter is
    /// already obvious from the label.
    static var trackedToolsHelp: String {
        t(en: "Turn off the tools you don't use. The matching cards and background polling will stop.",
          zh: "关闭你不使用的工具。对应的卡片和后台轮询都会停止。")
    }
    static var trackedToolsKeepOne: String {
        t(en: "At least one tool must stay enabled.",
          zh: "至少需要保留一个工具启用。")
    }

    // MARK: - onboarding

    /// Title bar string for the standalone onboarding Window scene.
    /// Generic enough to read sensibly during either step (language
    /// or providers) since the body content is what makes the
    /// current step obvious.
    static var onboardingWindowTitle: String {
        t(en: "Welcome to Quota Monitor", zh: "欢迎使用 Quota Monitor")
    }
    static var onboardingProvidersHeadline: String {
        t(en: "Pick the tools you use", zh: "选择你使用的工具")
    }
    static var onboardingProvidersSubhead: String {
        t(en: "We'll only track the ones you enable. You can change this later in Settings.",
          zh: "我们只会跟踪你启用的工具。稍后可在设置中更改。")
    }
    static var onboardingContinue: String { t(en: "Continue", zh: "继续") }

    /// Popover lock screen shown while the onboarding window is open
    /// (or was closed mid-setup). Replaces the entire normal popover
    /// body so the user can't trigger refreshes, scans, or settings
    /// before completing the wizard.
    static var setupNotComplete: String {
        t(en: "Setup not finished", zh: "设置尚未完成")
    }
    static var setupNotCompleteBody: String {
        t(en: "Finish the setup wizard so Quota Monitor knows which tools to track.",
          zh: "请先完成设置向导，Quota Monitor 才能知道要跟踪哪些工具。")
    }
    static var openSetup: String { t(en: "Open setup", zh: "打开设置向导") }

    // MARK: - settings · menu bar icon

    static var menuBarIconProviderLabel: String {
        t(en: "Show in menu bar", zh: "菜单栏显示")
    }
    static var menuBarIconProviderHelp: String {
        t(en: "Pick which tools' 5h and 7d quota percentages to show on the menu-bar icon. Choose both for a combined line, one for a shorter readout, or none to keep the gauge icon.",
          zh: "选择哪些工具的 5 小时与 7 日配额百分比显示在菜单栏图标上。两个都选会并排显示在一行，只选一个会更短，都不选则显示原本的表盘图标。")
    }
    /// Variant of `menuBarIconProviderHelp` used in Settings when only
    /// one provider is tracked — the "choose both" wording no longer
    /// applies because the other toggle isn't even rendered.
    static var menuBarIconProviderHelpSingle: String {
        t(en: "Toggle whether this tool's 5h and 7d quota percentages show on the menu-bar icon, or leave it off to keep the gauge icon.",
          zh: "勾选则在菜单栏图标上显示该工具的 5 小时与 7 日配额百分比；不勾选则保留原本的表盘图标。")
    }

    // Token unit language picker (Chinese-only — English mode already
    // uses B/M/K so there is nothing to choose).
    static var tokenUnitLanguageLabel: String {
        t(en: "Token unit language", zh: "Token 单位语言")
    }
    static var tokenUnitLanguageHelp: String {
        t(en: "Controls the language of compact token counts. Follow language renders 亿/万 in Chinese mode; English forces B/M/K everywhere.",
          zh: "控制 Token 数量的单位显示。跟随语言时中文显示 亿/万，英文显示 B/M/K。")
    }
    static var tokenUnitLanguageFollow: String {
        t(en: "Follow language", zh: "跟随语言")
    }
    static var tokenUnitLanguageEnglish: String {
        t(en: "English (B/M/K)", zh: "英文 (B/M/K)")
    }

    // MARK: - settings · advanced · uninstall

    static var sectionUninstall: String { t(en: "Uninstall", zh: "卸载") }
    static var uninstallButton: String {
        t(en: "Uninstall Quota Monitor…", zh: "卸载 Quota Monitor…")
    }
    static var uninstallExplain: String {
        t(en: "Removes the usage database, settings, and caches, then moves the app to Trash. Your ~/.codex and ~/.claude folders are not touched.",
          zh: "删除使用记录数据库、设置和缓存，并将应用移到废纸篓。你的 ~/.codex 与 ~/.claude 目录不会被动。")
    }
    static var uninstallConfirmTitle: String {
        t(en: "Uninstall Quota Monitor?", zh: "确认卸载 Quota Monitor？")
    }
    static var uninstallConfirmBody: String {
        t(en: "This will permanently delete your local usage history and settings, then move the app to Trash. This cannot be undone.",
          zh: "此操作会永久删除本地的使用历史与设置，并把应用移到废纸篓。无法撤销。")
    }
    static var uninstallConfirmAction: String {
        t(en: "Uninstall", zh: "卸载")
    }
    static var cancel: String { t(en: "Cancel", zh: "取消") }

    // MARK: - settings · advanced · claude credentials mirror

    static var mirrorClaudeCredsLabel: String {
        t(en: "Cache Claude credentials to disk",
          zh: "将 Claude 凭据缓存到磁盘")
    }
    static var mirrorClaudeCredsHelp: String {
        t(en: "After a successful Keychain read, write a copy to ~/.claude/.credentials.json (mode 0600). Stops macOS from re-prompting for the Keychain on every rebuild, but moves the token from a per-app Keychain item to a plain file readable by anything running as you. Off by default.",
          zh: "成功从钥匙串读取后，写一份副本到 ~/.claude/.credentials.json（权限 0600）。可以避免每次重新构建后 macOS 都弹出钥匙串提示，但代价是把 token 从仅本应用可读的钥匙串项搬到一个以你身份可读的普通文件。默认关闭。")
    }

    // MARK: - private
    private static func t(en: String, zh: String) -> String {
        switch LocalizationStore.activeLanguage {
        case .english: return en
        case .simplifiedChinese: return zh
        }
    }
}
