# QuotaMonitor 计费逻辑

本文梳理项目当前的 API-equivalent 计费链路。这里的金额不是订阅账单或平台真实扣费记录，而是 QuotaMonitor 根据本机 Codex / Claude 使用日志和模型价格表复算出的美元估值。核心落点是 `usage_events.value_usd`：导入器负责写入 token 明细，`PricingService.backfillAllValues` 负责按价格表统一回填金额，UI 和报表只读取这个派生值。

## 核心数据流

1. 启动或扫描前，`DatabaseManager` / `ImportEngine` 会调用 `PricingService.seedCatalog`，确保 `pricing_catalog` 至少有内置模型价格。
2. Codex 导入器读取 `~/.codex/sessions` / `archived_sessions` JSONL，把累计的 `token_count.info.total_token_usage` 转成每次增量；如果当前 `turn_context` 带有 `fast_mode` / `quick_mode` 标记，会同时写入该 turn 的 Fast / Standard 分类。
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
| `turn_id` | Codex turn id，用于 CSV 导出和调试时关联同一轮对话。 |
| `billing_tier` | Codex 计费档位：`fast`、`standard` 或 `unknown`。Claude 默认 `unknown`，不参与 Codex tier 展示。 |
| `billing_tier_source` | Codex tier 来源：`jsonl`、`missing_marker`、`legacy`、`not_codex` 等。 |

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

`PricingSeed.entries` 是随应用发布的内置价格表。它覆盖当前支持的 OpenAI / Codex 模型、Claude 模型，以及 Codex Fast Mode 的合成 `*-fast` 行。

LiteLLM 同步由 `LiteLLMPricingSource` 拉取 `model_prices_and_context_window.json`，再由 `PricingService.applyLiteLLMUpdate` 写入 `pricing_catalog`。当前策略是只更新 catalog 中已经存在、且 `price_source != 'local'` 的模型，不自动新增任意未知模型。这样可以避免把 LiteLLM 的大量无关 provider 直接塞进本地表，但也意味着新模型需要先加入 seed 或用户手工建行，之后 LiteLLM 才能持续刷新它。

Codex Fast Mode 现在是 JSONL 标记优先、设置兜底：当 `billing_tier = 'fast'` 且模型在 `CodexFastMode.multipliers` 中时，`PricingService` 不使用原 `model_id`，而是匹配合成行 `<model_id>-fast`；当 `billing_tier = 'standard'` 时始终按基础价格计费；当 `billing_tier = 'unknown'` 时，才由 Settings 里的“未识别 Codex 按 Fast Mode 计费”开关决定是否使用 `*-fast` 行。当前 multiplier 在代码里维护，例如 `gpt-5.5 = 2.5x`、`gpt-5.4 = 2.0x`。

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
- Fast Mode 不改变公式和 token 口径，只改变 `pricing_catalog` 的匹配行：JSONL 标记确认的 Fast 使用 `*-fast`；JSONL 标记确认的 Standard 使用基础行；未知档位按设置兜底。

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
- Codex Fast Mode 开关变化时：`applyCodexFastModeBilling` 重新回填所有事件。

没有匹配 `pricing_catalog` 的事件不会被回填，原 `value_usd` 保持不变。新导入事件默认是 0，所以未知模型会显示为 0 美元，直到 catalog 有对应价格并触发回填。

## 聚合和展示

UI 不重复实现计费公式。

- Dashboard / History / Sessions 通过聚合查询读取 `usage_events.value_usd`。
- Claude 5 小时 billing block 由 `BillingBlocks` 从 Claude `usage_events` 重建。block token 数使用原始 token 字段汇总，block cost 直接汇总 `value_usd`。
- `cache_creation_tokens` 仍保留为 Claude cache write 总量，用于 token 汇总和展示；金额精度由 5m / 1h 拆分列决定。

## 已知边界

- 这是 API-equivalent spend，不是 Codex / Claude 订阅费用，也不一定等于供应商账单。
- Long Context / 大上下文 tier 暂不纳入当前计费要求。QuotaMonitor 的输入源是本地 Codex / Claude 使用日志，而不是供应商账单；这些日志没有稳定记录每次请求是否触发 long-context tier。因此 `above_200k_input_price_per_million` 和 `above_200k_output_price_per_million` 目前只保存，不参与计费公式。这是估算边界，不是当前必须解决的计费缺口。
- 区域、执行层和未支持服务层倍率暂不纳入当前计费要求。例如 regional processing、data residency、flex / batch、Claude `inference_geo`、Opus fast tier、server-side tool 费用等，都需要更完整的逐请求字段或账单侧数据才能准确还原；当前实现只对 Codex JSONL 能确认的 Fast vs Standard 做逐事件计价。
- LiteLLM 当前只更新已存在于本地 catalog 的模型；新模型需要 seed 或本地建行。
- `price_source = 'local'` 的行不会被 LiteLLM 或 seed 覆盖。
- 并非所有 Codex JSONL 都带有 `fast_mode` / `quick_mode` 标记；缺标记的事件保持 `unknown`，只能按用户的兜底设置估算，不能完全还原供应商账单。
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
