# 更新日志

详细开发修复记录见 [docs/fix-log.md](docs/fix-log.md)，此处记录对外发布版本的变化。

## [1.1.5] - 2026-08-11

### 修复

- memories 表新装库缺 `type` 列：建表补列 + 启动兜底检查，缺失时自动补列，避免保存记忆报 `table memories has no column named type`。
- 聊天代码块偶尔多出一个空代码框：闭合围栏不再被拆成独立块，空围栏不渲染，流式未闭合围栏也不生成空框。
- 会话上下文统计口径统一：上下文估算计入 `tool_calls`，字符与 token 不再混用；无 usage 兜底改为统一 token 估算；子代理消耗计入「本轮」；会话切走不再污染统计显示。
- 上下文裁剪提示改为一次性事件：不再显示“仍接近上限”的误导横幅，改为 4 秒内显示裁剪前后 token；状态栏始终显示裁剪后的实际上下文，压缩判断继续使用全量估算。
- 上下文管理：完整工具回合按 `tool_calls` 与 `tool_call_id` 成组保留最近 3 轮，60% 起压缩旧工具结果、75% 起生成滚动任务摘要、85% 才强制裁剪；纯工具轮也落库，会话重开不丢工具记忆。
- 新增缓存命中率显示：状态栏单行追加 `缓存 75%`，使用 API 真实 usage 按 Token 加权累计，服务端未返回缓存字段时显示 `缓存 --`。
- 修复 128K 上下文提前裁剪：预算统一改为 Token，`usableInputTokens = contextLimit − 实际 maxOutputTokens − 2% 安全余量`；只有 `estimatedInputTokens > usableInputTokens` 才硬裁剪，裁剪目标同步扣除 system 与工具定义，并输出 `TrimBudget` 诊断日志（system/tool/history/current/image/outputReserve/trigger/target 全带 Token 单位）。

### 验证

- `flutter analyze` 无告警；`flutter test` 50 项全部通过（新增 128K/33K 不裁剪、100K 不裁剪、超预算裁剪、工具定义占用预算、请求级 Token 估算、多轮工具与图片回归用例）。
- 真机 `af3700b1` 覆盖安装验证通过：`1.1.5+9`，数据库保留；实测 2.4 万 Token 请求 `shouldTrim=false`，128K 配置下不再提前裁剪。

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
