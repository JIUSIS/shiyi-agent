import 'dart:async';
// probe
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'dsh_api.dart';
import 'file_workspace.dart';
import 'network_proxy.dart';
import 'notifier.dart';
import 'termux_runtime.dart';

/// DSH 服务状态。

enum DshStatus {
  idle,
  installing,
  updating,
  starting,
  running,
  stopping,
  uninstalling,
  error,
}

/// DSH（DeepSeek Harness）服务管理：版本检测 / 安装更新 / 启动停止。
///
/// - 版本源：npm registry（@deepseek-ai/dsh，官方发布渠道，与源码同步）；
///   国内不可达时自动尝试 npmmirror 镜像。
/// - 安装：`npm install -g @deepseek-ai/dsh@<version>`（用户级全局，无需管理员）。
/// - 启动：`dsh web`（当前服务的 profile=web），后台进程 + 端口轮询就绪。
///
/// 更新策略为「提示式」：检测到新版由 UI 弹窗让用户选择更新或暂不。
class DshService {
  DshService._();
  static final DshService instance = DshService._();

  static const String _localVersionKey = 'dsh_local_version';
  static const String _registryUrl =
      'https://registry.npmjs.org/@deepseek-ai/dsh';
  static const String _mirrorUrl =
      'https://registry.npmmirror.com/@deepseek-ai/dsh';

  /// 已知版本一次完整 npm install 的 http fetch GET 200 行数（实测），
  /// 用于真实下载百分比；不是 dry-run 的 added 数（它约等于 2×added）。
  static const Map<String, int> _knownNpmPackageCounts = {'0.1.0-rc.6': 1131};

  /// 状态流：UI 监听刷新。
  final ValueNotifier<DshStatus> status = ValueNotifier<DshStatus>(
    DshStatus.idle,
  );
  final ValueNotifier<String> statusMessage = ValueNotifier<String>('');
  final ValueNotifier<double> progress = ValueNotifier<double>(0);

  /// 安装、修复和服务启动的实时命令输出（UI 展开查看），只保留尾部防膨胀。
  final ValueNotifier<String> installOutput = ValueNotifier<String>('');

  /// 当前进度阶段区间（start, end）；null = 无阶段划分。
  (double, double)? _phase;

  DateTime? _lastNotifyAt;

  /// 安装/更新命令是否正在跑（此时输出才进 installOutput 与通知进度）。
  bool get _capturingOutput =>
      status.value == DshStatus.installing ||
      status.value == DshStatus.updating;

  /// 已记录的本地版本（null = 未安装/未知）。
  String? _localVersion;

  /// 最近一次检测到的最新版本（null = 未检测）。
  String? latestVersion;

  /// Android 安装后非致命警告（如 sharp wasm32 缺失），完成消息里带上。
  String? _postInstallWarning;

  bool get hasUpdate =>
      latestVersion != null &&
      _localVersion != null &&
      compareSemver(latestVersion!, _localVersion!) > 0;

  Process? _serverProcess;
  Future<void> _serverLogWriteTail = Future<void>.value();

  /// 安装互斥：防止并发 npm 安装（arborist Tracker 冲突 / 互相删文件）。
  Future<void>? _installInFlight;

  /// VPN / 网络变化后的自愈：避免并发重复重启。
  DateTime? _lastRecoverAt;
  Future<void>? _recovering;

  /// 是否启用自动代理（与设置 dshUseProxy 同步，UI 切换时写入）。
  bool useProxyEnabled = true;

  /// 检测可用代理（尊重开关；关闭时返回 null 走直连）。
  Future<ProxyInfo?> _detectProxy() async {
    if (!useProxyEnabled) return null;
    return NetworkProxyDetector.instance.detect();
  }

  /// 是否已安装（本地版本存在或命令可用）。
  Future<bool> isInstalled() async {
    final local = await localVersion();
    return local != null && local.isNotEmpty;
  }

  /// DSH 主目录。Android 落在内嵌 Termux 的 home/.dsh。
  Future<String> homeDir() async {
    if (Platform.isAndroid) {
      final prefix = await TermuxRuntime.prefixDir();
      return '$prefix/home/.dsh';
    }
    final override = Platform.environment['DSH_HOME'];
    if (override != null && override.isNotEmpty) return override;
    final userHome =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return '$userHome${Platform.pathSeparator}.dsh';
  }

  /// 从 `dsh --version` 抽版本。失败输出不当版本（例如链接器里的 libz.so.1.3.2）。
  static String? parseCliVersion(String output, int exitCode) {
    if (exitCode != 0) return null;
    final lines = output
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .where((e) => !e.contains('.so.'))
        .where((e) => !e.toLowerCase().contains('cannot link'))
        .toList();
    if (lines.isEmpty) return null;
    final m = RegExp(
      r'(?:^|[\s:])v?(\d+\.\d+\.\d+(?:-[\w.]+)?)',
    ).firstMatch(lines.join('\n'));
    return m?.group(1);
  }

  /// Android app 数据分区禁止 hard link（link 返回 EACCES）。
  /// DSH 用 link() 做无覆盖发布，失败后会话日志写不进去，用户消息会被回滚。
  /// 官方讨论 #487：EACCES/ENOSYS/EPERM/ENOTSUP/EOPNOTSUPP 时改 rename()。
  static String patchAndroidHardlinkPublish(String src) {
    var out = src;
    const importOld =
        'import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";';
    const importNew =
        'import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, stat, truncate } from "node:fs/promises";';
    if (out.contains(importOld)) out = out.replaceFirst(importOld, importNew);
    const needle =
        '\t\t\tawait link(tmp, finalPath);\n\t\t\tlinked = true;\n\t\t} finally {';
    const repl =
        '\t\t\tawait link(tmp, finalPath);\n\t\t\tlinked = true;\n\t\t} catch (error) {\n\t\t\tif (error?.code !== "EACCES" && error?.code !== "ENOSYS" && error?.code !== "EPERM" && error?.code !== "ENOTSUP" && error?.code !== "EOPNOTSUPP") throw error;\n\t\t\tawait this.rejectExistingLog(finalPath, id);\n\t\t\tawait rename(tmp, finalPath);\n\t\t\tlinked = true;\n\t\t} finally {';
    if (out.contains(needle)) out = out.replaceFirst(needle, repl);
    return out;
  }

  static String patchAndroidFsLocalLink(String src) {
    const needle = '''\t\tif (createIfAbsent !== void 0) try {
\t\t\tawait linkFile(tempPath, absolutePath);
\t\t} catch (error) {
\t\t\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);
\t\t}''';
    const repl = '''\t\tif (createIfAbsent !== void 0) try {
\t\t\tawait linkFile(tempPath, absolutePath);
\t\t} catch (error) {
\t\t\tif (error?.code === "EACCES" || error?.code === "ENOSYS" || error?.code === "EPERM" || error?.code === "ENOTSUP" || error?.code === "EOPNOTSUPP") {
\t\t\t\tlet existing;
\t\t\t\ttry {
\t\t\t\t\texisting = await inspectPublicationTarget(absolutePath);
\t\t\t\t} catch (metadataError) {
\t\t\t\t\tif (metadataError?.code !== "ENOENT" && metadataError?.code !== "ENOTDIR") throw error;
\t\t\t\t}
\t\t\t\tif (existing !== void 0) {
\t\t\t\t\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);
\t\t\t\t} else {
\t\t\t\t\tawait rename(tempPath, absolutePath);
\t\t\t\t}
\t\t\t} else {
\t\t\t\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);
\t\t\t}
\t\t}''';
    return src.contains(needle) ? src.replaceFirst(needle, repl) : src;
  }

  /// Android：dsh npm 全局包目录（Alpine 的 npm prefix=/usr/local，
  /// 与 Termux 的 /usr 不同——所有 dsh 包路径统一走这里解析）。
  Future<String> _androidDshDir() async {
    final usr = await TermuxRuntime.usrDir();
    return '$usr/local/lib/node_modules/@deepseek-ai/dsh';
  }

  Future<String?> _installedDshDir() async {
    if (Platform.isAndroid) return _androidDshDir();
    try {
      final result = await _runCommand([
        'npm',
        'root',
        '-g',
      ]).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) return null;
      final root = result.output
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .lastOrNull;
      if (root == null) return null;
      return '$root/@deepseek-ai/dsh';
    } catch (_) {
      return null;
    }
  }

  Future<bool> _patchAndroidDshHardlinks() async {
    var changed = false;
    final dshDir = await _androidDshDir();
    final persist = File(
      '$dshDir/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js',
    );
    if (await persist.exists()) {
      final raw = await persist.readAsString();
      final next = patchAndroidHardlinkPublish(raw);
      if (next != raw) {
        await persist.writeAsString(next);
        changed = true;
      }
    }
    final fsLocal = File(
      '$dshDir/node_modules/@deepseek-ai/dsh-fs-local/lib/index.js',
    );
    if (await fsLocal.exists()) {
      final raw = await fsLocal.readAsString();
      final next = patchAndroidFsLocalLink(raw);
      if (next != raw) {
        await fsLocal.writeAsString(next);
        changed = true;
      }
    }
    return changed;
  }

  Future<bool> _androidDshPackagePresent() async {
    try {
      return File('${await _androidDshDir()}/lib/bin.js').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 本地已装版本（优先持久化记录，缺省时探测 dsh 命令版本）。
  Future<String?> localVersion() async {
    if (Platform.isAndroid && !await _androidDshPackagePresent()) {
      _localVersion = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_localVersionKey);
      return null;
    }
    final cached = _localVersion;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_localVersionKey);
    if (saved != null && saved.isNotEmpty) {
      _localVersion = saved;
      return saved;
    }
    // 探测 `dsh --version`（npm 全局安装后命令可用；Android 经 Termux）。
    try {
      final r = await _runCommand([
        'dsh',
        '--version',
      ]).timeout(const Duration(seconds: 12));
      final ver = parseCliVersion(r.output, r.exitCode);
      if (ver != null) {
        _localVersion = ver;
        await prefs.setString(_localVersionKey, ver);
        return ver;
      }
    } catch (_) {}
    return null;
  }

  /// 检测 npm 最新版本。分层探测（实测：npmjs 国内直连/代理常不通，
  /// npmmirror 镜像直连最稳）：
  /// 镜像直连 → npmjs 直连 → 镜像走代理 → npmjs 走代理。
  ///
  /// 不只信 `dist-tags.latest`：官方可能已发 `0.1.0-rc.8` 却不把 latest
  /// 从 `0.1.0-rc.7` 推上去。扫描 dist-tags 与 `versions` 后取 semver 最高。
  Future<String?> checkLatestVersion() async {
    final proxy = await _detectProxy();
    final attempts = <(String, ProxyInfo?)>[
      (_mirrorUrl, null),
      (_registryUrl, null),
      if (proxy != null) (_mirrorUrl, proxy),
      if (proxy != null) (_registryUrl, proxy),
    ];
    for (final attempt in attempts) {
      final url = attempt.$1;
      final p = attempt.$2;
      try {
        final res = await _httpGet(url, p).timeout(const Duration(seconds: 12));
        if (res.statusCode != 200) continue;
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final latest = pickNewestPublishedVersion(body);
        if (latest != null && latest.isNotEmpty) {
          latestVersion = latest;
          return latest;
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// 从 npm registry 文档挑最新已发布版本。
  /// `dist-tags.latest` 可能落后于实际 `versions`（例如 rc.8 已发、latest 仍 rc.7）。
  /// 只跟 latest 同一条 `major.minor.patch` 线，避免把 `next`（如 0.1.1-rc.1）
  /// 当成当前线的更新。
  static String? pickNewestPublishedVersion(Map<String, dynamic> body) {
    final candidates = <String>{};
    final tags = body['dist-tags'];
    String? latestTag;
    if (tags is Map) {
      latestTag = tags['latest']?.toString().trim();
      if (latestTag != null && latestTag.isEmpty) latestTag = null;
      for (final value in tags.values) {
        final version = value?.toString().trim() ?? '';
        if (version.isNotEmpty) candidates.add(version);
      }
    }
    final versions = body['versions'];
    if (versions is Map) {
      for (final key in versions.keys) {
        final version = key.toString().trim();
        if (version.isNotEmpty) candidates.add(version);
      }
    }
    var pool = candidates;
    if (latestTag != null) {
      final core = _parseSemver(latestTag).$1;
      final sameLine = candidates.where((version) {
        final nums = _parseSemver(version).$1;
        return nums[0] == core[0] && nums[1] == core[1] && nums[2] == core[2];
      }).toSet();
      if (sameLine.isNotEmpty) pool = sameLine;
    }
    String? newest;
    for (final version in pool) {
      if (newest == null || compareSemver(version, newest) > 0) {
        newest = version;
      }
    }
    return newest;
  }

  /// HTTP GET：检测到代理时经代理请求（Dart HttpClient.findProxy）。
  Future<http.Response> _httpGet(String url, ProxyInfo? proxy) async {
    if (proxy == null) {
      return http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..findProxy = (_) => 'PROXY ${proxy.url}';
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 12));
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 12));
      return http.Response(body, res.statusCode);
    } finally {
      client.close(force: true);
    }
  }

  /// 安装或更新到指定版本（npm 全局安装，流式进度）。
  /// 自动代理：检测到代理时给 npm 传 --proxy/--https-proxy；
  /// 官方源失败（网络类错误）自动切 npmmirror 镜像重试一次。
  Future<void> installOrUpdate(String version, {bool isUpdate = false}) async {
    // 互斥：防止"立即安装"与自动重试/修复并发跑两个 npm（arborist 并发
    // 崩 Tracker "idealTree" already exists，且互相删除对方刚装的文件）。
    if (_installInFlight != null) {
      throw DshApiException('安装已在进行中，请等待完成');
    }
    final gate = Completer<void>();
    _installInFlight = gate.future;
    try {
      await _installOrUpdateInner(version, isUpdate: isUpdate);
    } finally {
      _installInFlight = null;
      gate.complete();
    }
  }

  Future<void> _installOrUpdateInner(
    String version, {
    bool isUpdate = false,
  }) async {
    await _appendServiceLog(
      'installOrUpdate 触发 version=$version isUpdate=$isUpdate '
      'wasRunning=${await isRunning()}',
    );
    final wasRunning = await isRunning();
    if (wasRunning) await stop();
    status.value = isUpdate ? DshStatus.updating : DshStatus.installing;
    statusMessage.value = isUpdate
        ? '正在更新 DeepSeek Harness 到 $version …'
        : '正在安装 DeepSeek Harness $version …';
    _postInstallWarning = null;
    progress.value = 0;
    installOutput.value = '';
    unawaited(
      _notifyDsh(
        title: isUpdate ? 'DeepSeek Harness 更新中' : 'DeepSeek Harness 安装中',
        body: '正在安装 $version，完成后会再通知。',
      ),
    );
    try {
      // Android：npm 依赖 Node.js，Termux 未装时先自动安装（pkg install）。
      if (Platform.isAndroid) {
        // 先等 rootfs 部署 + 首次 init 完成：否则 apk 与 init 并发抢数据库
        // 锁，且 _nodeReady 20s 探测会把正在跑的 init 杀掉留锁（死循环根因）。
        _setStep(0.08, '正在准备 Android 运行环境…');
        await TermuxRuntime.waitReady();
        _setStep(0.12, '正在检查 Node.js…');
        await _ensureNode();
        _setStep(0.18, '正在检查编译工具链…');
        // node-pty 的 install 脚本在 npm install 时编译原生模块，
        // 必须确保编译工具链（gcc/python3/cmake/ninja）先就位。
        // 已装则秒过；未装走清华优先快源下载。
        await _ensureAndroidBuildToolchain();
      }
      _setStep(0.22, '正在安装 DeepSeek Harness $version …');
      await _installDshPackage(version);
      // Android：安装后修正 Termux 侧运行环境（shebang / sharp wasm / 补丁）。
      if (Platform.isAndroid) {
        _setStep(0.78, '正在修正运行环境（本地终端支持）…');
        final postOk = await _androidPostInstall();
        if (!postOk) {
          throw DshApiException('DeepSeek Harness 安装完成，但运行环境修正失败，请查看日志');
        }
      }
      // 安装成功：更新本地版本记录。
      _localVersion = version;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_localVersionKey, version);
      latestVersion = version;
      status.value = DshStatus.idle;
      statusMessage.value = _postInstallWarning == null
          ? 'DeepSeek Harness $version 就绪，正在自动启动服务…'
          : 'DeepSeek Harness $version 就绪；$_postInstallWarning，'
                '正在自动启动服务…';
      progress.value = 1;
      unawaited(
        _notifyDsh(
          title: isUpdate ? 'DeepSeek Harness 更新完成' : 'DeepSeek Harness 安装完成',
          body: '$version 已就绪，正在自动启动服务…',
          progress: 1.0,
        ),
      );
      unawaited(
        start().then((started) {
          statusMessage.value = started
              ? 'DeepSeek Harness $version 就绪，服务已自动启动'
              : 'DeepSeek Harness $version 就绪，服务启动失败，请手动启动';
          unawaited(
            _notifyDsh(
              title: isUpdate
                  ? 'DeepSeek Harness 更新完成'
                  : 'DeepSeek Harness 安装完成',
              body: statusMessage.value,
              progress: 1.0,
            ),
          );
        }),
      );
    } catch (e) {
      await _appendServiceLog('installOrUpdate 失败：$e');
      status.value = DshStatus.error;
      statusMessage.value = '$e';
      unawaited(
        _notifyDsh(
          title: isUpdate ? 'DeepSeek Harness 更新失败' : 'DeepSeek Harness 安装失败',
          body: '$e',
        ),
      );
      rethrow;
    }
  }

  /// 安装/修复结果通知（固定 id 覆盖旧通知，不堆积）。
  /// [progress] 0-1，用于通知栏进度条；null = 无进度条。
  Future<void> _notifyDsh({
    required String title,
    required String body,
    double? progress,
  }) async {
    await Notifier.instance.ensureInitialized();
    await Notifier.instance.show(
      id: 2080,
      title: title,
      body: body,
      progress: progress == null ? null : (progress * 100).round(),
      maxProgress: progress == null ? null : 100,
    );
  }

  /// 切到真实步骤：百分比只在步骤切换时跳，段内不再按输出字节估。
  void _setStep(double value, String message) {
    _phase = null;
    progress.value = value.clamp(0.0, 1.0);
    statusMessage.value = message;
    installOutput.value = mergeInstallOutput(
      installOutput.value,
      '\n== $message（${(value * 100).round()}%） ==\n',
    );
    unawaited(
      _notifyDsh(
        title: status.value == DshStatus.installing
            ? 'DeepSeek Harness 安装中'
            : 'DeepSeek Harness 更新中',
        body: message,
        progress: value,
      ),
    );
  }

  /// 兼容旧调用：段内仍可按输出微推进。
  void _setPhase(double start, double end, String message) {
    _phase = (start, end);
    _npmExpectedFetches = 0;
    _npmFetchedLines = 0;
    _phaseOutputBytes = 0;
    progress.value = start;
    statusMessage.value = message;
    installOutput.value = mergeInstallOutput(
      installOutput.value,
      '\n== $message（${(start * 100).round()}%） ==\n',
    );
    unawaited(
      _notifyDsh(
        title: status.value == DshStatus.installing
            ? 'DeepSeek Harness 安装中'
            : 'DeepSeek Harness 更新中',
        body: message,
        progress: start,
      ),
    );
  }

  /// 命令输出尾部追加（安装中实时展示用），超长只留尾部，防内存膨胀。
  static String mergeInstallOutput(
    String current,
    String chunk, {
    int maxLength = 120000,
  }) {
    if (chunk.isEmpty) return current;
    final next = current + chunk;
    if (next.length <= maxLength) return next;
    return next.substring(next.length - maxLength);
  }

  void _appendRuntimeOutput(String chunk) {
    if (chunk.isEmpty) return;
    installOutput.value = mergeInstallOutput(installOutput.value, chunk);
  }

  void _captureServerOutput(Process process, File logFile) {
    void capture(Stream<List<int>> stream) {
      stream.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
        _appendRuntimeOutput(chunk);
        _serverLogWriteTail = _serverLogWriteTail
            .then<void>((_) async {
              await logFile.writeAsString(
                chunk,
                mode: FileMode.append,
                flush: true,
              );
            })
            .catchError((_) {});
      });
    }

    capture(process.stdout);
    capture(process.stderr);
  }

  /// 卸载 DSH npm 全局包（保留 ~/.dsh 数据目录）。
  Future<void> uninstall() async {
    if (await isRunning()) await stop();
    status.value = DshStatus.uninstalling;
    statusMessage.value = '正在卸载 DeepSeek Harness …';
    progress.value = 0;
    try {
      final r = await _runNpm(['uninstall', '-g', '@deepseek-ai/dsh']);
      if (r.exitCode != 0) {
        throw DshApiException('npm 卸载失败：${npmErrorTail(r.output)}');
      }
      _localVersion = null;
      latestVersion = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_localVersionKey);
      status.value = DshStatus.idle;
      statusMessage.value = 'DeepSeek Harness 已卸载';
      progress.value = 1;
    } catch (e) {
      status.value = DshStatus.error;
      statusMessage.value = 'DeepSeek Harness 卸载失败：$e';
      rethrow;
    }
  }

  /// 先查安装、再查运行：未安装返回 null，已安装按端口探测更新 running/idle。
  Future<DshStatus?> refreshStatus() async {
    // 安装/更新/启停中不覆盖，避免把进行中的状态打回未运行。
    // 必须先判（本地版本为空时也成立）：重进页面时安装还没写完 SharedPreferences，
    // 若先走 local==null 分支会把 status 覆盖成 idle，进度条消失（实测 bug）。
    final cur = status.value;
    if (cur == DshStatus.installing ||
        cur == DshStatus.updating ||
        cur == DshStatus.starting ||
        cur == DshStatus.stopping ||
        cur == DshStatus.uninstalling) {
      return cur;
    }
    final local = await localVersion();
    if (local == null || local.isEmpty) {
      status.value = DshStatus.idle;
      return null;
    }
    final running = await isRunning();
    status.value = running ? DshStatus.running : DshStatus.idle;
    return status.value;
  }

  /// 打开 app 体检：未安装返回 false；已安装未运行后台拉起（不阻塞 UI，
  /// 页面先显示缓存与「后台启动中」，服务就绪后由状态监听自动刷新）；
  /// 已运行刷新状态。
  Future<bool> ensureAvailableOnLaunch() async {
    if (!await isInstalled()) {
      await refreshStatus();
      return false;
    }
    if (await isRunning()) {
      await refreshStatus();
    } else {
      status.value = DshStatus.starting;
      statusMessage.value = '正在后台启动 DeepSeek Harness 服务…';
      unawaited(start());
    }
    return true;
  }

  /// 主页 / 文件页加载前的服务诊断：未安装 / 未启动 / 进行中返回展示文案，
  /// 服务可正常加载返回 null。
  Future<String?> unavailableReason() async {
    switch (status.value) {
      case DshStatus.installing:
        return 'DSH 安装中…';
      case DshStatus.updating:
        return 'DSH 更新中…';
      case DshStatus.starting:
        return 'DSH 启动中…';
      case DshStatus.stopping:
        return 'DSH 停止中…';
      case DshStatus.uninstalling:
        return 'DSH 卸载中…';
      default:
        break;
    }
    if (!await isInstalled()) return 'DSH 未安装';
    if (!await isRunning()) return 'DSH 未启动';
    return null;
  }

  /// 运行一次命令并收集输出（进度随输出推进）。
  /// Windows：直接执行可执行文件；Android：经内嵌 Termux bash 执行。
  Future<({int exitCode, String output})> _runCommand(
    List<String> argv, {
    String? workingDirectory,
    Map<String, String>? extraEnv,
    Duration timeout = const Duration(minutes: 10),
    bool captureToInstall = true,
  }) async {
    if (_capturingOutput && captureToInstall) {
      installOutput.value = mergeInstallOutput(
        installOutput.value,
        '\n> ${argv.map(_shellQuote).join(' ')}\n',
      );
    }
    final proc = await _startCommand(
      argv,
      workingDirectory: workingDirectory,
      extraEnv: extraEnv,
    );
    final outBuf = StringBuffer();
    proc.stdout
        .transform(utf8.decoder)
        .listen(
          (chunk) => _onCommandChunk(
            chunk,
            outBuf,
            captureToInstall: captureToInstall,
          ),
        );
    proc.stderr
        .transform(utf8.decoder)
        .listen(
          (chunk) => _onCommandChunk(
            chunk,
            outBuf,
            captureToInstall: captureToInstall,
          ),
        );
    final code = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        // libfetch 无网络超时：连接挂起时 apk 永久阻塞（init 卡死、锁残留的
        // 根源）。Future 超时不会杀子进程，这里主动 kill 释放 apk 锁。
        proc.kill();
        return -1;
      },
    );
    return (exitCode: code, output: outBuf.toString().trim());
  }

  /// 运行 npm 命令（可执行名按平台：Windows npm.cmd / Android 优先 node + npm-cli）。
  Future<({int exitCode, String output})> _runNpm(
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? extraEnv,
    bool captureToInstall = true,
  }) async {
    if (Platform.isAndroid) {
      final usr = await TermuxRuntime.usrDir();
      final cli = '$usr/lib/node_modules/npm/bin/npm-cli.js';
      if (await File(cli).exists()) {
        return _runCommand(
          ['node', cli, ...args],
          workingDirectory: workingDirectory,
          extraEnv: extraEnv,
          captureToInstall: captureToInstall,
        );
      }
    }
    return _runCommand(
      [Platform.isWindows ? 'npm.cmd' : 'npm', ...args],
      workingDirectory: workingDirectory,
      extraEnv: extraEnv,
      captureToInstall: captureToInstall,
    );
  }

  /// Android：确保 Alpine rootfs 里已安装 Node.js。
  /// 未安装时自动 `apk add nodejs npm`（proot 内执行，Alpine 源已在
  /// init 脚本配置：清华优先 + 官方兜底）。
  /// 探测用 `node --version`（Alpine 有 /usr/bin/env，npm 脚本无需修 shebang）。
  Future<void> _ensureNode() async {
    final machine = await TermuxRuntime.hostMachine();
    if (machine != null && !TermuxRuntime.isAarch64Machine(machine)) {
      throw DshApiException(
        '当前设备是 $machine，内嵌 Alpine 只支持 aarch64。'
        'x86 模拟器无法安装 Node.js / DeepSeek Harness，请用真机测试。',
      );
    }
    if (await _nodeReady()) return;
    statusMessage.value = '正在安装 Node.js（Alpine，首次约 1-3 分钟）…';
    try {
      await _apkInstallNode();
      if (await _nodeReady()) return;
      throw DshApiException('Node.js 已安装但无法执行 node，请查看日志');
    } on DshApiException {
      rethrow;
    } catch (e) {
      throw DshApiException('Node.js 安装失败：$e');
    }
  }

  Future<bool> _nodeReady() async {
    try {
      final probe = await _runCommand([
        'node',
        '--version',
      ], timeout: const Duration(seconds: 20));
      return probe.exitCode == 0 && probe.output.contains('v');
    } catch (_) {
      return false;
    }
  }

  static String _tailOutput(String output, [int max = 280]) {
    final t = output.trim();
    if (t.length <= max) return t;
    return t.substring(t.length - max);
  }

  Future<Map<String, String>?> _aptProxyEnv() async {
    final proxy = await _detectProxy();
    if (proxy == null) return null;
    return {
      'http_proxy': proxy.url,
      'https_proxy': proxy.url,
      'HTTP_PROXY': proxy.url,
      'HTTPS_PROXY': proxy.url,
    };
  }

  /// 用 app 内置的 v2 源脚本覆盖写 rootfs 里的版本并执行。
  /// 旧版脚本残留会把探测毫秒数写进 repositories（apk 报
  /// "unrecogized keyword: 455/v3.24/main" + no such package），
  /// 每次重试强制覆盖，不依赖设备上已有脚本的版本。
  Future<void> _refreshApkSources() async {
    try {
      final prefix = await TermuxRuntime.prefixDir();
      final host = File('$prefix/tmp/shiyi-apk-sources.sh');
      await host.writeAsString(TermuxRuntime.apkSourcesScript);
      await _runCommand([
        'sh',
        '-c',
        'cp /tmp/shiyi-apk-sources.sh /usr/local/bin/shiyi-apk-sources && '
            'chmod +x /usr/local/bin/shiyi-apk-sources && shiyi-apk-sources',
      ], timeout: const Duration(seconds: 90));
    } catch (_) {
      // 源刷新失败不阻塞：保留旧源配置继续重试。
    }
  }

  /// Alpine 版本分支：rootfs 固定 3.24.1，写死 v3.24（曾动态读
  /// /etc/alpine-release，基础包未装时解析异常导致单源 URL 404）。
  String get _alpineBranch => 'v3.24';

  /// apk 主版本 wait 参数（缓存探测）：apk 2 的 --wait 是网络超时
  ///（默认 10s 大包必超时，固定 300）；apk 3 的 --wait 是数据库锁等待
  ///（init 未就绪时每次命令重跑 init，与用户操作并发会 flock 冲突
  /// EAGAIN，锁等待 60 秒让持锁方完成），apk 3 的 libfetch 默认无网络
  /// 超时（fetchTimeout=0）。
  String? _apkWaitArgs;

  Future<String> _apkWaitArgsOrDetect() async {
    final cached = _apkWaitArgs;
    if (cached != null) return cached;
    var wait = '--wait 300';
    try {
      final r = await _runCommand([
        'apk',
        '--version',
      ], timeout: const Duration(seconds: 15));
      if (r.output.contains('apk-tools 3')) wait = '--wait 60';
    } catch (_) {}
    _apkWaitArgs = wait;
    return wait;
  }

  /// 运行 apk 命令，网络类失败（fetch 抖动/索引临时错误）自动重试：
  /// 先刷新软件源（官方优先，自动切国内镜像）再 `apk update`，最多 3 轮。
  /// --no-cache：apk 3 写缓存用 hardlink 原子发布，Android SELinux 禁
  /// untrusted_app 对 app_data_file 做 link（rootfs 重建残留的
  /// /var/cache/apk 旧属主 700 也会 EACCES），全源 Permission denied。
  /// 不开缓存只绕开缓存写入；装包文件仍走 hardlink（无 root 下报
  /// "Failed to create ... Permission denied"），由 tar 直解兜底。
  /// 重试的 update 用清华单源（-X）：9 源索引下载在慢网络下会卡死。
  Future<({int exitCode, String output})> _runApk(
    List<String> args, {
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final wait = await _apkWaitArgsOrDetect();
    Future<({int exitCode, String output})> run() async => _runCommand(
      ['apk', if (wait.isNotEmpty) ...wait.split(' '), '--no-cache', ...args],
      extraEnv: await _aptProxyEnv(),
      timeout: timeout,
    );
    var r = await run();
    for (
      var attempt = 0;
      attempt < 5 &&
          r.exitCode != 0 &&
          (isNetworkError(r.output) ||
              r.output.contains('errors;') ||
              r.output.contains('temporary error') ||
              r.output.contains('IO ERROR') ||
              r.output.contains('unable to') ||
              r.output.contains('no such package') ||
              r.output.contains('Unable to lock')) &&
          // SELinux link 拦截不是网络抖动，重试只会重复下载 337MB 再失败。
          !_apkSelinuxBlocked(r.output);
      attempt++
    ) {
      // 网络抖动恢复需要时间，重试间隔拉长；先强制刷新软件源
      //（覆盖写 v2 脚本 + 官方优先/国内镜像探测）再更新索引。
      await Future<void>.delayed(const Duration(seconds: 5));
      await _refreshApkSources();
      final branch = _alpineBranch;
      await _runCommand(
        [
          'apk',
          if (wait.isNotEmpty) ...wait.split(' '),
          '--no-cache',
          '-X',
          // apk 3 的 -X 期待完整仓库 URL（分支会被吞成 alpine/aarch64 404）
          'http://mirrors.tuna.tsinghua.edu.cn/alpine/$branch/main',
          'update',
        ],
        extraEnv: await _aptProxyEnv(),
        timeout: const Duration(minutes: 4),
      );
      r = await run();
    }
    return r;
  }

  /// 清理 apk 下载缓存，失败忽略（--no-cache 下基本无缓存可清）。
  Future<void> _apkCacheClean() async {
    try {
      await _runCommand(
        ['apk', '--no-cache', 'cache', 'clean'],
        extraEnv: await _aptProxyEnv(),
        timeout: const Duration(minutes: 2),
      );
    } catch (_) {}
  }

  Future<void> _apkInstallNode() async {
    statusMessage.value = '正在安装 Node.js（Alpine，约 30MB，首次可能要几分钟）…';
    // 无缓存直装：重试会重下，但绕开缓存写入的 hardlink 限制。
    var r = await _runApk([
      'add',
      'nodejs',
      'npm',
    ], timeout: const Duration(minutes: 10));
    if (r.exitCode != 0 &&
        !_apkSelinuxBlocked(r.output) &&
        (isNetworkError(r.output) ||
            r.output.contains('unable to') ||
            r.output.contains('fetch'))) {
      statusMessage.value = '软件源拉取失败，正在刷新后重试…';
      await _runApk(['update'], timeout: const Duration(minutes: 4));
      r = await _runApk([
        'add',
        'nodejs',
        'npm',
      ], timeout: const Duration(minutes: 10));
    }
    if (r.exitCode != 0) {
      throw DshApiException('Node.js 安装失败：${_tailOutput(r.output)}');
    }
    await _apkCacheClean();
  }

  /// Android 安装后修正运行环境（实测踩坑汇总）：
  /// 1. sharp 无 android 原生 prebuild（attachment-local 依赖），补装
  ///    @img/sharp-wasm32（WebAssembly 版，版本需与 sharp 主包一致）。
  /// 2. Android 完整模式：在 Alpine rootfs 里重建 node-pty / koffi，
  ///    移除旧版禁用补丁（Termux 时代的 cordis.patch.yml）。
  /// 3. Android 禁止 hard link：给 dsh session persist / fs-local 打
  ///    EACCES→rename 补丁（proot --link2symlink 已从根上规避，补丁兜底）。
  /// 注：Alpine 有 /usr/bin/env，dsh bin.js 的 shebang 无需修正。
  Future<bool> _androidPostInstall() async {
    try {
      final dshDir = await _androidDshDir();
      final bin = '$dshDir/lib/bin.js';
      // 1. 补装 sharp wasm32（版本与 sharp 主包一致；--force 绕开 cpu 校验）。
      final sharpVer = await _runCommand([
        'node',
        '-e',
        'console.log(require("$dshDir/node_modules/sharp/package.json").version)',
      ]).timeout(const Duration(seconds: 30));
      if (sharpVer.exitCode == 0 && sharpVer.output.trim().isNotEmpty) {
        final v = sharpVer.output.trim();
        final wasmPkg = File(
          '$dshDir/node_modules/@img/sharp-wasm32/package.json',
        );
        // 主 npm install 已带 wasm32 fallback 时跳过，避免在错误的 cwd 重装
        // 触发 npm arborist Tracker 冲突（实测 0.35.3 已在 @img 下完整就位）。
        final wasmReady =
            await wasmPkg.exists() &&
            sharpWasmVersionMatches(await wasmPkg.readAsString(), v);
        if (!wasmReady) {
          // workingDirectory 在 proot 内会落回 /（#173 同款坑），命令内
          // 显式 cd 到 rootfs 内 dsh 目录再跑 npm-cli。
          final usr = await TermuxRuntime.usrDir();
          final prootDsh = '/usr/${dshDir.substring(usr.length)}';
          final wasm = await _runCommand([
            'sh',
            '-c',
            r'cd "$1" && exec node "$2" install "@img/sharp-wasm32@$3"'
                ' --force --no-audit --no-fund --fetch-timeout=300000'
                ' --fetch-retries=2 --registry=https://registry.npmmirror.com',
            'sharp-wasm',
            prootDsh,
            '/usr/lib/node_modules/npm/bin/npm-cli.js',
            v,
          ]).timeout(const Duration(minutes: 10));
          if (wasm.exitCode != 0) {
            // 非致命：附件图片处理降级，但 dsh 主流程不受影响。
            _postInstallWarning = '附件图片处理降级（sharp wasm32 补装失败）';
            await _appendServiceLog(
              'sharp wasm32 补装失败：${_tailOutput(wasm.output)}',
            );
          }
        }
      }
      // 2. Android 完整模式：node-pty 重建 + 清理旧精简补丁。
      await _prepareAndroidFullRuntime(force: true);
      // 3. Android 禁止 hard link：给 session persist / fs-local 打 EACCES→rename。
      await _patchAndroidDshHardlinks();
      // 4. 部署拾忆内置免密搜索 provider。
      await _ensureBuiltInSearchPlugin();
      // 5. 验证 dsh 可执行。
      final probe = await _runCommand([
        'node',
        bin,
        '--version',
      ]).timeout(const Duration(seconds: 30));
      if (probe.exitCode != 0) {
        throw DshApiException('dsh 命令不可用：${npmErrorTail(probe.output)}');
      }
      return true;
    } catch (e) {
      statusMessage.value = 'Android 运行环境修正失败：$e';
      return false;
    }
  }

  /// sharp wasm32 包版本是否与主包一致（package.json 文本匹配，避免 JSON 解析）。
  @visibleForTesting
  static bool sharpWasmVersionMatches(String packageJson, String version) {
    return packageJson.contains('"version": "$version"');
  }

  /// 一次 `command -v` 探测的缺项。失败时视为全部缺失。
  @visibleForTesting
  static List<String> missingAndroidBuildTools(
    String output, {
    bool probeFailed = false,
  }) {
    const tools = ['gcc', 'g++', 'make', 'python3', 'cmake', 'ninja'];
    if (probeFailed) return List<String>.of(tools);
    return output
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trim())
        .where(tools.contains)
        .toList();
  }

  /// Android 精简预设的展示元数据。
  static const String _androidPresetMeta = '''
name: Android 精简
description: 手机端预设：禁用依赖 node-pty/subprocess 的本地工具
''';

  /// 旧版 Android 精简补丁标记（用于识别并清理自动生成的禁用配置）。
  static const String _androidPatchMarker = '# Android: 禁用依赖不可用原生模块';

  /// Android 完整模式准备：确保 node-pty / koffi 可用，并移除旧版禁用补丁。
  /// [force] 安装/修复后强制重建；普通启动只在前置检查失败时重建
  /// （工具链缺失会触发 apk 下载 + node-gyp 编译，流量大耗时长，
  /// 用户要求安装类操作必须手动触发——非 force 时缺组件直接抛错，
  /// 提示走「修复完整运行环境」按钮）。
  Future<void> _prepareAndroidFullRuntime({bool force = false}) async {
    if (!await _androidDshPackagePresent()) return;
    if (!force) {
      if (await _androidFullRuntimeReady()) return;
      throw DshApiException(
        '完整运行环境（node-pty / koffi）未就绪，需下载编译工具链并重建。'
        '请在 Agent 引擎设置页点击「修复完整运行环境」手动执行',
      );
    }
    await _ensureAndroidBuildToolchain();
    final rebuilt = await _rebuildAndroidNodePty();
    if (!rebuilt) {
      final detail = statusMessage.value.isNotEmpty
          ? statusMessage.value
          : 'node-pty 重建失败，详见 error.log';
      await _appendServiceLog('完整模式需要重建 node-pty：$detail');
      throw DshApiException('完整模式需要重建 node-pty：$detail');
    }
    final koffiOk = await _rebuildAndroidKoffi();
    if (!koffiOk) {
      final detail = statusMessage.value.isNotEmpty
          ? statusMessage.value
          : 'koffi 重建失败，详见 error.log';
      await _appendServiceLog('完整模式需要重建 koffi：$detail');
      throw DshApiException('完整模式需要重建 koffi：$detail');
    }
    await _removeAndroidLegacyPatch();
    await _patchAndroidDshHardlinks();
  }

  /// 探测 node-pty 原生模块能否加载。
  /// 不在 proot 里 spawn bash：那会偶发 SIGSEGV，随后 node-gyp rebuild
  /// 清掉已编译的 pty.node，运行环境就被拆掉。
  Future<bool> _androidNodePtyProbe() async {
    try {
      final dshDir = await _androidDshDir();
      final usr = await TermuxRuntime.usrDir();
      final probeDir = '/usr/${dshDir.substring(usr.length)}';
      final probe = File('$dshDir/.pty-probe.cjs');
      await probe.writeAsString(
        'const p=require("node-pty");'
        'console.log(typeof p.spawn==="function"?"pty-ok":"");',
      );
      final r = await _runCommand([
        'sh',
        '-c',
        r'cd "$1" && exec node .pty-probe.cjs',
        'pty-probe',
        probeDir,
      ], timeout: const Duration(seconds: 40));
      if (r.exitCode != 0 || !r.output.contains('pty-ok')) {
        await _appendServiceLog(
          'node-pty probe 失败 exit=${r.exitCode} out=${r.output}',
        );
      }
      return r.exitCode == 0 && r.output.contains('pty-ok');
    } catch (e) {
      await _appendServiceLog('node-pty probe 异常：$e');
      return false;
    }
  }

  /// 旧版禁用补丁或 App 生成的 android 精简预设是否仍存在。
  Future<bool> _androidLegacyPatchPresent() async {
    try {
      final home = '${await TermuxRuntime.prefixDir()}/home';
      final patch = File('$home/.dsh/cordis.patch.yml');
      if (await patch.exists() &&
          (await patch.readAsString()).contains(_androidPatchMarker)) {
        return true;
      }
      final presetDir = Directory('$home/.dsh/.agent-presets/android');
      if (await presetDir.exists()) {
        final meta = File('${presetDir.path}/preset.yml');
        if (await meta.exists() &&
            (await meta.readAsString()).trim() == _androidPresetMeta.trim()) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// 移除旧版 App 自动写入的禁用补丁与精简预设目录。
  Future<void> _removeAndroidLegacyPatch() async {
    final home = '${await TermuxRuntime.prefixDir()}/home';
    final patch = File('$home/.dsh/cordis.patch.yml');
    try {
      if (await patch.exists() &&
          (await patch.readAsString()).contains(_androidPatchMarker)) {
        await patch.delete();
      }
    } catch (_) {}
    final presetDir = Directory('$home/.dsh/.agent-presets/android');
    try {
      if (await presetDir.exists()) {
        final meta = File('${presetDir.path}/preset.yml');
        final appGenerated =
            await meta.exists() &&
            (await meta.readAsString()).trim() == _androidPresetMeta.trim();
        if (appGenerated) await presetDir.delete(recursive: true);
      }
    } catch (_) {}
  }

  /// Android 沙箱补丁标记（cordis.patch.yml 顶部注释行，幂等去重用）。
  static const String _androidSandboxPatchMarker =
      '# ShiYi Android: 无 bubblewrap/Landlock，命令/文件工具直接放行';

  /// Android 沙箱补丁条目（cordis.patch.yml 顶层数组元素）：
  /// - sandbox-policy 默认模式 danger-full-access：Android 无 bubblewrap /
  ///   Landlock（node-addon-landlock-run 无 android 平台包），保持
  ///   workspace-write 会让 bash/文件工具报 SANDBOX_UNAVAILABLE；
  /// - approval 策略 never：与 danger-full-access 预设一致。只改 sandbox
  ///   不改 approval 时，permission 预设推导不出（danger-full-access + ask
  ///   是 custom），新会话 pinInitialPermission 会直接启动报错。
  static const String _androidSandboxPatchBody = '''
- id: sandbox-policy
  config:
    mode: danger-full-access
- id: approval
  config:
    policy: never
''';

  static const String _searchPatchStart = '# ShiYi built-in free search: begin';
  static const String _searchPatchEnd = '# ShiYi built-in free search: end';
  static const String _searchPatchBody = '''
- insert:
    - id: web-search-shiyi-free
      name: ./plugins/shiyi-free-search/lib/index.js
- id: web
  config:
    searchProvider: shiyi-free
''';

  static const Map<String, String> _searchPluginAssets = {
    'package.json': 'assets/dsh_plugins/shiyi_free_search/package.json',
    'lib/index.js': 'assets/dsh_plugins/shiyi_free_search/lib/index.js',
  };

  @visibleForTesting
  static String builtInSearchPluginDir(String home) =>
      '$home/profiles/web/plugins/shiyi-free-search';

  /// 把 sandbox 放行补丁 upsert 进 cordis.patch.yml（幂等）：
  /// 已含标记原样返回；`[]` 空列表模板替换为补丁条目；其余情况末尾追加。
  @visibleForTesting
  static String upsertSandboxPatchYaml(String existing) {
    if (existing.contains(_androidSandboxPatchMarker)) return existing;
    final trimmed = existing.trimRight();
    if (trimmed.endsWith('[]')) {
      final head = trimmed.substring(0, trimmed.length - 2).trimRight();
      if (head.isEmpty) {
        return '$_androidSandboxPatchMarker\n$_androidSandboxPatchBody';
      }
      return '$head\n$_androidSandboxPatchMarker\n$_androidSandboxPatchBody';
    }
    if (trimmed.isEmpty) {
      return '$_androidSandboxPatchMarker\n$_androidSandboxPatchBody';
    }
    return '$trimmed\n$_androidSandboxPatchMarker\n$_androidSandboxPatchBody';
  }

  @visibleForTesting
  static String upsertBuiltInSearchPatchYaml(String existing) {
    var base = existing;
    final start = base.indexOf(_searchPatchStart);
    if (start >= 0) {
      final end = base.indexOf(_searchPatchEnd, start);
      base = end >= 0
          ? '${base.substring(0, start)}${base.substring(end + _searchPatchEnd.length)}'
          : base.substring(0, start);
    }
    final trimmed = base.trimRight();
    final block = '$_searchPatchStart\n$_searchPatchBody$_searchPatchEnd';
    if (trimmed.endsWith('[]')) {
      final head = trimmed.substring(0, trimmed.length - 2).trimRight();
      return head.isEmpty ? block : '$head\n$block';
    }
    return trimmed.isEmpty ? block : '$trimmed\n$block';
  }

  Future<bool> _ensureBuiltInSearchPlugin() async {
    try {
      final dshDir = await _installedDshDir();
      if (dshDir == null || !await File('$dshDir/lib/bin.js').exists()) {
        return false;
      }
      var changed = false;
      final home = await homeDir();
      // Cordis 对 cordis.patch.yml 中的相对插件路径以当前 profile 根目录
      //（~/.dsh/profiles/web）解析，因此插件必须部署在 profile 内。
      final pluginDir = Directory(builtInSearchPluginDir(home));
      await pluginDir.create(recursive: true);
      for (final entry in _searchPluginAssets.entries) {
        final target = File('${pluginDir.path}/${entry.key}');
        await target.parent.create(recursive: true);
        final content = await rootBundle.loadString(entry.value);
        final current = await target.exists()
            ? await target.readAsString()
            : '';
        if (current == content) continue;
        await target.writeAsString(content);
        changed = true;
      }
      final patch = File('$home/cordis.patch.yml');
      await patch.parent.create(recursive: true);
      final existing = await patch.exists() ? await patch.readAsString() : '';
      final next = upsertBuiltInSearchPatchYaml(existing);
      if (next != existing) {
        await patch.writeAsString(next);
        changed = true;
      }
      return changed;
    } catch (e) {
      debugPrint('DshService built-in search deployment failed: $e');
      return false;
    }
  }

  /// Android：确保 $DSH_HOME/cordis.patch.yml 含沙箱放行补丁。
  /// 启动前调用；DSH 对 home 层补丁热重载，运行中改动也会生效。
  Future<void> _ensureAndroidSandboxPatch() async {
    try {
      final home = '${await TermuxRuntime.prefixDir()}/home';
      final dir = Directory('$home/.dsh');
      await dir.create(recursive: true);
      final patch = File('${dir.path}/cordis.patch.yml');
      final existing = await patch.exists() ? await patch.readAsString() : '';
      final next = upsertSandboxPatchYaml(existing);
      if (next != existing) await patch.writeAsString(next);
    } catch (e) {
      debugPrint('DshService sandbox patch failed: $e');
    }
  }

  /// 确保 Alpine rootfs 具备 node-pty / koffi 源码编译工具链
  /// （build-base: gcc/g++/make/musl-dev + python3 + cmake + ninja）。
  Future<void> _ensureAndroidBuildToolchain() async {
    final probe = await _runCommand([
      'sh',
      '-c',
      r'for t in gcc g++ make python3 cmake ninja; do command -v "$t" >/dev/null 2>&1 || echo "$t"; done',
    ], timeout: const Duration(seconds: 20));
    final missing = missingAndroidBuildTools(
      probe.output,
      probeFailed: probe.exitCode != 0,
    );
    if (missing.isEmpty) return;
    statusMessage.value = '正在安装完整模式编译工具链（${missing.join('/')}）…';
    // 无缓存直装：重试会重下，但绕开缓存写入的 hardlink 限制。
    var r = await _runApk([
      'add',
      'build-base',
      'python3',
      'cmake',
      'ninja',
    ], timeout: const Duration(minutes: 15));
    if (r.exitCode != 0 &&
        !_apkSelinuxBlocked(r.output) &&
        (r.output.contains('unable to locate') ||
            r.output.contains('errors;') ||
            isNetworkError(r.output))) {
      statusMessage.value = '正在刷新 Alpine 软件源并重试…';
      r = await _runApk([
        'add',
        'build-base',
        'python3',
        'cmake',
        'ninja',
      ], timeout: const Duration(minutes: 15));
    }
    if (r.exitCode != 0) {
      // 无 root 设备上 binutils/gcc/g++ 的包文件发布被 SELinux file link
      // 拦截（apk 报 Failed to create / failed to rename），其余 41 个包
      // 已装好。这三个包改从 .apk 用 busybox tar 直解（普通文件写入不受限）。
      final tarOk = await _apkTarFallbackCompilers();
      if (tarOk) {
        await _apkCacheClean();
        return;
      }
      final tail = npmErrorTail(r.output);
      await _appendServiceLog('编译工具链安装失败：$tail');
      // 完整输出留档：apk 3 的 no-such-package/索引错误只有完整输出才能定位。
      await _appendServiceLog('编译工具链完整输出：\n${_tailOutput(r.output, 6000)}');
      await _diagnoseApkNetwork();
      throw DshApiException(
        '编译工具链安装失败：$tail。'
        '多为网络不稳定导致 apk 下载中断，'
        '请确认网络可用后重新执行「修复完整模式」',
      );
    }
    await _apkCacheClean();
  }

  /// apk 装包文件的 hardlink 发布在无 root 设备被 SELinux 拦截时，
  /// 直接解包 binutils/gcc/g++（版本从当前镜像索引取，依赖已在失败的
  /// apk add 里装好）。Python 解包时把 tar hardlink 物化成普通文件，
  /// 避免 busybox tar 再次触发 SELinux app_data_file link 拒绝。
  /// ponytail: 版本按索引最新取，
  /// 若镜像换版且依赖变化需重跑一次完整 apk add 重建工具链。
  Future<bool> _apkTarFallbackCompilers() async {
    statusMessage.value = 'apk 硬链接受限，正在用 tar 直解编译工具链…';
    const script = r'''
set -e
mkdir -p /tmp/apk-fix
cd /tmp/apk-fix
BASE=http://mirrors.tuna.tsinghua.edu.cn/alpine/v3.24/main/aarch64
curl -m 60 -fsSL -o APKINDEX.tar.gz "$BASE/APKINDEX.tar.gz"
rm -rf idx
mkdir idx
tar -xzf APKINDEX.tar.gz -C idx APKINDEX
for p in binutils gcc g++; do
  v=$(awk -v p="$p" '$0=="P:"p { getline; sub(/^V:/, ""); print; exit }' idx/APKINDEX)
  [ -n "$v" ] || { echo "no index entry for $p"; exit 1; }
  curl -m 900 -fsSL -o "$p.apk" "$BASE/$p-$v.apk"
  python3 - "$p.apk" <<'PY'
import os
import shutil
import sys
import tarfile

archive = sys.argv[1]
directories = []


def destination(name):
    name = name.removeprefix("./")
    normalized = os.path.normpath(name)
    if os.path.isabs(name) or normalized == ".." or normalized.startswith("../"):
        raise RuntimeError(f"unsafe apk path: {name}")
    if normalized != "usr" and not normalized.startswith("usr/"):
        return None
    path = "/" + normalized
    if path != "/usr":
        parent = os.path.realpath(os.path.dirname(path))
        if parent != "/usr" and not parent.startswith("/usr/"):
            raise RuntimeError(f"apk path escapes /usr: {name}")
    return path


def remove_non_directory(path):
    if not os.path.lexists(path):
        return
    if os.path.islink(path) or not os.path.isdir(path):
        os.unlink(path)
        return
    raise RuntimeError(f"cannot replace directory with file: {path}")


with tarfile.open(archive, "r:gz", ignore_zeros=True) as package:
    for member in package:
        path = destination(member.name)
        if path is None:
            continue
        if member.isdir():
            if os.path.islink(path):
                os.unlink(path)
            os.makedirs(path, exist_ok=True)
            directories.append((path, member.mode))
            continue

        os.makedirs(os.path.dirname(path), exist_ok=True)
        remove_non_directory(path)
        if member.issym():
            os.symlink(member.linkname, path)
            continue
        if member.isfile() or member.islnk():
            source = package.extractfile(member)
            if source is None:
                raise RuntimeError(f"missing payload for {member.name}")
            with source, open(path, "wb") as output:
                shutil.copyfileobj(source, output)
            os.chmod(path, member.mode & 0o7777)
            if member.islnk():
                print(f"materialized hardlink {member.name} -> {member.linkname}")
            continue
        raise RuntimeError(f"unsupported apk entry: {member.name}")

for path, mode in reversed(directories):
    os.chmod(path, mode & 0o7777)
PY
done
''';
    try {
      final r = await _runCommand([
        'sh',
        '-c',
        script,
      ], timeout: const Duration(minutes: 20));
      if (r.exitCode != 0) {
        await _appendServiceLog('tar 直解编译工具链失败：${_tailOutput(r.output, 1200)}');
        return false;
      }
      final gcc = await _runCommand([
        'gcc',
        '--version',
      ], timeout: const Duration(seconds: 15));
      final gpp = await _runCommand([
        'g++',
        '--version',
      ], timeout: const Duration(seconds: 15));
      return gcc.exitCode == 0 && gpp.exitCode == 0;
    } catch (e) {
      await _appendServiceLog('tar 直解编译工具链异常：$e');
      return false;
    }
  }

  /// apk 3（libfetch）网络诊断：curl https/http 对比 + apk update 详细输出
  /// + 缓存目录权限 + resolv.conf。定位「curl 探测通、apk update 全源
  /// Permission denied」这类只影响 libfetch 的网络问题。
  Future<void> _diagnoseApkNetwork() async {
    try {
      final r = await _runCommand([
        'sh',
        '-c',
        'echo "== resolv.conf =="; cat /etc/resolv.conf 2>&1; '
            'echo "== curl https =="; '
            'curl -m 6 -s -o /dev/null -w "code=%{http_code} err=%{errormsg}\n" '
            'https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.24/main/aarch64/APKINDEX.tar.gz 2>&1; '
            'echo "== curl http =="; '
            'curl -m 6 -s -o /dev/null -w "code=%{http_code} err=%{errormsg}\n" '
            'http://mirrors.ustc.edu.cn/alpine/v3.24/main/aarch64/APKINDEX.tar.gz 2>&1; '
            'echo "== apk update -v (--no-cache) =="; '
            'apk --wait 5 --no-cache update -v 2>&1 | head -25; '
            'echo "== cache dir =="; ls -ld /var/cache/apk 2>&1; '
            'echo "== root/cache =="; ls -ld /root /root/.apk-cache 2>&1; '
            'echo "== tmp =="; ls -ld /tmp 2>&1; '
            'echo "== apk version =="; apk --version 2>&1',
      ], timeout: const Duration(seconds: 90));
      await _appendServiceLog('apk 网络诊断：\n${r.output}');
    } catch (_) {}
  }

  /// 在 dsh 包目录重建 node-pty（Android 无 prebuild，源码编译）。
  /// 实测（2026-08-16）：npm rebuild 在 proot 下不执行 install 脚本
  /// （exit 0 秒完但 build/ 不生成）；node-gyp rebuild 直接编译 ~1 分钟
  /// 成功（工具链就绪时）。这里直接跑 node-gyp。
  /// 注意：_startCommand 的 workingDirectory 是宿主 cwd，init-host 的
  /// SHIYI_CWD 取不到（Dart 不设 PWD）→ proot 内 cd / → gyp ERR! cwd /。
  /// 必须在命令内显式 cd 到 proot 内路径（/usr/local/lib/...）。
  Future<bool> _rebuildAndroidNodePty() async {
    final dshDir = await _androidDshDir();
    if (await _androidNodePtyProbe()) return true;
    statusMessage.value = '正在编译本地终端支持（node-pty，约 2-5 分钟）…';
    await _ensureNodeGypExecutable();
    final usr = await TermuxRuntime.usrDir();
    final prootPtyDir =
        '/usr/${dshDir.substring(usr.length)}/node_modules/node-pty';
    final proxy = await _detectProxy();
    final env = <String, String>{
      'NODEJS_ORG_MIRROR': 'https://npmmirror.com/mirrors/node',
      'npm_config_disturl': 'https://npmmirror.com/mirrors/node',
      'npm_config_registry': 'https://registry.npmmirror.com',
      if (proxy != null) 'npm_config_proxy': proxy.url,
      if (proxy != null) 'npm_config_https_proxy': proxy.url,
    };
    final buildArgs = <String>[
      'sh',
      '-c',
      r'cd "$1" && exec node-gyp rebuild --verbose',
      'node-gyp-pty',
      prootPtyDir,
    ];
    var r = await _runCommand(
      buildArgs,
      extraEnv: env,
      timeout: const Duration(minutes: 20),
    );
    if (r.exitCode != 0 && await _androidNodePtyProbe()) {
      // 实测：链接已完成但 dep 文件目录缺失导致 make 报错，pty.node 其实可用。
      await _appendServiceLog('node-gyp 报错但 pty.node 已可加载，按成功处理');
      return true;
    }
    if (r.exitCode != 0) {
      statusMessage.value = 'node-pty 首次编译未完成，正在重试…';
      r = await _runCommand(
        buildArgs,
        extraEnv: env,
        timeout: const Duration(minutes: 20),
      );
    }
    if (r.exitCode != 0) {
      final tail = npmErrorTail(r.output);
      statusMessage.value = 'node-pty 重建失败：$tail';
      await _appendServiceLog('node-pty 重建失败：$tail');
      await _appendServiceLog(
        'node-pty 重建完整输出：\n${_tailOutput(r.output, 6000)}',
      );
      await _diagnoseNodeGyp();
      return false;
    }
    if (!await _androidNodePtyProbe()) {
      statusMessage.value = 'node-pty 已重建但加载验证失败，请查看日志';
      await _appendServiceLog('node-pty 已重建但加载验证失败');
      return false;
    }
    return true;
  }

  /// 确保 node-gyp 可用：缺失/不可执行时全局安装并补 exec 位。
  /// Alpine npm 自带 node-gyp，偶见 bin 链接缺失，这里兜底安装。
  Future<void> _ensureNodeGypExecutable() async {
    final probe = await _runCommand([
      'node-gyp',
      '--version',
    ], timeout: const Duration(seconds: 15));
    if (probe.exitCode == 0) return;
    statusMessage.value = '正在安装 node-gyp 编译工具…';
    final proxy = await _detectProxy();
    final env = <String, String>{
      'npm_config_registry': 'https://registry.npmmirror.com',
      'npm_config_fetch_timeout': '300000',
      'npm_config_fetch_retries': '2',
      if (proxy != null) 'npm_config_proxy': proxy.url,
      if (proxy != null) 'npm_config_https_proxy': proxy.url,
    };
    final r = await _runNpm([
      'install',
      '-g',
      'node-gyp',
      '--no-audit',
      '--no-fund',
    ], extraEnv: env).timeout(const Duration(minutes: 5));
    if (r.exitCode != 0) {
      await _appendServiceLog('node-gyp 安装失败：${npmErrorTail(r.output)}');
      return;
    }
  }

  /// node-gyp 执行失败时，把 PATH 解析与关键文件状态写进 error.log（Alpine 版）。
  Future<void> _diagnoseNodeGyp() async {
    final script = r'''
echo "== which -a node-gyp =="
which -a node-gyp 2>&1 || echo "(none on PATH)"
echo "== node/npm =="
node --version 2>&1
npm --version 2>&1
npm config get prefix 2>&1
npm root -g 2>&1
echo "== compiler toolchain =="
gcc --version 2>&1 | head -2
g++ --version 2>&1 | head -2
make --version 2>&1 | head -2
python3 --version 2>&1
cmake --version 2>&1 | head -1
ninja --version 2>&1
echo "== cc probe =="
printf 'int main(){return 0;}\n' > /tmp/cc-test.c
cc -c /tmp/cc-test.c -o /tmp/cc-test.o 2>&1; echo "cc compile exit=$?"
echo "== dsh native modules =="
find /usr/local/lib/node_modules/@deepseek-ai/dsh -maxdepth 6 \( -name binding.gyp -o -name '*.node' \) 2>/dev/null | head -40
echo "== env =="
env | sort | grep -E '^(LD_LIBRARY_PATH|PATH|SHELL|PREFIX|TMPDIR|HOME|CC|CXX)=' 2>&1
''';
    final info = await _runCommand([
      'bash',
      '-c',
      script,
    ], timeout: const Duration(seconds: 20));
    final probe = await _runCommand([
      'node-gyp',
      '--version',
    ], timeout: const Duration(seconds: 20));
    await _appendServiceLog(
      'node-gyp 诊断：\n'
      '${info.output}\n'
      'node-gyp --version exit=${probe.exitCode}\n'
      '${probe.output}',
    );
  }

  /// 用户手动触发：完整模式修复（Android）。
  /// 探测 koffi（dsh sandbox 的 FFI 原生模块）是否可加载。
  Future<bool> _androidKoffiProbe() async {
    try {
      final dshDir = await _androidDshDir();
      final usr = await TermuxRuntime.usrDir();
      // 同 node-pty probe：显式 cd 到 proot 内 dsh 目录，require 才解析得到。
      final probeDir = '/usr/${dshDir.substring(usr.length)}';
      final probe = File('$dshDir/.koffi-probe.cjs');
      await probe.writeAsString(
        'const k=require("koffi");console.log(k?"koffi-ok":"");',
      );
      final r = await _runCommand([
        'sh',
        '-c',
        r'cd "$1" && exec node .koffi-probe.cjs',
        'koffi-probe',
        probeDir,
      ], timeout: const Duration(seconds: 40));
      if (r.exitCode != 0 || !r.output.contains('koffi-ok')) {
        await _appendServiceLog(
          'koffi probe 失败 exit=${r.exitCode} out=${r.output}',
        );
      }
      return r.exitCode == 0 && r.output.contains('koffi-ok');
    } catch (e) {
      await _appendServiceLog('koffi probe 异常：$e');
      return false;
    }
  }

  Future<bool> _androidFullRuntimeReady() async {
    final nodePtyOk = await _androidNodePtyProbe();
    final koffiOk = await _androidKoffiProbe();
    final legacyPatch = await _androidLegacyPatchPresent();
    return nodePtyOk && koffiOk && !legacyPatch;
  }

  /// 只读检查 Android 完整运行环境，不安装工具链或重建原生模块。
  Future<bool> isFullAndroidRuntimeReady() async {
    if (!Platform.isAndroid) return true;
    if (!await _androidDshPackagePresent()) return false;
    return _androidFullRuntimeReady();
  }

  /// 在 dsh 包目录重建 koffi（Android 无 prebuild，源码编译）。
  /// Alpine rootfs 内 cmake/ninja 工具链正常，直接跑 koffi 自带构建脚本
  /// （cnoke.cjs），无需 Termux 时代的 ninja shim 手段。
  Future<bool> _rebuildAndroidKoffi() async {
    final dshDir = await _androidDshDir();
    if (await _androidKoffiProbe()) return true;
    statusMessage.value = '正在编译 FFI 支持（koffi，约 1-3 分钟）…';
    await _ensureNodeGypExecutable();
    final koffiDir = '$dshDir/node_modules/koffi';
    final usr = await TermuxRuntime.usrDir();
    final prootKoffiDir = '/usr/${koffiDir.substring(usr.length)}';
    final r = await _runCommand([
      'sh',
      '-c',
      r'cd "$1" && exec node cnoke.cjs -P . -D src/koffi --prebuild --release',
      'koffi-cnoke',
      prootKoffiDir,
    ], timeout: const Duration(minutes: 20));
    if (r.exitCode != 0) {
      final tail = npmErrorTail(r.output);
      statusMessage.value = 'koffi 重建失败：$tail';
      await _appendServiceLog('koffi 重建失败：$tail');
      await _appendServiceLog('koffi 重建完整输出：\n${_tailOutput(r.output, 6000)}');
      await _diagnoseNodeGyp();
      return false;
    }
    if (!await _androidKoffiProbe()) {
      statusMessage.value = 'koffi 已重建但加载验证失败，请查看日志';
      await _appendServiceLog('koffi 已重建但加载验证失败');
      return false;
    }
    return true;
  }

  /// 返回 true 表示执行了修复；环境已经健康时返回 false。
  Future<bool> repairFullAndroidRuntime() async {
    if (!Platform.isAndroid) return false;
    await TermuxRuntime.waitReady();
    if (await isFullAndroidRuntimeReady()) {
      statusMessage.value = '完整 DeepSeek Harness 环境已就绪，无需修复';
      return false;
    }
    final wasRunning = await isRunning();
    if (wasRunning) await stop();
    status.value = DshStatus.updating;
    statusMessage.value = '正在修复完整 DeepSeek Harness 运行环境…';
    progress.value = 0.08;
    installOutput.value = '';
    unawaited(
      _notifyDsh(
        title: 'DeepSeek Harness 完整模式修复中',
        body: '正在编译本地终端支持，完成后会再通知。',
      ),
    );
    try {
      _setStep(0.18, '正在检查编译工具链…');
      await _prepareAndroidFullRuntime(force: true);
      progress.value = 1;
      status.value = DshStatus.idle;
      statusMessage.value = '完整 DeepSeek Harness 环境已就绪';
      unawaited(
        _notifyDsh(
          title: 'DeepSeek Harness 完整模式修复完成',
          body: '本地终端支持已就绪，可重新启动服务。',
        ),
      );
      return true;
    } catch (e) {
      status.value = DshStatus.error;
      statusMessage.value = '完整模式修复失败：$e';
      await _appendServiceLog('完整模式修复失败：$e');
      unawaited(_notifyDsh(title: 'DeepSeek Harness 完整模式修复失败', body: '$e'));
      rethrow;
    }
  }

  /// 启动后把默认预设从旧 android 精简纠正回官方 standard。
  Future<void> _ensureOfficialDefaultPreset() async {
    try {
      final list = await DshApiClient.instance.listPresets();
      final current = list.presets.where((p) => p.isDefault).toList();
      if (current.isEmpty) {
        await DshApiClient.instance.setDefaultPreset('standard');
        return;
      }
      final preset = current.first;
      if (preset.id == 'android' ||
          preset.id.isEmpty ||
          preset.broken != null) {
        await DshApiClient.instance.setDefaultPreset('standard');
      }
    } catch (_) {}
  }

  /// 平台化启动命令：
  /// - Windows：直接执行（argv[0] 为可执行文件）
  /// - Android：经 init-host -c 在 Alpine rootfs 内执行（proot 启动链）
  Future<Process> _startCommand(
    List<String> argv, {
    String? workingDirectory,
    Map<String, String>? extraEnv,
  }) async {
    if (Platform.isAndroid) {
      final cmd = argv.map(_shellQuote).join(' ');
      final full = await TermuxRuntime.shellCommand(['-c', cmd]);
      final env = await TermuxRuntime.environment();
      if (extraEnv != null) env.addAll(extraEnv);
      return Process.start(
        full.first,
        full.sublist(1),
        environment: env,
        workingDirectory: workingDirectory,
      );
    }
    return Process.start(
      argv.first,
      argv.sublist(1),
      workingDirectory: workingDirectory,
    );
  }

  /// bash 单参数引号包装（Android init-host 命令拼接用）。
  static String _shellQuote(String s) {
    if (RegExp(r'^[\w@./:=-]+$').hasMatch(s)) return s;
    return "'${s.replaceAll("'", r"'\''")}'";
  }

  /// 判断 npm 输出是否为网络类错误（触发镜像重试）。
  static bool isNetworkError(String output) {
    final low = output.toLowerCase();
    const keys = <String>[
      'enotfound',
      'etimedout',
      'econnrefused',
      'econnreset',
      'eai_again',
      'enetunreach',
      'ehostunreach',
      'eproto',
      'epipe',
      'network',
      'sockettimeout',
      'socket hang',
      'timed out',
      'timeout',
      'tunneling',
      'proxy',
      'certificate',
      'cert_',
      'unable to get local issuer',
      'fetch failed',
      '503',
      '502',
      '504',
      '407',
    ];
    return keys.any(low.contains);
  }

  /// apk 装包文件用 hardlink 原子发布，无 root 设备被 SELinux 拦截时
  /// 只报 "N errors; ... MiB in N packages" 汇总，没有逐文件错误行。
  /// 这类失败重试只会重复下载同一批包，应直接走 tar 直解兜底。
  static bool _apkSelinuxBlocked(String output) {
    return output.contains('failed to rename') ||
        output.contains('Failed to create') ||
        RegExp(r'\d+ errors; [\d.]+ MiB in \d+ packages').hasMatch(output);
  }

  /// 抽出 npm 失败里真正有用的几行（丢掉 debug log 路径）。
  static String npmErrorTail(String output, [int max = 360]) {
    final lines = output
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .where((e) => !e.toLowerCase().contains('complete log of this run'))
        .toList();
    if (lines.isEmpty) return _tailOutput(output, max);
    final pick = lines.length <= 4 ? lines : lines.sublist(lines.length - 4);
    return _tailOutput(pick.join(' | '), max);
  }

  /// 追加 DSH 服务日志到智能体工作目录 logs/error.log。
  Future<void> _appendServiceLog(String message) async {
    try {
      final dir = await FileWorkspace.current();
      final file = File('$dir/logs/error.log');
      await file.create(recursive: true);
      final line =
          '[${DateTime.now().toIso8601String()}] [DshService] $message\n';
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志写入失败不影响主流程。
    }
  }

  Future<void> _installDshPackage(String version) async {
    final proxy = await _detectProxy();
    final installed = _localVersion ?? await localVersion();
    final sameVersion =
        installed != null &&
        installed.isNotEmpty &&
        compareSemver(installed, version) == 0;
    if (!sameVersion) {
      // 换版本才先卸旧包。同版本重装保留 node_modules，避免每次多等卸载。
      final preUninstall = await _runNpm([
        'uninstall',
        '-g',
        '@deepseek-ai/dsh',
        '--no-audit',
        '--no-fund',
      ]).timeout(const Duration(minutes: 3));
      if (preUninstall.exitCode != 0) {
        await _appendServiceLog(
          '安装前卸载旧 dsh 失败（忽略）：${npmErrorTail(preUninstall.output)}',
        );
      }
    }
    _npmExpectedFetches = _knownNpmPackageCounts[version] ?? 0;
    _resetPhaseOutput();
    final common = <String>[
      'install',
      '-g',
      '@deepseek-ai/dsh@$version',
      '--no-audit',
      '--no-fund',
      // 网络超时/重试防护：避免代理抖动或死源导致单次尝试卡死。
      // 实测（2026-08-16）：npm 慢不是带宽——单包 p50=254ms，
      // 但约 10% 请求长尾 20-256s（镜像 CDN 回源抖动）。fetch-timeout
      // 是"无进度超时"：设 300s 会让一个卡死的请求拖满 5 分钟×3 次重试，
      // 整体被长尾拖到 30-60 分钟。改 60s 无进度即放弃重试（重试通常
      // 命中 CDN 缓存反而快），maxsockets=32 让长尾不阻塞其他下载。
      '--fetch-timeout=60000',
      '--fetch-retries=3',
      '--fetch-retry-mintimeout=1000',
      '--fetch-retry-maxtimeout=10000',
      '--maxsockets=32',
      '--prefer-offline',
      // 必须 --ignore-scripts：dsh 依赖里 @google/genai 等带 preinstall 脚本，
      // 在 proot 里跑会 MODULE_NOT_FOUND 导致整体安装失败（实测）。node-pty
      // 的原生模块由 _prepareAndroidFullRuntime(force) 单独 npm rebuild 编译。
      if (Platform.isAndroid) '--ignore-scripts',
      // 非 TTY 下 npm 默认静默；http 级别才逐包输出，终端和进度才看得见。
      '--loglevel=http',
    ];
    final attempts = <(String, List<String>)>[
      if (Platform.isAndroid)
        ('npmmirror', [...common, '--registry=https://registry.npmmirror.com']),
      if (Platform.isAndroid)
        (
          'tencent',
          [...common, '--registry=https://mirrors.cloud.tencent.com/npm'],
        ),
      (
        'official',
        [
          ...common,
          if (proxy != null) '--proxy=${proxy.url}',
          if (proxy != null) '--https-proxy=${proxy.url}',
        ],
      ),
      if (Platform.isAndroid) ('official-direct', [...common]),
    ];
    String last = '';
    final sources = attempts.length;
    var index = 0;
    for (final attempt in attempts) {
      final start = 0.22 + 0.50 * (index / sources);
      _setStep(start, '正在从 ${attempt.$1} 安装 DeepSeek Harness $version …');
      final r = await _runNpm(attempt.$2);
      if (r.exitCode == 0) {
        _setStep(0.72, 'DeepSeek Harness $version 安装完成');
        return;
      }
      last = r.output;
      await _appendServiceLog(
        'npm 安装失败（${attempt.$1}）：\n${_tailOutput(r.output, 3000)}',
      );
      index++;
    }
    throw DshApiException('npm 安装失败：${npmErrorTail(last)}');
  }

  void _resetPhaseOutput() {
    _npmFetchedLines = 0;
    _phaseOutputBytes = 0;
    if (_phase != null) progress.value = _phase!.$1;
  }

  DateTime? _lastProgressAt;
  int _npmExpectedFetches = 0;
  int _npmFetchedLines = 0;
  int _phaseOutputBytes = 0;
  static final RegExp _npmFetchLine = RegExp(r'http fetch GET 200 ');

  void _onCommandChunk(
    String chunk,
    StringBuffer outBuf, {
    bool captureToInstall = true,
  }) {
    outBuf.write(chunk);
    if (_capturingOutput && captureToInstall) {
      _phaseOutputBytes += chunk.length;
      _npmFetchedLines += _npmFetchLine.allMatches(chunk).length;
      installOutput.value = mergeInstallOutput(installOutput.value, chunk);
    }
    _tickProgress();
  }

  void _tickProgress() {
    final now = DateTime.now();
    if (_lastProgressAt != null &&
        now.difference(_lastProgressAt!) < const Duration(milliseconds: 200)) {
      return;
    }
    _lastProgressAt = now;
    final phase = _phase;
    if (phase == null) return;
    final (start, end) = phase;
    // 阶段末留 2%：真正的阶段完成由下一次 _setPhase / 成功置 1 体现，
    // 避免下载输出过早把百分比推到段尾后“卡死”。
    final cap = end - 0.02;
    double next;
    if (_npmExpectedFetches > 0) {
      final ratio = (_npmFetchedLines / _npmExpectedFetches).clamp(0.0, 1.0);
      next = start + (cap - start) * ratio;
    } else {
      final frac = 1 - 1 / (1 + _phaseOutputBytes / 12000);
      next = start + (cap - start) * frac;
    }
    progress.value = next.clamp(start, cap);
    if (_capturingOutput &&
        (_lastNotifyAt == null ||
            now.difference(_lastNotifyAt!) >= const Duration(seconds: 2))) {
      _lastNotifyAt = now;
      unawaited(
        _notifyDsh(
          title: status.value == DshStatus.installing
              ? 'DeepSeek Harness 安装中'
              : 'DeepSeek Harness 更新中',
          body: '${statusMessage.value}（${(progress.value * 100).round()}%）',
          progress: progress.value,
        ),
      );
    }
  }

  /// 服务是否在运行（RPC 就绪探测，端口通了但 API 未初始化也算未就绪）。
  Future<bool> isRunning() => DshApiClient.instance.rpcPing();

  /// 连接失败 / 超时 / 假死：VPN 切换后 socket 仍 LISTEN 但握手失败（#113）。
  static bool looksUnreachable(Object error) {
    final s = '$error'.toLowerCase();
    return s.contains('不可达') ||
        s.contains('timeout') ||
        s.contains('timed out') ||
        s.contains('socketexception') ||
        s.contains('connection refused') ||
        s.contains('connection reset') ||
        s.contains('failed host lookup') ||
        s.contains('network is unreachable');
  }

  /// 已安装则拉起服务；已在跑则直接成功。未安装不自动 npm 安装。
  Future<bool> ensureRunning() async {
    if (await isRunning()) {
      status.value = DshStatus.running;
      return true;
    }
    if (!await isInstalled()) {
      status.value = DshStatus.error;
      statusMessage.value = 'DeepSeek Harness 尚未安装，请到 Agent 引擎页安装';
      return false;
    }
    await start();
    return isRunning();
  }

  /// 连接失败时自愈：杀掉旧进程并在当前网络环境下重启（#113 铁律）。
  Future<bool> recoverFromUnreachable() {
    final existing = _recovering;
    if (existing != null) {
      return existing.then((_) => isRunning());
    }
    final now = DateTime.now();
    if (_lastRecoverAt != null &&
        now.difference(_lastRecoverAt!) < const Duration(seconds: 12)) {
      return isRunning();
    }
    _lastRecoverAt = now;
    final done = () async {
      try {
        statusMessage.value = 'DeepSeek Harness 连接失败，正在重启服务…';
        await stop();
        await start();
      } finally {
        _recovering = null;
      }
    }();
    _recovering = done;
    return done.then((_) => isRunning());
  }

  /// API 调用失败且像服务不可达时，重启一次再重试。
  /// 默认不自动拉起服务：进入页面 / 读取类调用只透传错误，
  /// 由用户手动去 Agent 引擎页启动；主动写操作传 recover:true 才自愈重试。
  Future<T> withRecover<T>(
    Future<T> Function() action, {
    bool recover = false,
  }) async {
    try {
      return await action();
    } catch (e) {
      if (!recover || !looksUnreachable(e)) rethrow;
      final ok = await recoverFromUnreachable();
      if (!ok) rethrow;
      return action();
    }
  }

  Future<bool>? _startInFlight;

  /// 启动 DSH 服务（dsh web），轮询端口就绪；成功返回 true。
  /// Windows：dsh 命令后台进程；Android：proot 前台 exec 持有 node。
  /// 并发保护：同一时刻只允许一个启动流程，重复调用复用同一 Future。
  Future<bool> start() {
    final existing = _startInFlight;
    if (existing != null) return existing;
    final done = _start();
    _startInFlight = done;
    done.whenComplete(() => _startInFlight = null);
    return done;
  }

  Future<bool> _start() async {
    if (await isRunning()) {
      final searchChanged = await _ensureBuiltInSearchPlugin();
      if (Platform.isAndroid) {
        // 运行中也确保沙箱补丁：DSH 对 home 层 cordis.patch.yml 热重载，
        // 写盘后立即生效，无需重启服务。
        await _ensureAndroidSandboxPatch();
        final patched = await _patchAndroidDshHardlinks();
        final needsFull =
            !await _androidNodePtyProbe() || await _androidLegacyPatchPresent();
        if (patched || needsFull || searchChanged) {
          await stop();
        } else {
          status.value = DshStatus.running;
          statusMessage.value = 'DeepSeek Harness 已在运行';
          return true;
        }
      } else if (searchChanged) {
        await stop();
      } else {
        status.value = DshStatus.running;
        statusMessage.value = 'DeepSeek Harness 已在运行';
        return true;
      }
    }
    status.value = DshStatus.starting;
    statusMessage.value = '正在启动 DeepSeek Harness 服务…';
    progress.value = .04;
    installOutput.value = '';
    _appendRuntimeOutput(
      '== 启动 DeepSeek Harness ==\n'
      '准备运行环境与配置…\n',
    );
    // 冷启动路径也写沙箱补丁（运行中路径在上面 isRunning 分支已写）：
    // 无 bubblewrap/Landlock 的 Android 必须默认 danger-full-access，
    // 否则 bash/文件工具报 SANDBOX_UNAVAILABLE。
    if (Platform.isAndroid) await _ensureAndroidSandboxPatch();
    progress.value = .12;
    _appendRuntimeOutput('沙箱与权限配置已就绪。\n');
    await _ensureBuiltInSearchPlugin();
    try {
      // 工作目录 = 软件默认 agent 目录：dsh 的 cwd（host.describe）与
      // 文件入口默认位置都落在 agent 目录（Android: /storage/emulated/0/agent）。
      final agentDir = await FileWorkspace.ensure();
      final webLogFile = File('$agentDir/logs/dsh-web.log');
      await webLogFile.create(recursive: true);
      await webLogFile.writeAsString(
        '\n== ${DateTime.now().toIso8601String()} app start ==\n',
        mode: FileMode.append,
        flush: true,
      );
      progress.value = .2;
      _appendRuntimeOutput('工作目录：$agentDir\n');
      if (Platform.isAndroid) {
        // 完整模式前置：仅在探测到缺失时自动补齐（首次安装后 /
        // 手动「修复完整模式」走 force；普通启动不重建，避免打开 app
        // 就触发 apk/npm 大流量下载——用户明确要求安装必须手动触发）。
        await _prepareAndroidFullRuntime();
        progress.value = .32;
        _appendRuntimeOutput('Android 运行环境检查完成。\n');
        await _patchAndroidDshHardlinks();
        // Alpine rootfs 内前台 exec 启动 dsh（proot 持有 node 进程）：
        // 不能用 `nohup ... &` 后台——init-host 的 proot 退出时
        // --kill-on-exit 会清掉整个进程树（含后台 node），dsh 永远起不来。
        // 前台 exec 让 _serverProcess 持有 proot，stop() 杀 proot 即整树清理。
        // 必须 node --expose-internals：dsh 的 HMR 服务要求（loader.internal
        // 依赖 internal 模块，Android 无 node-addon-require-builtin 平台包）。
        // 路径经环境变量传入（init-host -c 单命令形态，避免位置参数错位）。
        final bin = await _dshBinPath();
        final env = await TermuxRuntime.environment();
        env.addAll({'SHIYI_AGENT_DIR': agentDir, 'SHIYI_DSH_BIN': bin});
        final full = await TermuxRuntime.shellCommand([
          '-c',
          'cd "\$SHIYI_AGENT_DIR" && exec node --expose-internals '
              '"\$SHIYI_DSH_BIN" web',
        ]);
        _serverProcess = await Process.start(
          full.first,
          full.sublist(1),
          environment: env,
        );
      } else {
        _serverProcess = await Process.start('dsh', [
          'web',
        ], workingDirectory: agentDir);
      }
      final serverProcess = _serverProcess!;
      _captureServerOutput(serverProcess, webLogFile);
      var serverExited = false;
      int? serverExitCode;
      unawaited(
        serverProcess.exitCode.then((code) {
          serverExited = true;
          serverExitCode = code;
          _appendRuntimeOutput('\n进程已退出，退出码：$code\n');
        }),
      );
      progress.value = .42;
      _appendRuntimeOutput('dsh web 已启动，正在等待 127.0.0.1:3080…\n');
      // 轮询就绪（500ms 间隔；dsh 冷启动真机实测约 4 分钟，超时放宽到
      // 5 分钟，避免服务还在初始化就被误判「启动超时」）。
      final readyStartedAt = DateTime.now();
      final readyDeadline = DateTime.now().add(const Duration(minutes: 5));
      while (DateTime.now().isBefore(readyDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (serverExited) {
          status.value = DshStatus.error;
          statusMessage.value =
              'DeepSeek Harness 启动失败（退出码 ${serverExitCode ?? -1}）';
          await _appendServiceLog(statusMessage.value);
          return false;
        }
        if (await isRunning()) {
          progress.value = 1;
          status.value = DshStatus.running;
          statusMessage.value = 'DeepSeek Harness 服务运行中（127.0.0.1:3080）';
          _appendRuntimeOutput('服务已就绪：http://127.0.0.1:3080\n');
          unawaited(_ensureOfficialDefaultPreset());
          return true;
        }
        final elapsed = DateTime.now().difference(readyStartedAt).inSeconds;
        progress.value = (.42 + elapsed / 300 * .5).clamp(.42, .92);
      }
      status.value = DshStatus.error;
      statusMessage.value = 'DeepSeek Harness 启动超时，请查看服务日志';
      _appendRuntimeOutput('\n启动超时，请查看 logs/dsh-web.log。\n');
      await _appendServiceLog('DeepSeek Harness 启动超时，请查看 logs/dsh-web.log');
      return false;
    } catch (e) {
      status.value = DshStatus.error;
      statusMessage.value = 'DeepSeek Harness 启动失败：$e';
      _appendRuntimeOutput('\n启动失败：$e\n');
      await _appendServiceLog('DeepSeek Harness 启动失败：$e');
      return false;
    }
  }

  /// Android：解析 dsh 的 bin.js 绝对路径（npm 全局安装位置）。
  Future<String> _dshBinPath() async {
    final p = '${await _androidDshDir()}/lib/bin.js';
    if (await File(p).exists()) return p;
    // 回退：dsh 命令软链解析。
    final r = await _runCommand([
      'readlink',
      '-f',
      'dsh',
    ]).timeout(const Duration(seconds: 15));
    final t = r.output.trim();
    if (t.isNotEmpty) return t;
    return p;
  }

  /// 停止 DSH 服务。
  Future<void> stop() async {
    status.value = DshStatus.stopping;
    statusMessage.value = '正在停止 DeepSeek Harness 服务…';
    if (Platform.isAndroid) {
      // rootfs 内 dsh 是 nohup 常驻：按进程名精确杀 node（不能用
      // `pkill -f 'dsh/lib/bin.js'`——proot 宿主命令行也含该串，会误杀
      // proot 并连带整个 rootfs 进程树）。
      try {
        await _runCommand(['pkill', '-x', 'node']);
      } catch (_) {}
    } else {
      final proc = _serverProcess;
      if (proc != null) {
        try {
          proc.kill();
        } catch (_) {}
        _serverProcess = null;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    status.value = DshStatus.idle;
    statusMessage.value = 'DeepSeek Harness 服务已停止';
  }

  /// 按设定比较两个 semver 版本（支持 rc 预发布：rc < 正式版）。
  static int compareSemver(String a, String b) {
    final pa = _parseSemver(a);
    final pb = _parseSemver(b);
    for (var i = 0; i < 3; i++) {
      if (pa.$1[i] != pb.$1[i]) return pa.$1[i].compareTo(pb.$1[i]);
    }
    final apre = pa.$2;
    final bpre = pb.$2;
    if (apre.isEmpty && bpre.isEmpty) return 0;
    if (apre.isEmpty) return 1; // 正式版 > 预发布
    if (bpre.isEmpty) return -1;
    final al = apre.split('.');
    final bl = bpre.split('.');
    final n = al.length < bl.length ? al.length : bl.length;
    for (var i = 0; i < n; i++) {
      final an = int.tryParse(al[i]);
      final bn = int.tryParse(bl[i]);
      if (an != null && bn != null) {
        if (an != bn) return an.compareTo(bn);
      } else {
        final cmp = al[i].compareTo(bl[i]);
        if (cmp != 0) return cmp;
      }
    }
    return al.length.compareTo(bl.length);
  }

  static (List<int>, String) _parseSemver(String v) {
    final s = v.trim().replaceFirst(RegExp('^v', caseSensitive: false), '');
    final dash = s.indexOf('-');
    final core = dash < 0 ? s : s.substring(0, dash);
    final pre = dash < 0 ? '' : s.substring(dash + 1);
    final parts = core.split('.');
    final nums = <int>[];
    for (final p in parts) {
      nums.add(int.tryParse(p) ?? 0);
    }
    while (nums.length < 3) {
      nums.add(0);
    }
    return (nums, pre);
  }
}
