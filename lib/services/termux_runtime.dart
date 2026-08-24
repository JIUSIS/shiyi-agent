import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'file_workspace.dart';
import 'storage_scope.dart';

/// 运行环境抽象：
/// - Android：内嵌 Alpine Linux 运行时（参照 OmniBot/ReTerminal 方案）——
///   assets 里的 Alpine minirootfs 解压到应用私有目录，proot 以 Android
///   系统 linker 加载，命令全部在 proot 内的 Alpine rootfs 中执行；
///   apk 包管理（bash / nodejs / 编译工具链），不再依赖 Termux 生态。
/// - Windows 桌面：WSL2 / Git Bash / PowerShell 7 / cmd，不走 Android proot。
class TermuxRuntime {
  static const MethodChannel _channel = MethodChannel('shiyi/skillpack');

  /// 资产路径（assets/termux/ 下，全部随 APK 内置，离线可用）。
  static const String _alpineAsset =
      'assets/termux/alpine-minirootfs-3.24.1-aarch64.tar.gz';
  static const String _prootAsset = 'assets/termux/proot';
  static const String _tallocAsset = 'assets/termux/libtalloc.so.2';
  static const String _shmemAsset = 'assets/termux/libandroid-shmem.so';
  static const String _loaderAsset = 'assets/termux/loader';
  static const String _loader32Asset = 'assets/termux/loader32';
  /// apk-tools 2.x 静态版（Alpine 3.20 官方包 apk-tools-static 提取）。
  /// rootfs 自带 apk-tools 3 写数据库用 hardlink 原子发布，无 root 设备
  /// SELinux 禁 app_data_file link，apk add 装完文件但写 db 报
  /// "failed to write database: Permission denied"；2.x 用 rename 写 db，
  /// 放 /usr/local/bin/apk（PATH 优先于 /sbin）即可整体替换。
  static const String _apk2Asset = 'assets/termux/apk.static';

  /// 环境版本号：rootfs 内容/结构变更时递增，写进 .env_version 强制重新部署。
  /// alpine-v7：干净重建——Alpine 3.24.1 + apk-tools 3（最新），设备旧数据
  /// 基线）。曾升级 3.24.1（apk 3）但实测 apk 3 在 proot 下有兼容性问题
  ///（libfetch 连接 EACCES、数据库锁 EINTR），故回退，保留换源/缓存/重试/
  /// 单源/DNS 等全部改进。
  static const String _envVersion = 'alpine-v7';

  static bool get isWindows => Platform.isWindows;

  /// Windows shell 探测结果缓存：'pwsh' 或 'cmd'（null = 尚未探测）。
  static String? _windowsShell;

  /// Git Bash 路径缓存：空串 = 已探测且没有；null = 尚未探测。
  static String? _gitBashPath;

  /// WSL 探测结果缓存：'wsl2' / 'wsl1' / 'none'（null = 尚未探测）。
  static Future<String>? _wslProbe;

  /// WSL 探测：运行 `uname -r` 判定内核。
  /// - WSL2 内核名含 `microsoft-standard-WSL2`
  /// - WSL1 内核名含 `Microsoft`（大写 M）
  /// - 未安装 WSL / 无默认发行版：命令失败 → none
  /// WSL_UTF8=1 强制 wsl.exe 以 UTF-8 输出（默认管道模式是 UTF-16LE）。
  static Future<String> wslVariant() => _wslProbe ??= _probeWsl();

  static Future<String> _probeWsl() async {
    try {
      final probe = await Process.run(
        'wsl.exe',
        ['-e', 'bash', '-lc', 'uname -r'],
        environment: const {'WSL_UTF8': '1'},
      ).timeout(const Duration(seconds: 20));
      if (probe.exitCode != 0) return 'none';
      final kernel = '${probe.stdout} ${probe.stderr}';
      if (kernel.contains('WSL2') || kernel.contains('microsoft-standard')) {
        return 'wsl2';
      }
      if (kernel.toLowerCase().contains('microsoft')) return 'wsl1';
      return 'none';
    } catch (_) {
      return 'none';
    }
  }

  /// 纯函数：按用户设置与探测结果解析实际后端（便于单测）。
  /// [setting]：auto / pwsh / cmd / wsl2 / gitbash；
  /// [wsl]：wsl2 / wsl1 / none；
  /// [shell]：已探测的 Windows shell（pwsh / cmd）。
  /// [gitBash]：本机是否装了 Git Bash。
  /// 返回：wsl2 / gitbash / pwsh / cmd。
  /// auto：WSL2 → Git Bash → PowerShell → cmd。不走 Android proot。
  static String resolveBackendChoice(
    String setting,
    String wsl,
    String shell, {
    bool gitBash = false,
  }) {
    if (setting == 'pwsh' || setting == 'cmd') return setting;
    if (setting == 'gitbash') return gitBash ? 'gitbash' : shell;
    if (wsl == 'wsl2') return 'wsl2';
    if (gitBash) return 'gitbash';
    return shell;
  }

  /// Windows 上解析实际生效的终端后端（wsl2 / gitbash / pwsh / cmd）。
  static Future<String> resolveWindowsBackend(String setting) async {
    if (!isWindows) {
      throw UnsupportedError('resolveWindowsBackend 仅支持 Windows 平台');
    }
    return resolveBackendChoice(
      setting,
      await wslVariant(),
      await windowsShell(),
      gitBash: await isGitBashAvailable(),
    );
  }

  /// 本机 Git for Windows 的 bash.exe；没有则 null。
  static Future<String?> gitBashPath() async {
    if (!isWindows) return null;
    final cached = _gitBashPath;
    if (cached != null) return cached.isEmpty ? null : cached;
    final found = _probeGitBashPath();
    _gitBashPath = found ?? '';
    return found;
  }

  static String? _probeGitBashPath() {
    final extra = <String>[];
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) {
      extra.add('$local\\Programs\\Git\\bin\\bash.exe');
    }
    final pf = Platform.environment['ProgramFiles'];
    if (pf != null && pf.isNotEmpty) {
      extra.add('$pf\\Git\\bin\\bash.exe');
    }
    final pf86 = Platform.environment['ProgramFiles(x86)'];
    if (pf86 != null && pf86.isNotEmpty) {
      extra.add('$pf86\\Git\\bin\\bash.exe');
    }
    for (final path in [
      r'C:\Program Files\Git\bin\bash.exe',
      r'C:\Program Files (x86)\Git\bin\bash.exe',
      ...extra,
    ]) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static Future<bool> isGitBashAvailable() async {
    return (await gitBashPath()) != null;
  }

  /// Windows 桌面 shell：优先 PowerShell 7（pwsh），缺失时回退 cmd。
  static Future<String> windowsShell() async {
    if (!isWindows) {
      throw UnsupportedError('windowsShell 仅支持 Windows 平台');
    }
    final cached = _windowsShell;
    if (cached != null) return cached;
    try {
      final probe = await Process.run('pwsh', [
        '-NoProfile',
        '-NoLogo',
        '-Command',
        'exit 0',
      ]).timeout(const Duration(seconds: 10));
      _windowsShell = probe.exitCode == 0 ? 'pwsh' : 'cmd';
    } catch (_) {
      _windowsShell = 'cmd';
    }
    return _windowsShell!;
  }

  /// Windows 上是否可用 PowerShell 7（pwsh）。
  static Future<bool> isPwshAvailable() async {
    if (!isWindows) return false;
    return await windowsShell() == 'pwsh';
  }

  /// 环境根目录（app 私有 files 目录下的固定 termux 目录，无版本后缀）。
  /// 兼容旧结构：prefix 下不再有 usr/（Termux bootstrap 已废弃），
  /// 新结构为 local/{bin,lib,alpine} + home + tmp。
  static Future<String> _baseDir() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/termux';
  }

  /// 环境根目录（与旧版一致，调用点无需修改）。
  static Future<String> prefixDir() async => _baseDir();

  /// local 目录（proot / init 脚本 / rootfs 均在其下）。
  static Future<String> localDir() async => '${await _baseDir()}/local';

  /// rootfs 目录（Alpine minirootfs 解压目标）。
  static Future<String> rootfsDir() async => '${await localDir()}/alpine';

  /// usr 目录 = rootfs 内的 /usr（宿主视角路径）。
  /// npm 全局包（@deepseek-ai/dsh 等）落在 rootfs/usr/lib/node_modules，
  /// 宿主侧通过该路径直接读写（proot 内外同文件系统）。
  static Future<String> usrDir() async => '${await rootfsDir()}/usr';

  /// home 目录（宿主侧）。proot 启动时绑定为 rootfs 的 /root，
  /// 因此 DSH 数据目录 $prefix/home/.dsh 与旧 Termux 结构完全一致，无缝迁移。
  static Future<String> homeDir() async => '${await _baseDir()}/home';

  /// Android 命令执行入口：init-host 启动器（/system/bin/sh 解析 shebang）。
  /// 支持 `-c <command>` 形态（与旧 bash -c 调用点兼容）。
  static Future<String> shellPath() async {
    if (isWindows) return windowsShell();
    return '${await localDir()}/bin/init-host';
  }

  /// Android 命令执行入口：返回启动 init-host 的完整 argv。
  /// 无 root 设备不能直接 exec app 数据目录里的脚本（SELinux 拒绝
  /// execute_no_trans），改为 /system/bin/sh 读取执行，只需读权限。
  static Future<List<String>> shellCommand(List<String> args) async {
    if (isWindows) return [await windowsShell(), ...args];
    return ['/system/bin/sh', '${await localDir()}/bin/init-host', ...args];
  }

  static String? _nativeLibDir;

  /// Android 原生库目录（proot loader 所在；apk_data_file 标签，
  /// 系统允许直接 exec，绕开 app 数据目录的 execute_no_trans 限制）。
  static Future<String?> nativeLibraryDir() async {
    if (isWindows) return null;
    try {
      return _nativeLibDir ??=
          await _channel.invokeMethod<String>('nativeLibraryDir');
    } catch (_) {
      return null;
    }
  }

  /// 内嵌 Alpine 仅支持 aarch64 真机。x86 模拟器上 proot/rootfs 无法运行。
  static bool isAarch64Machine(String unameM) {
    final m = unameM.trim().toLowerCase();
    return m == 'aarch64' || m == 'arm64' || m.startsWith('armv8');
  }

  /// 宿主 CPU（/system/bin/uname），不是 rootfs 内的。
  static Future<String?> hostMachine() async {
    try {
      final r = await Process.run('/system/bin/uname', [
        '-m',
      ]).timeout(const Duration(seconds: 3));
      if (r.exitCode != 0) return null;
      final m = '${r.stdout}'.trim();
      return m.isEmpty ? null : m;
    } catch (_) {
      return null;
    }
  }

  static Future<String> _versionFilePath() async =>
      '${await _baseDir()}/.env_version';

  /// 是否已安装且版本匹配（proot + rootfs busybox 存在 + 版本文件一致）。
  /// Windows 恒为 true。
  static Future<bool> isInstalled() async {
    if (isWindows) return true;
    try {
      if (!File(await shellPath()).existsSync()) return false;
      if (!File('${await localDir()}/bin/proot').existsSync()) return false;
      // 不能检查 rootfs/bin/sh：它是指向 /bin/busybox 的符号链接，宿主侧
      // stat 会跟随到 Android 的 /bin/busybox（app 域可能 EACCES 或不存在），
      // 误报缺失导致每次冷启动全量重建 rootfs（实测退出重进死循环）。
      // busybox 是 rootfs 内普通文件，直接 stat 可靠。
      if (!File('${await rootfsDir()}/bin/busybox').existsSync()) return false;
      final vf = File(await _versionFilePath());
      if (!vf.existsSync()) return false;
      return (await vf.readAsString()).trim() == _envVersion;
    } catch (_) {
      return false;
    }
  }

  /// 部署 Alpine 运行时（阻塞直到完成），失败抛异常：
  /// 1. 解压 alpine minirootfs 到 rootfs 目录（原生 tar.gz 解压，含符号链接）；
  /// 2. 复制 proot / libtalloc / loader（64/32）到 local/bin、local/lib；
  /// 3. 写 init-host（宿主侧启动器）与 init（rootfs 内初始化）脚本；
  /// 4. 建 home / tmp 目录并写入版本标记。
  static Future<void> install() async {
    await _appendLog('install 触发：rootfs 部署/重建（envVersion=$_envVersion）');
    final rootfs = await rootfsDir();
    // 重建（版本标记变更）时先清掉旧 rootfs 再解压新资产：
    // 只覆盖解压会残留旧属主/权限的文件（实测 /var/cache/apk 残留
    // 旧 uid 的 700 目录，apk 3 写缓存报 Permission denied 全源失败）。
    // 设备 uid 变更（换机/重装）后旧 uid 属主文件删不掉（EACCES）：
    // 删除失败则改名让位（rename 只需父目录写权限），残留目录不参与
    // 新部署（占空间，可手动清理），避免「删除失败→版本标记没写→
    // 每次启动重删」死循环。
    if (await Directory(rootfs).exists()) {
      try {
        await Directory(rootfs).delete(recursive: true);
      } catch (_) {
        final orphan =
            '$rootfs.old.${DateTime.now().millisecondsSinceEpoch}';
        await Directory(rootfs).rename(orphan);
      }
    }
    Directory(rootfs).createSync(recursive: true);
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'extractTarGz',
      {'assetPath': _alpineAsset, 'destDir': rootfs},
    );
    if (res == null) throw Exception('Alpine rootfs 解压失败');

    final local = await localDir();
    final binDir = Directory('$local/bin')..createSync(recursive: true);
    final libDir = Directory('$local/lib')..createSync(recursive: true);
    await _copyAsset(_prootAsset, '${binDir.path}/proot', executable: true);
    await _copyAsset(_tallocAsset, '${libDir.path}/libtalloc.so.2');
    await _copyAsset(_shmemAsset, '${libDir.path}/libandroid-shmem.so');
    await _copyAsset(_loaderAsset, '${libDir.path}/loader',
        executable: true);
    await _copyAsset(_loader32Asset, '${libDir.path}/loader32',
        executable: true);

    await ensureScripts();

    final prefix = await prefixDir();
    Directory('$prefix/home').createSync(recursive: true);
    Directory('$prefix/tmp').createSync(recursive: true);
    // rootfs 内基础目录（tar 未保留的空目录）。
    Directory('$rootfs/root').createSync(recursive: true);
    Directory('$rootfs/tmp').createSync(recursive: true);
    Directory('$rootfs/workspace').createSync(recursive: true);

    try {
      await Process.run('/system/bin/chmod', [
        '755',
        '${binDir.path}/init-host',
        '${binDir.path}/init',
        '${binDir.path}/proot',
        '${libDir.path}/loader',
        '${libDir.path}/loader32',
      ]);
    } catch (_) {}
    File(await _versionFilePath()).writeAsStringSync(_envVersion);
    // 首次初始化预热：走一次完整 init（apk 源 + 基础包安装），
    // 完成后 /etc/shiyi-ready 就位，后续命令与自检秒过（不超时）。
    // 失败容忍：首次命令执行时 init 会自动重试。
    try {
      final env = await environment();
      final argv = await shellCommand(const ['-c', 'true']);
      await Process.run(argv.first, argv.sublist(1), environment: env)
          .timeout(const Duration(minutes: 4));
    } catch (_) {}
  }

  static Future<void> _copyAsset(
    String assetPath,
    String target, {
    bool executable = false,
  }) async {
    final data = await rootBundle.load(assetPath);
    final f = File(target);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    ));
    if (executable) {
      try {
        await Process.run('/system/bin/chmod', ['755', target]);
      } catch (_) {}
    }
  }

  /// 确保已安装：Windows 仅探测 pwsh/cmd 可用性；Android 未安装则部署，
  /// 已安装也强制覆盖 init/init-host 脚本——APK 更新即脚本更新，不依赖
  /// 版本标记重建（曾因旧脚本残留导致 branch 解析空、基础包自举失败）。
  static Future<void> ensureInstalled() async {
    if (isWindows) {
      // Windows 无需安装：探测并缓存可用 shell。
      await windowsShell();
      return;
    }
    if (!await isInstalled()) {
      await _appendLog(
        'ensureInstalled：isInstalled=false（${await _installBlocker()}），触发 install',
      );
      await install();
    } else {
      await ensureScripts();
    }
    // 已部署的 rootfs 也强制覆盖 apk2（APK 更新即二进制更新），
    // 不依赖版本标记重建；/usr/local/bin 在 PATH 里先于 /sbin。
    await _copyAsset(
      _apk2Asset,
      '${await rootfsDir()}/usr/local/bin/apk',
      executable: true,
    );
    // apk 3 安装包时用 link() 做原子发布，而 Android SELinux neverallow
    // 禁止 untrusted_app 对 app_data_file 做 hardlink → 所有包
    // "Permission denied"（实测 audit: denied { link }）。KernelSU/Magisk
    // 环境静默补一条 allow 规则（运行时 patch + 持久化 sepolicy.rule）；
    // 无 root 设备跳过（此时 apk 3 装不上基础包，属平台限制）。
    await _ensureApkLinkPolicy();
  }

  /// 定位 isInstalled() 为 false 的具体缺失项（rootfs 重建死循环排查用）。
  static Future<String> _installBlocker() async {
    try {
      final parts = <String>[];
      if (!File(await shellPath()).existsSync()) parts.add('init-host');
      if (!File('${await localDir()}/bin/proot').existsSync()) parts.add('proot');
      if (!File('${await rootfsDir()}/bin/busybox').existsSync()) {
        parts.add('rootfs/bin/busybox');
      }
      final vf = File(await _versionFilePath());
      if (!vf.existsSync()) {
        parts.add('.env_version missing');
      } else if ((await vf.readAsString()).trim() != _envVersion) {
        parts.add('.env_version=${(await vf.readAsString()).trim()} != $_envVersion');
      }
      return parts.isEmpty ? 'unknown' : parts.join(', ');
    } catch (e) {
      return 'check failed: $e';
    }
  }

  /// 等待 Alpine rootfs 部署与首次 init 完成。
  /// app 启动的 ensureInstalled 可能在后台解压/预热；安装流程必须先等它，
  /// 否则 apk 命令会与正在跑的 init 并发抢数据库锁（EAGAIN/EINTR），
  /// 短超时探测还会把 init 进程树杀掉留下锁残留（安装死循环根因）。
  /// 若 rootfs 就绪但 init 未完成，主动触发一次完整 init 并等它结束。
  static Future<void> waitReady() async {
    if (isWindows) return;
    // 等 rootfs 部署完成（ensureInstalled 可能正在解压，最多 2 分钟）。
    for (var i = 0; i < 24 && !await isInstalled(); i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    final readyFile = File('${await rootfsDir()}/etc/shiyi-ready');
    if (readyFile.existsSync()) return;
    try {
      final env = await environment();
      final argv = await shellCommand(const ['-c', 'true']);
      final proc =
          await Process.start(argv.first, argv.sublist(1), environment: env);
      // init-host 会同步跑完整 init；锁被占时等持有者完成（init 最坏
      // 一轮约 8 分钟）。15 分钟超时兜底，超时不 kill（避免留锁）。
      final deadline = DateTime.now().add(const Duration(minutes: 15));
      while (DateTime.now().isBefore(deadline) && !readyFile.existsSync()) {
        if (await proc.exitCode.timeout(
              const Duration(seconds: 5),
              onTimeout: () => -1,
            ) !=
            -1) {
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    } catch (_) {
      // 等 init 失败/超时也不阻塞：后续命令会按现状继续，靠日志定位。
    }
  }

  /// 追加运行环境日志到工作目录 logs/error.log（与 DshService 同文件）。
  static Future<void> _appendLog(String message) async {
    try {
      final file = File('${await FileWorkspace.current()}/logs/error.log');
      await file.create(recursive: true);
      await file.writeAsString(
        '[${DateTime.now().toIso8601String()}] [TermuxRuntime] $message\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // 日志写入失败不影响主流程。
    }
  }

  /// 应用 apk 硬链接所需的 SELinux 策略（有 root 时；幂等）。
  static Future<void> _ensureApkLinkPolicy() async {
    if (isWindows || !await RootAccess.request()) return;
    const rule = 'allow untrusted_app_all app_data_file file link';
    try {
      // 运行时立即生效（KernelSU 的 ksud；Magisk 用 magiskpolicy）。
      final patched = await Process.run('/system/bin/sh', [
        '-c',
        '(command -v ksud >/dev/null 2>&1 && ksud sepolicy check "$rule" >/dev/null 2>&1) '
            '|| (command -v magiskpolicy >/dev/null 2>&1 && '
            'magiskpolicy --live "allow untrusted_app app_data_file file link" '
            '"allow untrusted_app_27 app_data_file file link" '
            '"allow untrusted_app_all app_data_file file link") '
            '|| true',
      ]).timeout(const Duration(seconds: 20));
      if (patched.exitCode != 0) {
        // ksud check 失败（未加载）时直接 patch。
        await Process.run('/system/bin/sh', [
          '-c',
          'command -v ksud >/dev/null 2>&1 && '
              'ksud sepolicy patch "allow untrusted_app app_data_file file link" '
              '&& ksud sepolicy patch "allow untrusted_app_27 app_data_file file link" '
              '&& ksud sepolicy patch "allow untrusted_app_all app_data_file file link" '
              '&& ksud sepolicy patch "allow untrusted_app app_data_file file execute_no_trans" '
              '&& ksud sepolicy patch "allow untrusted_app_all app_data_file file execute_no_trans"',
        ]).timeout(const Duration(seconds: 20));
      }
      // 持久化：KernelSU 开机从 /data/adb/ksu/sepolicy.rule 加载。
      // 同时补 execute_no_trans：targetSdk>=35 的新域（untrusted_app_36 等）
      // 不再默认允许直接 exec app 数据里的 ELF（proot/init-host 需要）。
      await Process.run('/system/bin/sh', [
        '-c',
        'if command -v ksud >/dev/null 2>&1 && [ -d /data/adb/ksu ]; then '
            'printf "allow untrusted_app app_data_file file link\\n'
            'allow untrusted_app_27 app_data_file file link\\n'
            'allow untrusted_app_all app_data_file file link\\n'
            'allow untrusted_app_all app_data_file file execute_no_trans\\n" '
            '> /data/adb/ksu/sepolicy.rule; '
            'chmod 644 /data/adb/ksu/sepolicy.rule; '
            'fi',
      ]).timeout(const Duration(seconds: 15));
    } catch (_) {
      // 无 root / 无 su 均容忍（平台限制，不影响非 Android）。
    }
  }

  /// 覆盖写 init-host / init 脚本（APK 内置内容），幂等。
  static Future<void> ensureScripts() async {
    if (isWindows) return;
    final local = await localDir();
    final binDir = Directory('$local/bin')..createSync(recursive: true);
    File('${binDir.path}/init-host').writeAsStringSync(_initHostScript);
    File('${binDir.path}/init').writeAsStringSync(_initScript);
    try {
      await Process.run('/system/bin/chmod', [
        '755',
        '${binDir.path}/init-host',
        '${binDir.path}/init',
      ]);
    } catch (_) {}
  }

  /// 执行环境变量（run_terminal / 终端页每次执行都注入）。
  /// Android：宿主侧启动链所需环境（proot 经 Android linker 加载，
  /// loader / libtalloc 走 LD_LIBRARY_PATH）；Windows：进程默认环境。
  static Future<Map<String, String>> environment() async {
    if (isWindows) {
      // Dart 的 environment 参数与父进程环境合并，空 map = 继承全部默认值。
      return const {};
    }
    final prefix = await prefixDir();
    final local = await localDir();
    final linker =
        File('/system/bin/linker64').existsSync()
            ? '/system/bin/linker64'
            : '/system/bin/linker';
    final nativeLib = await nativeLibraryDir();
    final loaderDir =
        (nativeLib == null || nativeLib.isEmpty) ? '$local/lib' : nativeLib;
    return {
      'HOME': '$prefix/home',
      'PREFIX': prefix,
      'PATH': '$local/bin:/system/bin:/system/xbin',
      'TMPDIR': '$prefix/tmp',
      'LD_LIBRARY_PATH': '$local/lib',
      'LINKER': linker,
      'PROOT_LOADER': '$loaderDir/libproot-loader.so',
      'PROOT_LOADER32': '$loaderDir/libproot-loader32.so',
      'PROOT_TMP_DIR': '$prefix/tmp',
      'LANG': 'C.UTF-8',
    };
  }

  /// 宿主侧启动器：检查 rootfs 就绪 → 组 proot ARGS → exec proot 执行命令。
  /// 用法：`init-host -c <command> [args...]`（run_terminal / dsh 调用形态）
  /// 或 `init-host <args...>`（透传）。
  /// 首次启动（rootfs 无就绪标记）先跑 rootfs 内 init 脚本完成
  /// resolv.conf / apk 源 / 基础包安装（bash 等），失败不阻塞命令执行。
  static const String _initHostScript = r'''#!/system/bin/sh
# shiyi alpine init-host: proot + Alpine rootfs 命令启动器
# 用法: init-host -c <command> [args...]   （command 由 rootfs 内 /bin/sh -c 执行）
#       init-host <args...>                （透传给 rootfs 内 /bin/sh）
# 依赖环境变量（Dart 注入）: PREFIX LD_LIBRARY_PATH LINKER PROOT_LOADER TMPDIR
PREFIX=${PREFIX:-/data/data/com.shiyi.agent/files/termux}
ROOTFS=$PREFIX/local/alpine
PROOT_BIN=$PREFIX/local/bin/proot
export PROOT_LOADER=${PROOT_LOADER:-$PREFIX/local/lib/loader}
# 禁用 proot seccomp 加速：实测 Android 上 seccomp 会把 apk 3 libfetch 的
# connect() 误判为 EACCES（所有源 "Permission denied"，wget/nc 正常）。
# PROOT_NO_SECCOMP=1 后 apk update/add 全部正常（2026-08-16 实测 9LKZL7）。
export PROOT_NO_SECCOMP=1
# proot 依赖 libtalloc.so.2（linker64 加载时经 LD_LIBRARY_PATH 查找）
export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-$PREFIX/local/lib}
# rootfs 内进程继承宿主环境变量，这里重置为 Alpine 布局：
# PATH 让 apk/node/npm/bash 在 rootfs 内可解析（/system/bin 兜底宿主工具）；
# HOME=/root 与 -b $PREFIX/home:/root 绑定一致（DSH 数据目录）；
# TMPDIR=/tmp 对应 -b $PREFIX/tmp:/tmp。
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin:/system/xbin
export HOME=/root
export TMPDIR=/tmp
# 经环境变量传给 rootfs 内 sh（单引号脚本不展开宿主变量）
export SHIYI_READY=/etc/shiyi-ready
export SHIYI_INIT=$PREFIX/local/bin/init
# 宿主 workingDirectory（proot -w / 会丢失 cwd，且内层 sh 会重置 PWD，
# 用独立变量传递，内层 cd "$SHIYI_CWD" 恢复）
export SHIYI_CWD=${PWD:-/}
LINKER=${LINKER:-/system/bin/linker64}
[ -x "$LINKER" ] || LINKER=/system/bin/linker
[ -x "$PROOT_BIN" ] || { echo "proot 未部署: $PROOT_BIN" >&2; exit 127; }
[ -d "$ROOTFS" ] || { echo "Alpine rootfs 未部署: $ROOTFS" >&2; exit 127; }

# 组 proot 参数（参照 Termux/ReTerminal 已验证的组合）。
# 注意：不用 --link2symlink —— proot 会把 link() 转成符号链接并生成
# .l2s glue 文件，破坏 node-gyp 的「link + rename」原子发布流程（编译出的
# pty.node 变成悬空链接，dlopen 失败）。Android 禁 hardlink 由 dsh 源码补丁
# （EACCES/ENOSYS→rename）兜底，node-gyp 对 link 失败自带 fallback。
# 工作目录：proot 内 cwd 由 -c 分支的 `cd "$PWD"` 恢复为宿主 workingDirectory
#（run_terminal 的工作目录、node require 相对解析都依赖它——若 cwd 钉在 /
# 会导致 require("node-pty") 找不到模块）。
ARGS="--kill-on-exit -0 --sysvipc -w /"
for m in /apex /odm /product /system /system_ext /vendor \
 /linkerconfig/ld.config.txt /linkerconfig/com.android.art/ld.config.txt \
 /plat_property_contexts /property_contexts; do
  [ -e "$m" ] && ARGS="$ARGS -b $m"
done
[ -d /sdcard ] && ARGS="$ARGS -b /sdcard"
[ -d /storage ] && ARGS="$ARGS -b /storage"
ARGS="$ARGS -b /dev -b /dev/urandom:/dev/random -b /proc"
APP_DATA=${PREFIX%/files/termux}
if [ -n "$APP_DATA" ] && [ "$APP_DATA" != "$PREFIX" ] && [ -d "$APP_DATA" ]; then
  ARGS="$ARGS -b $APP_DATA:$APP_DATA"
fi
# Process.start 的 workingDirectory 用真实路径（/data/user/0/...），
# 而 PREFIX fallback 是 /data/data/...（app 命名空间里两者都存在但互不跟随）。
# 显式把 /data/user/0 对应路径也绑进 rootfs，否则 proot 内 cd 到
# workingDirectory 会 No such file or directory（node require 相对解析失败）。
case "$APP_DATA" in
  /data/data/*)
    REAL_USER0=/data/user/0/${APP_DATA#/data/data/}
    ARGS="$ARGS -b $REAL_USER0:$REAL_USER0"
    ;;
esac
# home 绑定: rootfs 内 /root = 宿主 $PREFIX/home（DSH 数据目录无缝迁移）
mkdir -p "$PREFIX/home" 2>/dev/null
ARGS="$ARGS -b $PREFIX/home:/root"
# tmp 绑定
mkdir -p "$PREFIX/tmp" 2>/dev/null
export PROOT_TMP_DIR=$PREFIX/tmp
ARGS="$ARGS -b $PREFIX/tmp:/tmp"
if [ -d "$ROOTFS/tmp" ]; then
  ARGS="$ARGS -b $ROOTFS/tmp:/dev/shm"
fi
# PREFIX 自身绑定（rootfs 内可见 init/proot 等）
ARGS="$ARGS -b $PREFIX"
ARGS="$ARGS -r $ROOTFS"

# -c 形态：整条命令作为单个参数交给 rootfs 内 /bin/sh -c 执行，
# 其余参数作为位置参数透传（dsh 后台启动等场景用 $1/$2...）。
# 先 cd "$PWD"：恢复宿主 workingDirectory（proot -w / 会丢失 cwd）。
# 就绪标记 + apk 源脚本（带 v2-uricheck 防御）都就位才跳过 init；
# 旧 rootfs 的源脚本缺防御时自动重跑 init 重新生成。
if [ "$1" = "-c" ]; then
  shift
  CMD=$1
  shift
  exec "$LINKER" "$PROOT_BIN" $ARGS /bin/sh -c '
    cd "$SHIYI_CWD" 2>/dev/null || true
    if [ ! -f "$SHIYI_READY" ] || [ ! -x /usr/local/bin/shiyi-apk-sources ] || ! grep -q "v2-uricheck" /usr/local/bin/shiyi-apk-sources 2>/dev/null; then
      /bin/sh "$SHIYI_INIT" >/dev/null 2>&1 || true
    fi
    exec /bin/sh -c "$1" init-host "$@"
  ' init-host "$CMD" "$@"
fi
exec "$LINKER" "$PROOT_BIN" $ARGS /bin/sh -c '
  cd "$SHIYI_CWD" 2>/dev/null || true
  if [ ! -f "$SHIYI_READY" ] || [ ! -x /usr/local/bin/shiyi-apk-sources ] || ! grep -q "v2-uricheck" /usr/local/bin/shiyi-apk-sources 2>/dev/null; then
    /bin/sh "$SHIYI_INIT" >/dev/null 2>&1 || true
  fi
  exec "$@"
' init-host "$@"
''';

  /// rootfs 内初始化脚本（/bin/sh = busybox）：首次启动时执行一次，
  /// 写 resolv.conf 兜底 DNS、生成 apk 源选择脚本（官方优先 + 国内镜像
  /// 测速自动切换）并配置源、安装基础包（bash / gcompat / glib / nano /
  /// curl / ca-certificates / coreutils）；bash 就绪后写 /etc/shiyi-ready
  /// 标记，后续启动跳过（init-host 同时要求源脚本就位，旧 rootfs 升级
  /// 会自动重跑补齐）。网络失败容忍：不写标记，下次执行自动重试。
  static const String _initScript = r'''#!/bin/sh
# shiyi alpine init: 首次启动初始化（幂等，busybox sh 兼容）。
# mkdir 原子互斥：app 多命令并发触发 init 时同一时刻只跑一个（proot 下
# flock 不可靠，并发 apk 会锁冲突 EAGAIN/EINTR，基础包装不上）。
INIT_LOCK=/tmp/shiyi-init.lock
if ! mkdir "$INIT_LOCK" 2>/dev/null; then
  # 锁被占：等待持有者完成（init 一轮最长约 8 分钟），不能直接退出——
  # 否则后续命令会绕过 init 直接跑 apk，与正在进行的 apk 并发抢数据库
  # 锁（EAGAIN/EINTR），基础包/工具链互相踩踏（2026-08-16 安装死循环）。
  i=0
  while [ $i -lt 120 ] && [ -d "$INIT_LOCK" ]; do
    # 超过 15 分钟视为残留（init 一轮最长 5×90s+重试 ≈ 8 分钟），清除重试
    if find "$INIT_LOCK" -mmin +15 2>/dev/null | grep -q .; then
      chmod 777 "$INIT_LOCK" 2>/dev/null
      rm -rf "$INIT_LOCK" 2>/dev/null
      break
    fi
    sleep 5
    i=$((i + 1))
  done
  mkdir "$INIT_LOCK" 2>/dev/null || exit 0
  chmod 777 "$INIT_LOCK" 2>/dev/null
  # 等待期间持有者已完成初始化：直接释放锁退出，不重复安装
  if [ -f /etc/shiyi-ready ] && [ -x /usr/local/bin/shiyi-apk-sources ]; then
    rmdir "$INIT_LOCK" 2>/dev/null
    exit 0
  fi
fi
# proot -0 下 mkdir 的目录宿主属主是 root，app 无写权限删不掉（rmdir EACCES
# → 锁残留 → 后续 init 永远被挡）。chmod 777 让 app 随时能删，锁才真正释放。
chmod 777 "$INIT_LOCK" 2>/dev/null
[ -f /etc/shiyi-ready ] && [ -x /usr/local/bin/shiyi-apk-sources ] && { rmdir "$INIT_LOCK" 2>/dev/null; exit 0; }
# DNS 兜底：国内网络优先用国内 DNS（8.8.8.8 被 QoS/丢包，libfetch 解析
# 会间歇失败报 DNS: transient error / Permission denied）。
[ -s /etc/resolv.conf ] || printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 114.114.114.114\nnameserver 8.8.8.8\n' > /etc/resolv.conf 2>/dev/null
# apk 镜像源：官方优先 + 国内镜像测速自动切换（探测可达才写入）。
# 源选择脚本生成到 /usr/local/bin/shiyi-apk-sources，幂等可重跑；
# apk 安装失败时 app 也会调用它刷新源（旧 rootfs 由 init-host 补跑生成）。
mkdir -p /etc/apk /usr/local/bin
cat > /usr/local/bin/shiyi-apk-sources <<'SHIYI_APK_SOURCES'
#!/bin/sh
# shiyi-apk-sources: Alpine 源自动选择——国内镜像按测速优先，官方兜底；
# 所有镜像先探测连通性（curl 测速 / wget 兜底），可达才写入
# /etc/apk/repositories，国内源按响应速度升序排在官方之前。
# 分支：rootfs 固定 Alpine 3.24.1，直接写死 v3.24（动态解析依赖
# cut/sed 或 case 展开，基础包未装时曾解析为空导致单源 URL 404）。
branch=v3.24
PROBE_URL="$branch/main/aarch64/APKINDEX.tar.gz"
OFFICIAL=http://dl-cdn.alpinelinux.org/alpine
CN_LIST="http://mirrors.tuna.tsinghua.edu.cn/alpine
http://mirrors.aliyun.com/alpine
http://mirrors.ustc.edu.cn/alpine
http://mirrors.cloud.tencent.com/alpine
http://mirrors.huaweicloud.com/alpine
http://mirrors.163.com/alpine
http://mirrors.sjtug.sjtu.edu.cn/alpine
http://mirrors.bfsu.edu.cn/alpine"
TMPD=/tmp/shiyi-apksrc.$$
mkdir -p "$TMPD" 2>/dev/null
CURL=none
command -v curl >/dev/null 2>&1 && CURL=yes
probe() {
  base="$1"; tag="$2"
  if [ "$CURL" = "yes" ]; then
    t=$(curl -m 4 -s -o /dev/null -w '%{time_total}' "$base/$PROBE_URL" 2>/dev/null)
    [ -n "$t" ] || return 0
    ms=$(echo "$t" | awk '{printf "%d", $1 * 1000}')
  else
    wget -q -T 4 -U 'apk-tools/3.0.6' -O /dev/null "$base/$PROBE_URL" 2>/dev/null || return 0
    ms=9999
  fi
  echo "$ms $base" > "$TMPD/ok.$tag"
}
( probe "$OFFICIAL" official ) &
i=0
for base in $CN_LIST; do
  ( probe "$base" cn$i ) &
  i=$((i+1))
done
wait
{
  # 清华固定第一（用户指定首选）：wget 测速 4s 超时对清华不稳（慢响应
  # 但实际下载可用，apk libfetch 实测 200），探测脚本会把它排掉——这里
  # 不依赖探测，直接放最前（apk 顺序尝试，清华可达就命中，比官方 dl-cdn
  # 的 ~100KB/s 快得多）。
  echo "http://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/main"
  echo "http://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/community"
  for f in "$TMPD"/ok.cn*; do
    [ -f "$f" ] || continue
    cat "$f" >> "$TMPD/all"
  done
  if [ -s "$TMPD/all" ]; then
    # v2-uricheck：只输出 http(s):// 开头的行——探测结果经过排序/分词后
    # 只信任 URL 形态，任何残留（毫秒数等）都不会写进 repositories。
    # 其余国内镜像按响应速度升序排清华之后（apk 顺序尝试，快源先命中）；
    # 官方源兜底放最后，仅当所有国内镜像不可达时使用。
    sort -n "$TMPD/all" | while read ms base; do
      case "$base" in
        http://*|https://*)
          echo "$base/$branch/main"
          echo "$base/$branch/community"
          ;;
      esac
    done
  fi
  if [ -s "$TMPD/ok.official" ]; then
    echo "$OFFICIAL/$branch/main"
    echo "$OFFICIAL/$branch/community"
  fi
} > /tmp/shiyi-repos.$$ 2>/dev/null
# 探测全失败（网络全断）时不覆盖旧源，保留上次可用配置
if [ -s /tmp/shiyi-repos.$$ ]; then
  mv /tmp/shiyi-repos.$$ /etc/apk/repositories 2>/dev/null
fi
rm -f /tmp/shiyi-repos.$$
rm -rf "$TMPD"
exit 0
SHIYI_APK_SOURCES
chmod +x /usr/local/bin/shiyi-apk-sources 2>/dev/null
shiyi-apk-sources 2>/dev/null || true
# 分支：rootfs 固定 Alpine 3.24.1，写死 v3.24（动态解析曾失败导致
# 单源 URL 404、基础包自举失败）。
branch=v3.24
# 基础包（幂等；网络抖动时最多重试 5 轮，失败不阻塞、下次执行再试）。
# apk 默认 10s 网络超时对慢网络大包不够，固定 --wait 300（apk-tools
# 2.x 与 3.x 都支持；3.x 没有 --network-timeout，实测报 unrecognized）。
# apk 参数按主版本：apk 2 的 --wait 是网络超时（默认 10s 大包必超时，
# 固定 300）；apk 3 的 --wait 是数据库锁等待——init 未就绪时每次命令
# 都重跑 init，与用户操作的 apk 命令并发会 flock 冲突（EAGAIN：
# Unable to lock database），锁等待 60 秒让持锁方完成而不是立即失败。
# apk 3 的 libfetch 默认无网络超时（fetchTimeout=0），无需网络参数。
# --no-cache：apk 3 写缓存用 hardlink 原子发布，Android SELinux 对
# untrusted_app 禁 app_data_file link，无 root 设备全源 "Permission denied"
# （rootfs 重建残留的 /var/cache/apk 旧属主 700 也会 EACCES）。不开缓存
# 直接下载解包，重试代价只是重下索引，基础包阶段足够快。
APK_TO="--wait 60 --no-cache"
apk --version 2>/dev/null | grep -q 'apk-tools 2' && APK_TO="--wait 300 --no-cache"
# 基础包阶段用清华单源（-X）：多源索引下载（9 源 × main/community）
# 在国内慢网络下会卡死（probe 超时实测）；单源镜像全量足够，
# 就绪后 repositories 保持多源（add 时按顺序尝试官方优先）。
# 注意：apk 3 的 -X 期待完整仓库 URL，分支会被吞（alpine/v3.24 → 
# alpine/aarch64 404），必须带 /main 或 /community 子目录。
APK_SINGLE="-X http://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/main"
# 部署进度日志（定位 init 卡点，普通用户无感）
INIT_LOG=/sdcard/agent/logs/init-debug.log
INIT_VERSION=6
echo "[$(date)] init start v=$INIT_VERSION ready=$([ -f /etc/shiyi-ready ] && echo yes || echo no) branch=[$branch] release=[$(cat /etc/alpine-release 2>/dev/null)] apk=$(apk --version 2>/dev/null)" >> "$INIT_LOG" 2>/dev/null
if ! apk info -e bash >/dev/null 2>&1; then
  i=0
  while [ $i -lt 5 ]; do
    # timeout 防 libfetch 挂死：apk 3 无网络超时（fetchTimeout=0），连接
    # 挂起时 apk 永久阻塞 → init 卡住 → 锁残留 → 后续 init 全被挡。
    # 90s 兜底：单源索引下载+解压正常 5-30s，慢网络 90s 足够。
    # update 失败不阻断 add：apk 3 的 -X 单源只是追加，repositories 的
    # 18 个 URL 全量更新，个别源（sjtug 等）失败会让 update 非零退出，
    # 但其余源索引已可用——add 必须继续尝试，否则基础包永远装不上。
    timeout 90 apk $APK_TO $APK_SINGLE update >>"$INIT_LOG" 2>&1 || true
    if timeout 120 apk $APK_TO $APK_SINGLE add bash gcompat glib nano curl ca-certificates coreutils >>"$INIT_LOG" 2>&1; then
      break
    fi
    i=$((i + 1))
    sleep 5
  done
  timeout 60 apk $APK_TO cache clean 2>/dev/null || true
fi
echo "[$(date)] init: base done bash=$([ -x /bin/bash ] && echo yes || echo no)" >> "$INIT_LOG" 2>/dev/null
# apk-tools 自身升级到分支最新补丁（minirootfs 是发布快照，索引里可能有
# 更新 -r；单源索引足够，已就绪设备此段随 init 一并跳过）
timeout 90 apk $APK_TO $APK_SINGLE update 2>/dev/null || true
timeout 90 apk $APK_TO $APK_SINGLE upgrade apk-tools 2>/dev/null || true
echo "[$(date)] init: done ready=$([ -f /etc/shiyi-ready ] && echo yes || echo no)" >> "$INIT_LOG" 2>/dev/null
# 就绪判定：bash 可执行文件存在即可（apk info -e bash 在 proot 下偶发
# 失败/锁等待导致 ready 永不写入 → init 每次命令都重跑，卡死后续流程）。
[ -x /bin/bash ] && touch /etc/shiyi-ready 2>/dev/null
rmdir "$INIT_LOCK" 2>/dev/null
exit 0
''';

  /// apk 源选择脚本（v2，含 URL 校验防御）。内容必须与 [_initScript] 的
  /// heredoc 保持一致；DshService 在 apk 失败重试时用本常量覆盖写 rootfs
  /// 里的脚本再执行，确保设备上始终是新版（旧版残留会把探测毫秒数写进
  /// /etc/apk/repositories，导致 apk 报 "unrecogized keyword: 455/v3.24/main"
  /// 和 no such package）。
  static const String apkSourcesScript = r'''#!/bin/sh
# shiyi-apk-sources: Alpine 源自动选择——国内镜像按测速优先，官方兜底；
# 所有镜像先探测连通性（curl 测速 / wget 兜底），可达才写入
# /etc/apk/repositories，国内源按响应速度升序排在官方之前。
# 分支：rootfs 固定 Alpine 3.24.1，直接写死 v3.24（动态解析依赖
# cut/sed 或 case 展开，基础包未装时曾解析为空导致单源 URL 404）。
branch=v3.24
PROBE_URL="$branch/main/aarch64/APKINDEX.tar.gz"
OFFICIAL=http://dl-cdn.alpinelinux.org/alpine
CN_LIST="http://mirrors.tuna.tsinghua.edu.cn/alpine
http://mirrors.aliyun.com/alpine
http://mirrors.ustc.edu.cn/alpine
http://mirrors.cloud.tencent.com/alpine
http://mirrors.huaweicloud.com/alpine
http://mirrors.163.com/alpine
http://mirrors.sjtug.sjtu.edu.cn/alpine
http://mirrors.bfsu.edu.cn/alpine"
TMPD=/tmp/shiyi-apksrc.$$
mkdir -p "$TMPD" 2>/dev/null
CURL=none
command -v curl >/dev/null 2>&1 && CURL=yes
probe() {
  base="$1"; tag="$2"
  if [ "$CURL" = "yes" ]; then
    t=$(curl -m 4 -s -o /dev/null -w '%{time_total}' "$base/$PROBE_URL" 2>/dev/null)
    [ -n "$t" ] || return 0
    ms=$(echo "$t" | awk '{printf "%d", $1 * 1000}')
  else
    wget -q -T 4 -U 'apk-tools/3.0.6' -O /dev/null "$base/$PROBE_URL" 2>/dev/null || return 0
    ms=9999
  fi
  echo "$ms $base" > "$TMPD/ok.$tag"
}
( probe "$OFFICIAL" official ) &
i=0
for base in $CN_LIST; do
  ( probe "$base" cn$i ) &
  i=$((i+1))
done
wait
{
  # 清华固定第一（用户指定首选）：wget 测速 4s 超时对清华不稳（慢响应
  # 但实际下载可用，apk libfetch 实测 200），探测脚本会把它排掉——这里
  # 不依赖探测，直接放最前（apk 顺序尝试，清华可达就命中，比官方 dl-cdn
  # 的 ~100KB/s 快得多）。
  echo "http://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/main"
  echo "http://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/community"
  for f in "$TMPD"/ok.cn*; do
    [ -f "$f" ] || continue
    cat "$f" >> "$TMPD/all"
  done
  if [ -s "$TMPD/all" ]; then
    # v2-uricheck：只输出 http(s):// 开头的行——探测结果经过排序/分词后
    # 只信任 URL 形态，任何残留（毫秒数等）都不会写进 repositories。
    # 其余国内镜像按响应速度升序排清华之后（apk 顺序尝试，快源先命中）；
    # 官方源兜底放最后，仅当所有国内镜像不可达时使用。
    sort -n "$TMPD/all" | while read ms base; do
      case "$base" in
        http://*|https://*)
          echo "$base/$branch/main"
          echo "$base/$branch/community"
          ;;
      esac
    done
  fi
  if [ -s "$TMPD/ok.official" ]; then
    echo "$OFFICIAL/$branch/main"
    echo "$OFFICIAL/$branch/community"
  fi
} > /tmp/shiyi-repos.$$ 2>/dev/null
# 探测全失败（网络全断）时不覆盖旧源，保留上次可用配置
if [ -s /tmp/shiyi-repos.$$ ]; then
  mv /tmp/shiyi-repos.$$ /etc/apk/repositories 2>/dev/null
fi
rm -f /tmp/shiyi-repos.$$
rm -rf "$TMPD"
exit 0
''';
}








