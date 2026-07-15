# QuotaMonitor 计费逻辑

本文梳理项目当前的 API-equivalent 计费链路。这里的金额不是订阅账单或平台真实扣费记录，而是 QuotaMonitor 根据本机 Codex / Claude 使用日志和模型价格表复算出的美元估值。核心落点是 `usage_events.value_usd`：导入器负责写入 token 明细，`PricingService.backfillAllValues` 负责按价格表统一回填金额，UI 和报表只读取这个派生值。

## 核心数据流

1. 启动或扫描前，`DatabaseManager` / `ImportEngine` 会调用 `PricingService.seedCatalog`，确保 `pricing_catalog` 至少有内置模型价格。
2. Codex 导入器读取 `~/.codex/sessions` / `archived_sessions` JSONL，把累计的 `token_count.info.total_token_usage` 转成每次增量。
3. Claude 导入器读取 `~/.claude/projects` 和 `~/.config/claude/projects` JSONL，把每条 `assistant.message.usage` 作为独立用量事件。
4. 导入器写入 `sessions` 和 `usage_events`，新事件初始 `value_usd = 0`。
5. `ScanController.runScan` 在 Codex 和 Claude 扫描都完成后，如果有文件变化，会调用一次 `PricingService.backfillAllValues`。
6. 价格同步和恢复默认价格也会触发回填。
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
| `above_200k_*` | LiteLLM 暴露的其他大上下文价格字段；Codex 的 272K 规则由确定的请求级倍率单独计算。 |

## 价格来源

`PricingSeed.entries` 是随应用发布的内置价格表。它覆盖当前支持的 OpenAI / Codex 模型、Claude 模型，以及 Codex Fast / Flex 估算使用的合成 `*-fast`、`*-flex` 行。

LiteLLM 同步由 `LiteLLMPricingSource` 拉取 `model_prices_and_context_window.json`，再由 `PricingService.applyLiteLLMUpdate` 写入 `pricing_catalog`。当前策略是只更新 catalog 中已经存在、且 `price_source != 'local'` 的模型，不自动新增任意未知模型。这样可以避免把 LiteLLM 的大量无关 provider 直接塞进本地表，但也意味着新模型需要先加入 seed 或用户手工建行，之后 LiteLLM 才能持续刷新它。

`CodexFastMode.multipliers` 在代码里维护支持 Fast 估算的模型及倍率，例如 `gpt-5.5 = 2.5x`、`gpt-5.4 = 2.0x`。每个合成 `<model_id>-fast` 行会把对应模型的 input、cached input 和 output 单价都乘以该倍率；Codex 金额公式本身不变。未列入该映射的 Codex 模型，以及所有 Claude 事件，都不会使用这些倍率。

`CodexFlexMode.multipliers` 维护 OpenAI 已公布 Flex 价格的模型。当前这些模型的 input、cached input 与 output 都是 Standard 的 `0.5x`，因此合成 `<model_id>-flex` 行统一由基础价格乘以 `0.5` 得出；LiteLLM 刷新基础行时会同步刷新对应 Fast 和 Flex 行，避免派生价格漂移。

## Codex 服务档位偏好与 Fast 估算

### Rollout 证据与 turn 冻结

Codex rollout 的 `event_msg/thread_settings_applied` 表示一个面向**未来 turn** 的线程偏好。`RolloutParser` 按 JSONL 文件行顺序处理事件，不用 timestamp 重新排序：`thread_settings_applied` 只更新待生效偏好，下一条 `task_started` 才把当时的偏好冻结到新 turn。活跃 turn 中途出现新的设置事件不会改写该 turn；它从下一个 `task_started` 起生效。

解析器把 `priority` / `fast` 归一为 `priority`，把明确的 `default` 保存为 `default`，并把明确的 `flex` 保存为 `flex`；缺失、空值或不支持的值保存为未知。`thread_settings_applied` 只能证明 Codex 记录了这个未来-turn 偏好：客户端仍可能按模型或功能支持情况过滤它，rollout 也没有持久化服务端最终响应的 tier。因此这些字段用于估价，不是偏好已传输或 OpenAI 最终按该 tier 提供服务的证明。

子代理或 fork rollout 会先重放父会话历史，并可能重写外层事件时间。解析器在首个 child `session_meta` 上建立门禁：重放期间的 `token_count` 只更新累计量基线、不生成 `usage_events`；只有遇到 `task_started.started_at >= 子会话创建时间` 的首个真实任务后才开始计费。累计 `total_token_usage` 与上一条完全相同时，即使 `last_token_usage` 内容变化也视为陈旧重发，不产生新增消费。

### 存储与兼容迁移

每个 Codex `usage_events` 行保存 `codex_turn_id` 和 `codex_service_tier_preference`。后者有 `priority`、`default`、`flex`、`NULL` 四种数据库状态；`NULL` 明确表示没有可用的持久化偏好证据。存储上仍保留未知状态，计价时则按保守规则选择 Standard，不能推断为 Fast 或 Flex。

迁移保留了未发布 trace 方案的兼容路径：`v13-codex-billing-tier` 先建立 `codex_turn_id` 与旧 `codex_billing_tier` 列，`v14-codex-rollout-tier-preference` 再把旧列改名为 `codex_service_tier_preference`、清除 Codex 的 trace 派生值，并把 Codex `import_state` 置为需要从 0 offset 重读。`v15-codex-pricing-policy-reprice` 会在启动查询前 seed 当前价格行并强制回填全部派生金额，确保旧版未知→Fast 金额和缺失的长上下文倍率不会滞留；之后的扫描再用持久化 rollout 偏好重建事件。

这次失效按 `import_state.session_id` 关联 `sessions.provider = 'codex'`，不依赖路径中出现 `/.codex/`。因此默认 home、自定义 `CODEX_HOME` 和 App Store 中用户选择的 Codex home 都在重读范围内。

### 价格行优先级

对已配置相应档位价格的 Codex 模型，价格行选择顺序如下：

| 每事件偏好 | 价格行 |
| --- | --- |
| `priority` | 在不超过 272K 输入时使用 `<model_id>-fast`。 |
| `flex` | 使用 `<model_id>-flex`。 |
| 明确的 `default` | 使用基础 `model_id`。 |
| `NULL` | 使用基础 `model_id`；没有 Fast 证据就按 Standard。 |

超过 272K 输入 Token 时，支持模型的整个请求进入长上下文计价：输入与 cached input 都乘 `2.0`，输出乘 `1.5`。OpenAI 当前不支持 Priority long context，因此即使 rollout 明确记录 `priority`，越过边界后也会改用基础 Standard 行再应用长上下文倍率；明确的 `flex` 保持 Flex 行，再应用相同倍率。边界严格使用 `input_tokens > 272_000`，恰好 272K 仍按普通上下文计价。

旧版 `settings.codexFastModeBilling` 偏好不再参与计价，设置页也不再提供“未标记按 Fast”入口；底层回填函数暂时保留同名参数，仅用于源码兼容，传入任何值都不会把未知事件改成 Fast。

## Codex 计费公式

Codex JSONL 里的 `token_count.info.total_token_usage` 是会话内累计值。`RolloutParser` 将它与上一条累计值相减，得到每次 delta；如果累计计数回退，认为上下文重置，把当前累计值当成新段落的首个 delta。

Codex 单行回填公式：

```text
value_usd =
  (
    max(input_tokens - cached_input_tokens, 0) * input_price_per_million * input_multiplier
    + cached_input_tokens * cached_input_price_per_million * input_multiplier
    + output_tokens * output_price_per_million * output_multiplier
  ) / 1_000_000
```

普通上下文的两个 multiplier 都是 `1.0`；支持模型在输入超过 272K 时，`input_multiplier = 2.0`、`output_multiplier = 1.5`。

注意点：

- `input_tokens` 是 gross input，已经包含 cached input，所以标准输入只对 `input - cached` 计费。
- `output_tokens` 已经包含 reasoning output；`reasoning_output_tokens` 是拆分字段，不额外计费，否则会重复计算。
- 旧 Codex session 缺少模型时 fallback 到 `gpt-5`，并设置 `model_inferred = true`，UI 可提示该行是近似估算。
- 每行先按“价格行优先级”选择基础行或合成 `*-fast` / `*-flex` 行，再按请求输入量决定是否应用长上下文倍率。

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

没有匹配 `pricing_catalog` 的事件不会被回填，原 `value_usd` 保持不变。新导入事件默认是 0，所以未知模型会显示为 0 美元，直到 catalog 有对应价格并触发回填。

## 聚合和展示

UI 不重复实现计费公式。

- Dashboard / History / Sessions 通过聚合查询读取 `usage_events.value_usd`。
- Claude 5 小时 billing block 由 `BillingBlocks` 从 Claude `usage_events` 重建。block token 数使用原始 token 字段汇总，block cost 直接汇总 `value_usd`。
- `cache_creation_tokens` 仍保留为 Claude cache write 总量，用于 token 汇总和展示；金额精度由 5m / 1h 拆分列决定。

## 已知边界

- 这是 API-equivalent spend，不是 Codex / Claude 订阅费用，也不一定等于供应商账单。
- Codex 只对 OpenAI 已公布 272K 规则的支持模型应用长上下文倍率。当前 Codex 模型目录把 GPT-5.6 的最大上下文限制在 272K，因此常规 GPT-5.6 请求不会越过边界；历史、自定义目录或允许更大窗口的模型仍可能触发。Claude 及没有公布该规则的模型不套用这一逻辑。
- 区域以及未持久化的实际服务层、执行层倍率暂不纳入当前计费要求。例如 regional processing、data residency、batch、Claude `inference_geo`、Opus fast tier、server-side tool 费用等，都需要逐请求字段或账单侧数据才能准确还原。上文的 Codex Priority/Fast/Flex 逻辑只按 rollout 记录的偏好估算，不能突破这条 served-tier 边界。
- LiteLLM 当前只更新已存在于本地 catalog 的模型；新模型需要 seed 或本地建行。
- `price_source = 'local'` 的行不会被 LiteLLM 或 seed 覆盖。
- 近期 Codex 混合历史可以按 turn 中冻结的 `priority` / `default` / `flex` 偏好分别估算；没有 `thread_settings_applied` / `task_started` 证据的旧版或未标记事件仍为 `NULL`，并按 Standard 估算。两种情况都不等同于还原服务端实际 served tier。
- Codex 缺模型的历史事件按 `gpt-5` 估算，`model_inferred = true`。
- Claude 旧数据必须经过 v6 迁移后的重新扫描，才能从“全部按 5m cache write”升级为 1h / 5m 分开计价。

## 维护清单

新增模型或调整计费时，至少检查这些点：

1. 在 `PricingSeed.entries` 加入或修正模型价格。
2. 如果是 Codex Fast、Flex 或支持超过 272K 的模型，更新对应 multiplier / long-context 映射，确认合成价格行和边界合理。
3. 如果 LiteLLM 已有对应模型，确认本地 catalog 有 seed 行，否则同步不会自动新增。
4. 如果新增 token 类型或 provider，先扩展 `usage_events` schema，再扩展 `PricingService.backfillAllValues`。
5. 补 `PricingValueBackfillTests`，固定最终美元公式。
6. 如果改导入字段，补对应 parser / importer 测试，避免金额正确但原始 token 写错。
