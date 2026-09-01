# ShiYi Agent App（拾忆）项目说明

## 部署偏好（用户明确要求）
- 安装到真机时**必须使用覆盖安装**（如 `adb install -r` 或签名一致的 `flutter install`），**禁止先卸载再安装**。
- 卸载会清掉 app 数据（API Key / 模型 / 会话 / 记忆），用户每次都要重新配置，体验很差。
- 日常开发用 debug 签名构建（`flutter install --debug` 或 `adb install -r build\app\outputs\flutter-apk\app-debug.apk`），签名一致时覆盖安装不会清数据。
- **⚠️ 2026-08-08 实测教训：`flutter install --debug` 不可靠**——其内部先跑 `adb install -t -r`，失败时会**自动卸载重装**（日志出现 `Uninstalling old version...`），app 数据被清空。已两次踩坑。
  - **首选安装方式：手动 `adb install -r`**（同一 debug keystore 下实测 Success，数据保留）。
  - 用 `flutter install` 时：装完必须检查输出里**没有** `Uninstalling old version...`，有则说明走了卸载（数据已清）。
  - 装前可先验签：`adb shell dumpsys package com.shiyi.agent | grep signatures`（同签名覆盖才不清数据）。
  - 备份数据（debug 包可 run-as）：`adb exec-out run-as com.shiyi.agent cat files/... `（app_flutter/shiyi_agent.db + shared_prefs/）。
- **2026-08-14 起 debug 变体也使用正式签名**（`keystore.jks`，见 `android/app/build.gradle.kts`）：
  - debug 构建的 APK 与正式版签名一致，`adb install -r` 覆盖安装不会因签名不一致失败/清数据；
  - debug 包保持 debuggable，可 `run-as` 备份/验证数据；
  - 注意：因此**构建 debug 同样需要 `KEYSTORE_PASSWORD`**（`android/local.properties` 或环境变量），缺密码时 debug 构建直接报错。

## 真机环境
- 常用测试设备：`9LKZL7TGZTJFZ575`（近期覆盖安装验证）、`2509FPN0BC`（Android 16 / API 36）
- 应用包名：`com.shiyi.agent`（由 `com.hermes.hermes_agent_app` 改名而来）

## Android 内嵌终端（Alpine，2026-08-15 起）
- **架构**（参照 OmniBot/ReTerminal）：Android 宿主 + proot + Alpine minirootfs（3.85MB 内置资产），
  取代旧 Termux bootstrap（40MB+，apt/dpkg 全家桶）。详见 `docs/fix-log.md` #153/#154。
- **命令执行链**：`init-host -c <cmd>`（`$prefix/local/bin/init-host`，宿主侧脚本）→
  `exec linker64 proot -0 --sysvipc -r $rootfs /bin/sh -c <cmd>`；rootfs 内 `/root` 绑定宿主
  `$prefix/home`（DSH 数据目录 `.dsh` 无缝迁移）。
- **包管理**：`apk`（清华源优先 + 官方兜底，rootfs 首次启动自动配置）；Node.js 用
  `apk add nodejs npm`（Alpine npm prefix=/usr/local，dsh 包路径见 `_androidDshDir()`）。
- **首次初始化**：rootfs 内 init 脚本（`$prefix/local/bin/init`）装基础包（bash/gcompat/glib/
  nano/curl/ca-certificates/coreutils），就绪标记 `/etc/shiyi-ready`；网络失败容忍、下次重试。
- **⚠️ SELinux（Android 15/16，targetSdk 36）**：标准 `untrusted_app` 域缺两条关键权限，
  KernelSU/Magisk 环境由 app 启动时自动补（`TermuxRuntime._ensureApkLinkPolicy`，
  运行时 patch + 持久化 `/data/adb/ksu/sepolicy.rule`）：
  - `app_data_file file link`：apk 3 安装用硬链接原子发布，neverallow 禁止 → 全源
    "Permission denied"（audit: denied { link }），基础包装不上；
  - `app_data_file file execute_no_trans`：新域默认禁止 exec app 数据内 ELF →
    init-host/proot EXEC_FAILED。
  无 root 设备内嵌终端不可用（apk 装不了基础包），属平台限制。
- **⚠️ 铁律**：**验证/安装绝不能用 root 在 rootfs 里创建文件**（SELinux 标签异常，app 域读不了
  也删不掉，无 root 手机直接不可用，实测 EACCES）。一切安装走 app 内（Agent 引擎页 /
  修复完整模式，app uid）。
- 关键路径：rootfs=`files/termux/local/alpine`、proot/脚本=`local/bin`、库=`local/lib`、
  版本标记=`files/termux/.env_version`（alpine-vN，结构变更时递增）。
- **主页「终端」栏**：底部第四栏，拾忆与 DSH 都有。命令走 `EmbeddedShell` → `/system/bin/sh` + `init-host -c`，与 `run_terminal` 同一套 proot，禁止再拉一套 Termux。无 PTY，交互是一行命令一次 init-host。
- **终端交互铁律**：没有底部独立输入框，点画面输入；执行中输入仍可用（busy 时回车喂 stdin）。切引擎不发 Ctrl+C。输入法弹出贴底、滑动历史不弹键盘。输入浅蓝 / 正常输出灰绿 / 警告黄 / 错误红；命令行再按 token 分色（命令绿、flag 紫、字符串橙、路径蓝）。独立 `/` 才弹技能。
- **终端字号与补全**：双指捏合缩放字号，下限 1、上限 28，默认 13；捏合不算点击，不弹键盘。字体必须带中文回退（`NotoSansSC` 等），禁止纯 monospace 导致汉字缺字。输入时按前缀补全内置命令，历史命令优先，未提交部分用浅色幽灵字显示。
- **默认工作目录**：`/storage/emulated/0/agent`。人设 / 工具规则 / `run_terminal` 描述只写 Alpine / apk / 该路径，不出现 Windows 的「文档\agent」或 WSL / Git Bash / PowerShell。
- **构建隔离**：`flutter build apk` 只编 `android/` + 共享 `lib/`，不会把 `windows/` 的 exe / C++ 标题栏打进 APK。反过来编 Windows 也不会产出 APK。两端各打各的包。正式包只打 `arm64-v8a`（`ndk.abiFilters` + `flutter build apk --release --target-platform android-arm64`）。

## Windows 桌面版（exe）
- 2026-08-14 起项目支持 Windows 桌面完整版。**不要和 Android 搞混**：
  工作目录、终端后端、提示词都按平台隔离。
- **默认工作目录**：本机「文档\agent」（`%USERPROFILE%\Documents\agent`）。
  旧 `%TEMP%\agent` 视为未设置，自动改走文档目录。Android 的
  `/storage/emulated/0/agent` 只给手机用。
- **命令后端（用户可选，设置 → 通用 → 终端）**：自动 / WSL2 / Git Bash /
  PowerShell 7 / cmd。自动顺序：WSL2 → Git Bash → PowerShell 7 → cmd。
  不走 Android Alpine / proot / `apk` / `init-host`。设置页这条入口有
  `Platform.isWindows` 保护，手机上看不到。
- 数据库走 `sqflite_common_ffi`，技能 zip 用 archive 包纯 Dart 解压。
- **UI 已桌面化 + macOS 操作逻辑化**：右键菜单、悬停展开操作、ActionSheet 桌面居中、
  宽窗口侧边导航 + 内容限宽、Ctrl+Enter 快捷键；**无边框窗口 + 红黄绿三键**
  （拖拽/双击最大化/边缘缩放/贴靠）。Win11 红绿灯悬停灰条用原生子窗口
  `SHIYI_TITLEBAR` 盖住。
- **提示词隔离**：人设 / 工具规则 / `run_terminal` / `file_write` 描述按
  `Platform.isWindows` 取文案。Windows 只写本机终端与「文档\agent」；
  Android 只写 Alpine / apk / `/storage/emulated/0/agent`。禁止两端写进同一段。
- **Windows 端维护文档（独立，勿与手机端混淆）**：`docs/windows-maintenance.md`
  （架构/适配/维护铁律/排错/验证清单）；构建步骤见 `docs/windows-build.md`。
  手机端部署/排错见本文件顶部与 `docs/fix-log.md`。
- 构建：`flutter build windows --release` → `build\windows\x64\runner\Release\shiyi_agent.exe`。
  分发必须拷贝整个 Release 目录。
- 注意：桌面版与 Android 版共享同一套 lib/ 代码，所有平台差异用 `Platform.isWindows`
  分支隔离；改共享代码时不要破坏 Android 侧行为（`flutter test` 全量守护）。

## 拾忆 / DSH UI 同步规则
- 拾忆与 DSH 的聊天 UI 必须保持同一套视觉语言、液态玻璃样式和交互逻辑。
- 修改任一聊天 UI 时，必须同步检查并更新另一引擎，不能只修拾忆或只修 DSH。
- 输入框、消息气泡、工具胶囊、状态条、提问面板、附件预览等能共享的部分必须优先抽成共享组件，禁止复制两套后分别维护。
- 只有协议或引擎能力确实不同的界面允许单独实现，并需在维护文档说明原因。
- 输入区的液态玻璃抽屉（选择模型 / 权限预设 / 思考强度）必须走 `LiquidGlassPopupRoute`（透明 `PopupRoute`，`PopScope canPop:false` 拦截返回）：按返回键先收抽屉，模型抽屉二级菜单先回一级再收。禁止改回 `OverlayEntry` 直插 root overlay——不进导航栈会让返回键穿透抽屉直接退页。抽屉内容切换（如二级菜单）走路由级 `markNeedsBuild`，关闭走「先播收合动画再 `removeRoute`」。
- 子代理按钮可点：从按钮上沿浮出 mini 会话，多个子代理左右滑查看。走 `OverlayPortal` + 实心 Material，点空白或返回关闭。禁止再 `Navigator.push(PopupRoute)` 挂 rootNavigator（状态条重建会丢旧路由，连点会叠多层并红屏）。不要套 `LiquidGlassLens` / `MessageBubble` 玻璃。小窗里用户上滑看历史后不要自动跳回底部，只有贴底时才跟随最新。拾忆读 live 转写本，DSH 读 `subagent.history`。两端共用 `SubagentStatusBar`。
- 输入区项目目录入口收成文件夹图标，放在权限盾牌旁边，只留图标。缓存和子代理做成输入框上方悬浮芯片：共用 `ChatComposerChip`（高 32、字 13、行高 18/13），`ChatComposerFloatChips` 里缓存永远最左、子代理在右边。进度圈强制 10×10。
- 子代理列表跟 live 任务，不跟主 agent 是否 running。父会话 idle / 等待子代理返回时，状态条和芯片不得清掉；拾忆本轮快照留到下一条用户消息；DSH 跟 `subagent.list`。

## DSH 新建会话预设
- 新建 DSH 会话（工作区红绿灯 / 左滑新建 / 会话 tab）必须先 `pickDshAgentPreset`，再 `session.create(agentPreset:)`。取消返回 `null` 不创建；目录失败返回 `''` 时不传 `agentPreset`，按服务器默认。会话开始后预设锁定，不要创建后再 `agentPreset.select`。
- 弹层选项走 `CupertinoListSection.insetGrouped`：标题 Body 17（行高 22）、说明 Footnote 13（行高 18）、垂直 padding 12、leading 29 圆角 7。禁止裸默认 `CupertinoListTile` 副标题 6px 内边距（会顶格顶满）。

## 主页底部 Tab
- 手机端底部 Tab 悬浮覆盖。内容留白 `_mobileTabBarHeight(58) - viewInsets.bottom`（下限 0）。键盘弹起清掉这段空白，键盘收起仍给 Tab 留空。外层 `Scaffold(resizeToAvoidBottomInset: false)`，Tab 贴屏幕底。禁止把 58px 死垫叠在键盘上面——内层会话 Scaffold 仍按 viewInsets 垫底，再叠死 58 会在输入法上方多出一条空带。拾忆与 DSH 共用这一层。

## 拾忆主页长按拖拽
- 项目卡片、会话卡片长按拖起**整张卡片**（头像/标题/背景），不用半透明标题影子。
- 手势走共享 `HomeLongPressDrag`（350ms `LongPressGestureRecognizer`），禁止再接 `LongPressDraggable` / `DragTarget`。拖影走自建 `HomeDragOverlay`，跟手点是按下位置不是卡片中心。
- 展开项目长按先 170ms 快速收起，收起的会话必须离开文档流（`outOfFlow` / heightFactor=0）；挤开高度必须用项目头+间距，禁止沿用展开块高度把其它会话挤飞。
- 拖动时原列表立刻挤开让位；松手从手指位置飞入空隙（缩放 180ms / 飞回 320ms，`easeOutCubic`），远放也要飞回，禁止卸 overlay 后瞬移。
- 会话拖影高度用 `homeDragCardBodyHeight`（槽位减 8px 间距），禁止把列表间距画进卡面，否则首帧会上下涨一截。
- 会话拖入另一项目：源列表空占位收起，目标列表先插入 `HomeDragInsertGap` 挤开空隙，再从手指飞入；禁止原地缩小后瞬移。拖回原项目后源占位再打开。跨项目飞入不用回弹曲线，已经出现在目标列表里的新卡片不能再收成 0。
- 提交后位移立刻贴齐再写库，禁止旧位移套在新顺序上反向弹回（换位后第一下会炸）。飞入结束后等源卡片按最终顺序画完一帧，再卸拖影。
- 会话拖到另一项目/工作区：未展开停满 1 秒自动展开；已展开停满 1 秒显示「松开以移入」。可释放后占位空隙跟手指在目标列表里移动，松手插到该位置，禁止永远钉在第一格。另一指滚动列表时必须按新坐标重测插入下标，不能冻在拖起那一帧的可见卡片上。测槽位必须用不含 Transform 的布局盒，禁止用动画中的位移去减目标位移。会话写入目标项目/工作区的那一帧必须贴齐位移，且不能再套 foreign translate，否则归位会按卡片高度弹一下。跨组提交完成前源槽必须保持收起，且只收被拖的那张；`keepCollapsed` / `homeDragCardSlotFactor` 不能套到源组其它卡片，否则 BCD 会整组消失再出现。源槽高度不能只看 draggingId。拾忆会话拖入另一项目仍走乐观更新。DSH 不开放会话跨工作区移动，悬停其他工作区不得展开或显示「松开以移入」。远放不能直接移入别的项目。拖回原项目必须立刻清掉「松开以移入」，松手归位原项目，禁止沿用上一个目标。
- 会话在展开列表里拖动时不能被 `SizeTransition` 裁剪命中区；反馈层必须是独立卡片树，不能和列表共用左滑 State。
- 列表外层必须裁剪：手机 `SafeArea` 内侧 `ClipRect`，搜索栏用不透明 `Material`，`Expanded` 列表再包 `ClipRect`。禁止给会话 ListView 设 `Clip.none` 盖住搜索栏/状态栏。展开列表内部 `unclipped` 只留给长按命中。
- 顺序写入 `sessions.sort_order` / `projects.sort_order`（缺列由 `_ensureSortOrderColumns` 补，不要误升 DB version 清数据）。
- 左滑 / 交错展开 / 分组头 / 飞行层抽成共享组件（`lib/widgets/swipe_actions.dart`、`home_drag.dart`、`staggered_sessions.dart`），DSH 工作区页会话级拖拽复用同一套。
- 左滑必须用 `Listener` 跟手，禁止 `onHorizontalDrag*` 进竞技场；否则会话卡片长按会被抢走。展开列表 `unclipped` 时禁止包 `SizeTransition`。长按计时期间左滑有 300ms 启动窗口，拖中的卡片 `disableSwipe`。
- DSH 工作区按 `workspace.sessionIds` 显示顺序；重排走 `dshReorderPlanForInsertion` → `workspace.insertSessionBefore`，禁止按 `session.list` 的 `updatedAt` 盖掉服务端顺序。DSH 会话不跨工作区提交。`insertSessionBefore` 只能动已入账 id；cwd 兜底会话要先 `session.create(workspaceId)` 入账。`session.create` 不能同时带 `workspaceId` 和 `cwd`。
- DSH 工作区卡片长按排序走 `workspace.insertBefore`（`insertWorkspaceBefore`），和拾忆项目拖拽同一套挤开/飞回。工作区展开状态只在首次进入恢复偏好，之后 `_load` 不得整表盖回旧展开集；长按收起时同步写 `_savedExpanded`。
- DSH 三端关闭会话跨工作区移动（拖卡片 / 左滑搬家都不提供）。会话只能在本工作区内 `insertSessionBefore` 排序。本机搬家插件 `POST /__shiyi/move-session` 只留给工作区文件夹切换（改 zstd/jsonl 头、搬日志目录、registry detach/attach）。插件补丁只写 `$DSH_HOME/cordis.patch.yml`，禁止再写 `profiles/web/cordis.patch.yml`，否则 duplicate id 会让 DSH 起不来。启动最前面若 profile overlay 存在但不是顶层 YAML 数组（空文件/纯注释/对象），写成 `[]`，不要绑在插件部署或 `bin.js` 探测上。插件未加载且 cwd 已一致才允许 attach / `insertSessionBefore` 兜底。归属显示也要 cwd 对得上，不能只看 `sessionIds`。
- #243「会话长按无拖影」已由 #245 重建关闭。后续视觉/跨项目问题见 `docs/fix-log.md` #246-#273，不要再按 #243 的猜测补丁或重新接系统 Draggable。

## 拾忆跨会话查阅
- 拾忆会话之间必须能互相看见：用户从会话卡片左滑「复制 ID」后，把 ID 发到另一个会话，模型要用 `search_sessions` / `read_session` 找到并阅读，禁止声称搜不到或看不见。
- `search_sessions` 必须按完整会话 ID 命中（不只搜标题/正文）；`read_session` 读该会话已落库的用户/助手消息。不要走 `search_memory` 或联网搜索。
- 这是拾忆本地库能力，不是 DSH `session.search`。DSH 会话 ID 对拾忆无效。

## 拾忆会话并发规则
- 拾忆会话必须支持多会话同时生成；会话 A 正在思考时，用户可以在会话 B 继续发送，二者互不打断。
- 停止、引导、流式正文、思考过程、工具事件、模型提问、子代理进度、计划模式和本轮统计必须按会话隔离，禁止重新退化为单个全局运行状态。
- `isBusy` 只表示“至少一个会话在运行”，不能用于拦截其他会话发送；页面和会话卡片必须使用 `isBusyForSession(sessionId)`。
- 停止必须立即取消当前会话的 HTTP/SSE、子代理请求和 `run_terminal` 进程；禁止只设置标记后等待下一枚 token。引导发送/插话先收口旧回合，再启动新回合；旧回合迟到事件不得污染新回合。
- 修改拾忆生成链路时必须保留跨会话并行回归测试：A/B 同时 active，停止 B 不得设置 A 的停止令牌，流式内容和工具事件不得串线。

## 思考档位规则
- 会话页思考开关 / 档位按模型 ID 关键字识别，不绑死版本号：`gpt-5.6` 认 `gpt`，`deepseek-v4-flash` 认 `deepseek`。拾忆直连与 DSH 注入共用 `lib/core/reasoning_models.dart`。
- `gpt-4o` / `gpt-4.1` / `gpt-3.5` 没有 reasoning 参数，不能跟 `gpt-5` / Codex 一起被裸关键字 `gpt` 命中（OpenRouter 的 `openai/gpt-4o` 同理）。
- 命中家族关键字时有默认档位（多为 `high`）并按协议组包：OpenAI 兼容发 `reasoning_effort`，GPT 关闭发 `none`；Responses 发 `reasoning: {effort}`；DeepSeek 官方额外发 `thinking: {type: enabled}`；Anthropic Messages 发 `thinking.budget_tokens` 且不发 `temperature`。
- 对不上关键字的非空模型 ID 仍显示通用档位（off/low/medium/high/max），但默认不自动往请求或 DSH provider 里塞 thinking。空模型 ID 不显示按钮。
- DSH 会话页按钮读同一套目录；真正发请求走 `session.selectModel` 的 `reasoningEffort`，不要把拾忆请求体误写成 DSH 文件协议。
- OpenRouter 手写注入必须 `compat.supportsStore: false`（pi-ai 会把 `store: false` 转发给 OpenRouter 导致 400）；Anthropic 协议不要写 `supportsStore`。

## 拾忆 API 协议
- 三条并列：`openai`（Chat Completions）/ `responses`（OpenAI Responses）/ `anthropic`（Messages）。设置页与 `ApiProfile.apiProtocol` 同步持久化。
- Responses 可移植子集：冻头 → `instructions`，其余 → `input`，默认 `store: false`。**禁止** `previous_response_id` / `prompt_cache_key`。网关拒 `store` 时去掉再试。DeepSeek 官方路径去掉 `/v1`（`POST https://api.deepseek.com/responses`）。
- 压缩必须 cache-safe fork：同一冻头 + 同一 tools，压缩指令放动尾。长会话旧工具轮原地截断，不从中间抽轮。计划模式不换 tools 表，只读约束走动尾提示词 + 执行层拦截。
- Responses 可发 `include: ["reasoning.encrypted_content"]` 并原样回放 `type=reasoning`；网关拒 `include` / `parallel_tool_calls` 时去掉再试。Chat 补 `tool_choice: auto` 与 `parallel_tool_calls: true`。禁止 `prompt_cache_retention`。
- 图片：Chat 走 `{type:image_url, image_url:{url}}`；Responses 必须转成 `{type:input_image, image_url:"..."}`，`image_url` 是字符串。禁止把 Chat 块原样塞进 Responses。
- 冻头必须跨请求字节级稳定。滚动摘要、记忆、活人感、当前时间、裁剪说明、重试指令都进动尾或历史归档，不要改冻头。人设 / 技能出现 `{{now}}` / `{{user_text}}` 时整段改走动尾。
- Chat Completions：冻头第一条 system，动尾放到历史之后，禁止合并。Claude：冻头 system 与最后一个 tool 打 `cache_control: ephemeral`。
- 不要内嵌 Codex harness，不要把核心改成 Rust，不要和 DSH 混协议。拾忆 `responses` 同步 DSH 时映射 `openai-responses`。
- 缓存命中率：会话累计 + 本轮命中/未缓存。命中率高=便宜，低=爆炸。75% 滚动任务摘要只进动尾，禁止插在冻头和历史中间。
- 大工具输出 spill 到会话工作目录 `.shiyi/tool-outputs/`，模型只看头尾预览 + 路径；`file_read` 超长按头尾裁，不改 tools schema（禁止加 offset 参数）。只读 `tool_calls` 主循环并行，`run_terminal` / 写入 / `question` 仍串行。工具循环超预算先原地截断旧输出，再 trim。详见 `docs/fix-log.md` #274/#275/#276/#277/#278。

## SOCKS5 代理通道
- 设置 → 通用 → SOCKS5 代理：`off` / `auto` / `custom`。`auto` 扫本机 Clash mixed/socks、V2RayN、SS 常见端口并做 SOCKS5 握手；`custom` 用已保存服务器或临时主机端口。
- 对话（`LlmClient`）、拉模型、联网搜索（`web_tools`）走 `Socks5Proxy.client()`。DSH npm 安装用的 HTTP 自动代理（`NetworkProxyDetector`）不要混进这条 SOCKS5。
- 服务器密码走 `flutter_secure_storage`，不要写进 prefs JSON。分组底部说明必须是 12 号灰色提示，不要用默认正文字号。
- 手机连电脑 Clash：Clash 开允许局域网，自定义里填电脑局域网 IP，不要填 `127.0.0.1`。

## 活人感
 - `enablePresence` 默认关，开关在 Agent 引擎页的 LAAP 卡上，不在对话设置里。打开且皮层就绪后，才把官方 PSI preamble 走动尾（order 860）。对照 `psi_hermes_adapter.py`：注入 `## PSI Cognitive State (Live)` + preamble + 需求风格 + cot_hint。没有本地关键字/需求演化替身，也不要写「本机皮层已接通」。皮层挂了就不注入。不要写进冻头，不要改回静态 soul。
 - LAAP 是皮层不是第三套聊天引擎：引擎页单独安装/启停 `LaapService`（127.0.0.1:11546）。`PYTHONPATH` 必须带 `aris_brain`，Android 要有 numpy。启动时 `/health` 不够，还得 `/v1/cognitive_state` 真能返回 preamble/needs。回合结束 `/v1/reflect`。禁止把拾忆 `baseUrl` 改到 LAAP。

## 会话压缩入口
- 输入区常驻 `ChatCompressionButton` 是唯一手动压缩入口。禁止再在达到阈值时弹出右下角「压缩上下文」胶囊。

## 拾忆群聊
- 只属于拾忆，DSH 不做群聊。入口在拾忆主页会话 tab 顶部「群聊」条，以及功能页群聊列表。不进底栏第五项，DSH 主页不加。
- `HomeGroupChats` 不进长按拖拽；切回会话 tab 时刷新群聊列表。主页与功能页共用 `GroupRoomTile`，左滑编辑/删除。卡片必须和会话卡同一套：36 圆角头像、15.5 标题、12.5 副标题、14 圆角玻璃卡；头像用太极八卦 `BaguaAvatar`，禁止再叠成员色块或 `person_2`。
- 群聊会话页必须走共享聊天 UI：`ChatFloatingComposerScaffold` + `LiquidGlassChatComposer` + `MessageBubble`。禁止再画一套实心底输入框或自定义气泡。输入区不放附件按钮（群聊 `tools: []`）。点名芯片用 `ChatComposerChip`。红绿灯返回、17 号标题、右侧 `FrostedSettingsButton` 进成员设置，禁止用双人 `IconButton`。
- 群聊所有推入页（列表 / 新建编辑 / Agent / 会话）包 `MacBackFade`，和拾忆会话同一套预测性返回淡出。新消息走 `MessageBubble.animateEnter`。主页群聊展开/收起走 `StaggeredSessions`。从群聊返回主页/列表后等 350ms 再刷新，避免退场动画拆树。
- 群聊标识一律太极八卦：分组头 / 空态用 `BaguaIcon`，功能页入口和卡片用 `BaguaAvatar`。
- 功能页群聊空态对齐技能页：56 八卦图标、17 号标题、`CupertinoButton.filled`。新建/编辑/Agent 页红绿灯返回、64 导航栏、17 号标题、右侧 `CupertinoButton` 保存；表单走 `IosLabeledField` / `IosIconTile`，和设置页同一套，禁止 Material `TextButton` 加无标签输入框。
- 功能页可建多个群聊、可删除（左滑删除 / 编辑）。
- 每个 Agent 独立：自己的名字、职位、人设提示词、拾忆 API 配置和模型。人设只进该成员的 system，不改全局人设。
- 新建/编辑可粘贴 mermaid 或字符思维导图：识别角色人数、人设、汇报关系。填入只替换当前编辑中的成员和标题，不自动保存。每人先套当前默认 API 配置（`apiProfiles.first`）和模型，之后可单独改。有起步路线时可选「全部 / 最小 N 人」。
- 官方会话工具不进群聊（`tools: []`），没有文件 / 终端 / 子代理 / 记忆写入。
- 组织是公司结构，不是全员抢答：`reports_to` 为空的人对接用户；其他人被 `@名字` 或上级安排后才发言，说完向直接上级汇报。正常推进不设固定轮次/每人次数上限；只有明确「打回」的同一交接环节最多 3 次。
- 群聊按并行批次调度：同一批最多 3 个 Agent 同时生成；多个成员汇报同一位上级时合并成一次排队，已超限或已在队列里的成员不重复排队。
- 每个 Agent 的思考过程单独显示在自己的气泡里，禁止把 reasoning 写进正文。
- 库表 `group_rooms` / `group_agents` / `group_messages`，DB v23 只 `CREATE TABLE IF NOT EXISTS`；`title` / `reports_to` 在 `ensureTables` 里 ALTER，不清数据。

## DSH 连接
- 三种并列：`local`（本机 `http://127.0.0.1:3080`，可安装/启停）/ `lan`（主机+端口，默认 3080）/ `remote`（完整 URL，可选 Token）。默认 `local`。
- API / WS 一律读当前连接 URL，不要写死 `127.0.0.1:3080`。公网 URL 带路径前缀时，WS 必须挂在同一前缀下（`/app/api/events.mux`）。
- DSH 文件页必须读取当前连接的 `host.describe` / `host.listDirectory`，初始目录取该主机 `cwd`，缺省再取远端 `home`。切换 local / lan / remote 时清掉旧路径、面包屑和在途结果，禁止把手机 `FileWorkspace.defaultWorkspacePath` 发给局域网/公网，也禁止远端失败后回退手机文件系统。`host.createDirectory` 必须发送父目录 `path` + 单段 `name`。当前官方 `host.*` 没有文件读取/写入/删除 RPC，不要用本地 `File` API伪装远端能力。
- DSH 文件页的路径选择器必须展示当前远端可访问的根目录：Windows 通过 `host.listDirectory` 并发探测 `A:\` 到 `Z:\`，只保留成功盘符；Linux / Alpine 只探测 `/`。根盘扫描不能使用不存在的 `host.listDrives` RPC，也不能扫描手机本地磁盘。
- 工作区左滑的“工作区文件夹”必须进入应用内 DSH 文件页并用 `host.listDirectory` 浏览工作区路径；不要对局域网 / 公网工作区调用 `host.openPath`，该接口依赖远端系统打开权限，可能返回 `403`。
- 局域网 / 公网禁止 `ensureRunning()` 拉起本机进程，禁止 `stop()` / `dshStopOnExit` 杀本机 DSH，禁止用远程失败去卸本机包。搬家插件 `POST /__shiyi/move-session` 只存在于本机补丁；局域网 / 公网禁止打这条未知路径。DSH 会话跨工作区移动三端关闭：悬停其他工作区不展开、不显示「松开以移入」，松手飞回本工作区原位；左滑不再提供搬家。同工作区排序仍走 `insertSessionBefore`，手势不得 await RPC。工作区文件夹切换仍可用本机插件（8s，不重启 DSH）；局域网 / 公网禁止打 `/__shiyi/move-session`。远程没有插件不要为了补插件去重启本机 DSH。
- Token 进 `flutter_secure_storage`，不要写进 prefs JSON。局域网 DSH 需监听 `0.0.0.0`，手机不要填 `127.0.0.1`。
- `lan` 只连接用户填写的主机与端口，禁止自动扫描。Host/端口候选扫描只在 `remote` 模式启用；远程自定义 `dshRemoteHost` 优先于内置 `127.0.0.1` / `localhost` / `0.0.0.0` 与常用端口组合，命中后 API / WS 共用同一 Host。
- 内置回环 Host 返回 `200` 但 `session.list` / `workspace.list` 为空时，视为公网来源隔离视图，禁止记成连接成功；用户显式填写的 Host 可以连接空白新实例。
- 局域网 URL 始终连接用户填写的真实电脑 IP；若目标 DSH 对来源身份做隔离，HTTP 与 WebSocket 可以统一使用兼容 `Host` / `Origin`（例如 `127.0.0.1:<端口>`），但不得把 TCP 目标改回手机回环地址。兼容身份必须按连接 scope 保存并在切换主机时清除。
- 拾忆 API 走向（#307 统一，本机 = 局域网）：**本机与局域网 DSH 都走「手机临时中转」租约**（随用随删；本机经 `http://127.0.0.1:<dshRelayPort>`，局域网经手机局域网 IP + `dshRelayPort`），选中「手机临时中转 · <配置>」即按会话注入 + selectModel。**公网 DSH 拨不进手机**（#294/#297 已证，隧道方案全部否决）：走**直接注入**——`injectShiyiProfileForRemote` 把真实 baseUrl + API Key 持久写入目标 `settings.yaml` / `.credentials.yaml`（`injectShiyiDirectNow`，provider 按手机实例派生、幂等），选中「拾忆 API · <配置>」即注入 + selectModel；用户在目标 DSH 模型数据页可查看、可手动删除，公网目标主机因此持有真实密钥，这是用户知情接受的边界。禁止再往公网链路上加 Relay / 隧道。发送撞上失效 provider（`no adapter serves provider` / `model-unavailable`，#308）自动重取租约重试一次。三条连接链路按 scope 隔离，不得回退读取手机本地 DSH 文件。目标 DSH 必须开放 `settings.mutate` / `credentials.set` 才能登记（返回 403 时保持只读并提示开启管理权限）。
- 插件页按连接 scope 分流：本机读 `$DSH_HOME` 两层补丁文件（DshPluginStore，可启停/删除/改配置）；局域网 / 公网走官方 typert `pluginInventory/list` 实时清单（`POST /api/pluginInventory/list`，payload `{args:{}}`，只读），**禁止用本机补丁文件冒充远端插件状态**，远端修改需登目标服务器改 cordis.patch.yml。
- Relay 可达地址：本机 DSH 走 `http://127.0.0.1:<dshRelayPort>`（与 Relay 同设备，不依赖 Wi-Fi）；局域网走手机局域网 IP + `dshRelayPort`（`ShiyiApiRelay.preferredLanIpv4`）；公网不走 Relay（直接注入）。**公网不引入任何隧道**：Cloudflare Quick Tunnel（#294）与 SSH 反向隧道（#295/#296）先后实测放弃，#297 全部回退。
- 密钥边界不变：真实 API Key 与上游 `baseUrl` 不离开手机，目标 DSH 只保存临时 Relay provider / token；SSH 反向隧道端到端加密，模型正文不经任何第三方。
- 多台手机连接同一目标 DSH 时，Relay provider 与凭据引用必须包含手机实例派生标识，禁止共用固定 `shiyi_relay` / `SHIYI_RELAY_TOKEN` 后互相覆盖。

## DSH 配置同步规则
- **本机 = 局域网 = 公网，同一套代码路径（#307 统一）**：拾忆 API 在本机与局域网走「手机临时中转」租约（随用随删；本机 DSH 与 Relay 同设备，中转地址 `http://127.0.0.1:<dshRelayPort>`，不依赖 Wi-Fi），公网走直接注入（`injectShiyiDirectNow`，目标主机持有真实 Key，用户知情接受）。旧的「API 来源」全局开关与批量注入链路（syncFromShiyi / syncLive / syncFiles / injectNow / applyToSession）已整体移除，`dshApiSource` 字段仅存兼容不再读取；禁止再往本机加独立的注入/同步特殊路径。
- 拾忆与 DSH 的协议/状态路径必须分开：目标 DSH 自有 API 走原生 `session.selectModel` / `session.prompt`；拾忆 API 的中转模式只通过 `ShiyiApiRelay` 和独立 Relay provider 接通，真实上游请求仍在手机执行。禁止把拾忆请求误写成 DSH 文件协议或伪造 `commands/execute` 为远端工具 RPC。
- 发送自愈（#308）：prompt 命中 `no adapter serves provider` / `model-unavailable`（会话服务端选择指向已删除的 provider，如清理过的旧注入路由）且当前有中转选择时，自动重取一次中转租约（重新注入 + selectModel）并重试一次发送，再失败才报错。
- 密钥只进 credentials / `.credentials.yaml`，禁止写入 provider settings。
- “模型数据”三模式同一套目标 provider UI（`usesTargetModelCatalog` 恒 true）：合并 `settings.describe`、`llm.providers`、`llm.models` 与 `credentials.describe`，按一份 provider 显示一张卡。展示口径 = `active || declared` 且 settingsNs 非空（内置 deepseek-official / llm-deepseek 显示并带「内置声明」徽标；vision-toolkit-* 空命名空间镜像与未启用未手写的目录噪音隐藏）。清除按命名空间分发：llm-pi-ai 路由走 `unsetProviderOps`；其他有 settingsPath 的按声明路径原位 unset；内置无路由无凭据的弹说明不发空 mutate。本机也走这套 UI，旧的「已注入配置」列表已删。
- `profiles/web/cordis.patch.yml` 必须是顶层 YAML 数组。空文件会让 DSH 退出码 1；启动前由 `_repairDshPatchOverlays` 写成 `[]`。搬家插件不要往这一层 insert。
- 「修复完整运行环境」只检查 Alpine / Node / node-pty / koffi，不修复 YAML / 凭据文档。批量注入移除后本机不再由 app 写 settings.yaml；配置问题在模型数据页或服务器侧处理，不要误导用户点修复环境。
  Windows 没有这条「修复完整运行环境」Alpine 流程，桌面终端走本机 WSL / Git Bash / pwsh / cmd。
- **页面数据口径**：局域网 / 公网强制实时（不拿手机缓存冒充远端状态）；本机保留页面缓存（cache-first，同设备数据秒开，#307 真机反馈后保留）。工作区 Tab 只保留「DSH 后台启动中，完成后自动刷新」一个小横幅，「正在显示离线缓存」横幅已删。
- DSH 会话页权限按钮（输入区盾牌图标）：选项读 `settings.describe` 的 `permission` 命名空间 schema（schemastery `{uid, refs}` 引用图：根对象 dict.defaultPreset → union.list → const{value, meta.description}），禁止硬编码预设名。**切换对当前会话实时生效**：走 typert `commands/execute`（`POST /api/commands/execute`，client-request 信封，payload `{args: {agentId, line: '/permission <preset>'}}`，即官方输入框弹层同一条 `/permission` 命令链路），成功写入 `permission/preset` 会话事件；当前值从 history 折叠该事件（无事件=创建时组合默认，用服务器 defaultPreset 估计），mux 下行 `permission/preset` 实时反映其他客户端的切换。`settings.mutate defaultPreset` 是另一条语义（新会话默认，官方设置行走这条），不要和实时切换混用。会话未物化（agent 冷）时 commands/execute 会被服务端拒绝，如实报错。未挂 permissionPresets 服务的 DSH 按钮隐藏。
