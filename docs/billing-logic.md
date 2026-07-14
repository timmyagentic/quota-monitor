# QuotaMonitor 计费逻辑

本文梳理项目当前的 API-equivalent 计费链路。这里的金额不是订阅账单或平台真实扣费记录，而是 QuotaMonitor 根据本机 Codex / Claude 使用日志和模型价格表复算出的美元估值。核心落点是 `usage_events.value_usd`：导入器负责写入 token 明细，`PricingService.backfillAllValues` 负责按价格表统一回填金额，UI 和报表只读取这个派生值。

## 核心数据流

1. 启动或扫描前，`DatabaseManager` / `ImportEngine` 会调用 `PricingService.seedCatalog`，确保 `pricing_catalog` 至少有内置模型价格。
2. Codex 导入器读取 `~/.codex/sessions` / `archived_sessions` JSONL，把累计的 `token_count.info.total_token_usage` 转成每次增量。
3. Claude 导入器读取 `~/.claude/projects` 和 `~/.config/claude/projects` JSONL，把每条 `assistant.message.usage` 作为独立用量事件。
4. 导入器写入 `sessions` 和 `usage_events`，新事件初始 `value_usd = 0`。
5. `ScanController.runScan` 在 Codex 和 Claude 扫描都完成后，如果有文件变化，会调用一次 `PricingService.backfillAllValues`。
6. 价格同步、恢复默认价格、Codex Fast Mode 切换也会触发回填。
7. Dashboard、History、Sessions、menu bar 和 Claude 5 小时 block 都读取 `usage_events.value_usd` 的聚合结果。

## 关键表

### `usage_events`

每行代表一次可计费用量事件。

| 字段 | 含义 |
| --- | --- |
| `provider` | `codex` 或 `claude`，回填公式按它分支。 |
| `model_id` | 用来匹配 `pricing_catalog.model_id`。 |
| `codex_turn_id` | Codex turn 标识；rollout 没有稳定 ID 时为 `NULL`。 |
| `codex_service_tier_preference` | Codex rollout 为该 turn 记录的服务档位偏好：`priority`、`default`，或用 `NULL` 表示未知。它不是实际 served tier。 |
| `input_tokens` | 输入 token。Codex 里是包含 cached input 的 gross input；Claude 里是未缓存输入。 |
| `cached_input_tokens` | Codex cached input 或 Claude cache read input。 |
| `output_tokens` | 输出 token。Codex 中已经包含 reasoning output，不再额外加 reasoning。 |
| `reasoning_output_tokens` | 只用于展示和分析，不参与金额计算。 |
| `cache_creation_tokens` | Claude cache write 总量；Codex 固定为 0。 |
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
| `cache_creation_price_per_million` | Claude 5 分钟 cache write 价格；OpenAI / Codex 为 0。 |
| `price_source` | `seed`、`litellm` 或 `local`。`local` 行不会被自动同步覆盖。 |
| `fetched_at` | 最近一次从 LiteLLM 成功同步该行的时间。 |
| `above_200k_*` | LiteLLM 暴露的大上下文价格，目前只存储，不参与回填公式。 |

## 价格来源

`PricingSeed.entries` 是随应用发布的内置价格表。它覆盖当前支持的 OpenAI / Codex 模型、Claude 模型，以及 Codex Fast 估算使用的合成 `*-fast` 行。

LiteLLM 同步由 `LiteLLMPricingSource` 拉取 `model_prices_and_context_window.json`，再由 `PricingService.applyLiteLLMUpdate` 写入 `pricing_catalog`。当前策略是只更新 catalog 中已经存在、且 `price_source != 'local'` 的模型，不自动新增任意未知模型。这样可以避免把 LiteLLM 的大量无关 provider 直接塞进本地表，但也意味着新模型需要先加入 seed 或用户手工建行，之后 LiteLLM 才能持续刷新它。

`CodexFastMode.multipliers` 在代码里维护支持 Fast 估算的模型及倍率，例如 `gpt-5.5 = 2.5x`、`gpt-5.4 = 2.0x`。每个合成 `<model_id>-fast` 行会把对应模型的 input、cached input 和 output 单价都乘以该倍率；Codex 金额公式本身不变。未列入该映射的 Codex 模型，以及所有 Claude 事件，都不会使用这些倍率。

## Codex 服务档位偏好与 Fast 估算

### Rollout 证据与 turn 冻结

Codex rollout 的 `event_msg/thread_settings_applied` 表示一个面向**未来 turn** 的线程偏好。`RolloutParser` 按 JSONL 文件行顺序处理事件，不用 timestamp 重新排序：`thread_settings_applied` 只更新待生效偏好，下一条 `task_started` 才把当时的偏好冻结到新 turn。活跃 turn 中途出现新的设置事件不会改写该 turn；它从下一个 `task_started` 起生效。

解析器把 `priority` / `fast` 归一为 `priority`，把明确的 `default` 保存为 `default`；缺失、空值或不支持的值保存为未知。`thread_settings_applied` 只能证明 Codex 记录了这个未来-turn 偏好：客户端仍可能按模型或功能支持情况过滤它，rollout 也没有持久化服务端最终响应的 tier。因此这些字段用于估价，不是偏好已传输或 OpenAI 最终按该 tier 提供服务的证明。

### 存储与兼容迁移

每个 Codex `usage_events` 行保存 `codex_turn_id` 和 `codex_service_tier_preference`。后者只有 `priority`、`default`、`NULL` 三种数据库状态；`NULL` 明确表示没有可用的持久化偏好证据，不能被自动推断成 Standard。

迁移保留了未发布 trace 方案的兼容路径：`v13-codex-billing-tier` 先建立 `codex_turn_id` 与旧 `codex_billing_tier` 列，`v14-codex-rollout-tier-preference` 再把旧列改名为 `codex_service_tier_preference`、清除 Codex 的 trace 派生值，并把 Codex `import_state` 置为需要从 0 offset 重读。升级后的下一次扫描会一次性重新解析现有 Codex rollouts，用持久化 rollout 偏好重建事件。

这次失效按 `import_state.session_id` 关联 `sessions.provider = 'codex'`，不依赖路径中出现 `/.codex/`。因此默认 home、自定义 `CODEX_HOME` 和 App Store 中用户选择的 Codex home 都在重读范围内。

### 价格行优先级

对 `CodexFastMode.multipliers` 支持的 Codex 模型，价格行选择顺序如下：

| 每事件偏好 | 价格行 |
| --- | --- |
| `priority` | 始终使用 `<model_id>-fast`，不受全局回退开关影响。 |
| 明确的 `default` | 始终使用基础 `model_id`，即使全局回退开关已开启。 |
| `NULL` 且回退开启 | 使用 `<model_id>-fast`。 |
| `NULL` 且回退关闭 | 使用基础 `model_id`。 |

也就是说，优先级是 `priority` > 明确 `default` > `NULL`/全局回退。现有 `settings.codexFastModeBilling` 键、`codexFastModeBilling` 属性和 `applyCodexFastModeBilling` 方法仍然保留，但开关现在只表示“未标记用量按 Fast 估算”。切换后仍会触发全量金额回填，实际价格行只会改变支持模型中偏好为 `NULL` 的事件；已标记的混合历史会逐 turn 保持各自的 `priority` 或 `default`。

## Codex 计费公式

Codex JSONL 里的 `token_count.info.total_token_usage` 是会话内累计值。`RolloutParser` 将它与上一条累计值相减，得到每次 delta；如果累计计数回退，认为上下文重置，把当前累计值当成新段落的首个 delta。

Codex 单行回填公式：

```text
value_usd =
  (
    max(input_tokens - cached_input_tokens, 0) * input_price_per_million
    + cached_input_tokens * cached_input_price_per_million
    + output_tokens * output_price_per_million
  ) / 1_000_000
```

注意点：

- `input_tokens` 是 gross input，已经包含 cached input，所以标准输入只对 `input - cached` 计费。
- `output_tokens` 已经包含 reasoning output；`reasoning_output_tokens` 是拆分字段，不额外计费，否则会重复计算。
- 旧 Codex session 缺少模型时 fallback 到 `gpt-5`，并设置 `model_inferred = true`，UI 可提示该行是近似估算。
- Codex Fast 估算不改变上述公式；每行先按“价格行优先级”选择基础行或合成 `*-fast` 行。

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
- 1h cache write：不依赖 LiteLLM 的 `cache_creation_input_token_cost`，直接按 `2.0x input_price_per_million` 计算。

`Migrations` 的 `v6-claude-cache-creation-duration` 增加了 `cache_creation_5m_tokens` 和 `cache_creation_1h_tokens`，并把 Claude `import_state` 标记为需要从 0 offset 全量重读。这样已有 Claude 行会在下一次扫描时重新导入，补齐 1h / 5m 拆分后再回填正确金额。

## 回填触发点

`value_usd` 是派生值，以下路径会重算：

- 扫描有文件变化时：`ScanController.runScan` 在两种 provider 扫描后统一调用 `backfillAllValues`。
- LiteLLM 同步成功且更新了 catalog 行时：`applyLiteLLMUpdate` 内部调用回填。
- 恢复默认价格时：`restorePricingDefaults` 先 seed，再回填。
- 未标记 Codex 用量的 Fast 回退开关变化时：`applyCodexFastModeBilling` 重新回填所有事件，但只有支持模型的 `NULL` 偏好行会改变价格选择。

没有匹配 `pricing_catalog` 的事件不会被回填，原 `value_usd` 保持不变。新导入事件默认是 0，所以未知模型会显示为 0 美元，直到 catalog 有对应价格并触发回填。

## 聚合和展示

UI 不重复实现计费公式。

- Dashboard / History / Sessions 通过聚合查询读取 `usage_events.value_usd`。
- Claude 5 小时 billing block 由 `BillingBlocks` 从 Claude `usage_events` 重建。block token 数使用原始 token 字段汇总，block cost 直接汇总 `value_usd`。
- `cache_creation_tokens` 仍保留为 Claude cache write 总量，用于 token 汇总和展示；金额精度由 5m / 1h 拆分列决定。

## 已知边界

- 这是 API-equivalent spend，不是 Codex / Claude 订阅费用，也不一定等于供应商账单。
- Long Context / 大上下文 tier 暂不纳入当前计费要求。QuotaMonitor 的输入源是本地 Codex / Claude 使用日志，而不是供应商账单；这些日志没有稳定记录每次请求是否触发 long-context tier。因此 `above_200k_input_price_per_million` 和 `above_200k_output_price_per_million` 目前只保存，不参与计费公式。这是估算边界，不是当前必须解决的计费缺口。
- 区域以及未持久化的实际服务层、执行层倍率暂不纳入当前计费要求。例如 regional processing、data residency、flex / batch、Claude `inference_geo`、Opus fast tier、server-side tool 费用等，都需要逐请求字段或账单侧数据才能准确还原。上文的 Codex Priority/Fast 逻辑只按 rollout 记录的偏好估算，不能突破这条 served-tier 边界。
- LiteLLM 当前只更新已存在于本地 catalog 的模型；新模型需要 seed 或本地建行。
- `price_source = 'local'` 的行不会被 LiteLLM 或 seed 覆盖。
- 近期 Codex 混合历史可以按 turn 中冻结的 `priority` / `default` 偏好分别估算；没有 `thread_settings_applied` / `task_started` 证据的旧版或未标记事件仍为 `NULL`，只能使用全局回退。两种情况都不等同于还原服务端实际 served tier。
- Codex 缺模型的历史事件按 `gpt-5` 估算，`model_inferred = true`。
- Claude 旧数据必须经过 v6 迁移后的重新扫描，才能从“全部按 5m cache write”升级为 1h / 5m 分开计价。

## 维护清单

新增模型或调整计费时，至少检查这些点：

1. 在 `PricingSeed.entries` 加入或修正模型价格。
2. 如果是 Codex Fast Mode 模型，更新 `CodexFastMode.multipliers`，确认合成 `*-fast` 行合理。
3. 如果 LiteLLM 已有对应模型，确认本地 catalog 有 seed 行，否则同步不会自动新增。
4. 如果新增 token 类型或 provider，先扩展 `usage_events` schema，再扩展 `PricingService.backfillAllValues`。
5. 补 `PricingValueBackfillTests`，固定最终美元公式。
6. 如果改导入字段，补对应 parser / importer 测试，避免金额正确但原始 token 写错。
