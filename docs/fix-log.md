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

---

## 遗留已知项（非 bug，勿当问题）

- `ln`（软/硬链接）在 SD 卡（FUSE）上 `Permission denied`：Android 系统限制。
- `chmod`/`chown` 在 SD 卡不生效：FUSE 忽略权限变更。
- 未预装工具（wget/zip/git 等）：用 `pkg install xxx`（走 bin-shim → termux-apt）。
- `apt-key` 直调、`Dpkg.pm` 裁剪、`termux-info` 慢：内嵌环境已知限制。
- mimo-v2.5 输出上限较低：app 已实现**截断自动续写**（fr=length → 追加「继续」请求拼接），长内容直接流式输出完；个别超长场景可能续写多次，可换输出上限更大的模型。
