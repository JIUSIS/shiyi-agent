# 拾忆（ShiYi）Windows 桌面版维护手册

> **本文档只维护 Windows 桌面版（exe）**。
> 手机端（Android）的部署偏好 / 真机环境 / APK 构建见 `AGENTS.md` 顶部章节，
> 手机端历史排错见 `docs/fix-log.md`。
> 两端共享同一套 `lib/` 代码：所有平台差异必须用 `Platform.isWindows` 分支隔离，
> 改动后必须跑全量测试（`flutter test`）确认不破坏 Android 侧行为。
> 快速构建步骤见 `docs/windows-build.md`。

---

## 1. 平台全景（Windows 版 vs Android 版）

| 模块 | Android（手机） | Windows（桌面 exe） |
|---|---|---|
| 命令执行后端 | 内嵌 Alpine Linux（proot + minirootfs，apk 包管理，2026-08-15 起取代 Termux bootstrap）。主页第四栏「终端」走同一套 `init-host`。手机上看不到 WSL / Git Bash / PowerShell 设置 | **用户可选**（设置 → 通用 → 终端）：自动（WSL2 → Git Bash → PowerShell 7 → cmd）/ WSL2 / Git Bash / PowerShell 7 / cmd。不走 Android Alpine / proot / apk |
| 数据库 | sqflite 原生（应用 Documents） | `sqflite_common_ffi`（sqlite3.dll）；库文件 `%APPDATA%\com.shiyi\拾忆 ShiYi\shiyi_agent.db` |
| 技能包 zip | Android 原生 ZipInputStream（MethodChannel `shiyi/skillpack`） | archive 包纯 Dart（channel 抛 MissingPluginException 时回退） |
| 图片 | 相册/相机 + flutter_image_compress 压缩 | 相册（相机降级相册）、跳过压缩原图保存 |
| 通知 | flutter_local_notifications Android 通道 | 同插件 WinRT 实现（固定 GUID `c4a7d0e2-9f3b-4a5c-b6d7-8e9f0a1b2c3d`） |
| 应用更新 | 下载 APK + 签名校验 + 系统安装器 | 跳转 GitHub 发布页手动下载 |
| 权限 | permission_handler Android 权限 | 非 Android 直接跳过 |
| 工作目录 | `/storage/emulated/0/agent` | 本机「文档\\agent」（可自定义）；旧 `%TEMP%\\agent` 视为未设置 |
| 系统提示词 | 人设 / 工具规则 / `run_terminal` 只写 Alpine / apk / `/storage/emulated/0/agent` | 注入【平台环境】段落（order 250），按实际后端（wsl2 / gitbash / pwsh / cmd）动态描述。人设 / 工具规则 / `run_terminal` 只写本机终端与「文档\\agent」，不出现 Alpine / apk / 安卓路径 |
| 窗口 | 无（系统全屏） | **无边框 macOS 风格窗口**（红黄绿三键/拖拽/边缘缩放/贴靠） |
| 交互 | 手机操作逻辑（长按/左滑/底部弹层/底部 Tab） | 桌面逻辑（右键菜单/悬停操作/居中弹层/侧边导航/快捷键） |

**数据是分开的**：Windows 版数据库在 AppData，手机版在手机存储，互不影响。

**构建是分开的**：`flutter build apk` 只编 `android/` + 共享 `lib/`，不会把
`windows/` 的 exe / C++ 打进 APK。`flutter build windows` 也不会产出 APK。
共享 `lib/` 里另一侧的字符串会进 Dart 快照（死代码），运行时按
`Platform.isWindows` 取文案，模型在当前平台拿不到另一侧路径。

---

## 2. 构建与产物

```powershell
flutter create --platforms=windows .   # 仅首次：生成 windows/ 平台目录
flutter pub get
flutter build windows --release
```

产物：`build\windows\x64\runner\Release\shiyi_agent.exe`
**分发必须拷贝整个 Release 目录**（依赖同目录的 `flutter_windows.dll`、各插件 DLL、
`sqlite3.dll`、`data/`），单拷 exe 会启动失败。
桌面图标与 Android 启动图标同一套：`windows/runner/resources/app_icon.ico`
来自 `android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png`（16/24/32/48/64/128/256）。

前置条件：Flutter stable（当前 3.44.2）+ Visual Studio（Windows 桌面 C++ 工具链）。

---

## 3. 运行时架构（Windows 特有实现）

### 3.1 命令执行后端（`lib/services/termux_runtime.dart` + `lib/core/app_state.dart`）

- **WSL2 探测** `TermuxRuntime.wslVariant()`：`wsl.exe -e bash -lc 'uname -r'`
  带 `WSL_UTF8=1`（强制 UTF-8 输出，默认管道是 UTF-16LE 会乱码）。
  内核含 `WSL2`/`microsoft-standard` → wsl2；含 `Microsoft`（大写）→ wsl1；
  失败 → none。结果缓存。
- **后端解析** `resolveWindowsBackend(setting)`（纯函数 `resolveBackendChoice`
  可单测）：显式 pwsh/cmd/gitbash 直接生效；auto 与显式 wsl2 在 WSL2 可用时用 WSL2，
  否则 Git Bash（本机 `bash.exe`），再回退 Windows shell（pwsh → cmd）。
  Windows 不走 Android Alpine / proot / apk / init-host。
- **执行** `_execRunTerminal`：
  - WSL2：`wsl.exe -e bash -lc <cmd>`，workingDirectory 由 WSL 自动映射为 `/mnt/<盘符>/...`
  - Git Bash：本机 `Git\\bin\\bash.exe --login -c <cmd>`
  - pwsh：`-NoProfile -NoLogo -NonInteractive -Command <cmd>`
  - cmd：`/c <cmd>`
  - 显式选 WSL2 / Git Bash 但不可用时自动回退并在输出附告警；120s 超时强杀共用。
- **启动自检** `_ensureTermux`：Windows 按实际后端探测（日志 `TermuxProbe backend=...`）。

### 3.2 数据库（`lib/services/db.dart`）

`Platform.isWindows` 时 `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;`，
库目录用 `getApplicationSupportDirectory()`（AppData）。Android 路径不变。

### 3.3 技能包（`lib/services/skill_pack.dart`）

Windows 无原生端：先尝试 channel（测试环境有 mock），捕获
`MissingPluginException` 后回退 Dart archive 实现（`_extractZipDart`/`_createZipDart`）。
全内存实现，超大包（数 GB）可能吃内存，常规技能包无影响。

### 3.4 其他

- 更新（`update_service.dart`）：非 Android 直接 `url_launcher` 打开 GitHub 发布页。
- 通知（`notifier.dart`）：`InitializationSettings` 带
  `windows: WindowsInitializationSettings(appName/appUserModelId/guid)`。
- 设置（`models.dart`）：`AppSettings.terminalBackend`（auto/wsl2/gitbash/pwsh/cmd，JSON 持久化）。
  Android 恒用 Alpine，此设置不生效，设置页入口也不渲染。
- **提示词 / 工具描述隔离**（`prompt_builder.dart` + `_buildToolRegistry`）：
  Windows 只写本机终端与「文档\\agent」；Android 只写 Alpine / apk /
  `/storage/emulated/0/agent`。禁止两端写进同一段。测试：
  `test/prompt_section_test.dart`、`test/terminal_backend_test.dart`。
  工具目录快照 `tools.json` 固定 Android 文案；Windows 文案由行为测试覆盖。

---

## 4. UI：桌面化 + macOS 操作逻辑

### 4.1 无边框窗口（`windows/runner/`，C++）

| 能力 | 实现 |
|---|---|
| 无系统标题栏/黑边 | `WS_POPUP \| WS_THICKFRAME`；`WM_NCCALCSIZE` 客户区铺满；`WS_EX_DROPSHADOW` + `WS_EX_APPWINDOW`。Win11 悬停灰层盖不住原生子窗口标题栏 overlay（`SHIYI_TITLEBAR`） |
| 红黄绿三键 | Dart `MacTitleBar`（44px 全局标题栏，MaterialApp.builder 包裹所有路由）+ `WindowControl`（MethodChannel `shiyi/window`：minimize/toggleMaximize/close/isMaximized）；悬停显示图标；最大化状态由 C++ `WM_SIZE` 推送 `windowStateChanged` 同步，绿键图标随状态切换 |
| 标题栏拖拽 + 双击最大化 | 顶层不返回 `HTCAPTION`。子窗口 `SetWindowSubclass`：拖拽区 `HTTRANSPARENT`，红绿灯 `HTCLIENT`。按下超过拖拽阈值再 `WM_NCLBUTTONDOWN HTCAPTION`。Win11 灰条高度 = DWM 认为的标题栏高度；客户区顶边只留 1px 非客户区后，悬停灰条不再盖住红绿灯 |
| 边缘缩放 + 贴靠 | `WM_NCHITTEST` 6px 边缘返回 `HTLEFT/HTRIGHT/HTTOP/HTBOTTOM/四角`；`WS_MAXIMIZEBOX` 保证 Win+方向键贴靠 |

窗口控制 channel 文件：`flutter_window.cpp`（注册与处理）、`win32_window.cpp`（样式与创建）。

### 4.2 交互迁移（手机 → 桌面）

| 手机操作 | 桌面替代 |
|---|---|
| 长按消息气泡 | 右键（`onSecondaryTapDown`）鼠标位置弹菜单（`lib/widgets/context_menu.dart` `showDesktopMenu`） |
| 左滑会话/项目列表 | 悬停自动展开操作区（`_SwipeActions` MouseRegion）+ 右键同一菜单 |
| 底部 ActionSheet/面板 | 屏幕居中弹出（`showIosFadeModalPopup`/`showIosFadeSheet` 桌面分支，限宽 420/460 + 圆角阴影） |
| 文件/技能「…」按钮 | 列表项右键同一菜单 |
| Enter 发送 | Ctrl+Enter 换行（enterToSend 开）/ Ctrl+Enter 发送（关）；未处理按键交还 TextField |
| 底部 Tab | 宽窗口（≥720px）左侧导航栏；窄窗口保持底部 Tab |
| 全宽手机布局 | 宽窗口内容居中限宽（主页 980 / 聊天页 1080） |

### 4.3 桌面导航与按钮

- `_DesktopNavBar`：BackdropFilter 毛玻璃 + 选中圆角高亮条 + 拖拽调宽（150~300px，`_SidebarResizer`）。
- `MacActionButton`：毛玻璃胶囊按钮，替代页面内红绿灯（窗口控制已归全局标题栏，
  避免语义混淆）；聊天页返回改 chevron 箭头；仅 Windows 分支生效，手机端红绿灯保留。
- 快捷键：Ctrl+N 新建会话、Ctrl+, 打开设置（macOS ⌘ 惯例 = Ctrl，`_handleGlobalKeys`）。

---

## 5. 维护铁律（改代码前必读）

1. **平台隔离**：任何平台差异一律 `Platform.isWindows` 分支，禁止影响 Android 路径。
   工作目录、终端后端、人设、工具规则、`run_terminal` / `file_write` 描述
   必须两端各写各的，禁止「Android …；Windows …」写进同一段给模型看。
2. **全量测试守护**：`flutter test` 必须全绿才可交付；快照测试
   （tools.json / system-prompt-*.txt）已平台无关化（normalize 删除平台段落/打码），
   改动工具描述、人设、注入段落后跑测试会触发 diff，属预期变更时用
   `--dart-define=GENERATE_SNAPSHOTS=true` 重建快照。
3. **C++ 注释必须英文**：MSVC 在 GBK 代码页下遇中文字符报 C4819 硬错误
   （/WX 视为错误）；`windows/runner/` 下所有 .cpp/.h 保持纯 ASCII。
4. **C++ 安全 API**：`getenv`/`fopen` 等触发 C4996 硬错误，用 `_dupenv_s`/`fopen_s`。
5. **窗口常量同步**：`kMacTitleBarHeight=44` / `kMacTrafficLightsWidth=96`
   （win32_window.h）与 Dart `MacTitleBar` 布局（14px 边距 + 3×12px 按钮 + 8px 间距）
   必须保持一致，改一侧必须改另一侧。
6. **通知 GUID 固定**：`c4a7d0e2-9f3b-4a5c-b6d7-8e9f0a1b2c3d` 勿改（卸载重装沿用）。
7. **思考档位按模型 ID 关键字**：拾忆与 DSH 共用 `lib/core/reasoning_models.dart`，
   不绑死版本号（`gpt-5.6` 认 `gpt`，`deepseek-v4-flash` 认 `deepseek`）。
   `gpt-4o` / `gpt-4.1` / `gpt-3.5` 没有 reasoning，不能跟 `gpt-5` / Codex 一起
   被裸关键字 `gpt` 命中。命中家族时默认 `high`：OpenAI 兼容发 `reasoning_effort`
   （GPT 关闭发 `none`），Responses 发 `reasoning: {effort}`，DeepSeek 官方额外发 `thinking: {type: enabled}`，
   Anthropic Messages 发 `thinking.budget_tokens` 且不发 `temperature`。
   对不上关键字的非空 ID 仍显示通用档位，但不自动塞 thinking。网关拒绝思考参数时
   分别去掉不兼容字段重试。拾忆解析 `reasoning_content` / `reasoning` / `thinking`
   专用字段 + 正文 `<thinking>` 标签兜底；禁止对正文做启发式拆思考。DSH 会话页
   按钮读同一目录，真正发请求走 `session.selectModel`。OpenRouter 注入必须
   `compat.supportsStore: false`。
8. **拾忆 / DSH 聊天 Markdown 共用一套渲染器**：会话气泡走
   `lib/widgets/message_bubble.dart` → `AdaptiveMarkdownText`
   （`lib/widgets/markdown_text.dart`）。已有能力：标题、加粗/斜体/删除线/
   行内代码/链接、列表/任务列表、表格（自适应居中）、引用、围栏代码（紧凑分色）。
   2026-08-24 自研补齐：图片、标准脚注 `[^1]` + 文末 `[^1]:`、内联脚注
   `[^1](内容)`、定义列表（含缩进/全角冒号）、键盘按键、`==高亮==`、
   GitHub Alert、LaTeX 可读文本、独立分隔线。
   2026-08-25 再补：嵌套强调、转义字面量、自动/邮箱/参考式链接、
   `<u>` / `<sup>` / `<sub>` / `<mark>`、表格左右中对齐、有序列表按出现顺序重排、
   加号无序列表、行尾两空格硬换行、双反引号包内嵌反引号。
   改渲染必须两端一起验证，禁止只改拾忆或只改 DSH。测试：`test/markdown_text_test.dart`。
9. **思考过程不得升成正文**：拾忆落库走 `finalizeAssistantTurn`，DSH 走
   live / history 原样保留。空正文 + 非空思考必须留在思考面板，禁止再写成
   `content`。思考增量立即推送，正文布局才 80ms / 200 字节节流。两端共用
   `MessageBubble` 的折叠面板。测试：`test/reasoning_stream_test.dart`、
   `test/reasoning_fallback_test.dart`、`test/message_bubble_test.dart`。
10. **上下文上限是新建会话默认，会话可单独改**：设置页不再把 ≥50 万 token
    写回 128k。拾忆写入 `sessions.context_limit`，DSH 写入本机偏好；两端共用
    输入区「会话上下文」按钮。测试：`test/context_limit_test.dart`。
11. **工作目录与终端后端按平台分家**：Windows 默认「文档\\agent」+
    WSL2 / Git Bash / pwsh / cmd；Android 默认 `/storage/emulated/0/agent` +
    Alpine / apk / init-host。测试：`test/file_workspace_test.dart`、
    `test/terminal_backend_test.dart`、`test/prompt_section_test.dart`。
12. **拾忆跨会话查阅**：用户复制会话 ID 发到另一个拾忆会话时，模型必须用
    `search_sessions` / `read_session` 找到并阅读，禁止声称搜不到。
    按完整会话 ID 命中本地库。这不是 DSH `session.search`。
    测试：`test/session_bridge_test.dart`。
13. **终端捏合 / 补全 / 命令分色**：`TerminalPane` 双指捏合缩放字号（1~28，默认 13），
    捏合不弹键盘；中文回退字体；前缀补全（历史优先 + 幽灵字）；命令行 token 分色。
    测试：`test/terminal_pane_test.dart`。
14. **拾忆主页长按拖拽**：`HomeLongPressDrag` + 自建 overlay 拖起整张卡片；
    松手飞入空隙，远放不瞬移；提交贴齐禁止反向弹回。跨项目须停满 1 秒，
    拖回原项目立刻取消「松开以移入」。列表外层必须裁剪，不能让挤开位移盖住搜索栏/状态栏。
    顺序写 `sort_order`，缺列补列不清库。跨组提交只收被拖项源槽，禁止把同组其它卡片收成 0。
    DSH 跨工作区先乐观改本地 `sessionIds` 和 cwd，再静默 `_load()`。详见 `docs/fix-log.md` #241-#273。
    测试：`test/home_list_order_test.dart`、`test/home_sessions_tab_test.dart`、`test/staggered_sessions_test.dart`、`test/dsh_workspace_display_name_test.dart`。
15. **拾忆 API 三条协议 + 冻头/动尾**：`openai` / `responses` / `anthropic` 并列。
    Responses 可移植子集：冻头 → `instructions`，其余 → `input`，`store: false`。
    禁止 `previous_response_id` / `prompt_cache_key`。图片 Chat 走 `image_url` 对象，
    Responses 必须转 `input_image` + 字符串 URL。冻头跨请求字节稳定；记忆 / 活人感 /
    当前时间 / 滚动摘要不进冻头。不要内嵌 Codex harness，不要和 DSH 混协议。LAAP 是活人感皮层不是第三套聊天：Windows 用本机 Python 启 127.0.0.1:11546（PYTHONPATH 带 aris_brain，缺 numpy 就 pip install），不要把拾忆 baseUrl 指过去，也不要写 Alpine 路径。活人感开关在引擎页；按 Hermes 官方接法把 preamble 注入动尾，不要写「本机皮层已接通」，没有本地替身。
    测试：`test/llm_protocol_cache_test.dart`、`test/context_budget_test.dart`。详见 `docs/fix-log.md` #274/#275/#276。
    压缩与主请求同一冻头/tools；旧工具轮原地截断；Responses 回放加密思考 item；
    计划模式不换 tools 表。75% 滚动任务摘要只进动尾。超预算优先压缩，不要靠从中间抽历史来稳缓存。详见 `docs/fix-log.md` #276/#277。
    大工具输出 spill 到工作目录 `.shiyi/tool-outputs/`；只读 tool_calls 并行。详见 `docs/fix-log.md` #278。

---

## 6. 常见问题排查（已踩过的坑）

| 现象 | 根因 | 解法 |
|---|---|---|
| 窗口四周黑边 / 顶部点击变成拖拽 | 系统为 WS_OVERLAPPED 顶层窗口自动补 `WS_CAPTION` | `CreateWindowEx` 后强制 `SetWindowLongPtr` 清除 WS_CAPTION/WS_BORDER/WS_DLGFRAME/WS_SYSMENU + `SetWindowPos(SWP_FRAMECHANGED)` |
| 鼠标移到顶栏整条变灰 | 拖拽区 `WM_NCHITTEST` 返回 `HTCAPTION`，Win11 DWM 画系统标题栏悬停层 | 顶栏返回 `HTCLIENT`，按下移动再启动系统拖拽；关掉 DWM 非客户区绘制 |
| 鼠标移到红绿灯顶栏变灰 | Win11 DWM 把系统 caption 叠在 Flutter 表面之上；改命中测试/分层窗口都挡不住。`SetCursorPos` 复现不了 | 原生子窗口 `SHIYI_TITLEBAR` 盖在灰层上面画红绿灯；颜色跟 Flutter scaffold |
| 三键/拖拽/缩放全部失效 | Flutter 视图子窗口覆盖客户区，顶层收不到 `WM_NCHITTEST` | subclass 子窗口（`FlutterChildProc`）：拖拽区与 6px 边缘返回 `HTTRANSPARENT` 穿透到顶层 |
| C4819 编译错误 | C++ 注释含中文，MSVC GBK 代码页 | 注释改英文（纯 ASCII） |
| C4996 编译错误 | `getenv`/`fopen` 不安全 API | `_dupenv_s`/`fopen_s` |
| C2338 / STL1011 编译错误 | permission_handler_windows 用 `<experimental/coroutine>`，VS 2026 MSVC 14.5x 报硬错误 | `windows/CMakeLists.txt` 已给该插件 target 加 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` |
| WSL2 选了但命令回退 | WSL 未安装/无默认发行版 | 探测失败自动回退 pwsh/cmd 并附告警；装 WSL：`wsl --install` |
| WSL 输出中文乱码 | wsl.exe 管道默认 UTF-16LE | 执行时带 `WSL_UTF8=1` 环境变量 |
| 模拟点击三键无效（自动化测试时） | 窗口未激活时首次点击被系统用于激活 | 先点击内容区激活窗口，再点三键 |
| 拾忆思考进正文、折叠面板空 | 网关不带思考参数时不回 `reasoning_content`，思考被灌进 `content` | 命中家族关键字的模型默认带 `thinking`/`reasoning_effort`（拒绝时降级重试），正文 `<thinking>` 标签兜底拆分。见 `docs/fix-log.md` #219 / #222 |
| 点开思考过程后，思考完把思考当正文带出；部分思考不进面板 | 落库把空正文的思考升成 `content`；历史 `fromMap` 同样提升；拾忆把思考和正文绑在一起 80ms 节流，短 reasoning 增量进不了面板 | 空正文思考保持 `reasoning`；思考增量立即推送，只节流正文。DSH `_publishLive` 已是同一口径。见 `docs/fix-log.md` #231 |
| 设置里上下文改到 1M 后又变回 128k | `SettingsService.load` 把 ≥50 万当成旧字符默认冲掉 | 只纠正非法值；设置是新建会话默认，聊天页可改本会话。见 `docs/fix-log.md` #233 |
| mimo 工具续轮 HTTP 400，日志 `thinking=off reasoningEffort=high` | `thinking=off` 不是关开关；MiMo 拒绝 `reasoning_effort` 时只回模糊 BadRequest，旧重试抓不到字段名 | 模糊 400 也去掉 `reasoning_effort` 重试。见 `docs/fix-log.md` #234 |
| 自定义 Claude/GPT/Grok 会话页没有思考按钮 | 旧逻辑只认少量写死 ID，刷新 Anthropic 模型还会直接报不支持 | 按模型 ID 关键字识别；对不上关键字也显示通用档位。Anthropic 走 `GET /v1/models`。见 `docs/fix-log.md` #222 |
| 会话 Markdown 图片/脚注/定义列表/公式露原文 | 自研渲染器原先只覆盖标题/列表/表格/代码/引用/强调 | 缺口元素在 `markdown_text.dart` 自研补齐，拾忆与 DSH 共用 `MessageBubble`。见 `docs/fix-log.md` #230 |
| 粗体嵌斜体、转义、自动链接、参考式链接、HTML 片段仍露原文 | 2.5.7 只补了图片/脚注/定义列表等，嵌套强调与参考式链接还没拆 | 继续自研补齐。见 `docs/fix-log.md` #239 |
| 主页会话拖动卡住 / 远放瞬移 / 换位后第一下炸 / 搜索栏被挡 | 旧 `LongPressDraggable` 拆树；`SizeTransition` 裁剪命中；ListView `Clip.none` 盖住搜索 | `HomeLongPressDrag` + 自建 overlay；展开内部 unclipped；外层 SafeArea/列表 ClipRect。见 `docs/fix-log.md` #240-#259 |
| OpenRouter 在拾忆可用、DSH 返回 400 | pi-ai 给 OpenRouter 发 `store: false`，且 `openai/gpt-4o` 被 `gpt` 当成思考模型误发 `reasoning` | 注入 `compat.supportsStore: false`；gpt-4o/4.1/3.5 不声明思考。见 `docs/fix-log.md` #223 |
| Responses 纯文本正常、发图 Cloudflare 502 | Chat `image_url` 对象被原样塞进 Responses `input` | 转成 `input_image` + 字符串 URL。见 `docs/fix-log.md` #275 |
| 缓存命中爆炸、每轮都像冷启动 | 时间/记忆/摘要写进冻头 system，前缀对不齐 | 冻头/动尾分层；滚动摘要改历史归档。见 `docs/fix-log.md` #274 |
| DSH 0.1.1 启动即崩，修复完整运行环境没用 | `.credentials.yaml` 顶层仍是 `SHIYI_API_KEY:`，解析器只认 `version`/`refs`/`records` | 启动同步写成 `version: 1` + `refs:`，并把顶层密钥收进去。见 `docs/fix-log.md` #224 |

---

## 7. 改动后验证清单

```powershell
flutter analyze                      # 必须 0 issues
flutter test                         # 必须全绿
flutter build windows --release      # 必须成功
```

启动验证（真实窗口）：

1. 窗口无黑边、标题栏左侧红黄绿三键、悬停显示图标；鼠标移到任一红绿灯时顶栏不得变灰
2. 黄=最小化、绿=最大化/还原（图标随状态切换）、红=关闭
3. 标题栏拖拽移动窗口、双击最大化/还原
4. 窗口边缘 6px 缩放、Win+方向键贴靠、Alt+Tab 正常
5. 启动日志（`文档\\agent\\logs\\error.log`）`TermuxProbe backend=...` 正常（wsl2 / gitbash / pwsh / cmd）
6. 默认工作目录是本机「文档\\agent」（不是 `%TEMP%\\agent`，也不是安卓存储根）
7. 数据库自动创建：`%APPDATA%\com.shiyi\拾忆 ShiYi\shiyi_agent.db`
8. 设置 → 通用 → 终端能看到自动 / WSL2 / Git Bash / PowerShell 7 / cmd
9. 对话人设与 `run_terminal` 描述不出现 Alpine / apk / `/storage/emulated/0/agent`
10. 终端双指捏合缩放字号、命令补全幽灵字、命令行 token 分色仍可用（与 Android 同一套 `TerminalPane`）
11. 拾忆主页长按项目 / 会话卡片可拖拽排序；会话拖到另一项目须停满 1 秒；松手飞入空隙，换位后点一下不炸；上滑时搜索栏和状态栏不被卡片盖住

DS Harness 引擎验证点（#114，两端共享）：

1. 设置 → Agent 引擎切到 DS Harness：侧栏/底部 tab 变为 工作区/功能/文件/终端
2. 工作区页：红绿灯=添加工作区（选手机文件夹/目录）、分组点击展开/收回、
   左滑三键（新建会话/重命名/删除）；默认工作区删除按钮隐藏，删除
   方法仍保护性拦截；会话左滑（重命名/归档/复制 ID）。拾忆主页项目
   分组展开收起写入 `shiyi_project_expanded_v1`，会话左滑含复制 ID；
   无工作区时
   自动链接默认 agent 目录（Android `/storage/emulated/0/agent`、
   Windows `文档\\agent`）、新建空会话返回后自动归档
3. 功能页：只显示入口（技能/模型/预设/工作区/文件），不预加载不报错；
   技能入口二级页 = DSH skill.list（DSH 0.1.0-rc.6 起必带 sessionId 且会话
   需已挂载；先用 session.create(sessionId+cwd) 挂载会话再短重试，不再回退
   无参数查询）；模型数据页重新进入后从当前拾忆模型设置恢复已选模型
4. 会话页：子代理状态条显示在输入框缓存统计栏上方；技能候选胶囊
   显示在统计栏上方，可单独移除
5. 文件页：默认浏览 agent 目录；路径栏上箭头/选目录/新建文件夹；
   条目操作（复制路径/系统打开）
6. 设置入口 = DS Harness 中心；中心顶部 Agent 引擎可切回拾忆，
   切换后返回落点为对应引擎设置页
7. dsh 服务启动后 `host.describe` cwd = agent 目录（文件/工作区默认位置）

---

## 8. 变更记录

- **2026-08-27 2.5.10**（共享 `lib/`；详见 `docs/fix-log.md` #274-#282）：
  拾忆直连第三条协议 Responses；冻头/动尾稳缓存；Responses 发图转 `input_image`。
  小米小窗 MediaQuery 钳制。LAAP 皮层本机部署，活人感按 Hermes 官方 preamble 注入动尾，
  开关在引擎页，不要写「本机皮层已接通」。Windows 用本机 Python 启 11546，不写 Alpine 路径。
- **2026-08-27**（共享 `lib/`；详见 `docs/fix-log.md` #274/#275）：
  拾忆直连第三条协议 OpenAI Responses（冻头 `instructions` / `input` / `store: false`）。
  Chat Completions 与 Claude 按冻头/动尾拆开，稳住前缀缓存。Responses 发图必须转
  `input_image` 字符串，禁止把 Chat `image_url` 对象原样塞进去。状态栏加本轮命中/未缓存。
  Windows 无新增平台分支。
- **2026-08-26**（共享 `lib/`；详见 `docs/fix-log.md` #267-#273）：
  跨项目/工作区可插到任意位置；滚动后重测插入格；测槽位用不含 Transform 的布局盒。
  DSH 跨工作区飞入后先乐观更新 `sessionIds` 和 cwd，再静默 `_load()`，避免源组 BCD 被撑开弹回。
  `keepCollapsed` 只收被拖的那张，不能把同组其它卡片收成 0。Windows 拾忆主页共用源槽口径。
- **2026-08-26**（共享 `lib/`；详见 `docs/fix-log.md` #243-#259）：
  #243 会话长按无拖影已由 #245 重建关闭（`HomeLongPressDrag` + 自建 overlay，不再用 `LongPressDraggable`）。
  后续补齐跨项目状态、抓取点、收起动画、挤开高度、源空槽、飞入曲线和搜索栏层级。
  真机 `af3700b1` 正式包 `adb install -r` Success，未卸载未清数据。
- **2026-08-26 2.5.9**（共享 `lib/` 改动；Windows 无新增平台分支；详见 `docs/fix-log.md` #241）：
  左滑 / 交错展开 / 分组头 / 飞行层抽成共享组件。DSH 工作区会话长按拖拽按 `sessionIds` 排序，
  `dshReorderPlanForInsertion` 生成 `insertSessionBefore`。Windows 拾忆主页同一套拖拽。
- **2026-08-25**（共享 `lib/` 改动；Windows 无新增平台分支；详见 `docs/fix-log.md` #238/#239/#240）：
  1. 终端双指捏合缩放字号（1~28）、中文回退、命令前缀补全与幽灵字、命令行 token 分色；
  2. Markdown 再补嵌套强调 / 转义 / 自动与参考式链接 / HTML 片段 / 表格对齐 / 有序列表重排；
  3. 拾忆主页长按拖拽项目与会话排序，会话可拖到另一项目（停满 1 秒）；松手飞入空隙，提交贴齐。
  共享验证：`flutter test test/terminal_pane_test.dart test/markdown_text_test.dart test/home_list_order_test.dart test/home_sessions_tab_test.dart`。
- **2026-08-24 2.5.8**（详见 `docs/fix-log.md` #235/#236）：
  Windows 默认工作目录改为本机「文档\\agent」（旧 `%TEMP%\\agent` 视为未设置）。
  终端走 WSL2 / Git Bash / PowerShell / cmd，不走 Android Alpine。人设 / 工具规则 /
  `run_terminal` 描述按平台隔离。Win11 红绿灯悬停灰条用原生子窗口 `SHIYI_TITLEBAR`
  盖住；桌面图标换成 Android `ic_launcher`。拾忆跨会话查阅：`search_sessions` /
  `read_session`，复制 ID 发到另一拾忆会话可看见（仅拾忆本地库，不是 DSH）。
- **2026-08-24**：鼠标移到顶栏不再变灰。拖拽区不再回报 `HTCAPTION`（Win11 会叠系统标题栏悬停层），改为客户区按下后拖、双击最大化。
- **2026-08-24 2.5.7**（共享 lib/，详见 `docs/fix-log.md` #230–#234）：
  Markdown 缺口自研补齐（图片/脚注/定义列表等，拾忆与 DSH 共用）；思考过程不再升成正文；
  主页项目展开记忆 + 会话左滑复制 ID；设置上下文改为新建会话默认且会话可单独改；
  MiMo 模糊 400 去掉 `reasoning_effort` 重试。Windows 设置页与聊天输入区同步生效。
- **2026-08-24**（共享 lib/ 改动，详见 `docs/fix-log.md` #234）：MiMo 模糊 400 去掉
  `reasoning_effort` 重试；思考开关开着不等于日志 `thinking=on`。
- **2026-08-24**（共享 lib/ 改动，详见 `docs/fix-log.md` #233）：设置「上下文」改为新建会话默认，
  不再把 ≥50 万 token 写回 128k；拾忆 / DSH 会话页可单独改本会话上限。Windows 设置页与
  聊天输入区同步生效。
- **2026-08-17**（共享 lib/ 改动，详见 `docs/fix-log.md` #193/#194/#195；Windows 未改功能）：
  技能页/会话页先 `session.create(sessionId+cwd)` 挂载会话再调 `skill.list`（DSH
  0.1.0-rc.6 必带 sessionId，不再回退空 payload）；模型数据页重新进入后从当前
  拾忆模型设置恢复选择；工作区默认目录删除按钮隐藏、会话左滑新增「复制 ID」、
  卡片留白与垂直对齐调整；子代理状态条移到输入框缓存统计栏上方。共享文件均
  已用平台分支隔离，Windows 侧行为未变。验证：`flutter analyze` 0 issues；
  `flutter test` 354 项全绿；debug APK 真机覆盖安装 Success。
- **2026-08-14**：Windows 桌面版落地（运行时适配 + UI 桌面化 + macOS 操作逻辑化）。
  详见 `docs/windows-build.md` 与 git 历史。
- **2026-08-14**（共享 lib/ 改动，两端同生效，详见 `docs/fix-log.md` #106–#109）：
  1. 缓存命中率改为**会话累计口径**（对齐 DSH：Σ缓存token ÷ Σ输入token），
     并持久化到 sessions 表（DB v16，`cache_hit_tokens`/`cache_input_tokens`），
     退出会话/重启后仍显示；切换/新建会话清零；
  2. 聊天状态栏精简：去掉会话总 token，上下文只留剩余百分比
     （`本轮 X · 上下文剩 N% · 缓存 Z%`，≤20% 红 / ≤50% 橙告警不变）；
  3. 续写请求补带 `reasoning_content`（thinking 模式网关要求原样回传，否则 HTTP 400）；
  4. 网络错误友好化：连接类错误自动重试一次，仍失败显示中文提示
     （不再抛原始 `ClientException with SocketException` 英文）。
  - 验证：`flutter analyze` 0 issues；`flutter test` 176 用例全绿；
    release 构建 + `adb install -r` 真机覆盖安装通过。
- **2026-08-14**（共享 lib/ 改动，详见 `docs/fix-log.md` #114）：**DS Harness 引擎主页三 tab 套壳**
  （外观=拾忆、数据=DeepSeek Harness）：
  1. 主页 tab 随引擎切换：拾忆（会话/功能/文件）↔ DS Harness（**工作区/功能/文件**）；
     Windows 侧栏标签/图标与 `Ctrl+,`（打开当前引擎设置）同步；
  2. 设置入口跟随引擎：DS Harness → DS Harness 中心（含引擎切换），拾忆 → 拾忆设置；
  3. Agent 引擎页复用拾忆的（`AgentEnginePage` 公开）：切换后不自动返回，
     返回落点跟随引擎（切 dsh 回 DS Harness 中心 / 切拾忆回拾忆设置）；
  4. 工作区 tab = 拾忆会话页外观（分组展开/左滑/搜索/红绿灯添加工作区），
     无「未分类」（自动链接 agent 目录为默认工作区、新会话自动挂入）、空会话自动归档；
  5. 功能 tab = 拾忆功能页外观，只放 DSH 功能入口（技能/模型/预设/工作区/文件），不预加载；
  6. 文件 tab = 拾忆文件页外观（路径栏/新建文件夹/操作菜单），DSH 主机目录数据，
     默认浏览 agent 目录；dsh 服务启动 cwd 改为 agent 目录（Windows 为「文档\\agent」）。
  - 验证：`flutter analyze` 0 issues；`flutter test` 188 用例全绿；
    debug APK `adb install -r` 真机覆盖安装通过；设备实测 `host.describe` cwd=agent 目录。
- **2026-08-14**（共享 lib/ 改动，详见 `docs/fix-log.md` #116）：拾忆文件页增加 Android 专用 SD 根/Root 闸门（`StorageScope` + `RootAccess`）。Windows 不走 Root/SD 限制，文件页仍按本机路径直接浏览；改共享 `files_screen.dart` 时勿把 Android 闸门套到桌面。
- **2026-08-15**（共享 lib/ 改动，详见 `docs/fix-log.md` #133–#135；Windows 未改功能）：
  DSH 聊天页对齐拾忆会话 UI（runtime-context 折叠、模型手动注入、工作区会话带 cwd、
  流式正文 + 思考过程走 DSH mux 下行）。涉及 `dsh_chat_screen.dart` / `message_bubble.dart` /
  `dsh_api.dart` / `dsh_live.dart` / `dsh_model_sync.dart` 等共享文件，Windows 侧无新增平台分支。
  全量验证：`flutter analyze` 0 issues；`flutter test` 251 项全绿。

- **2026-08-15**（共享 lib/ 改动，详见 `docs/fix-log.md` #136–#152；Windows 未改功能）：
  Android DSH 主线：聊天滚动定位 / 底部统计栏 / 提问弹窗 / 模型同步 / 气泡工具栏 /
  工作区持久化与图标 / ENOSYS 写文件 / subagent 页面 / 服务状态自动检测与卸载 /
  预设页重做与完整 DSH 模式（node-pty 重建、移除禁用补丁）。共享文件改动已用平台分支隔离，
  Windows 侧行为未变。全量验证：`flutter analyze` 0 issues；`flutter test` 266 项全绿。
  #152 另补：koffi 改走 Unix Makefiles 源码重建（Android 专用 shim 手段），`flutter analyze` 0 issues、
  `dsh_service_test` 18 项全过、debug APK 真机覆盖安装 Success；Windows 无新增平台分支，行为未变。

- **2026-08-17**（共享 lib/ 改动，详见 `docs/fix-log.md` #205；Windows 无新增平台分支）：
  消息气泡接入真正液态玻璃（Pub 包 `liquid_glass_easy 4.0.0`），用户/助手气泡改为 `LiquidGlassLens`；
  工具运行时恢复保留「思考过程 / 子代理总结」折叠，DSH 消息过滤把 `reasoning`/`subagentSummary`
  视为有效内容；流式正文改为稳定 `_StreamingFadeMarkdown`，不再按正文重建气泡，折叠态不丢。
  - **Windows 维护要点**：含 Lens 的滚动列表（本地 `chat_screen.dart` / DSH `dsh_chat_screen.dart` /
    DSH 子代理 `dsh_subagents_screen.dart`）已用 `ScrollConfiguration` 关闭 stretch overscroll，
    这是包文档针对 Android Impeller 的官方建议；Windows 桌面（Skia）默认走 frosted 毛玻璃回退并打
    一条一次性 debug 提示，不影响功能。Windows 桌面是 Skia/无背景捕获，Liquid Glass 的折射/放大/
    色差能力不可用，仅表现为毛玻璃+描边，属预期回退。
  - 验证：`flutter analyze` 0 issues；`flutter test` 373 项全绿；release APK 真机
    `adb install -r` 覆盖安装 Success、未卸载未清数据。

- **2026-08-17**（共享 lib/ 改动，详见 `docs/fix-log.md` #206；Windows 无新增平台分支）：
  DSH 快照恢复完整保留 reasoning / runtime-context / subagentSummary，历史短响应不会覆盖本地折叠状态；
  消息折叠体、工具胶囊、统计栏、工作路径、提问面板、工具日志和输入条统一接入
  `liquid_glass_easy 4.0.0`。Windows Skia 继续使用包的 frosted 回退，不增加平台分支，
  输入条改为悬浮圆角布局。共享验证：`flutter analyze` 0 issues；`flutter test` 376 项全绿。

- **2026-08-17**（共享 lib/ 改动，详见 `docs/fix-log.md` #207；Windows 无新增平台分支）：
  MessageBubble 将“思考中”和“思考过程”合并为同一折叠面板；空的流式 reasoning 会回退到消息字段，
  reasoning 与子代理总结独立保留。Windows 行为与 Android 共享，无平台分支新增。

- **2026-08-17**（共享 lib/ 改动，详见 `docs/fix-log.md` #208；Windows 无新增平台分支）：
  拾忆与 DSH 提问卡片合并为共享 `AgentQuestionPanel`；拾忆继续走自身 question 状态，DSH 继续走
  `question/requested` / `POST /api/respond`，只统一 UI 与键盘布局。问题正文按可用高度滚动，操作区固定，
  DSH 提问期间隐藏普通输入条，避免键盘挤压溢出。Windows Skia 下液态玻璃继续使用包的 frosted 回退。
  共享验证：`flutter analyze` 0 issues；`flutter test` 380 项全绿；Android debug APK 构建及真机覆盖安装成功。

- **2026-08-17**（共享 lib/ 与内置 DSH 插件改动，详见 `docs/fix-log.md` #209）：
  插件页合并读取 `$DSH_HOME/cordis.patch.yml` 与 `profiles/web/cordis.patch.yml`，只展示带 `name`
  的插件行，home 层同 id 优先；内置 bundles 改为只读组合。`shiyi-free-search` 1.1.0 新增
  `plugin_list` 模型工具，区分宿主持久插件与 `cordis_inspect_self` 的会话临时插件。
  Windows 与 Android 共用相同 home/profile 规则，无新增平台分支；共享验证为 `flutter analyze`
  0 issues、`flutter test` 381 项全绿，Android 真机工具调用返回 `web-search-shiyi-free`。

- **2026-08-17**（共享 lib/ 改动，详见 `docs/fix-log.md` #210；Windows 无新增平台分支）：
  DSH `assistant/message` 只收口当前 LLM 步骤，不再清空整轮 reasoning；工具步骤之间“思考中”
  面板持续保留并流式追加思考过程，直到 `turn/end` 与正式 history 完成收口。history 补种同样
  跨步骤累积 reasoning。共享验证：`flutter analyze` 0 issues；`flutter test` 382 项全绿；
  Android debug APK 构建及真机 `adb install -r` 覆盖安装成功。

- **2026-08-17**（共享 lib/ 改动，详见 `docs/fix-log.md` #211；Windows 无新增平台分支）：
  DSH reasoning 推送对齐拾忆 2.0：思考增量立即更新折叠面板，正文继续节流；当 mux 漏掉
  `reasoning-delta` 时，会话等待期间从已落盘的 `assistant/message.reasoning` 自动补回，
  并在新回合开始时清理旧流式通知器。Windows 继续复用同一套 DSH 会话状态机，无平台差异。

- **2026-08-18**（共享 lib/ 改动，详见 `docs/fix-log.md` #212；Windows 无新增平台分支）：
  模型同步为明显的思考模型（DeepSeek/reasoner/thinking/o1/o3/o4/r1/qwq）写入
  `llm-pi-ai.providers.shiyi.reasoning = high`，并按 DSH 0.1.0-rc.6 schema 为模型写入
  `reasoningEfforts` 字典（`off: null`，其他档位带同名线上值）；普通模型不添加这些字段。
  运行中 mutate 与离线 `settings.yaml` 保持一致；坏配置导致命名空间未注册时会先修文件、
  重启 DSH 再重试。Windows 与 Android 共用同一配置生成和自恢复逻辑。

- **2026-08-18**（共享 lib/ 改动，详见 `docs/fix-log.md` #213；Windows 无新增平台分支）：
  DSH 子代理报告按消息 ID 去重，避免 `agent/inbox/spliced` 与后续 `user/message` 双路径
  重复显示；已消费的报告不会再带出重复助手确认回合。并发 history 旧快照也不能重新打开
  已收口的 live 气泡。Windows 与 Android 共用同一解析与实时状态机。

- **2026-08-18**（共享 lib/ 改动，详见 `docs/fix-log.md` #214；Windows 无新增平台分支）：
  拾忆工具回合固化 reasoning、API 历史回传 `reasoning_content`、思考-only 消息不过滤；
  子代理报告落到左侧助手气泡折叠展示。其中默认发送 `reasoning_effort` 已由 #218 撤销。
- **2026-08-18**（共享 lib/ 改动，详见 `docs/fix-log.md` #215–#216；Windows 无新增平台分支）：
  拾忆恢复多会话并行生成：每会话独立停止/引导/流式正文与思考/工具事件/提问/统计。
  `isBusy` 只表示至少一个会话在跑，不能拦截其他会话发送。
- **2026-08-18**（共享 lib/ 改动，详见 `docs/fix-log.md` #218；Windows 无新增平台分支）：
  拾忆直连思考口径回到 8/15 备份：请求不发送 `thinking` / `reasoning_effort`，正文走
  `content`，思考只走 `reasoning_content` 等专用字段。#217 整段作废。DSH 思考档位仍只
  由 `DshModelSync` 写入，两端共用同一套直连客户端，改 `llm_client.dart` 时不要再把
  DSH 的 thinking 开关搬进拾忆请求。
  （#219 修订：#218 口径在当前网关下失效，改回“思考模型带思考参数 + 降级重试 +
  think 标签兜底”，见下条。）

- **2026-08-18**（共享 lib/ 改动，详见 `docs/fix-log.md` #219；Windows 无新增平台分支）：
  拾忆思考过程恢复显示：明显思考模型默认发送 `thinking: {type: enabled}` 与
  `reasoning_effort: high`（网关拒绝时分别去掉重试，普通模型不带）；正文带明确
  `<thinking>` 标签时兜底拆进思考折叠面板（不做启发式）。DSH 侧不变。

- **2026-08-19**（共享 `lib/` 改动；Windows 无新增平台分支；详见 `docs/fix-log.md` #220）：
  修复拾忆流式思考内容先泄漏到正文、完成后才收进折叠面板的问题。流式归一化不再把
  reasoning-only 增量提升为正文；`_applyTurn` 仅在整轮最终确认无正文时执行兼容兜底，
  始终保持 `streamText` / `streamReasoning` 分离。新增 6 个流式 reasoning 回归用例。
  共享验证：`flutter analyze` 0 issues；`flutter test` 414 项全绿；`flutter build apk --debug`
  成功；真机 `9LKZL7TGZTJFZ575` 使用 `adb install -r` 覆盖安装 Success，未卸载、未清数据。

- **2026-08-20**（共享 `lib/` 改动；Windows 无新增平台分支；详见 `docs/fix-log.md` 会话页与 DSH 同步条目）：
  拾忆与 DSH 会话页统一为悬空液态玻璃输入区、消息入场动画、流式跟随；输入区增加思考开关、思考强度与手动压缩。
  DSH 多配置注入、安装进度按真实步骤推进、安装完成后自动切到 DSH 引擎。启动 DSH 期间发送消息或切换模型
  不再损坏 `settings.yaml`：文件同步改为进程内串行队列 + 原子 rename；已损坏 YAML 启动时备份为
  `settings.yaml.corrupt` 后重建。Windows 继续复用同一套 `DshModelSync`，无平台分支。
  共享验证：`flutter analyze` 0 issues；`flutter test test/dsh_model_sync_test.dart` 42 项全绿。

- **2026-08-20**（共享 `lib/` 改动；Windows 无新增平台分支；详见 `docs/fix-log.md` #222）：
  思考档位改为按模型 ID 关键字识别，拾忆与 DSH 共用 `ReasoningModels`。Anthropic Messages
  「刷新模型」走 `GET /v1/models` 分页；Claude 原生思考发 `budget_tokens`；GPT 关闭发 `none`。
  对不上关键字的模型也显示通用思考按钮，默认不自动发 thinking。Windows 继续复用同一套
  `LlmClient` / `DshModelSync`，无平台分支。

- **2026-08-22**（共享 `lib/` 改动；Windows 无新增平台分支；详见 `docs/fix-log.md` #223/#224/#225）：
  1. OpenRouter 注入关闭 `store`，`gpt-4o`/`gpt-4.1`/`gpt-3.5` 不再当思考模型；
  2. `.credentials.yaml` 改为 DSH 0.1.1 的 `version: 1` + `refs:`，启动同步迁移旧扁平/混写文档；
  3. 安装 DSH 去掉 `--prefer-offline`，避免过期 packument 漏掉已发布 rc。
  Windows 继续复用同一套 `DshModelSync` / `DshService`，无平台分支。
  共享验证：`flutter analyze` 0 issues；相关单测全绿。

- **2026-08-23**（共享 `lib/` 改动；Windows 无新增平台分支）：
  1. SOCKS5 自定义通道：设置 → 通用 → SOCKS5 代理。`auto` 扫本机 Clash / V2Ray / SS 常见端口；`custom` 可保存多台服务器。对话、拉模型、联网搜索走 `Socks5Proxy`。DSH npm HTTP 自动代理仍用 `NetworkProxyDetector`，不要混用。
  2. 可选活人感（默认关）：`PresenceEngine` 本地内心状态循环，不改工具管线。
  3. 去掉会话页阈值弹出的压缩胶囊，只留输入区常驻压缩按钮。
  Windows 本机 Clash 默认 7890/7891 可被自动检测；桌面版与 Android 共用同一套设置页与客户端。

- **2026-08-24**（共享 `lib/` 改动；Windows 无新增平台分支）：
  主页底部第四栏「终端」。Android 走 `EmbeddedShell` → `init-host -c` 进同一套 Alpine；Windows 仍走设置里的终端后端（WSL2 / pwsh / cmd）。两端共用 `TerminalSession.shared`，切引擎不中断。点画面输入、无独立输入框；输入浅蓝、正常输出灰绿、警告黄、错误红。独立 `/` 才弹技能。
  共享验证：`flutter test test/home_tabs_test.dart test/terminal_pane_test.dart test/slash_trigger_test.dart` 全绿。
