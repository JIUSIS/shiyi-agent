# 更新日志

详细开发修复记录保存在本地 `docs/fix-log.md`（仅本地维护，不随仓库发布），此处记录对外发布版本的变化。

## [2.5.5] - 2026-08-23

相对 2.5.3：对话和搜索可走自定义 SOCKS5（本机 Clash 自动检测或手动添加服务器）；可选「活人感」；去掉会话页阈值弹出的压缩按钮。

### 新增

- **SOCKS5 代理通道**：设置 → 通用 → SOCKS5 代理。国内 IP 被小蓝等中转站拦截时可走境外出口。三种模式：
  - 关闭（直连）
  - 自动检测本机 Clash / FlClash / V2RayN / SS 常见端口（7890 / 7891 / 7897 / 10808 / 1080），握手确认为 SOCKS5 才采用
  - 自定义：可保存多台服务器，支持粘贴 `socks5://user:pass@host:port` 或 `host:port`，点选切换
- 对话、拉模型列表、联网搜索走该 SOCKS5；密码进安全存储，不进明文 JSON。DSH 安装用的 HTTP 自动代理仍是另一套。
- **可选活人感**（默认关）：本地先生成本轮内心话，模型只负责讲出来，不改工具工作台管线。

### 优化

- 会话上下文达到阈值时不再弹出右下角「压缩上下文」胶囊，只保留输入区常驻压缩按钮。
- SOCKS5 设置页分组底部说明改为 12 号灰色提示，不再跟标题一样大。

### 验证

- `flutter analyze` 针对 SOCKS5 / 活人感 / 会话页改动无告警。
- `flutter test test/socks5_proxy_test.dart test/settings_model_test.dart test/web_tools_test.dart test/presence_engine_test.dart test/prompt_section_test.dart` 全部通过。
- 正式包同签名覆盖安装，未卸载、未清数据。

## [2.5.3] - 2026-08-22

相对 2.5.2：DSH 0.1.1 启动不再被旧凭据文件拦住；OpenRouter 注入不再 HTTP 400；安装 DSH 不再因过期 npm 清单漏掉已发布版本。

### 修复

- **DSH 0.1.1 凭据文档**：`.credentials.yaml` 改为 `version: 1` + `refs:`。旧扁平 `SHIYI_API_KEY:` 顶层映射、以及 DSH 迁完 version 后又被旧写入器追加到顶层的密钥，启动同步都会收进 `refs`，不再报 `unknown top-level key`。「修复完整运行环境」修不了这件事，冷启动会先改文件再拉 DSH。
- **OpenRouter 在 DSH 返回 400**：注入 `compat.supportsStore: false`，避免 pi-ai 把 `store: false` 转发给 OpenRouter。`openai/gpt-4o` 不再被裸关键字 `gpt` 当成思考模型，因而也不会误发 `reasoning`。
- **gpt-4o / gpt-4.1 / gpt-3.5 不是思考模型**：只有 gpt-5 / Codex 才默认 `high` 并走思考档位。
- **安装 DSH 不再带 `--prefer-offline`**：Alpine 里过期 packument 会把已发布的 `0.1.1-rc.x` 当成不存在。依赖 tarball 仍走本地缓存，只强制刷新清单。

### 验证

- `flutter analyze` 针对同步与思考目录无告警。
- `flutter test test/dsh_model_sync_test.dart test/dsh_service_test.dart test/reasoning_models_test.dart` 全部通过。
- 真机 `2509FPN0BC` 使用 `adb install -r` 覆盖安装 debug 包验证凭据迁移路径；正式包同签名覆盖安装。

## [2.5.2] - 2026-08-21

### 修复

- DSH 检查更新不再只信 npm `dist-tags.latest`。`0.1.0-rc.8` 已发布但 latest 仍停在 `0.1.0-rc.7` 时也能检出；只跟 latest 同一条版本线，不会把 `next` 的 `0.1.1-rc.1` 当成当前更新。

## [2.5.1] - 2026-08-20

相对 2.5.0：自定义 Claude / GPT / Grok 等模型在会话页显示思考按钮；Anthropic 原生协议可刷新模型列表。

### 新增

- **思考档位按模型 ID 关键字识别**：`gpt-5.6` 认 `gpt`，`deepseek-v4-flash` 认 `deepseek`，不绑死版本号。覆盖 Claude、GPT、o 系列、Grok、Gemini、DeepSeek、Qwen、GLM、Kimi、豆包等常见家族。
- **对不上关键字也显示思考按钮**：llama、本地 7B 等给出通用档位，默认不自动往请求里塞 thinking。
- **拾忆与 DSH 共用同一套目录**：`ReasoningModels` 同时驱动会话页按钮和 DSH `settings.yaml` 注入。

### 修复

- Anthropic Messages「刷新模型」不再提示协议不支持，改为 `GET /v1/models` 分页拉取（含 `x-api-key` + `anthropic-version`）。
- Claude 原生协议开启思考时发送 `thinking.budget_tokens`，且不发 `temperature`；budget 始终小于 `max_tokens`。
- GPT 关闭思考发 `reasoning_effort: none`（不能发 `off`）。

### 验证

- `flutter analyze` 针对思考目录与 Anthropic 列表无告警。
- `flutter test test/reasoning_models_test.dart test/llm_continuation_test.dart test/dsh_model_sync_test.dart test/reasoning_state_test.dart` 全部通过。

## [2.5.0] - 2026-08-20

相对 GitHub `v2.0.0` 的增量：双引擎工作台、Alpine 内嵌终端、会话页液态玻璃与思考控制，以及 DSH 配置自愈。

### 新增

- **双引擎切换**：可在拾忆本地引擎与 DeepSeek Harness 之间切换，会话、工作区与设置各自独立。
- **DeepSeek Harness 工作台**：工作区 / 功能 / 文件三 Tab，技能、模型、预设、插件与完整模式安装都在 App 内完成。
- **Alpine 内嵌终端**：proot + Alpine minirootfs 取代旧 Termux bootstrap，无需额外安装 Termux，也无需 root。
- **会话页悬空输入区**：拾忆与 DSH 共用液态玻璃输入条、消息入场动画和流式跟随。
- **思考控制**：输入区增加思考开关、思考强度与手动压缩。
- **DSH 多配置注入**：已保存的 API 配置可分别注入为独立 provider，互不覆盖。
- **Windows 桌面版**：无边框窗口、红黄绿三键、WSL2 / PowerShell / cmd 可选终端。

### 优化

- 安装 DSH 时默认展开日志，进度按真实步骤推进，完成后自动切到 DSH 引擎。
- 关于页重写软件描述与功能特性，引擎页拾忆介绍改为跨会话记忆、技能沉淀与工具调用。
- 检查更新弹窗按 Apple 设计理念重做；更新说明继续用会话同款 Markdown 渲染。
- 工具结果掐头去尾裁剪、系统提示词段落注册、自定义系统提示词 32KB 上限。

### 修复

- **启动 DSH 期间发送消息或切换模型不再损坏 YAML**：配置同步改为进程内串行队列，`settings.yaml` 用临时文件 + rename 原子替换。
- 已损坏的 `settings.yaml` 启动时自动备份为 `settings.yaml.corrupt` 并重建干净配置；「修复完整运行环境」只修 Alpine/Node/koffi，不误报 YAML 问题。
- 修复安装进度假进度、node-pty 探测误拆运行环境、缓存命中率漏读 DeepSeek 官方字段、上下文估算漏算 reasoning。
- 修复流式思考泄漏到正文、重复气泡、提问面板圆角阴影、引擎切换后页面空白 / 黑屏等问题。

### 验证

- `flutter analyze` 针对同步改动无告警；`flutter test test/dsh_model_sync_test.dart` 42 项全部通过。
- 真机 `9LKZL7TGZTJFZ575` 使用 `adb install -r` 覆盖安装，未卸载、未清除数据。

## [2.0.0] - 2026-08-13

### 新增

- **引入 Apple 设计思路（HIG）重构全 App UI**：主页、功能、文件、长期记忆、技能、日志、设置、关于页统一为 iOS 观感——大标题居中、Inset Grouped 分组卡片、毛玻璃导航与底部 Tab、圆角图标块、深浅色统一跟随。
- **底部三 Tab 重设计**：会话 / 功能 / 文件，自绘 iOS 毛玻璃栏，选中系统蓝、未选中灰，页面切换保持缓存与淡入。
- **设置页 iOS 化与二级菜单**：设置入口移到右上角，深浅色即时切换；模型 API / 上下文 / 外观 / 高级 / 关于按 Apple HIG 重排，图标统一圆角色块。
- **Anthropic Messages 协议自定义接口**：支持 `x-api-key` + `/v1/messages`，SSE 解析 thinking / 工具增量；内置 OpenAI、Anthropic Claude、Gemini、DeepSeek、Kimi、通义千问、智谱、豆包、OpenRouter、Groq、MiMo、OpenCode Go 常见 API 预设。
- **配置管理新建接口**：模型 API 预设二级菜单统一收口，支持 OpenAI / Anthropic 协议切换、自动补 `/v1`、测试连接、删除。
- **红绿灯全局状态**：思考中左上角红绿灯依次高亮闪烁、完成后全亮，主页 / 功能 / 文件 / 记忆 / 技能页同步；点击仍执行返回或新建。
- **消息气泡与工具栏**：气泡加宽为屏幕仅留一个工具栏图标宽度；朗读 / 复制 / 重新生成 / 记忆 / 技能 / 删除操作条常驻；长按面板 iOS 化并支持选择文字。
- **长期记忆多选批量删除、技能导入、日志自动刷新、关于页完整功能清单**。
- **项目与会话左滑圆形操作**：项目横幅左滑新建会话 / 项目文件夹 / 重命名 / 删除，点击空白自动收回，项目会话逐条展开。

### 优化

- **性能与健壮性**：原生压缩 / 解压移到后台线程，文件页与附件复制改异步读取，`run_terminal` 输出限流防内存溢出，Anthropic 自定义网关 `/v1` 归一化，移除会话页自绘返回手势改走系统预测性返回。
- 弹窗统一 180ms 纯淡入淡出，低端设备不再飞入卡顿；更新弹窗的 Release 说明使用与聊天会话同款 Markdown 渲染。
- 深浅色切换即时生效，主题卡片背景、设置页黄条、长按弹窗透明、工具胶囊底色、输入框对齐、记忆字体与卡片宽度等视觉细节统一收敛。

### 修复

- 修复主页 / 会话左滑不跟手、点空白不收、操作后不收回；项目与会话左滑按钮统一为圆形图标。
- 修复工具胶囊样式回归：恢复胶囊 + 阴影，底色与红绿灯同款，字体粗细 / 颜色统一。
- 修复气泡下方工具栏刷新不及时、输入条与背景圆角框不对齐、消息代码块空块等交互问题。
- 修复 API 自定义接口漏 `/v1` 导致回复不完整、Anthropic 网关填 `/v1` 拼出 `/v1/v1/messages` 的边界问题。

### 验证

- `flutter analyze` 无告警；`flutter test` 100 项全部通过。
- release 构建通过；真机 `f29c6ad8` 覆盖安装 `2.0.0+13`，`adb install -r` 输出 Success，`firstInstallTime` 未变化，数据保留。

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

## [1.1.8] - 2026-08-11

### 新增

- **项目分类管理会话**：主页按项目分组展示，点击项目标题即可展开 / 收起会话；项目操作集中在主页项目横幅左滑，会话可左滑“项目”按钮或通过聊天页目录面板移动到项目。
- **项目级工作目录**：项目可设置工作目录，项目下未单独设置目录的会话自动继承，不用每个会话重复配置；会话单独设置的目录仍优先于项目目录。
- **新建入口改为项目优先**：侧边栏和主页空状态的新建入口由“新建会话”改为“新建项目”，创建项目时必须选择文件夹位置；主页项目横幅左滑可直接在当前项目下新建会话。
- **项目横幅左滑操作**：主页项目横幅支持左滑，提供“新建会话 / 项目文件夹 / 重命名 / 删除”四个操作，样式与会话左滑保持一致；未分类横幅保留“新建会话”入口。
- **侧边栏精简**：侧边栏移除“项目”导航项，只保留“新项目”入口；项目管理能力全部由主页项目横幅左滑承担。

### 修复

- **主页会话列表不再“不刷新”**：删除、新建、重命名、移动会话后立即反映到主页，不再需要切换页面才看到变化；会话 tab 改为监听数据版本号增量重建。
- **主页会话卡片间距分离**：分组列表中的会话卡片间距统一为 8dp，不再紧贴重合；项目横幅与会话之间也保留独立间距。
- **左滑跟手优化**：项目和会话左滑改为 `AnimationController` 驱动，拖动时即时跟随手指、无回弹卡顿；松手后平滑吸附，展开判定阈值从半程降到 35%，更容易保持展开。
- **左滑点空白收回**：同一时间只保留一个展开的左滑卡片；点击列表空白、开始滑动其他卡片或点击已展开内容时，自动收回当前操作区。
- **版本检查读取真实版本号**：`UpdateService` 改用 `package_info_plus` 读取包内版本，不再因写死 `1.1.7` 把 `1.1.8` 误判为可更新；关于页、设置页、更新提示统一显示真实版本。
- **API Key 等密钥加密存储**：主密钥、视觉密钥、API 配置密钥从 SharedPreferences 明文迁移到 Android Keystore 加密存储（`flutter_secure_storage`），旧明文首次加载自动迁移并清理。
- **更新包签名校验**：下载完成后先比对 APK 与当前安装包签名，镜像源篡改包会取消安装；安装前同样二次校验。
- **技能包路径穿越封堵**：导入、导出与 `create_skill` 统一拒绝 `..`、绝对路径、反斜杠、盘符等不安全相对路径，压缩包恶意条目不再写入技能目录。
- **硬裁剪后状态栏显示实际 payload**：发送前裁剪后，输入框上方上下文改为显示裁剪后的真实请求 Token，不再停留裁剪前全量。
- **子代理失败不再伪装成功**：子代理 LLM 请求异常改为抛 `LlmException`，由主循环标记“子代理异常”，不再把“（子代理请求失败…）”当成功报告返回。
- **左滑操作执行后自动收回**：项目/会话左滑的重命名、项目文件夹、删除等操作结束后自动收起操作区，不再停留在展开状态。
- **技能列表不再静默删除超大行**：运行时 `listSkills` 只筛出可安全加载的行，超大行交给迁移期清理；坏库中的数字字段改用 `tryParse` 兜底，避免启动失败。

### 验证

- `flutter analyze` 无告警；`flutter test` 81 项全部通过（新增技能路径安全回归 3 项）。
- release 构建通过；版本保持 `1.1.8+12`，直接替换 GitHub `v1.1.8` Release APK。

## [1.1.7] - 2026-08-11

### 修复

- **上下文压缩不再删除历史**：messages 表升到 v13 新增 `archived` 标记，压缩只把早期消息标记归档，完整原文保留在本地；需要时可搜索或重新读取。
- **压缩后上下文立即下降**：已归档消息从状态栏、压缩判断、请求 payload 与 Token 估算中统一排除，不再继续占用输入框上方的上下文统计。
- **压缩不再丢工具记忆**：摘要输入保留完整工具轮的结构化信息（命令 / 路径 / 结果 / 错误 / 结论）；最近工具回合继续按 `tool_calls` + `tool_call_id` 成组保留，不拆散配对。

### 优化

- 压缩边界按 Token 预算选择，不再只按“前 60% 条数”一刀切：至少归档早期 60%，预算紧张时按 Token 归档更多。
- 滚动摘要持久化到 `sessions.rolling_summary`，后续每轮注入系统提示；不再插入假的“【历史会话摘要】”用户消息污染对话。
- 手动压缩弹窗改为“归档早期历史，完整历史保留在本地”；压缩完成后提示归档条数与上下文变化；聊天列表顶部新增“已归档 N 条 · 不占用当前上下文”分隔提示。
- 更新弹窗的 Release 说明改用与聊天会话同款的 Markdown 渲染，标题、列表、代码块、表格、链接不再以纯文本显示。

### 验证

- `flutter analyze` 无告警；`flutter test` 78 项全部通过（新增归档统计跳过、压缩边界 Token 预算、工具轮成组不拆散、归档标记落库往返、更新弹窗 Markdown 渲染回归用例）。
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

- v1.1.0 / v1.1.1 及更早版本的变更与修复见本地 `docs/fix-log.md`（仅本地维护）。
