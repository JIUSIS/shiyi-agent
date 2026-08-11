# 更新日志

详细开发修复记录见 [docs/fix-log.md](docs/fix-log.md)，此处记录对外发布版本的变化。

## [1.1.6] - 2026-08-11

### 新增

- **上下文统计改为 Codex 口径**：最近一次服务端真实 `total_tokens` 作为基线，加上最后一条模型生成之后新增消息的本地估算；服务端没返回过 usage 时回退到统一 Token 估算。
- **usage 字段兼容**：`LlmClient.applyUsage` 同时支持 Chat Completions 与 Responses API 的 `input_tokens` / `output_tokens` / `input_tokens_details.cached_tokens` / `cached_input_tokens` 等字段。
- sessions 表升到 v12，新增 `last_usage_total_tokens` 列持久化统计基线。

### 优化

- 状态栏、压缩判断、发送前阈值统一走同一个上下文统计入口；删除 / 重新生成 / 压缩历史时清空旧 usage，避免显示残值。
- 新增 `test/token_usage_test.dart`，覆盖 usage 字段兼容与真实基线统计。

### 验证

- `flutter analyze` 无告警；`flutter test` 72 项全部通过。
- release 真机覆盖安装（`adb install -r`）验证通过：`1.1.6+10`。

## [1.1.7] - 2026-08-11

### 修复

- **上下文压缩不再删除历史**：messages 表升到 v13 新增 `archived` 标记，压缩只把早期消息标记归档，完整原文保留在本地；需要时可搜索或重新读取。
- **压缩后上下文立即下降**：已归档消息从状态栏、压缩判断、请求 payload 与 Token 估算中统一排除，不再继续占用输入框上方的上下文统计。
- **压缩不再丢工具记忆**：摘要输入保留完整工具轮的结构化信息（命令 / 路径 / 结果 / 错误 / 结论）；最近工具回合继续按 `tool_calls` + `tool_call_id` 成组保留，不拆散配对。

### 优化

- 压缩边界按 Token 预算选择，不再只按“前 60% 条数”一刀切：至少归档早期 60%，预算紧张时按 Token 归档更多。
- 滚动摘要持久化到 `sessions.rolling_summary`，后续每轮注入系统提示；不再插入假的“【历史会话摘要】”用户消息污染对话。
- 手动压缩弹窗改为“归档早期历史，完整历史保留在本地”；压缩完成后提示归档条数与上下文变化；聊天列表顶部新增“已归档 N 条 · 不占用当前上下文”分隔提示。

### 验证

- `flutter analyze` 无告警；`flutter test` 77 项全部通过（新增归档统计跳过、压缩边界 Token 预算、工具轮成组不拆散、归档标记落库往返回归用例）。
- release 真机覆盖安装（`adb install -r`）验证通过：`1.1.7+11`。

## [1.1.5] - 2026-08-11

### 新增

- **真实缓存命中率显示**：状态栏单行追加 `缓存 75%`，按 API 返回的 usage（`cached_tokens` / `cache_read_input_tokens` 等）做 Token 加权累计；服务端明确返回 0 时显示 `缓存 0%`，未提供缓存字段时显示 `缓存 --`。
- **上下文管理升级**：完整工具回合按 `tool_calls` 与 `tool_call_id` 成组保留最近 3 轮；上下文占用 60% 起压缩旧工具结果、75% 起生成滚动任务摘要、85% 才强制裁剪；纯工具轮也落库，会话重开不丢工具记忆。

### 优化

- **上下文预算统一 Token 口径**：UI 当前上下文、发送前阈值判断、裁剪后 Token 数统一走同一估算入口；`contextLimit` 不再被除以 4 当字符预算，`content.length` 不再直接与 Token 预算比较。
- **裁剪提示改为一次性事件**：不再显示“仍接近上限”的误导横幅，改为 4 秒内显示裁剪前后 token；状态栏始终显示裁剪后的实际上下文，压缩判断继续使用全量估算。

### 修复

- 修复 128K 上下文提前裁剪：预算统一为 Token，`usableInputTokens = contextLimit − 实际 maxOutputTokens − 2% 安全余量`；只有 `estimatedInputTokens > usableInputTokens` 才硬裁剪，裁剪目标同步扣除 system 与工具定义，并输出 `TrimBudget` 诊断日志（system/tool/history/current/image/outputReserve/trigger/target 全带 Token 单位）。
- 会话上下文统计口径统一：上下文估算计入 `tool_calls`，字符与 token 不再混用；无 usage 兜底改为统一 token 估算；子代理消耗计入「本轮」；会话切走不再污染统计显示。
- 聊天代码块偶尔多出一个空代码框：闭合围栏不再被拆成独立块，空围栏不渲染，流式未闭合围栏也不生成空框。
- memories 表新装库缺 `type` 列：建表补列 + 启动兜底检查，缺失时自动补列，避免保存记忆报 `table memories has no column named type`。

### 验证

- `flutter analyze` 无告警；`flutter test` 50 项全部通过（新增 128K/33K 不裁剪、100K 不裁剪、超预算裁剪、工具定义占用预算、请求级 Token 估算、多轮工具与图片回归用例）。
- release 真机覆盖安装（`adb install -r`）验证通过：`1.1.5+9`，数据库保留；128K 配置下实测 2.4 万 Token 请求 `shouldTrim=false`，不再提前裁剪。

## [1.1.4] - 2026-08-11

### 新增

- **输出上限可调**：设置页「上下文」新增「输出上限」（512~384000，默认 8192），主循环与子代理统一读取，思考型模型长输出不再被打断；网关拒绝过大的 `max_tokens` 时会自动降级 8192 重试。
- **新增 OpenCode Go 预设**（`deepseek-v4-flash`），建议输出上限 32768，长任务可开更高上限。
- **发送前按上下文预算裁剪历史**：按 `contextLimit × 0.9 − 系统提示 − 真实工具定义` 计算预算，从最新往回保留历史；长会话继续对话不再因超出 `contextLimit` 被网关拒绝。

### 优化

- **缓存命中优化**：当前时间从 system prompt 中段移到末尾，base、工具规则、工作目录、记忆、技能保持稳定前缀，跨分钟只改尾部一小截，服务端缓存可跨分钟复用，命中率与首字速度提升。
- **Markdown 解析缓存 + 流式刷新节流**：同一文本只解析一次；流式输出按 80ms / 200 字符节流刷新，长文更顺滑，动画与渲染体验不降级。
- **页面重建收敛**：主页只监听初始化状态（`loadedNotifier` / `initErrorNotifier`），聊天列表只监听消息版本（`messagesRevision`），状态条、token 统计、工具事件变化不再触发整页重建。

### 修复

- `fr=length` 且正文为空时改为整轮重试，并注入「不要长篇思考，直接输出结果 / 调用工具」，避免思考内容打满输出上限时空转；首包超时从 30s 放宽到 60s。
- 修复思考型模型长任务时 `reasoning` 打满 `max_tokens`、正文一直不开始的场景。

### 验证

- `flutter analyze` 无告警；`flutter test` 29 项全部通过（含新增上下文预算裁剪单元测试）。
- release 真机覆盖安装（`adb install -r`），数据保留；35 秒采样 218 帧、0 janky。

## 历史版本

- v1.1.0 / v1.1.1 及更早版本的变更与修复见 [docs/fix-log.md](docs/fix-log.md)。
