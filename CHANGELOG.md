# 更新日志

详细开发修复记录保存在本地 `docs/fix-log.md`（仅本地维护，不随仓库发布），此处记录对外发布版本的变化。

## [2.6.3] - 2026-09-01

相对 2.6.2：拾忆群聊升级为可长期推进的并行公司结构；流式输出和子代理 UI 更稳；群聊项目文件夹接入真实目录；缓存命中率与前端错误可以逐轮定位。

### 新增

- **群聊并行协作**：多个成员可同批生成，最多 3 个 Agent 并行；停止一次会取消当前所有活跃请求。
- **群聊项目文件夹**：编辑/新建群聊可选既有项目，也支持新建项目并选择真实磁盘目录；项目支持左滑删除，删除项目不删除真实文件，并清理会话和群聊房间里的旧引用。
- **群聊导入容错**：思维导图支持无 `/` 的角色名、嵌套角色、单行职责、多目标对接、箭头语义、常见分组别名、Tab/空格混用、空行、冒号与数字开头职责，不再因为格式写法丢节点。
- **群聊最小结构模板**：编辑群聊内置模板，可一键填入或复制给 Agent。
- **缓存命中指纹**：cache.usage / cache.unknown 日志新增本轮冻头 SHA-256 指纹（frozenSha256），逐轮可证冻头字节稳定；命中率差异定位到提供方/模型变体（硅基流动小上下文不缓存 + 空闲过期，OpenCode 小上下文即缓存）。
- **前端操作步骤日志**：RuntimeLogger 新增 uiGuard / uiRoute / uiStep；发送消息等前端操作开始记 ui.operation，失败记 ui.error（操作名+页面+会话+步骤+错误+堆栈）；所有日志自动带 data.ui.route / data.ui.step，未捕获异常也带 UI 上下文。

### 优化

- **群聊组织推进**：正常推进不再受“每人 2 次 / 整轮 12 次”固定限制；只有明确打回才计数，同一交接最多打回 3 次，避免返工死循环。
- **群聊失败可见**：接口失败、回复截断或请求异常会保留失败草稿并显示原因；某个成员失败后本轮停止，不再静默消失。
- **群聊滚动跟随**：生成中上滑查看历史不会被流式输出强行拉回；只有贴底或用户主动发送时才跟随最新。
- **流式输出**：新 token 逐字平滑追赶，换行时旧内容以 160ms 缓动上移；主聊天 / DSH / 群聊共用，子代理详情去掉增高动画并改为贴底跟随，避免乱跳。
- **消息列表动画**：新消息插入时旧消息平滑上移；入场从弹跳改成泡泡分离式淡入上升。
- **工具状态**：工具执行时流式气泡显示「正在使用工具」，不再常驻“思考中”；发出消息时用户气泡先出现，模型消息后出现。
- **子代理 UI**：mini 会话展开/收起对齐缓存弹窗，气泡边距对称，工具功能卡与气泡外壳统一。
- **关于页**：新增「太极群聊」能力说明。

### 修复

- 修复群聊 `project_id` 迁移 SQL 缺闭合引号导致的启动“初始化失败”。
- 修复群聊拉取历史被流式滚动打断、干到一半静默停止、被点名后仍停止的问题。
- 修复思维导图长职位丢角色、汇报关系全部压给主编的问题。
- 修复 DSH 工作区跨工作区拖卡卡死；三端只保留本工作区排序，不再提供跨工作区搬家。
- 修复子代理重进丢失、流式乱跳和加载图标不统一的问题。

### 验证

- flutter test 全量 902 项全绿；flutter analyze 仅保留仓库既有 21 条提示/警告。
- `flutter build apk --release --target-platform android-arm64` 成功；`aapt dump badging` 确认 `versionName=2.6.3 / versionCode=28`，native-code 仅 `arm64-v8a`。
- 真机手动 `adb install -r` 覆盖安装成功；`firstInstallTime` 保持 `2026-08-17 18:41:21`，冷启动进程存活且无崩溃日志。
- 详细记录见 docs/fix-log.md #327-#365。

## [2.6.2] - 2026-08-30

相对 2.6.1：子代理可以点开看 mini 会话；缓存和子代理收成输入框上方的小按钮；项目目录改成文件夹图标。修掉点子代理红屏、返回红屏、连点叠栏，以及主 agent 等待时子代理状态被清掉的问题。DSH 工作区会话只保留本工作区内排序，三端都关闭跨工作区搬家。拾忆新增群聊：主页会话 tab 可进，可贴思维导图生成 Agent，多个独立 Agent 可各自配置接口、名字和人设。

### 新增

- **拾忆群聊**：主页会话 tab 顶部和功能页都可进入；可创建多个群聊并删除。多个独立 Agent 一起聊天，每人自选拾忆 API、名字、职位和人设提示词。按公司结构对接：用户默认只找负责人，其他人被点名或上级安排后才发言。每个 Agent 的思考过程单独可见。不带文件/终端工具，不影响 DSH。
- **思维导图导入**：粘贴 mermaid 或字符思维导图，自动识别 Agent 人数、人设和汇报关系。填入时每人先套当前默认 API 和模型，有起步路线可选全部或最小人数。
- **子代理 mini 会话**：点击输入框上方的子代理按钮，从按钮上沿打开 mini 会话，查看子代理实时状态、思考和工具过程。拾忆与 DSH 共用。
- **多子代理左右滑**：同时有多个子代理时，小窗里左右滑动查看，不用先点进列表再进详情。
- **输入区悬浮芯片**：缓存命中率和子代理状态改成输入框上方的小按钮；项目目录入口收到权限盾牌旁边，只留文件夹图标。

### 优化

- **群聊组织架构**：可设职位和上级；不再一个人说话全员回答。下属说完自动向直接上级汇报。
- **群聊思考过程**：每个 Agent 气泡可展开自己的思考，流式时显示「思考中」。
- **群聊 UI 对齐会话**：群聊会话页改用液态玻璃输入框和共享气泡；主页/功能页群聊卡左滑编辑删除，跟会话卡同一套操作。
- **群聊动画**：列表/编辑/会话页接入预测性返回淡出；新气泡入场；主页群聊展开交错。空态和编辑页导航栏对齐功能页。
- **群聊太极八卦图标**：主页分组、会话卡、功能页入口和空态都换成太极八卦图，不再用双人图标。
- **群聊卡片对齐会话卡**：36 圆角头像、同样字号和玻璃左滑卡，不再叠成员色块。
- **群聊设置对齐**：会话右上角改用磨砂设置胶囊；新建/编辑/Agent 页改用设置页同款分组表单和保存按钮。

- **小窗尺寸**：mini 会话收成约 280×248，不再占半屏。
- **芯片对齐**：缓存和子代理共用同一套 32px 高、13 号字芯片；缓存永远钉在最左边，子代理出现时不再把它挤走。
- **子代理保留到本轮结束**：主 agent 停下来等子代理返回时，手机端状态不再消失；拾忆本轮快照留到下一条用户消息。

- **只在本工作区排序**：本机 / 局域网 / 公网 DSH 会话都只能在当前工作区内长按重排，走官方 `insertSessionBefore`。
- **关闭跨工作区移动**：官方 `SessionHeader.cwd` 创建后不可改，没有换工作区 RPC。拖到其他工作区不再展开、不显示「松开以移入」，松手回到原位；左滑不再提供搬家。本机搬家插件只留给工作区文件夹切换。拾忆跨项目拖拽不受影响。

### 修复

- 修复点击子代理闪红、整页变红：小窗不再把动画控制器或 GlobalKey 挂到已销毁的状态条上。
- 修复点开子代理后连续返回到主页仍红屏：页面卸载时立刻收掉小窗，不再听已销毁的 animation。
- 修复连点子代理会往上叠出多行缓存/子代理栏：小窗改走 `OverlayPortal`，同一控制器只会有一个浮层。
- 修复主 agent 已停止但电脑上子代理还在跑时，手机端把子代理状态清掉的问题。
- 修复远端 DSH 把会话拖到其他工作区后，卡片 UI 卡在最上层拖不动：飞入用 try/finally 卸拖影，手势不再 await RPC。
- 修复远端跨工作区 toast「移动失败」：不再打官方不存在的 `session.update` / `session.setCwd`。

### 验证

- 子代理 mini 会话、连续点击只开一个小窗、打开后卸掉会话页不红屏、缓存最左且同高新增回归测试。
- DSH 三端关闭跨工作区移动、只保留本工作区排序新增回归测试。
- `flutter analyze` 无新增 error；`flutter test` 相关工作区测试全绿。
- 详细记录见 `docs/fix-log.md` #318–#334。

覆盖安装即可升级，不会清数据。

## [2.6.1] - 2026-08-29

相对 2.6.0：远端 DSH 可以安全使用手机上的拾忆 API，也能直接管理目标电脑自己的模型 API；本机与局域网统一为同一套中转链路，公网改为直接注入所选模型；补强会话中断、错误解释、小屏交互、抽屉返回键，以及新建会话 Agent 预设与主页底栏。

### 新增

- **拾忆 API 安全 Relay**：本机 / 局域网 DSH 使用手机 API 时，请求仍由手机转发到真实上游。目标 DSH 只保存 Relay 地址、独立令牌和模型目录，不接收拾忆真实 Base URL 或 API Key；多台手机使用不同 provider 和凭据槽，互不覆盖。
- **远端 DSH API 完整管理**：模型数据页可新增、编辑、删除目标 DSH 自有 API，支持 Chat Completions / Responses / Claude 协议选择、获取模型目录、搜索多选、手动补模型和最小请求测试连接。
- **LLM 错误代码说明**：补充常见 HTTP / SSE / 协议错误的中文含义和处理建议，400 与无状态码中断分开识别，不再把所有失败混成同一种重试。
- **会话权限预设按钮**：DSH 输入框新增权限预设（Read Only / Workspace Write / Full access），切换对当前会话实时生效；权限按钮只留盾牌图标。
- **公网 DSH 直接注入拾忆 API**：公网拨不进手机时，所选拾忆配置直接写入目标 DSH（可手动删除），插件页等管理入口跟随当前远端连接。
- **工作区下拉刷新**：DSH 工作区列表支持下拉刷新，无需等后台定时器。
- **新建 DSH 会话选择 Agent 预设**：创建会话前先选标准 / PTC / 极简 / 创造（或自定义），写入 `session.create(agentPreset:)`。

### 优化

- **本机 = 局域网统一**：本机 DSH 与局域网 DSH 共用同一套「手机临时中转」租约链路，删除设置里的「API 来源」菜单；本机保留页面缓存（cache-first 秒开），局域网 / 公网强制实时加载。
- **远端配置回读合并**：同时合并 `settings.describe`、`llm.providers` 和 `llm.models`，卡片保留名称、协议、Base URL、凭据状态和完整模型目录，不再把每个模型误拆成一份配置。
- **配置入口重新分工**：模型数据页成为日常 API 管理入口；原“凭据与配置”改为“DSH 高级诊断”，原始命名空间默认折叠，仅供排错。
- **模型数据页内置预设与抽屉去重**：内置 deepseek 预设正常显示且可清除，局域网模型抽屉不再出现 `vision-toolkit-*` 重复镜像分组。
- **移动端自适应**：小屏字体、输入区、弹窗和键盘安全区进一步收紧；点击输入框外释放光标，底部菜单不再被输入法顶成灰色长条。
- **模型按钮定宽跑马灯**：输入区模型名按 `mimo-2.5` 的宽度居中显示，超出部分跑马灯滚动。
- **运行中工具栏**：会话生成时输入区上方按钮保持可见，思考开关不再置灰。
- **预设选项卡片**：按 Apple 列表规范（标题 17 / 说明 13 / 上下内边距 12），文字不再顶格顶满。
- **主页底栏留白**：展开会话后最后一张不再被底部菜单挡住；输入法弹起时不再把那段 58px 空白一起顶起来。
- **子代理按任务调度**：移除固定数量上限，由拾忆按任务复杂度决定并行子代理数量；DSH 插话继续走当前会话，不再误显示额外子代理。
- **远端页面实时加载**：局域网 / 公网页面以目标 DSH 实时数据为准，不缓存手机本地页面，也不回退读取本机 DSH 文件。

### 修复

- 修复局域网 / 公网切换 API 来源失败、Relay provider 尚未加载就立即选模导致切换失败的问题。
- 修复目标 DSH 模型页只取 provider 目录、忽略 settings 完整字段，导致编辑时 Base URL 或凭据引用丢失的问题。
- 修复 DSH 运行中插话被当成停止、旧事件迟到污染新回合，以及手机界面误跳出子代理状态的问题。
- 修复小屏设备部分标题、输入框和操作按钮挤压或截断的问题。
- 修复本机 DSH 冷启动直接进入会话时首条消息失败：当前会话没有中转缓存时，发送前自动按 scope + 会话恢复所选拾忆配置并重新建立租约，不再打在已删除的旧 provider 上。
- 修复模型 / 权限 / 思考强度抽屉拉开时按返回键直接退页：抽屉改走导航栈内的透明路由，返回键先收抽屉（模型抽屉二级菜单先回一级）。
- 修复主页搜索拉起键盘后，底部 Tab 留白叠在输入法上方的问题。

### 验证

- 远端 provider 合并、协议映射、自动 ID、模型编辑还原、320px 小屏滚动、中转选择按 scope/会话隔离、抽屉返回键收合新增回归测试。
- `flutter analyze` 仅仓库既有 1 warning / 2 info；`flutter test` 847 项全绿；`flutter build apk --release` 生成 37.5MB `app-release.apk`。
- 真机 `af3700b1`（2509FPN0BC）手动 `adb install -r` Success，无卸载。`versionName=2.6.1 / versionCode=26`，签名 `f6dde40b`，`firstInstallTime` 保持 `2026-08-17 18:41:21`。
- 详细记录见 `docs/fix-log.md` #293 / #307–#317。

## [2.6.0] - 2026-08-27

相对 2.5.10：补齐 DSH 局域网/公网连接与远端文件浏览，增加全链路运行审计；本轮重点让停止和插话真正立即生效。

### 新增

- **DSH 多连接模式**：支持本机、局域网和公网远程 DSH，API、WebSocket、文件页均跟随当前连接；远程连接不拉起或停止手机本机 DSH。
- **全链路运行审计**：日志页记录 App、LLM 三协议、缓存、DSH RPC、工具、终端、文件、会话、LAAP 和异常；AI 可用 `inspect_runtime` 自查，敏感字段自动脱敏。
- **远端文件浏览**：文件页使用当前 DSH 的官方 `host.*` 接口，扫描可访问盘符，菜单只保留盘符和工作目录。
- **后台运行基础**：Android 前台服务按实际运行会话同步，降低切后台后任务被系统回收的概率。

### 优化

- **真正的即时停止**：停止时主动关闭当前 HTTP/SSE 连接，不再等待下一枚 token；Responses、Chat Completions、Claude 三条协议共用取消链路。
- **即时插话**：拾忆引导发送等待旧回合真实退出后立刻启动新回合；DSH 运行中允许直接发送，并过滤旧回合迟到事件。
- **工具级中断**：子代理的 LLM 请求和 `run_terminal` 子进程纳入会话取消范围，长任务可以跟随停止按钮收口。
- **模型配置稳定绑定**：会话按 API profile ID 绑定，避免同名配置或改名后串模型；拾忆与 DSH 注入仍保持协议隔离。

### 修复

- 修复 DSH 局域网/远程切换后工作区、文件页使用旧主机或旧路径的问题。
- 修复远程 Host/端口扫描误把空隔离视图当成连接成功的问题。
- 修复工作区左滑打开远端目录错误调用 `host.openPath` 导致 403 的问题，改用应用内远端文件页。

### 验证

- `flutter analyze` 无新增错误；仓库原有 6 条 warning/info 保持不变。
- `flutter test`：792 项全部通过。
- `flutter build apk --debug`：成功生成 `build/app/outputs/flutter-apk/app-debug.apk`。
- 真机安装继续遵循手动 `adb install -r` 覆盖安装，不卸载、不清理 API Key、会话和记忆。

## [2.5.10] - 2026-08-27

相对 2.5.9：拾忆直连补上 OpenAI Responses；冻头/动尾对齐 Codex 口径稳住缓存；活人感改接本机 LAAP 皮层，按官方 preamble 注入。

### 新增

- **第三条协议 Responses**：设置页 Chat Completions / Claude 之外增加 OpenAI Responses。冻头走 `instructions`，其余走 `input`，默认 `store: false`。禁止 `previous_response_id` / `prompt_cache_key`。
- **LAAP 认知皮层**：引擎页按 DSH 同款方式本机部署 `laap-MAX`（Android Alpine Python / Windows 本机 Python，端口 11546）。只给活人感供内心状态，不是第三套聊天引擎。
- **活人感开关搬到引擎页**：对话设置里不再放活人感。打开且皮层就绪才注入；皮层挂了就不注入，没有本地关键字替身。

### 优化

- **冻头/动尾稳缓存**：Chat Completions 冻头第一条 system、动尾放历史之后；Claude 冻头 system 与最后一个 tool 打 `cache_control`。滚动摘要、记忆、活人感、当前时间不进冻头。
- **压缩与工具轮 cache-safe**：压缩与主请求同一冻头和 tools；长会话旧工具轮原地截断；计划模式不换 tools 表；Responses 可回放加密思考 item。
- **75% 任务摘要改走历史归档**：不再插在冻头和历史中间挡前缀。
- **大工具输出 spill**：超长结果落到工作目录 `.shiyi/tool-outputs/`，模型只看头尾预览；只读 `tool_calls` 主循环可并行。
- **状态栏本轮缓存**：会话页显示本轮命中 / 未缓存，命中率按会话累计。

### 修复

- **Responses 发图 HTTP 502**：图片改为 `{type:input_image, image_url:"..."}` 字符串，不再把 Chat 的 `image_url` 对象原样塞进 Responses。
- **小米小窗空白卡死**：HyperOS 自由窗口把状态栏 padding 报成窗口高度时，钳制 MediaQuery，主页/会话能画出来。Activity 声明 `resizeableActivity`。
- **活人感官方接法**：去掉提示词里的「本机皮层已接通」。按 `psi_hermes_adapter.py` 注入 `## PSI Cognitive State (Live)` + preamble + 需求风格 + cot_hint。未改 Alpine 里的 laap-MAX 源码。

### 验证

- `flutter test test/laap_api_test.dart test/presence_engine_test.dart test/prompt_section_test.dart test/llm_protocol_cache_test.dart test/media_query_fix_test.dart test/tool_output_spill_test.dart test/context_budget_test.dart test/settings_model_test.dart` 通过。
- 正式包同签名覆盖安装到 `af3700b1`（2509FPN0BC），`adb install -r` Success，`firstInstallTime` 未变化，数据保留。

## [2.5.9] - 2026-08-26

相对 2.5.8：主页拖拽抽成共享组件，DSH 工作区会话也能长按排序并持久化到服务端。

### 优化

- **拖拽滚动重测**：按住拖动时另一指滑动列表，占位会跟到新划出来的格子，不再冻在当前屏那几张卡片上。
- **跨项目插入位置**：会话拖到其他项目/工作区后，占位空隙跟手指走，可插到任意格，不再钉在第一格。
- **DSH 启动自愈 overlay**：profile 层 `cordis.patch.yml` 若不是 YAML 数组（空文件会退出码 1），启动前写成 `[]`；搬家插件只写 home 层，避免 duplicate id。
- **共享拖拽组件**：左滑、交错展开、分组头、飞行层 / 让位位移从拾忆主页抽出，DSH 工作区页复用同一套交互。
- **DSH 工作区会话排序**：组内按 `workspace.sessionIds` 显示，不再被 `session.list` 的 `updatedAt` 盖掉；长按拖拽同组重排或停满 1 秒跨工作区移入。
- **DSH 顺序持久化**：`dshReorderPlanForInsertion` 以最长公共连续段为锚点，后向前生成 `insertSessionBefore`，尾部移动是插到末尾，不会被前项带偏。
- **会话卡片长按拖拽**（同版本覆盖）：`HomeLongPressDrag` + 自建 overlay 拖起整张卡片；#243 无拖影已关闭。跨组提交只收被拖项源槽；DSH 先乐观改 `sessionIds` 和 cwd 再静默刷新，源组其它卡片不再被撑开或整组消失。

### 验证

- `flutter test test/home_list_order_test.dart test/dsh_workspace_display_name_test.dart test/home_sessions_tab_test.dart` 通过。
- `dart analyze` 相关文件无告警。
- 正式包同签名覆盖安装到 `af3700b1`（2509FPN0BC），`adb install -r` Success，`firstInstallTime` 未变化，数据保留。

## [2.5.8] - 2026-08-24

相对 2.5.7：拾忆会话之间可按会话 ID 互相查阅；Windows 工作目录、终端和提示词与 Android 彻底分家。

### 新增

- **拾忆跨会话查阅**：主页左滑「复制 ID」后，把 ID 发到另一个拾忆会话，模型用 `search_sessions` / `read_session` 能找到并阅读该会话，不再声称搜不到。按完整会话 ID 命中本地库，不走 `search_memory` 或联网搜索。DSH 会话 ID 对拾忆无效。

### 优化

- **Windows 默认工作目录**：本机「文档\\agent」。旧 `%TEMP%\\agent` 视为未设置。Android 仍是 `/storage/emulated/0/agent`。
- **Windows 终端后端**：自动顺序 WSL2 → Git Bash → PowerShell 7 → cmd；不走 Android Alpine / proot / apk。设置页这条入口只在桌面显示。
- **提示词按平台隔离**：人设 / 工具规则 / `run_terminal` / `file_write` 两端各写各的，禁止「Android …；Windows …」写进同一段。
- **Win11 红绿灯悬停灰条**：原生子窗口 `SHIYI_TITLEBAR` 盖住系统标题栏悬停层；桌面图标与 Android 启动图标同一套。
- **终端捏合 / 补全 / 分色**（2026-08-25 同版本覆盖）：双指捏合缩放字号（1~28，默认 13），中文回退避免缺字；命令前缀补全（历史优先 + 幽灵字）；命令行按 token 分色。
- **Markdown 再补缺口**（2026-08-25）：嵌套强调、转义、自动/参考式链接、HTML 片段、表格对齐、有序列表重排、硬换行等，拾忆与 DSH 共用。
- **主页长按拖拽**（2026-08-25）：项目 / 会话卡片长按拖起整张卡片排序；会话可拖到另一项目（停满 1 秒）；松手飞入空隙，远放不瞬移，提交贴齐不弹回。

### 验证

- `flutter test` 全量通过（含 `session_bridge` / `file_workspace` / `terminal_backend` / `prompt_section` / 工具与提示词快照）。
- 2026-08-25 覆盖：`flutter test test/terminal_pane_test.dart test/markdown_text_test.dart test/home_list_order_test.dart test/home_sessions_tab_test.dart` 通过。
- 正式包同签名覆盖安装到 `af3700b1`（2509FPN0BC），`adb install -r` Success，`firstInstallTime` 未变化，数据保留。

## [2.5.7] - 2026-08-24

相对 2.5.6：聊天 Markdown 补齐缺口元素；思考过程不再被当成正文；上下文改成新建会话默认并可按会话覆盖；MiMo 工具续轮不再因模糊 400 卡住。

### 新增

- **会话级上下文上限**：设置页「上下文」改为新建会话默认，不再把 ≥50 万 token 自动写回 128k。拾忆 / DSH 输入区增加「会话上下文」按钮，本会话可单独改；未改过的会话继续跟全局默认。
- **主页项目展开记忆**：拾忆主页项目分组展开/收起写入本机偏好，重启后保持。会话卡片左滑增加「复制 ID」（与 DSH 工作区会话一致）。

### 优化

- **Markdown 自研补齐**：拾忆与 DSH 共用同一套渲染器。在原有标题/列表/表格/代码/引用/强调之外补上图片、标准脚注 `[^1]`、内联脚注、定义列表、键盘按键、`==高亮==`、GitHub Alert、LaTeX 可读文本、独立分隔线。
- **思考过程留在折叠面板**：空正文 + 非空思考不再升成正文；思考增量立即推送，只节流正文布局。点开思考过程后，思考完不会再把思考当正文带出来。
- 非空模型 ID 都会显示思考档位按钮；命中家族关键字才自动往请求里塞思考参数，对不上关键字的不自动注入。

### 修复

- **MiMo 工具续轮 HTTP 400**：部分网关拒绝 `reasoning_effort` 时只回模糊 `Invalid request parameters`，旧重试抓不到字段名就不会去掉。现在模糊 400 也会去掉该参数再试。日志里的 `thinking=off` 表示没发 DeepSeek/Anthropic 的 `thinking` 对象，不是思考开关被关掉。

### 验证

- `flutter test` 全量通过（含 `markdown_text` / `reasoning_*` / `context_limit` / `home_sessions_tab` / `llm_continuation`）。
- 正式包同签名覆盖安装，未卸载、未清数据。

## [2.5.6] - 2026-08-24

相对 2.5.5：主页底部增加「终端」栏，接到已有 Alpine proot，不是另装 Termux。

### 新增

- **底部终端入口**：拾忆为 会话 / 功能 / 文件 / 终端，DeepSeek Harness 为 工作数据 / 功能 / 文件 / 终端。
- Android 命令经 `/system/bin/sh` + `init-host -c` 进 Alpine 沙箱，与 AI 的 `run_terminal` 同一条链；Windows 仍走设置里的终端后端。
- 打开终端页会检查并准备内嵌环境。点画面输入、回车执行；执行中仍可输入（回车喂给当前进程 stdin）。停止按钮 / Ctrl+C 注入强制中断。
- 两端共用同一 Alpine 会话，切换拾忆 / DSH **不会**自动停止终端，只等手动点停止。

### 优化

- 没有底部独立输入框；日志即画面。输入法弹出、输出增长时贴底看最新；滑动看历史不弹输入法；已聚焦时回车不闪键盘。
- 草稿末尾块状闪烁光标，空格也能看见。
- 输入浅蓝、正常输出灰绿、警告黄、错误红（`error` / `command not found` / 非 0 `[exit N]` 等标红，`warning` 标黄）。
- 部分输入法把「字母 + 空格 + `/`」收成 `abcd/` 时自动补回空格。
- 聊天输入只有独立的 `/` 才弹技能（`abcd/` 这种路径斜杠不弹）。

### 验证

- `flutter test test/home_tabs_test.dart test/terminal_pane_test.dart test/slash_trigger_test.dart` 通过。
- `flutter analyze` 针对终端栏相关文件无告警。
- 正式包同签名覆盖安装，未卸载、未清数据。

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
