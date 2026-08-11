# 拾忆 ShiYi · 开发修复记录

> 本文件记录项目从开发到发布的 **bug / 问题 / 修复** 全过程，供后续排查参考。
> 每条格式：日期 · 现象 · 根因 · 修复 · 涉及文件。

---

## 2026-08-04 · 项目初始化与首版发布

### 1. 品牌与包名统一
- **现象**：包名沿用 `com.hermes.hermes_agent_app`（模仿 Hermes 制作）。
- **修复**：改名 `com.shiyi.agent`，应用名「拾忆 ShiYi」。
- **涉及**：`android/app/build.gradle.kts`、AndroidManifest、代码内引用。

### 2. 图标与头像统一
- **现象**：App 图标与会话头像使用不同图片。
- **修复**：全部统一为欢迎页图片（`assets/welcome.png` 及派生资源）。

### 3. 存储权限横幅误报
- **现象**：已申请「所有文件访问权限」仍显示"终端访问手机存储被拒绝"提示。
- **修复**：移除存储权限横幅误报逻辑。

### 4. 重试成功后状态提示残留
- **现象**：对话中断自动重试成功后「正在自动重试…」提示不消失。
- **修复**：重试成功（completed）后统一清除状态提示。

### 5. 开源前敏感信息清理
- **现象**：旧提交历史含签名密码（4 处）、keystore 配置；本地 stash 也残留。
- **修复**：`git filter-branch` 重写历史清除密码；删除含旧密码的 stash；`.gitignore` 加固（`**/*.db` 覆盖所有子目录）。
- **涉及**：git 历史、`.gitignore`。

### 6. file_picker 补丁仓库外依赖
- **现象**：`pubspec.yaml` 的 `dependency_overrides` 指向仓库外 `../file_picker_patch`，clone 后 `flutter pub get` 必然失败，项目对第三方不可构建。
- **修复**：patch 包迁入 `third_party/file_picker_patch/`，`analysis_options.yaml` 排除 `third_party/**`。
- **涉及**：`pubspec.yaml`、`analysis_options.yaml`、`third_party/`。

### 7. 检查更新 403
- **现象**：手机上访问 `api.github.com` 被区域网络拦截返回 403，检查更新报"服务器返回异常（403）"。
- **修复**：GitHub API 403/失败时自动回退 jsDelivr 镜像（`data.jsdelivr.com`）获取版本；版本相同提示"已是最新"。
- **涉及**：`lib/screens/about_screen.dart`。

### 8. 检查更新改为直接下载安装
- **现象**：检查更新只能复制链接去网站下载，国内网络访问 GitHub 慢。
- **修复**：弹窗加「下载更新」按钮：GitHub 直链优先 → 超时/慢切国内镜像（gh-proxy.com / ghfast.top）→ 进度条 → 调起系统安装器（FileProvider + `REQUEST_INSTALL_PACKAGES`）。
- **涉及**：`about_screen.dart`、`AndroidManifest.xml`、`MainActivity.kt`、`res/xml/file_paths.xml`。

### 9. 内置终端在国产 ROM 无法启动（SELinux）
- **现象**：坚果 DT2002C（Android 11）上终端报 `Permission denied (errno 13)`，dmesg 显示 `avc: denied { execute_no_trans }`——国产 ROM 的 `untrusted_app` 域无 `app_data_file` 执行权限。
- **修复**：`targetSdk 34 → 27`，进程落入 `untrusted_app_27` 兼容域（自带 `execute_no_trans`，Termux 同款方案）；lint 禁用 `ExpiredTargetSdkVersion`；终端错误自动附带诊断信息（系统/SELinux/权限）。
- **涉及**：`android/app/build.gradle.kts`、`lib/core/app_state.dart`。

---

## 2026-08-08 · 体验与稳定性修复

### 10. "思考中"指示过早消失
- **现象**：会话进行中"正在思考…"在流式文本出现后消失，用户要求持续到回合完成。
- **修复**：气泡在 `streaming` 期间常驻"正在思考…"（有文本时显示在文本上方），`streaming=false`（回合完成）才消失。
- **涉及**：`lib/widgets/message_bubble.dart`。

### 11. run_terminal 超时后进程不杀（转圈挂死）
- **现象**：`Process.run().timeout(300s)` 的 `Future.timeout` 只放弃等待、**不杀子进程**——命令卡住时工具进程永远挂着，右上角转圈不停、僵尸进程堆积。
- **修复**：改用 `Process.start` + 监听流 + `exitCode.timeout(120s)`，超时 `proc.kill()` 强杀；文案从"30 秒"修正为实际值。
- **涉及**：`lib/core/app_state.dart`。

### 12. 退出重进会话显示"终端还在运行中"
- **现象**：工具事件被中断（停止/异常）时 `finished_at` 未写入 DB，`done=false` 永久残留，重进会话加载后永远转圈。
- **修复**：`selectSession` 加载后兜底收尾残留未完成事件（会话不在生成中时标记"已中断"并写回 DB）。
- **涉及**：`lib/core/app_state.dart`。

### 13. 输出反复截断 / "停在冒号"
- **现象**：AI 输出停在"："（如"好的，我创建脚本："）后静默结束、无工具调用；reasoning 完整、content 被截。已确认**网关和模型正常**（实测 fr=tool_calls 完整透传），根因是 **mimo-v2.5 输出 token 上限**（`fr=length`）与处理策略不足。
- **修复（分四步）**：
  1. 解析 `finish_reason`，`length` 时抛中断触发整轮重试；
  2. 请求显式 `max_tokens: 4096`（后因 mimo 实测支持提升到 **8192**）；
  3. 启发式检测（reasoning 非空 + 正文停半截标点 + 无工具 → 判定截断），覆盖网关不发 finish_reason 的情况；
  4. 重试时 system prompt 注入「直接行动」指令（不输出开场白、第一步就调工具）；
  5. **自动续写**：纯文本截断时追加「继续完成」请求拼接（不重发整轮、不丢已输出）；工具完整时不续写、工具半截才整轮重试。
- **涉及**：`lib/services/llm_client.dart`、`lib/core/app_state.dart`。

### 14. 工具胶囊读秒与步骤计数
- **现象**：右上角胶囊只显示工具名，看不到运行时长与进度。
- **修复**：`_ToolPill` 转 StatefulWidget 每秒刷新读秒；进行中显示「工具名 3/5」步骤计数。
- **涉及**：`lib/screens/chat_screen.dart`。

### 15. 操作信息流面板闪烁 / 默认打开
- **现象**：面板随工具间隙自动收起/弹出（闪烁）；后改为自动打开又导致重进会话默认展开。
- **修复**：**面板完全手动控制**（默认收起，点胶囊展开/收起），去掉全部自动打开逻辑。
- **涉及**：`lib/screens/chat_screen.dart`。

### 16. 思考过程与"正在思考…"重复显示
- **现象**：有 reasoning 的模型同时显示"思考过程"折叠头和"正在思考…"spinner。
- **修复**：整合为单一指示——有思考内容用「思考过程 ▾」（内含 spinner，点击展开推理全文）；无思考内容保留"正在思考…"。
- **涉及**：`lib/widgets/message_bubble.dart`。

### 17. 模型思考内容（reasoning）不可见
- **现象**：DeepSeek/mimo 等思考模型的 `reasoning_content` 被丢弃，用户看不到思考过程。
- **修复**：全链路支持——`LlmClient` 解析 `delta['reasoning_content']` → `TurnResult.reasoning` → 流式 `streamReasoning` 实时展示 + `ChatMessage.reasoning` 落库（DB v10 迁移），历史重进可见，气泡默认收起可展开。
- **涉及**：`llm_client.dart`、`models.dart`、`db.dart`、`app_state.dart`、`message_bubble.dart`。

### 18. 终端默认工作目录
- **现象**：目录无效（不存在/被删）时 `Process.start` 直接抛异常，终端报错。
- **修复**：默认目录 = 会话自定义工作目录 → Agent 目录（`/storage/emulated/0/agent`）；目录不存在自动创建，创建失败回退 Agent 默认目录。
- **涉及**：`lib/core/app_state.dart`。

### 19. 内置默认系统提示词升级
- **现象**：默认人设过于简短，未体现"先行动/简洁输出/长内容写文件"等实战规则。
- **修复**：升级为完整版（工作台定位 + 6 条工作原则：先行动、简洁输出、工具优先、信息求真、记忆复用、诚实边界）。
- **涉及**：`lib/core/app_state.dart`（设置页可自定义覆盖）。

### 20. question 工具未弹窗、模型自行决定保存
- **现象**：模型问用户"是否保存到文件"时没有弹出选择框，自己决定直接保存了。
- **根因（两层）**：
  1. 模型把问句写进回复文本、直接调 `file_write` 自己保存——**没有生成 question 的 tool_calls**，所以 `_QuestionHandler` 弹窗从未触发（`_execQuestion` 是阻塞式 `await completer.future`，真调用必弹窗；没弹 = 没调用）；
  2. 系统提示词自相矛盾：「先行动」+「长内容直接 file_write 存文件」教它别问，`question` 描述又要求确认——中小模型（DeepSeek/MiMo）倾向服从更强的"先行动"。
- **修复（提示词层三处 + 工具描述一处）**：
  1. 工作原则 1「先行动」加限定：涉及「是否保存/写入」「选哪个方案」等需用户拍板的决策，必须先调用 question 等待回答，不得替用户决定；
  2. 【工具使用规则】新增强制规则：需要确认/选择的决策必须调用 question 并等待；禁止在回复文本里提问后不等待、自己替用户决定；
  3. 「长内容先用 file_write」补例外：用户明确要求先确认的除外，此时先 question 再写入；
  4. `question` 工具 description 强化：任何需拍板操作都必须用本工具并等待回答，禁止文本提问后自行继续。
- **遗留**：提示词修复对中小模型非 100% 保险；若再遇"文本提问没弹窗"，兜底方案是检测回复以问句结尾且无 tool_calls 时提示用户确认（未实现）。
- **涉及**：`lib/core/app_state.dart`。

### 21. flutter install 签名不一致触发卸载重装、清空 app 数据
- **现象**：`flutter install --debug` 日志出现 `Uninstalling old version...`，旧版本被卸载重装，`/data/data/com.shiyi.agent` 下 `shiyi_agent.db`、SharedPreferences 全部重建——API Key/会话/记忆被清空（违反"覆盖安装不清数据"部署偏好）。**2026-08-08 连续两次踩坑。**
- **根因（查 flutter_tools 源码确认）**：`flutter install` 内部先跑 `adb install -t -r`（`android_device.dart` 的 `_installApp`）；**只要这次安装失败，就自动"Uninstalling old version" → 卸载 → 重装**（`installApp` 兜底分支）。失败的具体原因被 flutter 吞掉（只打印到 stderr trace）。实测**手动 `adb install -r` 同一 APK 成功**——说明同签名下手动覆盖可靠，flutter 的失败原因未知（疑与设备/时序相关），但它卸载清数据的代价不可接受。
- **修复/预防（已写入 AGENTS.md 部署偏好）**：
  1. **首选手动 `adb install -r build\app\outputs\flutter-apk\app-debug.apk`**（同 debug keystore 下实测数据保留）；
  2. 用 `flutter install` 时必须检查输出**无 `Uninstalling old version...`**，有则数据已清；
  3. 装前验签：`adb shell dumpsys package com.shiyi.agent | grep signatures`；
  4. debug 包可备份：`adb exec-out run-as com.shiyi.agent cat app_flutter/shiyi_agent.db` 等。
- **涉及**：部署流程（非代码）。

### 22. question 弹窗只有预设选项、无法自定义回答
- **现象**：模型调用 question 提问时，弹窗只有模型给的选项按钮，用户想输入自己的回答没有入口；且 mimo 模型会声称"本工具只有 2~4 个预设选项，不支持自由文本输入"（来自工具描述里的误导文案"选项 2~4 个"）。
- **修复（两步）**：
  1. **弹窗重构为内嵌自由文本输入框**：主弹窗 = 问题文本 + `TextField`（多行、自动聚焦、回车提交）+ 快捷选项按钮 + 确定按钮；用户可直接打字提交，也可一键选选项，空输入按"用户取消了选择"处理。删除了此前"自定义回答按钮+二次弹窗"的绕路方案（`_QuestionResult` 区分 option/custom 两种结果）。
  2. **更新 `question` 工具描述**：明确"弹窗支持自由文本输入，用户可直接打字回答；选项为 0~4 个可选快捷项"，消除"只能从选项里选"的误导；`options` 参数 description 同步改为"可选快捷选项（0~4 个）"。
- **涉及**：`lib/core/app_state.dart`（`question` 工具 description）、`lib/screens/chat_screen.dart`（`_QuestionHandler`）。

### 23. 点 question 弹窗选项全屏红屏（Flutter issue #180569 变体）
- **现象**：点击弹窗里任意快捷选项后全屏暗红（`#880000`）ErrorWidget，红屏上输入法键盘还开着；logcat 无 E/flutter（错误发生在非标准错误路径，未进 logcat）。
- **根因**：**Flutter 框架 bug 的变体**（官方 issue #180569，found in 3.38/3.40，2026-05-29 修复）：弹窗关闭动画中若还有活跃子组件（聚焦的 TextField + 开着的输入法），`LayoutBuilder` 重建会触发 `Element._retakeInactiveElement` → `_InactiveElements.remove` 断言失败（framework.dart:2168 `_elements.contains(element)`）→ ErrorWidget 红屏。我们项目 3.44.2 仍复现（修复不完整或变体路径）。
  - 我们的触发模式：`Navigator.pop` **立即 resolve** `showDialog` 的 future（不等退出动画）→ `_show` 后续代码（`ctrl.dispose()` + `answerQuestion` → `notifyListeners` → 全页重建）都在弹窗退出动画中执行，此时 TextField/键盘仍活跃。
  - 此前的"Impeller 渲染故障"诊断为误判（禁 Impeller 后仍红屏），已撤销 `EnableImpeller=false`。
- **修复（代码规避，chat_screen.dart `_QuestionHandler._show`）**：
  1. 结果在**点击回调里直接提交**，不依赖 `Navigator.pop` 返回值（`answerQuestion` 在 pop 前调用）；
  2. 点击时先 `FocusManager.instance.primaryFocus?.unfocus()` 收起键盘，让 TextField 失焦（消除关闭动画中的活跃子组件）；
  3. `TextEditingController.dispose()` 延迟到退出动画结束后（`Future.delayed 350ms`），避免动画中 TextField 引用已释放 controller。
- **涉及**：`lib/screens/chat_screen.dart`（`_QuestionHandler`）。

### 24. 聊天页卡顿掉帧（主线程回调/弹窗键盘布局抖动）
- **现象**：骁龙 870 设备上聊天页操作和流式输出明显卡顿；坚果 ROM 报 `slow_main_thread`。
- **测量**：优化前 `dumpsys gfxinfo com.shiyi.agent`：Janky frames 58/151（38.41%）、90th 44ms、Slow UI thread 35；GPU 90th 仅 5ms，确认瓶颈在 Flutter/Dart UI 主线程而非 GPU/CPU 性能不足。
- **根因**：
  1. 流式 token 每次变化都会安排 `addPostFrameCallback`，回调又调用带动画的 `_scrollToLatest/animateTo`，高频 token 下滚动回调和动画重复排队；
  2. question 弹窗的 `TextField autofocus=true`，即使用户只点快捷选项也会强制拉起键盘，触发窗口 resize、整页 layout 和 ROM FPS 切换；
  3. `answerQuestion → notifyListeners` 在弹窗退出动画前执行，modal 退场与整个聊天页重建重叠。
- **修复**：
  1. 流式自动滚动增加 `_autoScrollScheduled`，每帧最多安排一次；流式阶段用 `jumpTo(0)` 替代连续 `animateTo`；消息新增和 token 增长分开处理，避免重复排滚动回调；
  2. question 输入框取消 `autofocus`，只点快捷选项时不弹键盘；
  3. 点击时仅记录答案并关闭弹窗，等待 350ms 退出动画结束后再 `answerQuestion/notifyListeners` 和释放 controller。
- **初步结果**：新包冷启动清零统计后 Janky frames 5/50（10%）、90th 22ms、Slow UI thread 4；需继续用实际会话/流式输出验证。
- **涉及**：`lib/screens/chat_screen.dart`。

### 25. 主页搜索框弹出键盘后侧边栏溢出、返回主页目录不可见
- **现象**：主页点搜索框弹出输入法后，再点左上角侧边栏会出现黄黑溢出条纹；点击空白处无法取消搜索框光标；从搜索结果进入会话再返回，已回到主页但正常会话目录不可见，部分情况下侧栏遮罩仍会拦截点击。
- **根因**：
  1. `HomeScreen` 外层 `Scaffold` 默认随键盘 `viewInsets` 缩高，连同悬浮侧边栏一起被压缩；侧边栏是固定内容的 `Column`，剩余高度不足时触发 `RenderFlex overflow`；
  2. 主页搜索框没有独立 `FocusNode` 和空白点击失焦处理，打开侧栏、切 tab、进入会话时仍保留活跃输入连接；
  3. `_SessionsTabState` 在路由返回后继续保留搜索 query，因此仍显示搜索结果分支而非正常会话目录；侧栏入口新建会话后也会保留展开遮罩。
- **修复**：
  1. 外层主页 `Scaffold` 设置 `resizeToAvoidBottomInset: false`，让各 tab 的内层 `Scaffold` 自行避让键盘，悬浮侧边栏始终保持全高；
  2. 搜索框增加 `FocusNode`、`onTapOutside`、`onSubmitted`，点击空白或提交搜索时主动失焦；
  3. 打开/关闭侧栏、切换 tab、进入会话、新建会话、打开关于页及退出聊天页前统一收起键盘；侧栏导航时同步关闭侧栏；
  4. 新建会话前、已有会话路由完整返回后清空搜索状态，避免在路由动画中拆除活跃输入框，并让主页恢复完整会话目录。
- **涉及**：`lib/screens/home_screen.dart`、`lib/screens/chat_screen.dart`。

### 26. 会话返回主页后内容空白，切换 tab 触发 `_dependents.isEmpty` 红屏
- **现象**：从搜索结果进入会话再返回后，主页只剩左上角侧边栏入口，标题、搜索框和会话目录全部不可见；UI 自动化树仍能找到这些控件。此时切换到设置页会显示红色 ErrorWidget：`framework.dart:6268 '_dependents.isEmpty': is not true`。
- **根因**：`await Navigator.push(...)` 使用的是路由 `popped` Future，会在调用 `Navigator.pop` 时先完成，并不等待 `MacPageRoute` 的 240ms 反向动画结束。主页随即执行 `_resetSearch → setState`，同时整页 `AnimatedSwitcher` 正在拆装 tab 子树，导致仍被依赖的 `InheritedElement` 在退场动画中进入 deactivate，绘制层先失效，后续切 tab 时触发 `debugDeactivated` 断言。
- **修复**：
  1. 移除包裹整个主页 tab 的 `AnimatedSwitcher`，tab 直接切换，避免大页面及其 `Scaffold/TextField` 经由 inactive-element 重挂载；
  2. 会话路由返回后等待 350ms（大于 240ms 反向动画）再清空搜索和重建主页，确保路由 Overlay 已完全移除；
  3. 保留进入会话前失焦、返回聊天页前失焦，以及侧栏/键盘布局隔离措施。
- **涉及**：`lib/screens/home_screen.dart`。

### 27. 连续三次进入会话并返回后主页停止绘制
- **现象**：不操作搜索框，直接连续执行“进入会话 → 返回”，第三次稳定出现主页内容空白；控件仍存在于无障碍树，继续切换页面后触发 `framework.dart:6268 '_dependents.isEmpty'` 断言。
- **根因**：应用根节点用 `ListenableBuilder(listenable: shiyi)` 包裹整个 `MaterialApp`。会话选择、token 统计刷新、消息状态变化等任意业务 `notifyListeners()` 都会重建 `MaterialApp`，连同 `Navigator` 和 `Theme/MediaQuery` 等继承依赖一起更新。通知若与聊天路由退场重叠，Flutter 会在仍有依赖者时 deactivate 对应 `InheritedElement`；主页先停止绘制，后续切 tab 拆除旧子树时断言才显现。
- **修复**：根节点改为只监听主题模式的实际变化；普通业务通知不再重建 `MaterialApp`，仍由主页和聊天页内部的局部 `ListenableBuilder` 响应。主题切换保持实时生效，自定义透明路由维持原有返回预览。
- **涉及**：`lib/main.dart`。

### 28. 不思考直接回复时正文被存成思考过程
- **现象**：模型未输出独立思考、直接把最终回复放在 `reasoning_content`（可能同时出现在 `content`）时，回复被当成「思考过程」展示；数据库里部分助手消息 `content` 为空或与 `reasoning` 重复，`reasoning=完整回复`。
- **根因**：流式解析只按 OpenAI 惯例把 `reasoning_content` 当作思考、`content` 当作正文；部分网关/模型在“直接回复”时把正文放进 `reasoning_content`，应用未做兜底。
- **修复**：落库前若一轮结果正文为空、有思考文本且没有工具调用，则把思考文本当作正文、清空思考字段；若思考文本与正文重复，同样清空思考字段。历史消息从数据库读取时做同样归位，已存错的消息也能正常显示。
- **涉及**：`lib/core/models.dart`、`lib/core/app_state.dart`。

---

## 2026-08-09 · 输出与交互体验修复

### 29. 输出截断自动续写（fr=length 拼接，不重发整轮）
- **现象**：mimo 长输出 `finish_reason=length` 截断时，整轮重试会丢已输出内容且可能再次截断。
- **修复**：`LlmClient` 改为**续写循环**——纯文本截断时追加「继续完成」请求拼接（已输出保留，最多续 3 轮）；**工具调用完整**时即使截断也当完成（工具照常执行）；工具参数半截才整轮重试。
- **涉及**：`lib/services/llm_client.dart`。

### 30. 内置提示词：超长内容直接流式输出（去掉"写文件"引导）
- **现象**：此前提示词引导模型"超长内容先写文件再给摘要"，用户不需要本地文件、希望直接输出完。
- **修复**：system prompt 改为「超长内容直接完整流式输出，不要写入本地文件；被截断会自动续写拼接」。
- **涉及**：`lib/core/app_state.dart`。

### 31. question 弹窗输入法弹出后黑黄条（BOTTOM OVERFLOWED）
- **现象**：点弹窗输入框、键盘弹出后，输入框下方出现黄黑条纹 `BOTTOM OVERFLOWED BY 55 PIXELS`（RenderFlex 溢出）。
- **根因**：键盘弹出使弹窗可用高度骤减，`AlertDialog` 的 `content` 是固定 `Column`（不滚动）→ 底部溢出。
- **修复**：`content` 外层包 `SingleChildScrollView`（空间不足时可滚动）。
- **涉及**：`lib/screens/chat_screen.dart`。

### 32. 覆盖安装失败：signatures do not match（debug/release 签名不一致）
- **现象**：`adb install -r` 报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match`，代码改动装不上手机（表面 Success 实际失败）。
- **根因**：手机上的包是**另一个会话用 debug 构建**装的（`pkgFlags=[DEBUGGABLE]`、证书 `CN=Android Debug`），release 签名覆盖失败。
- **修复/教训**：该项目**装手机统一用 debug 构建**（`flutter build apk --debug` + `adb install -r`）；release 包覆盖需先卸载（会清数据）。排查"改动了没生效"先查 `dumpsys package <pkg> | grep lastUpdateTime` 与签名。

### 33. 页面切换卡顿：tab 每次切换全量重建
- **现象**：侧边栏切换 tab 卡顿（操作/页面切换掉帧）。
- **根因**：`home_screen` 的 `_buildTab()` 用 `switch` **每次切换重建整个页面**（会话列表还重新查 DB）。
- **修复**：**tab 懒缓存**——切换过的页面复用不重建（内部 `ListenableBuilder` 监听 `shiyi` 自动刷新数据）；新建/删除会话时清会话 tab 缓存强制重建。
- **涉及**：`lib/screens/home_screen.dart`。

### 34. 路由动画：确认纯淡入淡出
- **现象/过程**：页面切换动画原为 `FadeTransition`（淡入淡出）；曾尝试加轻微缩放增强，用户明确只要淡入淡出 → 移除缩放。
- **涉及**：`lib/core/mac_page_route.dart`。

### 35. 工具胶囊：新建会话右侧空荡 → 静默读秒 0.0s
- **现象**：新建会话时右上角胶囊只有「● 工具」，右侧空出一截。
- **修复**：`_ToolPillIdle` 两端对齐（`spaceBetween`）——左侧灰点+工具，右侧 **0.0s**（读秒初始态）。
- **涉及**：`lib/screens/chat_screen.dart`。

### 36. tab 切换无过渡 + 设置入口点击无响应（卡顿）
- **现象**：① 侧边栏切 tab 直接硬切无淡入淡出；② 点右上角设置第一次"没反应"，再点其他按钮才切换。
- **根因**：
  - `_selectTab` 用 `addPostFrameCallback` 延迟 setState，点击要等下一帧才生效；
  - 首次切到设置页时同步构建 40+ 项 `ListView`，主线程被占满、点击事件被吞；
  - 尝试的 `AnimatedSwitcher`（新旧双页并存）反而加重首帧负担。
- **修复**：`IndexedStack` 常驻全部 6 个 tab（切换零构建、立即响应）+ `FadeTransition` 180ms 淡入 + 启动后逐帧预构建 tab 1-5（`_prebuildTabs`）；`_selectTab` 去掉 postFrame 延迟直接 setState。
- **涉及**：`lib/screens/home_screen.dart`（`c49d501` 尝试方案、`9a96768` 最终方案）。

### 37. 关于页：开源协议与功能特性展示
- **需求**：关于页展示软件介绍、功能特性列表与 GPL-3.0 开源协议说明。
- **修复**：`about_screen.dart` 新增「功能特性」卡片区块（LLM 切换/多轮会话/独立工作目录/附件/内置终端/长期记忆/技能系统/网页搜索/语音朗读等）；底部版权改为 GPL-3.0 开源说明；功能列表与公开 README 对齐。
- **涉及**：`lib/screens/about_screen.dart`、`README.md`。

### 38. 公开仓库清理外部引用（Claude 字样）
- **需求**：公开仓库与 Release 描述中不出现"Claude Code 移植"等外部产品引用。
- **修复**：Release v1.0.2 body 中"参考 Claude Code 工具体系"改为中性表述；`app_state.dart` 注释"与 Claude Code 的"改为"与常见 Agent 记忆索引格式一致"；全库 grep 确认无残留。
- **涉及**：`lib/core/app_state.dart`、GitHub Release v1.0.2。

### 39. v1.0.2 发行版发布与资产替换流程
- **需求**：修复（IndexedStack tab 常驻、设置入口无响应等）后重新构建发行版，替换 GitHub 已上传的 APK。
- **流程**：版本号三处（`pubspec.yaml` 1.0.2+3 / `build.gradle.kts` versionCode=3 versionName=1.0.2 / `about_screen.dart` '1.0.2'）→ analyze + test(19) + `flutter build apk --release` → 提交推送源码 → GitHub API **删除旧资产再上传同名新资产**（DELETE assets/{id} 204 → POST uploads）→ Release body 更新修复描述。
- **注意**：APK ~93MB 上传超 2 分钟工具限制，需后台任务；资产替换必须先 DELETE 再 POST（同名会 422）。

---

## 2026-08-09 · 子代理系统（第二批：Agent 委派）

### 40. spawn_agent 子代理系统（explore/plan/worker/general-purpose）
- **需求**：复杂多步骤任务（写章节/多文件调研）由主循环单线程硬扛易乱；参考常见 Agent 架构引入"派子代理分工"：主脑派专项小兵干活，小兵报告后主脑整合。
- **实现**：
  1. `lib/services/subagent.dart`：`SubagentDefinition`（**数据驱动**：name / whenToUse / allowedTools 白名单 / systemPrompt / maxTurns）+ 4 个内置定义（`explore` 只读搜索、`plan` 只读规划、`worker` 独立执行、`general-purpose` 兜底）+ `SubagentRunner`（独立 LLM 工具循环：构造子代理对话 → 解析 tool_calls → 白名单校验 → 复用主循环 `_executeTool` 执行 → 回填 → 直到无工具）；
  2. `app_state.dart` 注册表新增 `spawn_agent` 工具 + `_execSpawnAgent` + `_toolsJsonFor`（按白名单过滤注册表）。
- **安全设计**：子代理工具白名单（explore/plan 只读；worker/general 排除 spawn_agent/question/save_memory/create_skill）；**子代理不能再派子代理**（防递归）；`maxTurns` 轮数上限（15/15/40/25）防失控；提示词含只读命令白名单与"最终文本=返回值"协议（禁"Done"类确认语）。
- **扩展点**：新增代理类型 = 加一个 `SubagentDefinition` 条目（后台代理/观察者可直接加定义，执行器无需改动）。
- **说明**：注释与描述全部中性表述（无外部产品引用，符合 #38 约定）。
- **涉及**：`lib/services/subagent.dart`（新增）、`lib/core/app_state.dart`。

### 41. 系统提示重写为「工作台」结构 + 子代理体验三连（滚动/进度/自主识别）
- **需求**：用户要求提示词也按主流 agent 架构的结构来（去道德、留实用规则），且子代理要"看得见、自己会判断"。
- **系统提示重写**（`_buildSystemPrompt` base）：新增【运行方式】（你的输出=用户看到的一切、工具被拒=换方式、并行工具调用）、【沟通规范】（先给结论、可读性>简洁、删除前先看目标、如实报告）、【自主与确认】（有信息就行动、拍板才 question、结束前当场完成承诺）、【临时文件】、【安全底线】（不泄漏密钥、不编造工具/子代理结果）；保留原 6 条工作原则。道德段全部剔除；计划模式下"当场完成承诺"除外（review 后补）。
- **思考区自动滚动**（`message_bubble.dart`）：`_reasoningBody` 加 `ScrollController`，`didUpdateWidget` 检测 `liveReasoning` 流式增长自动 `jumpTo(maxScrollExtent)`，展开时也直接滚到最新。
- **子代理进度可见**（`subagent.dart` + `app_state`）：`SubagentRunner` 加 `onProgress(round, maxTurns, tool)` 回调 → `_execSpawnAgent` 更新状态条「子代理「explore」第 3/15 轮 · 正在调用 file_read」。
- **子代理自主识别**（`_buildSystemPrompt` 工具规则段）：when-to-use 判断规则——读多文件/独立调研→explore；复杂规划→plan；可独立执行无需交互→worker；单点查找直接读不派。
- **交付检查**：review 审查结论"无阻塞问题"，仅按建议修计划模式冲突一处。
- **涉及**：`lib/core/app_state.dart`、`lib/services/subagent.dart`、`lib/widgets/message_bubble.dart`。

### 42. 设置「人设/系统提示词」与默认提示词的关系（改提示词前必读）
- **机制**：`_buildSystemPrompt`（`app_state.dart`）由两部分拼接：
  1. **base 段**（`final base = settings.systemPrompt.isNotEmpty ? 用户自定义 : 默认`）——**用户在设置里填了系统提示词时，会整体替换默认 base**（含【运行方式】【沟通规范】【自主与确认】【临时文件】【安全底线】和 6 条工作原则）；
  2. **追加段**（`parts.add`，**始终生效、替换不掉**）：【当前时间】【工具使用规则】（含 question 确认、web 多源验证、**子代理判断规则**、长内容规则）【长期记忆】【技能】【计划模式】。
- **影响**：
  - 子代理**功能**（spawn_agent/白名单/进度）与**自主判断规则**：不受人设影响（在追加段）；
  - 沟通风格/自主原则：仅用户自定义人设时被替换。
- **改默认提示词注意**：默认 base 升级**不会覆盖**用户已填的自定义人设（自定义优先）；若新版默认有重大改动想强制生效，需提示用户清空设置里的自定义内容。
- **涉及**：`lib/core/app_state.dart`（`_buildSystemPrompt`）。

### 43. 抓取防爬失败反复重试（模型不会自动止损）
- **现象**：目标站点防爬导致 `web_extract` 连续 10+ 次 `TimeoutException`（15s），模型每次失败后说"换个方向"却继续抓同类页面，用户发"抓不到就换一个地方找"也无效；浪费大量轮次。
- **根因**：模型拿到的失败信息只有"工具执行异常: TimeoutException after 15s"，无法区分防爬/站点挂/网络问题；且模型（尤其中小模型）不会统计上下文里的失败次数，不会自动止损。
- **修复（两层，工程替模型补判断）**：
  1. **技术层失败计数**（`app_state.dart` `_executeTool`）：`_toolFailStreak` 记录每个工具连续失败次数（成功清零），**连续失败 ≥2 次**时返回 `⚠️ 工具 xx 已连续失败 N 次，立即停止重试同一目标：换 URL/换搜索词/换工具…`，强制打断重试循环；
  2. **防爬诊断**（`web_tools.dart` `extract`）：失败信息分类——超时（提示"可能被防爬拦截，换站或 run_terminal curl"）、403（"站点启用防爬"）、429（"频率受限"）、空内容（"防爬空页"），让模型拿到明确信号做对判断；
  3. **提示词规则**：工具规则段加"同一来源连续失败 2 次立即放弃；工具返回「已连续失败 N 次」提示时必须立刻停止"。
- **涉及**：`lib/core/app_state.dart`、`lib/services/web_tools.dart`。

---

## 遗留已知项（非 bug，勿当问题）

- `ln`（软/硬链接）在 SD 卡（FUSE）上 `Permission denied`：Android 系统限制。
- `chmod`/`chown` 在 SD 卡不生效：FUSE 忽略权限变更。
- 未预装工具（wget/zip/git 等）：用 `pkg install xxx`（走 bin-shim → termux-apt）。
- `apt-key` 直调、`Dpkg.pm` 裁剪、`termux-info` 慢：内嵌环境已知限制。
- mimo-v2.5 输出上限较低：app 已实现**截断自动续写**（fr=length → 追加「继续」请求拼接），长内容直接流式输出完；个别超长场景可能续写多次，可换输出上限更大的模型。

### 44. 子代理自动触发机制强化（按主流 agent 提示词写法）
- **需求**：模型不主动派子代理，用户每次都要手动指挥。
- **借鉴**：主流 agent（CLI 类）的触发设计——① 工具描述第一句就给触发信号（如 explore="广网只读侦查"）；② 系统提示写触发原则（"真正需要上下文密集/长链的任务才派，弱相关不派"）；③ 触发时机偏主动（"非平凡任务动手前先考虑派"）。
- **修复**（`app_state.dart`）：`spawn_agent` description 重写——第一句"需要跨多个文件、长链调研或独立执行的任务：先考虑派子代理"，末尾加边界"简单单点任务不要派"；工具规则段改为「子代理触发原则」——动手前先考虑派（宁可先派 explore 侦查）+ 重型路径边界 + 类型选择规则。
- **涉及**：`lib/core/app_state.dart`。

### 45. v1.1.0 发行版发布（bug/新增/优化）
- **版本**：1.1.0（build 4）——v1.0.2 之后第二批功能（子代理系统）+ 若干修复。
- **🆕 新增**：
  1. `spawn_agent` 子代理系统：explore（只读侦查）/ plan（只读方案）/ worker（独立执行）/ general-purpose（兜底）；工具白名单 + 禁递归 + 轮次上限 + 执行层二次校验（`lib/services/subagent.dart`）；
  2. 系统提示重写：新增【运行方式】【沟通规范】【自主与确认】【临时文件】【安全底线】，保留 6 条工作原则（去道德留实用）；
  3. 子代理进度可见（状态条「第 n/max 轮 · 正在调用 xxx」）+ 思考区流式自动滚动；
  4. 子代理自主触发机制（工具描述首句触发信号 + 触发原则 + 边界）。
- **🐛 修复**：
  1. 设置入口点击无响应（IndexedStack 常驻 tab + 立即切换）；
  2. 侧边栏 tab 切换卡顿（淡入淡出过渡）；
  3. 抓取防爬失败反复重试（`_toolFailStreak` 失败计数 + web_extract 防爬诊断 403/429/超时 + 止损提示词）。
- **⚙️ 优化**：
  1. 子代理交付检查修复（白名单纵深防御 / 只读终端写操作拦截 / token 计入统计 / tool_call_id 唯一化 / 输出截断）；
  2. 代码注释中性化（公开仓库合规，fix-log #38）；
  3. 人设提示词替换机制文档化（#42）。
- **涉及**：版本号三处（pubspec 1.1.0+4 / gradle versionCode=4 versionName=1.1.0 / about '1.1.0'）+ README 功能清单与下载链接更新。

---

## 2026-08-10 · 输出上限通用化与空正文截断修复

### 46. 思考型模型输出上限通用化 + 空正文截断修复
- **现象**：DeepSeek / MiMo / OpenCode Go 等思考型模型做长任务时，思考内容打满 `max_tokens`（`fr=length`），正文还没开始；续写轮又可能被网关断开（`done=false`），用户看到「回复中断，正在自动重试」。
- **根因**：请求写死 `max_tokens: 8192`，对思考型模型偏小；`fr=length` 且正文为空时仍走「空正文续写」，没有可接断点，续写容易继续思考或被网关断开。
- **修复**：
  1. `AppSettings` 新增 `maxOutputTokens`，设置页「上下文」区新增「输出上限」（默认 8192，范围 512~384000），主循环与子代理统一读取；
  2. 内置预设新增 OpenCode Go（`deepseek-v4-flash`），建议输出上限 32768；
  3. `LlmClient` 不再写死 8192；网关拒绝过大的 `max_tokens` 时自动降级 8192 重试；
  4. `fr=length` 且正文为空时改为整轮重试，并注入「不要长篇思考，直接输出结果/调用工具」；
  5. `StreamDiag` 增加 `model` / `max_tokens` 字段；首包超时 30s → 60s。
- **涉及**：`models.dart`、`model_presets.dart`、`llm_client.dart`、`subagent.dart`、`app_state.dart`、`settings_screen.dart`、版本号三处（1.1.2+6）。

### 47. 长会话上下文窗口：发送前按预算裁剪历史
- **现象**：长会话（数千条消息）继续发消息时，请求把全部历史发送，超过 `contextLimit`，继续会话第一条消息就上下文爆满/网关拒绝。
- **根因**：`_historyToApi` 全量发送历史，没有按 `contextLimit` 裁剪；用户关闭自动压缩后没有任何兜底。
- **修复**：发送前 `_trimApiMessages` 按 `contextLimit × 0.9 − system − 工具定义` 的预算从最新往回保留历史，超预算时保留尾部并在 system 提示里说明；上下文估算的工具开销从固定 1500 改为真实 `activeTools` JSON；新增 `trimApiMessagesForBudget` 单元测试。
- **涉及**：`app_state.dart`、`test/context_budget_test.dart`、版本号三处（1.1.3+7）。

---

## 2026-08-11 · 性能与缓存优化

### 48. 缓存命中优化：当前时间移到 system 尾部
- **现象**：用量监控缓存命中率约 80%，跨分钟请求会掉一段缓存。
- **根因**：`_buildSystemPrompt` 把「当前时间」以分钟精度插入 system 中段；跨分钟后，后面大段工具规则/工作目录/记忆/技能全部字节偏移，前缀缓存从时间处断开。
- **修复**：时间块移到 `parts` 最末尾，base、工具规则、工作目录、记忆、技能保持稳定，跨分钟只改尾部一小截。不改变时间精度，不降低模型对时效性的感知。
- **涉及**：`lib/core/app_state.dart`。

### 49. 首轮性能优化（不砍动画与渲染）
- **现象**：长文流式输出、全局状态变化时掉帧卡顿。
- **根因与修复**：
  1. **Markdown 重复解析 + 流式逐 token 重建**：`splitMarkdownBlocks` 每次 build 都重新 split，流式每 chunk 全量重解析。改为单条目解析缓存（同一文本只解析一次），并在 `_streamRound` 对 `streamText/streamReasoning` 做 80ms / 200 字符节流，视觉连续但主线程压力下降。
  2. **HomeScreen 外层监听整个 `ShiyiState`**：任意 notify 都重建整页结构。新增 `loadedNotifier` / `initErrorNotifier`，外层只监听初始化状态，内容交给各 tab 自己的监听器。
  3. **聊天列表随 status/token 等任意 notify 重建**：新增 `messagesRevision`，消息列表只监听消息版本；`messages` 所有变更点统一 `_bumpMessages()`，状态条、token 统计、工具事件变化不再重建整列。
- **涉及**：`lib/widgets/markdown_text.dart`、`lib/core/app_state.dart`、`lib/screens/home_screen.dart`、`lib/screens/chat_screen.dart`。
- **验证**：`flutter analyze` 无告警；`flutter test` 29 项全部通过。
- **提醒**：debug 包本身为 JIT 模式，体感明显慢于 release；流畅度验收建议用 release 构建覆盖安装。

### 50. memories 表建表漏 type 列（新装/异常库保存记忆失败隐患）
- **现象**：外部诊断报告称真机 `memories` 表缺 `type` 列、`user_version` 未设置，保存记忆报 `table memories has no column named type`。
- **排查**：备份真机库后用 SQLite 实测：`PRAGMA user_version = 11`，`memories` 已有 `type TEXT NOT NULL DEFAULT 'user'`，带 `type` 插入正常；`shiyi_agent.db-journal` 为 512 字节全零残留，SQLite 打开时会自行忽略，并非热 journal。
- **根因**：`_createBaseTables` 建 `memories` 表时漏写 `type` 列。旧库走 v10→v11 升级分支会补列，但**新装库**由 onCreate 直接建表后 `user_version` 即 11，不会再走升级分支，必然缺列——属于代码版本与 schema 不一致的隐患，真机当前库未复现。
- **修复**：`onCreate` 建表补 `type TEXT NOT NULL DEFAULT 'user'`；新增 `_repairSchema` 在 `onOpen` 兜底检查，缺列时自动 `ALTER TABLE memories ADD COLUMN type TEXT NOT NULL DEFAULT 'user'`，覆盖已生成的异常库。
- **涉及**：`lib/services/db.dart`、`CHANGELOG.md`。
- **验证**：`flutter analyze` 无告警；`flutter test` 全部通过；备份库插入 `type=project` 测试成功。

### 51. 聊天代码块多出空代码框（fence 闭合被拆成独立块）
- **现象**：同一回复显示「一个正常代码块 + 一个带复制按钮的空代码块」；数据库原文只有一个完整围栏，` ``` ` 总数仅 2。
- **根因**：`splitMarkdownBlocks` 处理闭合 ` ``` ` 时先 `_flushBuf` 提交「开始围栏 + 正文」，再把闭合围栏单独写入新块，产生 `"```\n"` 空块；该块 trim 后为 ` ``` ` 非空，`MarkdownText` 过滤不掉，仍渲染成正文为空的 `_CodeBlock`。
- **修复**：闭合围栏时把开始围栏、正文、结束围栏作为一个完整块提交；空围栏（如 ` ```text\n``` `）不再生成代码块；`_flushBuf` 同时过滤纯空白段；未闭合围栏有内容时保留部分块、无内容时不生成空框。
- **涉及**：`lib/widgets/markdown_text.dart`、`test/markdown_text_test.dart`。
- **验证**：`flutter analyze` 无告警；`flutter test` 36 项全部通过（新增单个代码块不产生空块 / 空代码块不渲染 / 连续两个代码块 / 未闭合围栏等回归用例）。

### 52. 会话上下文统计口径不统一（漏算 tool_calls / 字符 token 混用 / 兜底估算偏差）
- **现象**：会话统计显示「上下文」偏低、剩余百分比虚高，工具多 / agent 会话尤其明显；「会话/本轮」与「上下文」数字单位感觉对不上。
- **根因**：
  1. 上下文估算只算消息正文，漏掉 assistant 的 `tool_calls`；发送时 `toApiMap` 会带上，实际请求比显示大很多（真机样本：「查看忆秦app」正文约 4.1 万 token、含 `tool_calls` 约 21 万 token）。
  2. 字段 / 函数名义是「字符」、弹窗写「万字符」，实际存的是 token 估算，单位混乱。
  3. 网关不返回 usage 时兜底用 `chars / 2`，与 `_estimateTokens`（中文约 1 token/字）不一致，中文会话少算约一半。
  4. 子代理 token 只加「会话」不加「本轮」；并行子代理逐个读库写库有丢更新风险；会话切走时全局统计可能写串。
- **修复**：统一为 token 口径（`sessionContextTokens` / `sessionContextTokenEstimate`）；估算计入 `tool_calls`；新增 `estimateApiMessageTokens` 纯函数供兜底与测试；无 usage 兜底改用统一估算；子代理并行累计后一次性落库并入「本轮」；主循环 / 子代理只在仍查看该会话时更新全局显示；弹窗单位改为「w token」。
- **涉及**：`lib/core/app_state.dart`、`lib/screens/chat_screen.dart`、`lib/screens/settings_screen.dart`、`test/context_budget_test.dart`。
- **验证**：`flutter analyze` 无告警；`flutter test` 39 项全部通过（新增 `estimateApiMessageTokens` 3 项回归用例）。

### 53. 上下文裁剪提示与状态生命周期分离（裁剪是一次性事件，不是持续告警）
- **现象**：长会话发送时出现「上下文接近上限，已自动裁剪较早历史后发送」横幅，但状态栏同时显示 `上下文 2.0w / 12.8w（剩 84%）`，两者矛盾。
- **根因**：裁剪逻辑把「本次发生了裁剪」直接写进通用 `status` 横幅，文案表示仍接近上限；且状态栏在回合结束后用全量历史重算，会从裁剪后的 2.0w 跳回百万级。
- **修复**：
  1. 裁剪改为一次性 `trimNotice`：4 秒自动消失，新会话/切换会话/新一轮发送/重新生成时清除；文案改为 `历史较长，已从约 13.6w 裁剪至 2.0w token 后发送`。
  2. 状态栏只显示裁剪后的实际值：发送时立即更新，回合结束后按同一预算口径重算，不再回跳全量。
  3. 新增 `sessionContextTokensFull` 供压缩判断使用，避免裁剪后永不触发压缩；手动压缩弹窗仍显示全量估算。
- **涉及**：`lib/core/app_state.dart`、`lib/screens/chat_screen.dart`。
- **验证**：`flutter analyze` 无告警；`flutter test` 39 项全部通过。

### 54. 上下文管理：保留最近 3 个完整工具回合，60/75/85 三级压缩
- **现象**：新一轮请求无条件删除历史 `tool` 消息与 assistant `tool_calls`，模型很快忘记之前读取的文件、终端输出和报错信息。
- **根因**：`_historyToApi` 对 `role == 'tool'` 一律 `continue`，并把 assistant 的 `tool_calls` 剥离；纯工具轮的 tool_calls 只存在于内存，重开会话后无法恢复。
- **修复**：
  1. 完整工具回合按 `assistant tool_calls + 对应 tool_call_id` 成组保留；达到窗口 60% 后只保留最近 3 个完整工具回合，更早的旧工具轮压缩成结构化摘要（命令/路径/关键结果/错误/结论）。
  2. 达到 75% 生成滚动任务摘要（目标、涉及文件、重要决定、验证结果、未完成事项）并写进 system，85% 后仍由预算裁剪兜底；摘要不会因裁剪丢失。
  3. 纯工具轮也把 assistant tool_calls 落库，会话切换/重开仍能按完整回合恢复。
  4. `trimApiMessagesForBudget` 按工具回合成组裁剪，不拆散配对；`sessionContextTokenEstimate` 计入 tool 结果，保证 60/75/85 阈值按真实上下文触发。
- **涉及**：`lib/core/app_state.dart`、`test/context_budget_test.dart`。
- **验证**：`flutter analyze` 无告警；`flutter test` 41 项全部通过（新增工具轮成组保留/整组裁掉回归用例）。

### 55. 缓存命中率显示：真实 usage 按 Token 加权
- **现象**：没有缓存命中率信息，无法判断上下文复用效果。
- **修复**：
  1. `LlmClient` 解析 `usage.prompt_tokens` 与缓存字段（兼容 `prompt_tokens_details.cached_tokens` / `cached_tokens` / `cache_read_input_tokens`）。
  2. 状态栏单行末尾追加 `· 缓存 75%`；服务端明确返回 0 显示 `缓存 0%`，没有缓存字段显示 `缓存 --`。
  3. 同一轮多次工具循环请求按 Token 加权累计（cached ÷ prompt），每次发送新用户消息时清零，不做百分比平均，也不按本地上下文推算。
- **涉及**：`lib/services/llm_client.dart`、`lib/core/app_state.dart`、`lib/screens/chat_screen.dart`。
- **验证**：`flutter analyze` 无告警；`flutter test` 41 项全部通过。

### 56. 128K 上下文提前裁剪：预算统一改为 Token，禁止字符数与 Token 混比
- **现象**：128K 配置下实际上下文约 3.3 万时触发强制裁剪，裁剪后约 2.4 万（3.2 万≈128000/4，2.4 万≈3.2万×75%）；自动压缩已关闭仍发生。
- **排查**：全仓搜索未发现字面 `contextLimit / 4`；但旧预算公式固定 `contextLimit × 0.9 − system − tools − 500`，既没有按真实 `maxOutputTokens` 预留输出，也没有单独的安全余量，且存在把 `content.length` 与 Token 预算混算的历史风险。
- **修复**：
  1. 新增唯一请求级 Token 估算入口 `estimateRequestTokens`：system、工具定义、历史、当前输入、图片全部统一口径；图片按每张 1000 Token 计入。
  2. 新增 `planContextBudget`：`usableInputTokens = contextLimit − maxOutputTokens − contextLimit × 2%`；只有 `estimatedInputTokens > usableInputTokens` 才硬裁剪。
  3. 裁剪循环使用 `estimateApiMessageTokens` 逐条计 Token，不再用 `content.length` 与 Token 预算直接比较；工具轮继续整组保留/整组裁掉。
  4. UI 当前上下文、发送前阈值、裁剪后 Token 全部调用同一个估算函数。
  5. `_trimApiMessages` 在发送时写 `TrimBudget` 日志，字段包含 contextLimit/system/toolDefinition/history/currentInput/image/outputReserve/safetyReserve/totalEstimated/trimTrigger/trimTarget，全部标注 `token` 单位。
  6. 裁剪目标预算同步扣除 system 与工具定义，保证裁剪后的 `estimatedInputTokens`（含工具定义）不超过 `usableInputTokens`，而不是只把消息裁到窗口大小。
  7. 版本提升为 `1.1.5+9`（pubspec / gradle / about / README）。
- **涉及**：`lib/core/app_state.dart`、`test/context_budget_test.dart`、`pubspec.yaml`、`android/app/build.gradle.kts`、`lib/screens/about_screen.dart`、`README.md`、`CHANGELOG.md`。
- **验证**：`flutter analyze` 无告警；`flutter test` 50 项全部通过（新增 128K/33K 不裁剪、100K 不裁剪、未超预算不裁剪、超预算裁剪到合法预算、工具定义占用预算、请求级 Token 估算、多轮工具与图片回归用例）。
- **真机验证**：`af3700b1` 用 `adb install -r` 覆盖安装 `1.1.5+9`，数据库原样保留；实测 `TrimBudget`：`contextLimit=128000 token, systemTokens=2095, toolDefinitionTokens=2538, historyTokens=17388, currentInputTokens=2, imageTokens=2000, outputReserve=8192, safetyReserve=2560, totalEstimatedTokens=24023, trimTriggerTokens=117248, trimTargetTokens=117248, shouldTrim=false`。

---

## 2026-08-11 · 上下文统计 Codex 口径与压缩非破坏化

### 57. 上下文统计改为 Codex 口径（真实 usage 基线）
- **现象**：本地全量估算与会话显示仍有偏差，长会话压缩/裁剪后状态栏可能回跳；缓存与上下文数字希望以服务端真实 usage 为准。
- **修复**：
  1. `LlmClient.applyUsage` 兼容 Chat Completions 与 Responses API 的 usage 字段，并支持 `cached_tokens` 等缓存别名。
  2. sessions 表升到 v12，新增 `last_usage_total_tokens`；`Session` 增加 `lastUsageTotalTokens`。
  3. 新增 `activeContextTokenEstimate` / `computeActiveContextTokens`：以最近一次真实 `total_tokens` 为基线，加上最后一次模型生成之后新增消息的本地估算；无真实 usage 时回退全量估算。
  4. 状态栏、压缩判断、发送前阈值统一走同一统计入口；删除 / 重新生成 / 压缩历史时清空旧 usage。
- **涉及**：`lib/services/llm_client.dart`、`lib/services/db.dart`、`lib/core/models.dart`、`lib/core/app_state.dart`、`test/token_usage_test.dart`、版本号（1.1.6+10）。
- **验证**：`flutter analyze` 无告警；`flutter test` 72 项全部通过；`af3700b1` 覆盖安装 `1.1.6+10`。

### 58. 上下文压缩非破坏化：归档不删历史，压缩后统计立即下降
- **现象**：手动/自动压缩会把早期 60% 消息直接删除，tool 消息整段丢失；压缩完成后输入框上方的上下文数字不变，用户以为压缩没生效。
- **根因**：
  1. `compressSession` 用 `deleteMessagesByIds` 真删旧消息，摘要输入还跳过全部 `tool` 消息，工具记忆随压缩一起丢。
  2. 压缩后清空真实 usage，但回退的全量估算仍把已归档消息算进去，状态栏数字不降。
- **修复**：
  1. messages 表升到 v13 新增 `archived` 列；压缩只把旧消息标记归档，完整原文保留在本地。
  2. `_historyToApi`、`sessionContextTokenEstimate`、`computeActiveContextTokens`、滚动任务摘要统一跳过 `archived` 消息；压缩后状态栏立即按“未归档消息 + 滚动摘要”重新估算。
  3. 摘要输入不再跳过工具轮：完整工具回合压缩成结构化一行（命令 / 路径 / 结果 / 错误 / 结论），不完整工具轮保留调用摘要。
  4. 压缩边界改为 Token 预算：新增纯函数 `compressionKeepStart`，至少归档早期 60%，预算紧张时按 Token 归档更多；工具轮按 `tool_calls + tool 结果` 成组归档，不拆散配对。
  5. 滚动摘要持久化到 `sessions.rolling_summary`，后续每轮注入系统提示，不再插入假的“【历史会话摘要】”用户消息。
  6. 手动压缩弹窗文案改为“归档早期历史，完整历史保留在本地”；聊天列表顶部新增“已归档 N 条 · 不占用当前上下文”分隔提示。
- **涉及**：`lib/services/db.dart`、`lib/core/models.dart`、`lib/core/app_state.dart`、`lib/screens/chat_screen.dart`、`test/context_budget_test.dart`、`test/token_usage_test.dart`、`CHANGELOG.md`、`README.md`、版本号三处（1.1.7+11）。
- **验证**：`flutter analyze` 无告警；`flutter test` 77 项全部通过（新增归档统计跳过、压缩边界 Token 预算、工具轮成组不拆散、归档标记落库往返回归用例）。

### 59. 更新弹窗 Release 说明无 Markdown 渲染
- **现象**：更新弹窗里 GitHub Release 的 `## v1.1.7`、列表、代码块等全部以纯文本显示，和会话里的 Markdown 款式不一致。
- **根因**：`UpdateService.showUpdateAvailable` 用 `Text` 直接输出 `notes`，没有走项目统一的 Markdown 渲染组件。
- **修复**：弹窗正文改用 `AdaptiveMarkdownText`，与聊天会话同一款式渲染标题 / 列表 / 代码块 / 表格 / 链接；更新说明区域仍保持限高可滚动。
- **涉及**：`lib/services/update_service.dart`、`test/update_service_test.dart`、`CHANGELOG.md`、`README.md`；版本号保持 `1.1.7+11`，直接替换 GitHub `v1.1.7` Release APK。
- **验证**：`flutter analyze` 无告警；`flutter test` 78 项全部通过（新增更新弹窗 Markdown 渲染回归用例）。
