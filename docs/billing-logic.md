# QuotaMonitor 计费逻辑

本文梳理项目当前的 API-equivalent 计费链路。这里的金额不是订阅账单或平台真实扣费记录，而是 QuotaMonitor 根据本机 Codex / Claude 使用日志和模型价格表复算出的美元估值。核心落点是 `usage_events.value_usd`：导入器负责写入 token 明细，`PricingService.backfillAllValues` 负责按价格表统一回填金额，UI 和报表只读取这个派生值。

## 核心数据流

1. 数据库打开时，`DatabaseManager` 调用 `PricingService.installBundledCatalog`，把 `pricing_catalog` 恢复为当前 App 随包提供的完整模型价格。
2. Codex 导入器读取 `~/.codex/sessions` / `archived_sessions` JSONL，把累计的 `token_count.info.total_token_usage` 转成每次增量。
3. Claude 导入器读取 `~/.claude/projects` 和 `~/.config/claude/projects` JSONL，把每条 `assistant.message.usage` 作为独立用量事件。
4. 导入器写入 `sessions` 和 `usage_events`，新事件初始 `value_usd = 0`。
5. 每个导入器会在写入事件、推进 checkpoint 的同一个数据库事务里，对本次新增或重建的事件调用 `PricingService.backfillValues`；计价失败时不会留下已提交但金额为 0 的新行。
6. App 升级带来新的内置价格或有效模型映射时，启动流程会对既有历史执行一次完整回填。
7. Dashboard、History、Sessions、menu bar 和 Claude 5 小时 block 都读取 `usage_events.value_usd` 的聚合结果。

## 关键表

### `usage_events`

每行代表一次可计费用量事件。

| 字段 | 含义 |
| --- | --- |
| `provider` | `codex` 或 `claude`，回填公式按它分支。 |
| `model_id` | 用来匹配 `pricing_catalog.model_id`。 |
| `codex_turn_id` | Codex turn 标识；rollout 没有稳定 ID 时为 `NULL`。 |
| `codex_service_tier_preference` | Codex rollout 为该 turn 记录的服务档位偏好：`priority`、`default`、`flex`，或用 `NULL` 表示未知。它不是实际 served tier。 |
| `input_tokens` | 输入 token。Codex 里是包含 cached input 和 cache write input 的 gross input；Claude 里是未缓存输入。 |
| `cached_input_tokens` | Codex cached input 或 Claude cache read input。 |
| `output_tokens` | 输出 token。Codex 中已经包含 reasoning output，不再额外加 reasoning。 |
| `reasoning_output_tokens` | 只用于展示和分析，不参与金额计算。 |
| `cache_creation_tokens` | Provider-neutral cache write 总量：Claude 保存 `cache_creation_input_tokens`，Codex 保存 `cache_write_input_tokens`。Codex 中它是 `input_tokens` 的子集，不额外加入 `total_tokens`。 |
| `cache_creation_5m_tokens` | Claude 5 分钟 ephemeral cache write。 |
| `cache_creation_1h_tokens` | Claude 1 小时 ephemeral cache write。 |
| `value_usd` | 由价格表回填出的美元估值。 |
| `model_inferred` | Codex 没有模型信息时 fallback 到 `gpt-5`，这里标记该金额是近似。 |
| `provider_message_id` | Claude message id，用于增量重读时去重。 |

### `pricing_catalog`

价格以 USD / 1M tokens 存储。

| 字段 | 含义 |
| --- | --- |
| `input_price_per_million` | 标准输入价格。 |
| `cached_input_price_per_million` | cache read / cached input 价格。 |
| `output_price_per_million` | 输出价格。 |
| `cache_creation_price_per_million` | Provider-specific cache write 价格：Claude 保存 5 分钟 cache creation 单价；Codex 保存随包预先算好的 prompt-cache write 单价。 |

旧数据库仍可能包含 `price_source`、`fetched_at`、`above_200k_*` 和 `max_*` 列。这些列只为保持既有 append-only migration 链可升级而保留；当前运行时会把受支持行统一恢复为内置目录，并清空旧的外部来源元数据，不再用这些列选择价格。

## 价格来源

`BundledPricingCatalog.entries` 是唯一价格来源。它随应用版本发布，覆盖当前支持的 OpenAI / Codex、Claude、GLM 模型；Codex 还会物化 `*-fast`、`*-flex`、`*-long`、`*-fast-long`、`*-flex-long` 以及相同形状的历史价格行。应用不会联网下载价格，不提供单行本地覆盖，也不会保留旧版外部目录对随包价格的优先级。

`PricingService.installBundledCatalog` 每次打开数据库都会 upsert 全部内置行。若计算相关字段发生变化，或受支持行需要从旧版外部 / 本地来源归一为 `bundled`，启动流程会重算既有 `usage_events.value_usd`；即使旧行数值碰巧等于当前内置价，也会执行这次升级回填，修复旧版本地覆盖曾绕过生效日期而留下的历史金额。金额回填只接受 `price_source = 'bundled'` 的行，且 Codex 事件只能使用 `BundledPricingCatalog.codexModelIds` 中明确登记的 GPT/Codex 行及其 Fast/Flex 行；Claude/GLM 行不会因为 rollout 中出现同名 model id 而进入 Codex 公式。不在内置目录中的旧 LiteLLM/local 行可以继续留在兼容 schema 中，但不再参与估价。原始 token、事件时间和会话数据不受影响。

`CodexFastMode.multipliers` 在 catalog 构造阶段维护支持 Fast 估算的模型及倍率，例如 `gpt-5.5 = 2.5x`、`gpt-5.4 = 2.0x`。它只用于生成最终 Fast Short 行；GPT-5.6 还会生成官方 Fast Long 行。事件计费不会再次乘 Fast 倍率。未列入该映射的 Codex 模型，以及所有 Claude 事件，都不会选择这些行。

`CodexFlexMode.multipliers` 在 catalog 构造阶段维护 OpenAI 已公布 Flex 价格的模型。它生成最终 Flex Short 行；同时支持长上下文的模型再生成 Flex Long 行。所有数值都会写入 SQLite catalog，事件计费只选择行，不再次乘 Flex 或 Long 倍率。

## 生效日期与历史价格

价格变更不能只覆盖当前目录，否则完整回填会把旧用量按新价格重算。`CodexPriceHistory.periods` 保存已经发生的固定价格区间，并为每个区间生成完整的 Short/Long × Standard/Flex/Fast 最终价格行。`backfillAllValues` 根据 `usage_events.timestamp` 选择历史或当前 row id，不重新计算历史价格。

GPT-5.6 Terra 与 Luna 以 `2026-07-30` 为切换点：此前事件使用上市价格，当日及之后使用降价后的当前价格。GPT-5.6 Sol 以 OpenAI 官方账号发布降价公告的 `2026-08-21T19:34:10Z` 为可审计切点：此前使用 `$5/$0.50/$6.25/$30`，当时及之后使用 `$4/$0.40/$5/$20`。该秒点是可验证的公开公告时间，不声称等同于未公开的内部账单切换秒点。以后供应商调价时，必须同时保留旧区间并更新当前内置行，不能只修改当前数字。

## Codex 服务档位偏好与 Fast 估算

### Rollout 证据与 turn 冻结

Codex rollout 的 `event_msg/thread_settings_applied` 表示一个面向**未来 turn** 的线程偏好。`RolloutParser` 按 JSONL 文件行顺序处理事件，不用 timestamp 重新排序：`thread_settings_applied` 只更新待生效偏好，下一条 `task_started` 才把当时的偏好冻结到新 turn。活跃 turn 中途出现新的设置事件不会改写该 turn；它从下一个 `task_started` 起生效。

解析器把 `priority` / `fast` 归一为 `priority`，把明确的 `default` 保存为 `default`，并把明确的 `flex` 保存为 `flex`；缺失、空值或不支持的值保存为未知。`thread_settings_applied` 只能证明 Codex 记录了这个未来-turn 偏好：客户端仍可能按模型或功能支持情况过滤它，rollout 也没有持久化服务端最终响应的 tier。因此这些字段用于估价，不是偏好已传输或 OpenAI 最终按该 tier 提供服务的证明。

子代理或 fork rollout 会先重放父会话历史，并可能重写外层事件时间。解析器在首个 child `session_meta` 上建立门禁：重放期间的 `token_count` 只更新累计量基线、不生成 `usage_events`；通常只有遇到 `task_started.started_at >= 子会话创建时间` 的首个真实任务后才开始计费。旧格式缺少 `started_at` 时，优先从 UUIDv7 `turn_id` 的毫秒时间判断；没有父 `session_meta` 重放的直接子任务则可在首个 task 开门，最后才使用严格晚于创建时间的外层时间兼容无法解析 UUIDv7 的旧数据，避免把等于创建时间的重放事件误当真实任务。累计 `total_token_usage` 与上一条完全相同时，即使 `last_token_usage` 内容变化也视为陈旧重发，不产生新增消费。

### 存储与兼容迁移

每个 Codex `usage_events` 行保存 `codex_turn_id` 和 `codex_service_tier_preference`。后者有 `priority`、`default`、`flex`、`NULL` 四种数据库状态；`NULL` 明确表示没有可用的持久化偏好证据。存储上仍保留未知状态，计价时则按保守规则选择 Standard，不能推断为 Fast 或 Flex。

迁移保留了未发布 trace 方案的兼容路径：`v13-codex-billing-tier` 先建立 `codex_turn_id` 与旧 `codex_billing_tier` 列，`v14-codex-rollout-tier-preference` 再把旧列改名为 `codex_service_tier_preference`、清除 Codex 的 trace 派生值，并把 Codex `import_state` 置为需要从 0 offset 重读。`v15-codex-pricing-policy-reprice` 会在启动查询前安装当前随包价格并强制回填全部派生金额；`v21-codex-cache-write-reread` 会安装包含 Codex Short/Long、tier、历史和 cache-write 单价的完整 catalog、立即重算已有金额，并清除 Codex checkpoint、强制从头重读一次。原始 rollout 已不可读的事件仍能选择正确价格行，仍可读的历史前缀则会补齐 `cache_write_input_tokens`。这些失效都通过 `import_state.session_id` 关联 `sessions.provider = 'codex'`，不依赖路径中出现 `/.codex/`。

### 价格行优先级

对已配置相应档位价格的 Codex 模型，价格行选择顺序如下：

| 每事件偏好 | 价格行 |
| --- | --- |
| `priority` | Short 使用 `<model_id>-fast`；GPT-5.6 Long 使用 `<model_id>-fast-long`，缺少 Fast Long 行的旧模型使用 `<model_id>-long`。 |
| `flex` | Short 使用 `<model_id>-flex`；Long 使用 `<model_id>-flex-long`。 |
| 明确的 `default` | Short 使用基础 `model_id`；Long 使用 `<model_id>-long`。 |
| `NULL` | 与 Standard 相同；没有 Fast/Flex 证据就不选择相应 tier 行。 |

超过 272K 输入 Token 时，支持模型的整个请求选择预先物化的 Long 行。Long 行在 catalog 构造时已经写入官方最终单价；事件 SQL 不乘 `2.0` 或 `1.5`。GPT-5.6 明确的 `priority` 选择 Fast Long，明确的 `flex` 选择 Flex Long；未发布 Fast Long 价的旧模型选择 Standard Long。边界严格使用 `input_tokens > 272_000`，恰好 272K 仍选择 Short 行。

旧版 `settings.codexFastModeBilling` 偏好不再参与计价，设置页也不再提供“未标记按 Fast”入口；底层回填函数暂时保留同名参数，仅用于源码兼容，传入任何值都不会把未知事件改成 Fast。

## Codex 计费公式

Codex JSONL 里的 `token_count.info.total_token_usage` 是会话内累计值。`RolloutParser` 将它与上一条累计值相减，得到每次 delta；如果累计计数回退，认为上下文重置，把当前累计值当成新段落的首个 delta。

Codex 单行回填公式：

```text
value_usd =
  (
    max(input_tokens - cached_input_tokens - cache_creation_tokens, 0)
        * selected_row.input_price_per_million
    + cached_input_tokens * selected_row.cached_input_price_per_million
    + cache_creation_tokens * selected_row.cache_creation_price_per_million
    + output_tokens * selected_row.output_price_per_million
  ) / 1_000_000
```

注意点：

- `input_tokens` 是 gross input，已经包含 cached input 与 cache write input，所以普通输入只对 `input - cached - cache_write` 计费。
- `cache_write_input_tokens` 通过 provider-neutral 的 `cache_creation_tokens` 列保存。GPT-5.6 及以后 row 的 write 单价是对应 uncached input 的 `1.25x`；GPT-5.5 及更早 row 没有额外 write charge，因此 write 单价等于 input。所有值都预先物化，没有 fallback。
- `output_tokens` 已经包含 reasoning output；`reasoning_output_tokens` 是拆分字段，不额外计费，否则会重复计算。
- 旧 Codex session 缺少模型时 fallback 到 `gpt-5`，并设置 `model_inferred = true`，UI 可提示该行是近似估算。
- 每行按 timestamp、tier 和 `>272K` 边界直接选择一个最终 catalog row。

## Claude 计费公式

Claude rollout 的 `assistant.message.usage` 是每条消息的独立用量，不需要累计差分。导入器只消费 `assistant` 事件，跳过 `<synthetic>` 模型和全 0 usage 的占位消息。相同 `message.id` 会在同一解析 pass 和 SQL 层去重。

Claude 单行回填公式：

```text
value_usd =
  (
    input_tokens * input_price_per_million
    + cached_input_tokens * cached_input_price_per_million
    + cache_creation_5m_billable * cache_creation_price_per_million
    + cache_creation_1h_billable * (input_price_per_million * 2.0)
    + output_tokens * output_price_per_million
  ) / 1_000_000
```

其中：

```text
if cache_creation_5m_tokens + cache_creation_1h_tokens > 0:
  cache_creation_5m_billable = cache_creation_5m_tokens
  cache_creation_1h_billable = cache_creation_1h_tokens
else:
  cache_creation_5m_billable = cache_creation_tokens
  cache_creation_1h_billable = 0
```

这个 fallback 是为了兼容旧导入数据：如果还没有 5m / 1h 拆分列的真实值，就维持过去“全部按 5m cache write 价格”的行为，而不是把 cache write 成本算成 0。

当前 Claude cache 口径：

- cache read：通过 `cached_input_price_per_million` 表达，通常是 `0.1x input`。
- 5m cache write：通过 `cache_creation_price_per_million` 表达，通常是 `1.25x input`。
- 1h cache write：直接按内置 `input_price_per_million` 的 `2.0x` 计算。

`Migrations` 的 `v6-claude-cache-creation-duration` 增加了 `cache_creation_5m_tokens` 和 `cache_creation_1h_tokens`，并把 Claude `import_state` 标记为需要从 0 offset 全量重读。这样已有 Claude 行会在下一次扫描时重新导入，补齐 1h / 5m 拆分后再回填正确金额。

## 回填触发点

`value_usd` 是派生值，以下路径会重算：

- 扫描有文件变化时：各 provider 导入器在写入事件与 checkpoint 的同一事务内，只回填本次新增事件或重建 session。
- App 升级后内置目录的计算字段发生变化，或旧价格来源需要归一为 `bundled` 时：数据库启动流程先安装目录，再执行完整回填。

没有匹配 `pricing_catalog` 的事件不会被回填，原 `value_usd` 保持不变。新导入事件默认是 0，所以未知模型会显示为 0 美元，直到 catalog 有对应价格并触发回填。

## 聚合和展示

UI 不重复实现计费公式。

- Dashboard / History / Sessions 通过聚合查询读取 `usage_events.value_usd`。
- Claude 5 小时 billing block 由 `BillingBlocks` 从 Claude `usage_events` 重建。block token 数使用原始 token 字段汇总，block cost 直接汇总 `value_usd`。
- `cache_creation_tokens` 是共用 cache write 总量：Claude 金额精度由 5m / 1h 拆分列决定，Codex 直接使用该列保存 rollout 的 cache write input。

## 已知边界

- 这是 API-equivalent spend，不是 Codex / Claude 订阅费用，也不一定等于供应商账单。
- Codex 只为 OpenAI 已公布 272K 规则的支持模型生成和选择 Long 行。Claude 及没有公布该规则的模型不会生成或选择这类行。
- 区域以及未持久化的实际服务层、执行层倍率暂不纳入当前计费要求。例如 regional processing、data residency、batch、Claude `inference_geo`、Opus fast tier、server-side tool 费用等，都需要逐请求字段或账单侧数据才能准确还原。上文的 Codex Priority/Fast/Flex 逻辑只按 rollout 记录的偏好估算，不能突破这条 served-tier 边界。
- 未随 App 内置价格的未知模型不会获得美元估值；需要在新版本中加入模型行后才会开始计价。
- 近期 Codex 混合历史可以按 turn 中冻结的 `priority` / `default` / `flex` 偏好分别估算；没有 `thread_settings_applied` / `task_started` 证据的旧版或未标记事件仍为 `NULL`，并按 Standard 估算。两种情况都不等同于还原服务端实际 served tier。
- Codex 缺模型的历史事件按 `gpt-5` 估算，`model_inferred = true`。
- Claude 旧数据必须经过 v6 迁移后的重新扫描，才能从“全部按 5m cache write”升级为 1h / 5m 分开计价。

## 维护清单

新增模型或调整计费时，至少检查这些点：

1. 在 `BundledPricingCatalog.entries` 加入或修正模型价格。
2. 如果是 Codex Fast、Flex 或支持超过 272K 的模型，更新对应 catalog 构造映射，确认 Short/Long × tier 最终行完整且数值正确。
3. 如果供应商价格发生变化，在更新当前内置行的同时为旧价格增加有效日期区间，避免重算历史用量。
4. 如果新增 token 类型或 provider，优先复用语义一致的 provider-neutral 列；只有现有行形状无法表达时才扩展 `usage_events` schema，再同步扩展 parser、importer、CSV 与 `PricingService.backfillAllValues`。
5. 补 `PricingValueBackfillTests`，固定最终美元公式。
6. 如果改导入字段，补对应 parser / importer 测试，避免金额正确但原始 token 写错。
