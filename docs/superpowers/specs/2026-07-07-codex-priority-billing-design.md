# Codex 逐 turn Priority(Fast)计费识别 — 设计文档

日期:2026-07-07
分支:`codex/codex-priority-billing`

## 1. 背景与问题

用户反馈 Codex 的费用"算少了"。审计结论:**基础 token 统计与计费公式正确**
(`max(input − cached, 0)·input + cached·cached + output·output`,reasoning 不重复计费,
与 `ccusage` / CodexBar 一致),真正的低估来自 **计费档位(tier)归因太粗**:

当前 `usage_events` 没有 tier 信息,Fast/Priority 只由一个全局开关
`codexFastModeBilling`(`SettingsStore.swift:131`)控制,"全有或全无"——打开后所有
`gpt-5.5` 都被当 Fast,连实际是 Standard 的也误伤;关闭则 Priority 请求全部少算。

OpenAI 的 `service_tier: priority` 就是本 app 叫的 "Fast Mode"(`gpt-5.5` 的 2.5× 正好是
官方 Standard→Priority 比例)。Codex CLI 会把每次请求的 `service_tier` 写进
`~/.codex/logs_2.sqlite` 的 websocket 请求日志,可用于**逐 turn** 精确识别。

## 2. 目标 / 非目标

**目标**
- 从 `~/.codex/logs_2.sqlite` 逐 turn 识别 `service_tier: priority`,对命中的 turn 强制按
  Priority(Fast)价计费,与全局开关无关。
- 保留全局开关,语义收窄为"仅用于 trace 未覆盖的历史"的兜底。
- 存量历史通过一次强制全量重扫补齐 turn_id,并被 tagging 覆盖。

**非目标(本 MR 明确不做)**
- 不加 `gpt-5.3-codex` 的 Fast 倍率:Priority 价必须有 OpenAI 官方依据,当前无确证数字,
  宁缺毋滥(另开 issue)。
- 不支持 headless `codex exec` 的 `turn.completed`/`usage` 日志形态(本机无此类日志)。
- 不做 CodexBar 式的 trace memo / 增量 rowid 缓存(核心优先)。
- UI 最小:仅更新全局开关的说明文案;不新增 trace 覆盖率报告面板。

## 3. 关键事实(已用真实数据验证)

- rollout `event_msg/task_started` 与 `turn_context` 都带 `turn_id`;`token_count` **不带** →
  顺序扫描维护"当前 turn_id"归属给 delta。
- `logs_2.sqlite` 是通用日志表 `logs(feedback_log_body TEXT, ts INTEGER, ...)`(365K 行);
  websocket 请求 JSON 内含 `"service_tier":"priority"` 与 turn_id。
- **交叉验证**:窗口内 75 个 priority turn_id,73 个(97%)精确匹配到 rollout 的 turn_id;
  未匹配的 2 个是不落 rollout 的后台请求(ambient suggestions)。→ 映射链可靠。
- trace 覆盖窗口约近 10 天(本机 2026-06-27 起);更早历史无 trace。

## 4. 计费语义(三态,核心)

每条 Codex `usage_event` 得到 `codex_billing_tier`:

| 情形 | tier | 定价 |
|---|---|---|
| turn_id 命中 trace 的 priority 集合 | `priority` | **强制** `<model>-fast` 价(即使全局开关关) |
| event 在 trace 窗口内、turn 未命中 priority | `standard` | **强制**标准价(即使全局开关开) |
| event 在 trace 窗口外,或无 turn_id | `NULL` | 无证据 → 沿用全局 `codexFastModeBilling` 兜底 |

**priority 判定单调不回退**:tagging 只 (re)tag「trace 窗口覆盖的行」+「priority 命中行」,
窗口外的既有判定原样保留。避免今天识别为 priority 的 turn,十天后 trace 滚出窗口又退回兜底。

## 5. 数据模型(migration v13,append-only)

`Core/Storage/Migrations.swift` 追加:

```swift
migrator.registerMigration("v13-codex-billing-tier") { db in
    try db.alter(table: "usage_events") { t in
        t.add(column: "codex_turn_id", .text)          // 归属 turn;可空(legacy)
        t.add(column: "codex_billing_tier", .text)      // 'priority' | 'standard' | NULL
    }
    // 强制 Codex 全量重扫,给存量行补 turn_id。Codex 每次全解析整份文件,
    // 只需让 (size, mtime) 失效即可判定为 changed。
    try db.execute(sql: """
        UPDATE import_state
        SET file_size = -1, file_mtime_ms = -1, byte_offset = 0
        WHERE source_path LIKE '%/.codex/sessions/%'
           OR source_path LIKE '%/.codex/archived_sessions/%'
        """)
}
```

`Core/Storage/Records.swift` 的 `UsageEventRecord` 加两个可选字段
`codexTurnId: String?` / `codexBillingTier: String?`(默认 nil,CodingKeys 对应蛇形列名)。

## 6. 处理链路改动

1. **`RolloutEvent.swift`**
   - `TurnContextPayload` 加 `turnId: String?`(`turn_id`)。
   - 新增 `case taskStarted(turnId: String?, timestamp: String?)`;`decode` 里
     `event_msg` 分支识别内层 `type == "task_started"` 抽 `turn_id`(现在落进 `.other`)。

2. **`RolloutParser.swift`**
   - 维护 `currentTurnId`:`taskStarted` 与 `turnContext` 都更新它。
   - `UsageDelta` 加 `turnId: String?`;构造 delta 时带上 `currentTurnId`。

3. **`ImportEngine.persist`(`:357` 循环)**
   - 插入 `UsageEventRecord` 时写 `codexTurnId: delta.turnId`;`codexBillingTier` 留 nil
     (由 tagging 步骤填)。

4. **`ImportEngine.performScan` 尾部(`reconcileSessionTree()` 之后)**
   - 调 `CodexPriorityTagger.tag(...)`,读 trace 并 (re)tag tier。返回受影响行数,计入
     `ScanReport.codexTierUpdated`。

5. **`ScanController.runScan`(`:182`)**
   - backfill 触发条件由 `merged.changedFiles > 0` 改为
     `merged.changedFiles > 0 || merged.codexTierUpdated > 0`,保证 tier 变化能重新定价。

## 7. 新组件

### `CodexPriorityTraceReader`(`Core/Importer/`)
只读打开 `~/.codex/logs_2.sqlite`(`file:...?mode=ro&immutable=1`,**永不写**,~2s 超时;
文件缺失/打不开即返回空)。产出:
- `priorityTurnIds: Set<String>` — `feedback_log_body LIKE '%service_tier%'` 的行(约数百,
  毫秒级)里,`service_tier` 为 `priority` 的请求所含 turn_id。
- `window: (startISO, endISO)?` — `MIN(ts)/MAX(ts)` 转 UTC ISO8601 字符串,便于与
  `usage_events.timestamp`(同为 UTC ISO)按字典序比较。

解析用限定正则:在同一 body 内先确认存在 `"service_tier":"priority"`,再抽全部 UUID 形态
`turn_id`。纯 Swift 字符串扫描,不依赖第三方。

### `CodexPriorityTagger`(`Core/Importer/`,或 ImportEngine 私有方法)
输入 reader 结果,对 `usage_events` 执行(单事务,幂等):

```sql
-- (b) 窗口内、有 turn_id 的行先判 standard(有 trace 覆盖=有反证)
UPDATE usage_events SET codex_billing_tier = 'standard'
WHERE provider = 'codex' AND codex_turn_id IS NOT NULL
  AND timestamp >= :winStart AND timestamp <= :winEnd;

-- (a) priority 命中覆盖为 priority(不受窗口限制;单调,不回退)
UPDATE usage_events SET codex_billing_tier = 'priority'
WHERE provider = 'codex' AND codex_turn_id IN (:priorityIds);
```

窗口外、未被上面两条触及的行保持原值(初次为 NULL → 兜底;曾判 priority 的保留)。
priority set 为空或 window 为 nil(trace 不可用)时,只跑 (a) 的空集合 = 无操作,
既有 tier 全部保留,系统整体降级到"全局开关兜底"。返回两条 UPDATE 的 `changesCount` 之和。

## 8. 定价 SQL 改造

`PricingService.effectiveModelIdSQL(codexFastModeBilling:)`(`:497`)——签名不变,
三处调用点(`ScanController`、`applyCodexFastModeBilling`、`restorePricingDefaults`、
`applyLiteLLMUpdate` 内部)全部沿用。SQL 逻辑改为按行 tier 分支:

```sql
CASE
  WHEN usage_events.provider = 'codex'
       AND usage_events.model_id IN (<fast-capable model ids>)
  THEN CASE
         WHEN usage_events.codex_billing_tier = 'priority'
              THEN usage_events.model_id || '-fast'      -- 有证据,强制
         WHEN usage_events.codex_billing_tier = 'standard'
              THEN usage_events.model_id                 -- 有反证,强制标准
         WHEN usage_events.codex_billing_tier IS NULL AND <globalFast>
              THEN usage_events.model_id || '-fast'      -- 无证据,兜底开关
         ELSE usage_events.model_id
       END
  ELSE usage_events.model_id
END
```

`<fast-capable model ids>` 与 `<globalFast>` 由 `CodexFastMode.multipliers` /
入参决定,与现状同源(code-controlled,可安全插值)。当 `codexFastModeBilling=false`
时,`IS NULL` 分支自然落到 `ELSE`(标准价),行为与旧全局关一致。

## 9. 全局开关的新语义

`codexFastModeBilling` 保留,不改存储/UI 结构;仅:
- 说明文案(`L10n.codexFastModeBillingHelp`)更新为"仅影响 trace 未覆盖的历史事件"。
- 切换时 `applyCodexFastModeBilling()` 仍只重跑 `backfillAllValues`(tier 列不变,
  SQL 按新参数对 NULL 行重新定价),无需重扫。

## 10. 边界与失败降级

- trace 文件不存在/被裁剪/打不开 → reader 返回空 → tagging 无操作 → 全靠全局开关兜底,
  不报错、不阻塞 scan。
- 只读打开,绝不写 `logs_2.sqlite`(避免干扰正在运行的 Codex)。
- tagging 与 backfill 都在既有 scan 写事务模型内,不新增长事务风险(reader 单独只读连接)。

## 11. 测试计划(Swift Testing,`Tests/QuotaMonitorTests/`)

- **RolloutParser**:task_started/turn_context 的 turn_id 正确附到后续 delta;单文件跨多个
  turn 切换;legacy(无 turn 事件)delta 的 turnId 为 nil。
- **CodexPriorityTraceReader**:构造 fixture sqlite(logs 表 + 若干 priority/auto body),
  验证 priority turn 抽取与 window 计算;缺表/空库返回空且不抛。
- **CodexPriorityTagger**:三态各分支(priority 命中、窗口内 standard、窗口外/无 turn_id
  保持);单调性(窗口外既有 priority 不被重置);空 priority set 全保留。
- **PricingService 定价**:priority→fast 价、standard→标准价(即使 globalFast=true)、
  NULL+globalFast→fast、NULL+!globalFast→标准。
- **migration v13**:幂等;跑后列存在、codex import_state 被失效。

## 12. 验证与交付

- `swift test --disable-keychain`(先 `--filter` 迭代)。
- `./qa/run-static.sh`(PR gate)。
- 更新 `CHANGELOG.md` + `CHANGELOG.zh-Hans.md`(非 appcast PR 强制)。
- 独立 worktree `codex/codex-priority-billing` → 推送 → 开 MR;不碰主 checkout / main。
- 预计 ~600–900 行(含测试)。
