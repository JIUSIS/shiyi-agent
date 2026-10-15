# 拾忆 ↔ DSH 官方功能对接表（rc.2）

> **对齐依据**：目标 DSH 自己装的那份 `@deepseek-ai/dsh@0.2.0-rc.2`。
> - 接口契约 = 各包的 `lib/typert.remote-client.js`（端点 id、wire 参数名、请求/响应 schema）；
> - **官方用法** = `dsh-client-ui-*` 的 `lib/client.js`（浏览器半边；`lib/index.js` 只是 Node 空壳）；
> - 不要按旧注释或猜测写协议（#396 的教训：`workspace/list`、`subagents/list`、`agentPresets/copy` 都不存在）。
>
> 提取命令（设备连着时）：
> ```sh
> # 谁带客户端清单
> cd <dsh-pkg>/node_modules/@deepseek-ai && for d in */; do [ -f "$d/lib/typert.remote-client.js" ] && echo "$d"; done
> # 某功能的官方用法
> run-as com.shiyi.agent cat <pkg>/lib/client.js | grep -o '\b[a-zA-Z]*\.[a-zA-Z]*(('
> ```

## 一、官方接口面（26 个包带 typert 客户端清单）

| 命名空间 | 端点 | 拾忆状态 |
|---|---|---|
| `session/` | list, page, follow*, control*, create, prompt, rename, search, selectModel, cancel, **fork**, **attachment**, **projections**, **updateQueue**, canOpenWorkspacePath, openWorkspacePath, **workspacePathApplications**, modelCatalog, initializeDefaultModel, skills/list, **fileReferences/list** | 核心已接；**加粗**未接 |
| `workspace/` | follow*, create, rename, delete, insertBefore, insertSessionBefore, archiveSession, **unarchiveSession**, **pinSession**, **unpinSession**, **initializeDefault** | 核心已接；置顶/取消归档/默认工作区未接 |
| `workspaceFiles/` | list, read, readBytes, stat, changes | **全未接**（文件页现在走 `directoryPicker/*`） |
| `directoryPicker/` | list, pick, createDirectory | 已接 |
| `terminal/` | create, write, resize, follow*, list, shells, close, rename, retain, environment | **全未接**（局域网终端 tab 跑的是手机内 Alpine） |
| `job/` | list, follow*, kill | **全未接**（后台任务面板） |
| `settings/` | describe, update, mutate, replace, openSettingsDocument | 已接（默认预设 ns 运行时解析） |
| `credentials/` | describe(refs), set(ref,value), unset(ref) | 已接（record 形状已修） |
| `agentPresets/` | list, read, select | 已接；copy/delete **不存在**（入口已收起） |
| `subagents/` | prompt, interruptByParent | 已接；**list 不存在**，改由 `session/list` 派生 |
| `goals/` | create, edit, get, pause, resume, complete, clear | 已接 |
| `userQuestions/` | answer(agentId,callId,{answers}), attachWait | **answer 已接**（#398）；attachWait 未接 |
| `commands/` | list, execute | 仅 permission 切换用了 execute；**斜杠命令菜单未接** |
| `fileUploads/` | upload | **未接**（附件/图片上传） |
| `schedule/` | catalog, list, update, delete, history | **全未接**（定时任务） |
| `messageFeedback/` | list, put, delete | **未接**（消息反馈） |
| `sessionFeedback/` | record | **未接** |
| `sessionReferenceResolver/` | candidates | **未接**（@-引用候选） |
| `pluginInventory/` | list | 已接（远端插件只读清单） |
| `pluginManager/` | 12 个：listPlugins/listBundles/inspect/installBundle/removeBundle/setPluginEnabled/setBundleEnabled/registries/listVersionExemptions/setVersionExemption/cancelInstall/waitForInstall | **未接**（远端装/删/启停插件） |
| `pluginRegistryProbe/` | fastest | 未接（镜像测速） |
| `llm/` | listProviders, listConfigurableProviders, discoverModels | 前两个已接；**discoverModels 未接**（刷新某 provider 的模型） |
| `permissionPresets/` | catalog | 未接（现从 `settings.describe` 的 permission ns 读，可用） |
| `speech/` | catalog, configure, prepare, follow*, transcribe, cancelPreparation | **未接**（语音转文字） |
| `account/` | getState, getProfile, getBalance, startSignIn, cancelSignIn, signOut, watch*, watchExpiry, hasRunningAccountTasks, getUnnotifiedBonuses, ackBonusNotified | **未接**（账号/余额；拾忆自带 API Key，可不做） |
| `officeToPdf/` | render, generation | 未接 |
| `dynamicCordisRunner/` | 12 个 | 未接（Cordis 面板；插件作者向，优先度低） |

（`follow` 带 `*` 的是流式端点，需要 WebSocket —— 局域网 8080 那层转发不做隧道，见 fix-log #392。）

## 二、官方桌面版功能 → 拾忆现状

| 官方功能（客户端包） | 依赖接口 | 拾忆 |
|---|---|---|
| 会话对话 / 流式 | `session/follow*`, `session/page` | ✅（局域网降级为轮询，已限流 #397） |
| 模型选择 / 思考档位 | `session/selectModel`, `session/modelCatalog`, `llm/*` | ✅ |
| 权限预设 | `commands/execute`（`/permission`）、`permissionPresets/catalog` | ✅（后可改走 catalog） |
| Agent 预设 | `agentPresets/*` | ✅（copy/delete 已收起） |
| 子代理 | `subagents/*` + `session/list` 派生 | ✅（#396） |
| 目标 / 计划 | `goals/*` | ✅ |
| 提问 | `userQuestions/answer` | ✅ 新增（#398）；**局域网看不到提问**（发现依赖 WS） |
| 工作区 / 会话列表 | `workspace/follow*`, `session/list` | ✅（#388/#396） |
| 归档 / 置顶 / 默认工作区 | `workspace/archiveSession|pinSession|unpinSession|unarchiveSession|initializeDefault` | ⚠️ 只有归档 |
| 搜索 | `session/search` + join | ✅（#396） |
| **@-引用** | `fileReferences/list`, `sessionReferenceResolver/candidates` | ❌ |
| **附件/图片** | `fileUploads/upload`, `session/attachment` | ❌ |
| **斜杠命令菜单** | `commands/list`, `commands/execute` | ❌ |
| **后台任务** | `job/list|follow*|kill` | ❌ |
| **目标机终端** | `terminal/*` | ❌（现在跑手机内 Alpine） |
| **工作区文件（含预览）** | `workspaceFiles/*` | ❌（现在用 `directoryPicker/*`） |
| 插件（远端） | `pluginInventory/list`, `pluginManager/*` | ⚠️ 只读 |
| 定时任务 | `schedule/*` | ❌ |
| 消息反馈 | `messageFeedback/*` | ❌ |
| 语音转写 | `speech/*` | ❌（拾忆有自己的 TTS/STT 入口） |
| 账号 / 余额 | `account/*` | ❌（非必需） |
| 文档预览转 PDF | `officeToPdf/*` | ❌ |
| 队列编辑（引导插话排队） | `session/updateQueue` | ❌ |
| 会话分叉 | `session/fork` | ❌ |
| Cordis 面板 / 动态插件 | `dynamicCordisRunner/*` | ❌（插件作者向） |

## 三、建议顺序（按用户可见价值）

1. **附件/图片上传**（`fileUploads/upload` + `session/attachment`）—— 输入区直接缺能力；
2. **斜杠命令**（`commands/list` + `execute`）—— 官方输入框的 `/` 菜单；
3. **后台任务面板**（`job/list|follow|kill`）—— 长任务可见/可杀；
4. **工作区文件**（`workspaceFiles/*`）—— 文件页改走正确 API，并支持预览；
5. **目标机终端**（`terminal/*`）—— 局域网/远程终端 tab 接目标机；
6. 归档/置顶/默认工作区、`llm/discoverModels`、`session/updateQueue|fork`；
7. 定时任务、消息反馈、插件管理、语音、账号、PDF、Cordis。

每项都应：先按 `lib/client.js` 的用法确认参数，再在 `dsh_api.dart` 加 typed 方法（+ wire 映射）、补单测、最后真机验证。
