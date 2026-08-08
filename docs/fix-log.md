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

---

## 遗留已知项（非 bug，勿当问题）

- `ln`（软/硬链接）在 SD 卡（FUSE）上 `Permission denied`：Android 系统限制。
- `chmod`/`chown` 在 SD 卡不生效：FUSE 忽略权限变更。
- 未预装工具（wget/zip/git 等）：用 `pkg install xxx`（走 bin-shim → termux-apt）。
- `apt-key` 直调、`Dpkg.pm` 裁剪、`termux-info` 慢：内嵌环境已知限制。
- mimo-v2.5 输出上限较低：长内容走"写文件+摘要"，或换输出上限更大的模型。
