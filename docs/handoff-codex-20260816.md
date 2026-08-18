# 交接文档：拾忆 App（com.shiyi.agent）DSH 引擎安装卡死排查

> 生成时间：2026-08-16。本文件供 codex 接手继续排查，所有信息自包含。

## 一、项目与设备

- **代码库**：`D:\sourcecode\hermes_agent_app`（Flutter app，包名 `com.shiyi.agent`，Android 端 + Windows 桌面端共享 lib/）
- **当前测试设备**：`9LKZL7TGZTJFZ575`（Android 15/16 类，**KernelSU root 可用**，adb 直连 `adb -s 9LKZL7TGZTJFZ575`）
- **app uid**：`u0_a225` = 10225（卸载重装后从 u0_a223 变为 u0_a225）
- **targetSdk**：36（2026-08-16 刚从 27 升级，见 fix-log #166）
- **内嵌终端架构**：Android 宿主 + proot + Alpine 3.24.1 minirootfs（`assets/termux/alpine-minirootfs-3.24.1-aarch64.tar.gz`）
- **目标**：在设备上完整安装并运行 DeepSeek Harness（`@deepseek-ai/dsh@0.1.0-rc.6`，npm 全局安装到 Alpine rootfs）

## 二、核心架构（务必先读）

- 命令执行链：`init-host -c <cmd>`（`files/termux/local/bin/init-host`，宿主侧脚本）→ `exec linker64 proot -0 --sysvipc -r $rootfs /bin/sh -c <cmd>`
- rootfs：`files/termux/local/alpine`（宿主路径）；proot 内 `/usr` 对应宿主 `$rootfs/usr`
- 关键路径：
  - `files/termux/local/bin/init-host`（宿主启动器）
  - `files/termux/local/bin/init`（rootfs 内初始化脚本：装基础包 bash/gcompat/glib/nano/curl/ca-certificates/coreutils）
  - `files/termux/local/alpine/etc/shiyi-ready`（就绪标记）
  - `files/termux/local/alpine/usr/local/lib/node_modules/@deepseek-ai/dsh`（dsh 包，npm prefix=/usr/local）
  - `files/termux/local/alpine/usr/local/bin/dsh`（bin 链接 → ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js）
  - `files/termux/tmp/shiyi-init.lock`（init 互斥锁，mkdir 原子）
  - npm 缓存：`files/termux/home/.npm/_cacache`（**367M，dsh 依赖已缓存，重装大量 cache hit**）
  - Node headers 缓存：`files/termux/home/.cache/node-gyp/24.18.1/`（已就绪）
- 日志：
  - `files/termux/home/.npm/_logs/`（npm debug 日志，按时间戳命名）
  - `/sdcard/agent/logs/init-debug.log`（init 脚本日志）
  - `/sdcard/agent/logs/error.log`（app 侧 `_appendServiceLog`）

## 三、已完成的修复（fix-log.md #153-#174，不要再重复排查）

1. **SELinux（Android 15/16 关键）**：标准 `untrusted_app` 域缺两条权限，KernelSU 环境 app 启动自动补（`TermuxRuntime._ensureApkLinkPolicy`，运行时 `ksud sepolicy patch` + 持久化 `/data/adb/ksu/sepolicy.rule`）：
   - `app_data_file file link`（apk 3 硬链接安装必需，否则全源 Permission denied）
   - `app_data_file file execute_no_trans`（exec app 数据内 ELF 必需，否则 init-host EXEC_FAILED）
   - 无 root 设备内嵌终端不可用（平台限制）
2. **apk 源顺序**：清华固定第一（用户指定，实测 apk 带 UA 可用），其余国内镜像按测速排序，官方 dl-cdn 兜底；wget 探测带 `-U apk-tools/3.0.6`（否则清华 403 被跳过）
3. **npm 提速**：`--fetch-timeout=60000 --fetch-retries=3 --maxsockets=32 --prefer-offline`；镜像链 npmmirror → 腾讯云 → official → official-direct
4. **安装互斥**：`installOrUpdate` 加 `_installInFlight` 锁（防两个 npm 并发 → arborist `Tracker "idealTree" already exists`）
5. **全新环境**：`installOrUpdate` 先 `npm uninstall -g @deepseek-ai/dsh`（失败忽略）
6. **`--ignore-scripts` 必须保留**：去掉后 `@google/genai` 等 preinstall 在 proot 跑 MODULE_NOT_FOUND 导致 npm install 整体失败（npm 日志 4785-4792 行铁证）
7. **node-pty 重建**：`npm rebuild node-pty` 在 proot 下不执行 install 脚本（exit 0 秒完但 build/ 不生成）→ 改为直接 `node-gyp rebuild --verbose`
   - **⚠️ 关键坑**：`_startCommand` 的 workingDirectory 是宿主 cwd，init-host 的 `SHIYI_CWD=${PWD:-/}` 取不到（Dart Process.start 不设 PWD）→ proot 内 cd / → `gyp ERR! cwd /`。修复：命令内显式 `cd "$1"`，$1 传 **proot 内路径**（`/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/node-pty`，由 usrDir 前缀映射）
8. **probe 脚本化**：`_androidNodePtyProbe` 不用 `node -e` 内联（`_shellQuote` 引号破坏 → 静默失败），改写字幕文件 `.pty-probe.cjs` 到 dsh 目录再执行
9. **init ready 条件**：`apk info -e bash && touch ready` 在 proot 偶发失败 → 改 `[ -x /bin/bash ] && touch /etc/shiyi-ready`
10. **init 锁残留清理**：`-mmin +3` → `+15`（init 一轮最长 5×90s ≈ 8 分钟，3 分钟误删导致并发 init 踩踏）
11. **init-host 禁用 proot seccomp**：`PROOT_NO_SECCOMP=1`（Android 上 seccomp 误判 libfetch connect EACCES——**此结论已被推翻**，真因是 SELinux link，但保留无害）
12. **安装流程**：`installOrUpdate` 先 `_ensureNode()` → `_ensureAndroidBuildToolchain()`（gcc/python3/cmake/ninja）→ npm install → `_androidPostInstall()`（sharp-wasm + node-pty rebuild + hardlink 补丁）

## 四、当前卡点（交给 codex 解决的核心问题）

**现象**：app 每次启动后，init 反复重跑、bash 装不上、ready 不生成、dsh 包目录反复消失，形成死循环；node-pty 编译成功（pty.node 存在且 probe 通过）但 app 仍报"完整模式需要重建 node-pty"。

**最新现场证据（13:32-13:33 CST 手动验证）**：
- 手动删锁 + 手动跑 init → bash 装上（`OK: 421.3 MiB in 94 packages`）、ready 写入（root 属主，已 `chown 10225:10225` 修正）
- pty.node 存在（app uid，13:26 编译），手动 probe 通过：`PTY_LOAD_OK` + `OUT: pty-ok` + RC=0
- **但 app 重启后**：bash 消失、ready 消失、dsh 目录消失——rootfs 被重建或 dsh 被卸载
- 进程现场：`18189 sh`（init-host 检查）→ `18190 sh init`（跑 init），`18282 linker64` → `18287 apk`、`18318 apk` —— **两个 apk 并发**（init 的 apk + app 其他流程的 apk）

**核心怀疑（按优先级）**：
1. **app 启动并发**：`app_state.dart` 的 `_ensureTermux()`（570 行 `unawaited`）→ `TermuxRuntime.ensureInstalled()` 跑 init（apk 装基础包）；若用户同时点「立即安装」→ `installOrUpdate` → `_ensureNode`/`_ensureAndroidBuildToolchain`（apk 命令）→ **与 init 的 apk 并发抢锁**（EAGAIN/EINTR）→ init 的 bash 装不上 → ready 不写 → 每次启动重来
2. **dsh 目录消失**：`installOrUpdate` 的预卸载 `npm uninstall -g` 会删 dsh；若安装中途失败/被中断，npm 回滚或 app 重试触发卸载 → dsh 反复消失
3. **rootfs 反复重建**：`isInstalled()` 检查 `rootfs/bin/sh` + `.env_version`；若 app 启动时检测异常 → `install()` 重建 rootfs（删 + 重新解压）→ 一切重来
4. **ready 标记被删**：app 的某些流程（`ensureScripts`？`install()`？）可能删除 ready；或 init 的 ready 条件仍不稳

**建议排查方向**：
- 在 `ensureInstalled()` / `install()` / `installOrUpdate` 入口加日志（当前 error.log 只有 `_appendServiceLog` 摘要，缺 install 触发原因）
- 确认 app 启动时 `isInstalled()` 返回 false 的**具体原因**（哪个文件缺失）
- 确认 dsh 目录消失的**具体时机**（npm uninstall？rootfs 重建？）
- init 与 `_ensureNode`/`_ensureAndroidBuildToolchain` 的 apk 并发：**init 未就绪时 installOrUpdate 应等待或串行**（当前 apk 锁等待 60s 但 init 一轮 8 分钟）
- 验证 `_ensureTermux` 的 `ensureRunning()` 是否在 dsh 未安装时误触发安装

## 五、设备当前状态（交接时点）

- app 进程 18096 运行中，init 18190 + apk 18318/18287 并发执行中
- rootfs 13:32:48 mtime（手动 init 时间），bin/sh 存在，init-host/proot 存在，.env_version=alpine-v7
- bash/ready/dsh 当前缺失（app 重启后重跑中）
- npm 缓存 367M + Node headers 缓存就绪

## 六、关键代码位置

- `lib/services/termux_runtime.dart`：`_initScript`（init 脚本）、`_initHostScript`、`apkSourcesScript`、`ensureInstalled()`、`install()`、`_ensureApkLinkPolicy()`
- `lib/services/dsh_service.dart`：`installOrUpdate()`、`_installDshPackage()`、`_prepareAndroidFullRuntime()`、`_rebuildAndroidNodePty()`、`_androidNodePtyProbe()`、`_ensureAndroidBuildToolchain()`、`_ensureNode()`
- `lib/core/app_state.dart`：`_ensureTermux()`（570 行启动链）
- `docs/fix-log.md`：#153-#174 完整排查记录
- `AGENTS.md`：项目纪律（覆盖安装、勿 root 建文件、SELinux 说明）
