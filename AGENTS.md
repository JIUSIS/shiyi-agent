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
- **终端交互铁律**：没有底部独立输入框，点画面输入；执行中输入仍可用（busy 时回车喂 stdin）。切引擎不发 Ctrl+C。输入法弹出贴底、滑动历史不弹键盘。输入 / 正常输出 / 警告 / 错误分色。独立 `/` 才弹技能。

## Windows 桌面版（exe）
- 2026-08-14 起项目支持 Windows 桌面完整版：命令后端**用户可选**（设置 → 通用 → 终端）：
  自动（WSL2 优先 → PowerShell 7 → cmd）/ WSL2 / PowerShell 7 / cmd；
  数据库走 sqflite_common_ffi，技能 zip 用 archive 包纯 Dart 解压。
- **UI 已桌面化 + macOS 操作逻辑化**：右键菜单、悬停展开操作、ActionSheet 桌面居中、
  宽窗口侧边导航 + 内容限宽、Ctrl+Enter 快捷键；**无边框窗口 + 红黄绿三键**
  （拖拽/双击最大化/边缘缩放/贴靠）。
- **Windows 端维护文档（独立，勿与手机端混淆）**：`docs/windows-maintenance.md`
  （架构/适配/维护铁律/排错/验证清单）；构建步骤见 `docs/windows-build.md`。
  手机端部署/排错见本文件顶部与 `docs/fix-log.md`。
- 构建：`flutter build windows --release` → `build\windows\x64\runner\Release\shiyi_agent.exe`。
- 注意：桌面版与 Android 版共享同一套 lib/ 代码，所有平台差异用 `Platform.isWindows`
  分支隔离；改共享代码时不要破坏 Android 侧行为（`flutter test` 全量守护）。

## 拾忆 / DSH UI 同步规则
- 拾忆与 DSH 的聊天 UI 必须保持同一套视觉语言、液态玻璃样式和交互逻辑。
- 修改任一聊天 UI 时，必须同步检查并更新另一引擎，不能只修拾忆或只修 DSH。
- 输入框、消息气泡、工具胶囊、状态条、提问面板、附件预览等能共享的部分必须优先抽成共享组件，禁止复制两套后分别维护。
- 只有协议或引擎能力确实不同的界面允许单独实现，并需在维护文档说明原因。

## 拾忆会话并发规则
- 拾忆会话必须支持多会话同时生成；会话 A 正在思考时，用户可以在会话 B 继续发送，二者互不打断。
- 停止、引导、流式正文、思考过程、工具事件、模型提问、子代理进度、计划模式和本轮统计必须按会话隔离，禁止重新退化为单个全局运行状态。
- `isBusy` 只表示“至少一个会话在运行”，不能用于拦截其他会话发送；页面和会话卡片必须使用 `isBusyForSession(sessionId)`。
- 修改拾忆生成链路时必须保留跨会话并行回归测试：A/B 同时 active，停止 B 不得设置 A 的停止令牌，流式内容和工具事件不得串线。

## 思考档位规则
- 会话页思考开关 / 档位按模型 ID 关键字识别，不绑死版本号：`gpt-5.6` 认 `gpt`，`deepseek-v4-flash` 认 `deepseek`。拾忆直连与 DSH 注入共用 `lib/core/reasoning_models.dart`。
- `gpt-4o` / `gpt-4.1` / `gpt-3.5` 没有 reasoning 参数，不能跟 `gpt-5` / Codex 一起被裸关键字 `gpt` 命中（OpenRouter 的 `openai/gpt-4o` 同理）。
- 命中家族关键字时有默认档位（多为 `high`）并按协议组包：OpenAI 兼容发 `reasoning_effort`，GPT 关闭发 `none`；DeepSeek 官方额外发 `thinking: {type: enabled}`；Anthropic Messages 发 `thinking.budget_tokens` 且不发 `temperature`。
- 对不上关键字的非空模型 ID 仍显示通用档位（off/low/medium/high/max），但默认不自动往请求或 DSH provider 里塞 thinking。空模型 ID 不显示按钮。
- DSH 会话页按钮读同一套目录；真正发请求走 `session.selectModel` 的 `reasoningEffort`，不要把拾忆请求体误写成 DSH 文件协议。
- OpenRouter 手写注入必须 `compat.supportsStore: false`（pi-ai 会把 `store: false` 转发给 OpenRouter 导致 400）；Anthropic 协议不要写 `supportsStore`。

## SOCKS5 代理通道
- 设置 → 通用 → SOCKS5 代理：`off` / `auto` / `custom`。`auto` 扫本机 Clash mixed/socks、V2RayN、SS 常见端口并做 SOCKS5 握手；`custom` 用已保存服务器或临时主机端口。
- 对话（`LlmClient`）、拉模型、联网搜索（`web_tools`）走 `Socks5Proxy.client()`。DSH npm 安装用的 HTTP 自动代理（`NetworkProxyDetector`）不要混进这条 SOCKS5。
- 服务器密码走 `flutter_secure_storage`，不要写进 prefs JSON。分组底部说明必须是 12 号灰色提示，不要用默认正文字号。
- 手机连电脑 Clash：Clash 开允许局域网，自定义里填电脑局域网 IP，不要填 `127.0.0.1`。

## 活人感
- `enablePresence` 默认关。打开后 `PresenceEngine` 每轮生成本轮内心话，经 `PromptSection` 注入；模型只翻译内心，不改工具工作台管线。不要把它改回静态 soul 段落。

## 会话压缩入口
- 输入区常驻 `ChatCompressionButton` 是唯一手动压缩入口。禁止再在达到阈值时弹出右下角「压缩上下文」胶囊。

## DSH 配置同步规则
- 拾忆与 DSH 的协议/状态路径必须分开：模型注入走 `DshModelSync`，会话发送与模型选择走各自 API，禁止把拾忆请求误写成 DSH 文件协议。
- 所有会读改写 DSH 文件（`settings.yaml` / `.credentials.yaml` / `cordis.patch.yml`）的入口必须走 `DshModelSync` 共享串行队列；`unawaited(syncFromShiyi)` 可以保留，但不能各自加锁。
- `settings.yaml` 必须临时文件写完再 `rename` 原子替换，禁止直接 `writeAsString` 截断目标。DSH 启动解析时只能看到完整旧文件或完整新文件。
- 启动同步若发现 `settings.yaml` 已损坏，先备份为 `settings.yaml.corrupt` 再重建干净配置；不要把坏快照再喂给行级 upsert。
- 密钥只进 credentials / `.credentials.yaml`，禁止写入 provider settings。
- DSH 0.1.1 的 `.credentials.yaml` 只认 `version: 1` + `refs` / `records`。禁止把 `SHIYI_API_KEY` 写到顶层；启动同步必须把旧扁平文档和混写文档收进 `refs`。
- 「修复完整运行环境」只检查 Alpine / Node / node-pty / koffi，不修复 YAML / 凭据文档。YAML 或凭据损坏应靠启动同步自愈，不要误导用户点修复环境。
