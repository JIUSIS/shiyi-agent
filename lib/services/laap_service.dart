import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'laap_api.dart';
import 'termux_runtime.dart';

enum LaapStatus {
  idle,
  installing,
  starting,
  running,
  stopping,
  uninstalling,
  error,
}

/// LAAP 皮层本地服务：安装 / 启动 / 停止。
/// 不是第三套聊天引擎，只给活人感提供需求状态。
class LaapService {
  LaapService._();
  static final LaapService instance = LaapService._();

  static const port = 11546;
  static const _versionKey = 'laap_local_version';
  static const _readyName = '.shiyi-laap-ready';
  static const _zipUrl =
      'https://github.com/lorryjovens-hub/laap-AGI/archive/refs/heads/main.zip';
  static const _zipMirror =
      'https://ghproxy.net/https://github.com/lorryjovens-hub/laap-AGI/archive/refs/heads/main.zip';

  final ValueNotifier<LaapStatus> status = ValueNotifier<LaapStatus>(
    LaapStatus.idle,
  );
  final ValueNotifier<String> statusMessage = ValueNotifier<String>('');
  final ValueNotifier<double> progress = ValueNotifier<double>(0);
  final ValueNotifier<String> installOutput = ValueNotifier<String>('');

  Process? _serverProcess;
  Future<void>? _installInFlight;
  Future<bool>? _startInFlight;
  String? _localVersion;

  bool get _capturingOutput => status.value == LaapStatus.installing;

  Future<String> hostRoot() async {
    if (Platform.isAndroid) {
      return '${await TermuxRuntime.homeDir()}/.laap';
    }
    final userHome =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return '$userHome${Platform.pathSeparator}.laap';
  }

  Future<String> srcDir() async => '${await hostRoot()}${_sep}src';
  Future<String> stateDir() async => '${await hostRoot()}${_sep}state';
  static String get _sep => Platform.pathSeparator;

  /// Alpine 内路径（init-host 命令用）。Windows 不用。
  static const alpineSrc = '/root/.laap/src';
  static const alpineState = '/root/.laap/state';
  static const alpinePythonPath = '$alpineSrc:$alpineSrc/aris_brain';

  /// PYTHONPATH：源码根 + aris_brain（psi_jspace_bridge 在这里）。
  static String pythonPathFor(String src, {bool posix = true}) {
    final delim = posix ? ':' : ';';
    final sep = posix ? '/' : r'\';
    return '$src$delim$src${sep}aris_brain';
  }

  Future<String?> localVersion() async {
    if (_localVersion != null) return _localVersion;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_versionKey);
    if (stored != null && stored.isNotEmpty) {
      _localVersion = stored;
      return stored;
    }
    final marker = File('${await srcDir()}$_sep$_readyName');
    if (await marker.exists()) {
      final v = (await marker.readAsString()).trim();
      if (v.isNotEmpty) {
        _localVersion = v;
        await prefs.setString(_versionKey, v);
        return v;
      }
    }
    return null;
  }

  Future<bool> isInstalled() async {
    final src = Directory(await srcDir());
    final api = File('${await srcDir()}${_sep}laap_brain${_sep}api.py');
    return src.existsSync() && api.existsSync();
  }

  Future<bool> isRunning() => LaapApiClient.instance.health();

  Future<bool> isCortexReady() => LaapApiClient.instance.cortexReady();

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

  void _append(String chunk) {
    if (chunk.isEmpty) return;
    installOutput.value = mergeInstallOutput(installOutput.value, chunk);
  }

  void _setStep(double value, String message) {
    progress.value = value.clamp(0.0, 1.0);
    statusMessage.value = message;
    _append('\n== $message（${(value * 100).round()}%） ==\n');
  }

  Future<void> install() async {
    if (_installInFlight != null) {
      throw LaapApiException('LAAP 安装已在进行中');
    }
    final gate = Completer<void>();
    _installInFlight = gate.future;
    try {
      await _installInner();
    } finally {
      _installInFlight = null;
      gate.complete();
    }
  }

  Future<void> _installInner() async {
    if (await isRunning()) await stop();
    status.value = LaapStatus.installing;
    statusMessage.value = '正在安装 LAAP 认知皮层…';
    progress.value = 0;
    installOutput.value = '';
    try {
      if (Platform.isAndroid) {
        _setStep(0.08, '正在准备 Android 运行环境…');
        await TermuxRuntime.waitReady();
        _setStep(0.16, '正在安装 Python…');
        await _ensurePython();
      } else {
        _setStep(0.12, '正在检查本机 Python…');
        await _ensurePython();
      }
      _setStep(0.28, '正在下载 laap-MAX…');
      final zipPath = await _downloadZip();
      _setStep(0.55, '正在解压源码…');
      await _extractZip(zipPath);
      _setStep(0.72, '正在安装 Python 依赖…');
      await _installPythonDeps();
      final version = 'laap-MAX-main';
      final marker = File('${await srcDir()}$_sep$_readyName');
      await marker.writeAsString(version);
      _localVersion = version;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_versionKey, version);
      status.value = LaapStatus.idle;
      statusMessage.value = 'LAAP 认知皮层已就绪，正在自动启动…';
      progress.value = 1;
      unawaited(
        start().then((started) {
          statusMessage.value = started
              ? 'LAAP 认知皮层已就绪，服务已启动'
              : 'LAAP 已安装，服务启动失败，请手动启动';
        }),
      );
    } catch (e) {
      status.value = LaapStatus.error;
      statusMessage.value = '$e';
      rethrow;
    }
  }

  Future<void> _ensurePython() async {
    if (Platform.isAndroid) {
      final probe = await _runCommand(const [
        'sh',
        '-c',
        'python3 --version && python3 -c "import numpy"',
      ]);
      if (probe.exitCode == 0) {
        _append('${probe.output}\n');
        return;
      }
      final apk = await _runCommand(const [
        'apk',
        'add',
        '--no-cache',
        'python3',
        'py3-pip',
        'py3-numpy',
        'py3-yaml',
        'py3-requests',
      ], timeout: const Duration(minutes: 4));
      if (apk.exitCode != 0) {
        throw LaapApiException('安装 Python 失败：${apk.output}');
      }
      final verify = await _runCommand(const [
        'sh',
        '-c',
        'python3 --version && python3 -c "import numpy"',
      ]);
      if (verify.exitCode != 0) {
        throw LaapApiException('Python/numpy 不可用：${verify.output}');
      }
      _append('${verify.output}\n');
      return;
    }
    final py = await _windowsPython();
    if (py == null) {
      throw LaapApiException('未找到 Python 3.11+，请先安装后再装 LAAP');
    }
    _append('Python：$py\n');
    final numpy = await Process.run(py, ['-c', 'import numpy']);
    if (numpy.exitCode != 0) {
      final pip = await Process.run(py, [
        '-m',
        'pip',
        'install',
        '--disable-pip-version-check',
        'numpy>=1.24,<3',
      ]);
      _append('${pip.stdout}${pip.stderr}');
      if (pip.exitCode != 0) {
        throw LaapApiException('安装 numpy 失败');
      }
    }
  }

  Future<String?> _windowsPython() async {
    for (final cmd in const [
      ['python', '--version'],
      ['python3', '--version'],
      ['py', '-3', '--version'],
    ]) {
      try {
        final r = await Process.run(cmd.first, cmd.sublist(1));
        final out = '${r.stdout}${r.stderr}';
        if (r.exitCode == 0 && out.contains('Python 3.')) {
          final m = RegExp(r'Python 3\.(\d+)').firstMatch(out);
          final minor = int.tryParse(m?.group(1) ?? '') ?? 0;
          if (minor >= 11) return cmd.first;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String> _downloadZip() async {
    final root = Directory(await hostRoot());
    await root.create(recursive: true);
    final zipPath = '${root.path}${_sep}src.zip';
    final bytes =
        await _httpGetBytes(_zipUrl) ?? await _httpGetBytes(_zipMirror);
    if (bytes == null || bytes.isEmpty) {
      throw LaapApiException('下载 laap-MAX 失败，请检查网络后重试');
    }
    await File(zipPath).writeAsBytes(bytes, flush: true);
    _append('已下载 ${(bytes.length / 1048576).toStringAsFixed(1)} MB\n');
    return zipPath;
  }

  Future<List<int>?> _httpGetBytes(String url) async {
    try {
      _append('GET $url\n');
      final resp = await http
          .get(Uri.parse(url))
          .timeout(const Duration(minutes: 4));
      if (resp.statusCode != 200) {
        _append('HTTP ${resp.statusCode}\n');
        return null;
      }
      return resp.bodyBytes;
    } catch (e) {
      _append('下载失败：$e\n');
      return null;
    }
  }

  Future<void> _extractZip(String zipPath) async {
    final bytes = await File(zipPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final dest = Directory(await srcDir());
    if (dest.existsSync()) {
      dest.deleteSync(recursive: true);
    }
    dest.createSync(recursive: true);
    var strip = '';
    for (final item in archive) {
      final name = item.name.replaceAll('\\', '/');
      if (name.endsWith('laap_brain/api.py')) {
        final idx = name.indexOf('laap_brain/api.py');
        strip = name.substring(0, idx);
        break;
      }
    }
    for (final item in archive) {
      var name = item.name.replaceAll('\\', '/');
      if (strip.isNotEmpty && name.startsWith(strip)) {
        name = name.substring(strip.length);
      }
      if (name.isEmpty || name.endsWith('/')) continue;
      if (name.contains('..')) continue;
      final out = File('${dest.path}$_sep${name.replaceAll('/', _sep)}');
      await out.parent.create(recursive: true);
      if (item.isFile) {
        await out.writeAsBytes(item.content as List<int>);
      }
    }
    final api = File('${dest.path}${_sep}laap_brain${_sep}api.py');
    if (!api.existsSync()) {
      throw LaapApiException('解压后找不到 laap_brain/api.py');
    }
  }

  Future<void> _installPythonDeps() async {
    const pkgs = [
      'aiohttp>=3.9.0,<4',
      'pyyaml>=6.0,<7',
      'python-dotenv>=1.0,<2',
      'psutil>=5.9,<8',
      'requests>=2.31.0',
      'numpy>=1.24,<3',
    ];
    if (Platform.isAndroid) {
      final r = await _runCommand([
        'python3',
        '-m',
        'pip',
        'install',
        '--disable-pip-version-check',
        '--break-system-packages',
        ...pkgs,
      ], timeout: const Duration(minutes: 6));
      if (r.exitCode != 0) {
        throw LaapApiException('pip 安装失败：${r.output}');
      }
      return;
    }
    final py = await _windowsPython();
    final r = await Process.run(py!, [
      '-m',
      'pip',
      'install',
      '--disable-pip-version-check',
      ...pkgs,
    ]);
    _append('${r.stdout}${r.stderr}');
    if (r.exitCode != 0) {
      throw LaapApiException('pip 安装失败');
    }
  }

  Future<bool> start() {
    final existing = _startInFlight;
    if (existing != null) return existing;
    final done = _start();
    _startInFlight = done;
    done.whenComplete(() => _startInFlight = null);
    return done;
  }

  Future<bool> _start() async {
    if (!await isInstalled()) {
      status.value = LaapStatus.error;
      statusMessage.value = 'LAAP 未安装';
      return false;
    }
    try {
      await _ensurePython();
    } catch (e) {
      status.value = LaapStatus.error;
      statusMessage.value = '$e';
      return false;
    }
    if (await isRunning()) {
      if (await isCortexReady()) {
        status.value = LaapStatus.running;
        statusMessage.value = 'LAAP 认知皮层已在运行';
        return true;
      }
      await stop();
    }
    status.value = LaapStatus.starting;
    statusMessage.value = '正在启动 LAAP 认知皮层…';
    progress.value = 0.2;
    installOutput.value = mergeInstallOutput(
      installOutput.value,
      '\n== 启动 LAAP :$port ==\n',
    );
    await Directory(await stateDir()).create(recursive: true);
    if (Platform.isAndroid) {
      final env = await TermuxRuntime.environment();
      env.addAll({
        'LAAP_ROOT': alpineSrc,
        'ARIS_BRAIN_ROOT': '$alpineSrc/aris_brain',
        'LAAP_STATE_DIR': alpineState,
        'PYTHONPATH': alpinePythonPath,
        'LAAP_PORT': '$port',
      });
      const script =
          'mkdir -p "$alpineState" && cd "$alpineSrc" && '
          'export LAAP_ROOT="$alpineSrc" ARIS_BRAIN_ROOT="$alpineSrc/aris_brain" '
          'LAAP_STATE_DIR="$alpineState" PYTHONPATH="$alpinePythonPath" && '
          'exec python3 -m laap_brain.api --port $port';
      final full = await TermuxRuntime.shellCommand(['-c', script]);
      _serverProcess = await Process.start(
        full.first,
        full.sublist(1),
        environment: env,
      );
    } else {
      final py = await _windowsPython();
      if (py == null) {
        status.value = LaapStatus.error;
        statusMessage.value = '未找到 Python 3.11+';
        return false;
      }
      final src = await srcDir();
      final state = await stateDir();
      _serverProcess = await Process.start(
        py,
        ['-m', 'laap_brain.api', '--port', '$port'],
        workingDirectory: src,
        environment: {
          ...Platform.environment,
          'LAAP_ROOT': src,
          'ARIS_BRAIN_ROOT': '$src${_sep}aris_brain',
          'LAAP_STATE_DIR': state,
          'PYTHONPATH': pythonPathFor(src, posix: false),
          'LAAP_PORT': '$port',
        },
      );
    }
    final proc = _serverProcess!;
    proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_append);
    proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_append);
    var exited = false;
    unawaited(
      proc.exitCode.then((code) {
        exited = true;
        _append('\n进程已退出，退出码：$code\n');
      }),
    );
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (exited) {
        status.value = LaapStatus.error;
        statusMessage.value = 'LAAP 启动失败，进程已退出';
        return false;
      }
      if (await isRunning()) {
        if (await isCortexReady()) {
          status.value = LaapStatus.running;
          statusMessage.value = 'LAAP 认知皮层运行中（127.0.0.1:$port）';
          progress.value = 1;
          return true;
        }
      }
    }
    status.value = LaapStatus.error;
    statusMessage.value = 'LAAP 启动超时（进程在但皮层未就绪）';
    return false;
  }

  Future<void> stop() async {
    status.value = LaapStatus.stopping;
    statusMessage.value = '正在停止 LAAP…';
    final proc = _serverProcess;
    if (proc != null) {
      try {
        proc.kill();
      } catch (_) {}
      _serverProcess = null;
    }
    if (Platform.isAndroid) {
      try {
        await _runCommand(const [
          'sh',
          '-c',
          'pkill -f laap_brain.api || true',
        ], captureToInstall: false);
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    status.value = LaapStatus.idle;
    statusMessage.value = 'LAAP 已停止';
  }

  Future<void> uninstall() async {
    if (await isRunning()) await stop();
    status.value = LaapStatus.uninstalling;
    statusMessage.value = '正在卸载 LAAP 源码（保留状态目录）…';
    final src = Directory(await srcDir());
    if (src.existsSync()) {
      src.deleteSync(recursive: true);
    }
    final zip = File('${await hostRoot()}${_sep}src.zip');
    if (zip.existsSync()) zip.deleteSync();
    _localVersion = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_versionKey);
    status.value = LaapStatus.idle;
    statusMessage.value = 'LAAP 已卸载，状态目录已保留';
  }

  Future<({int exitCode, String output})> _runCommand(
    List<String> argv, {
    Duration timeout = const Duration(minutes: 10),
    bool captureToInstall = true,
  }) async {
    if (_capturingOutput && captureToInstall) {
      _append('\n> ${argv.join(' ')}\n');
    }
    late final Process proc;
    if (Platform.isAndroid) {
      final cmd = argv.map(_shellQuote).join(' ');
      final full = await TermuxRuntime.shellCommand(['-c', cmd]);
      final env = await TermuxRuntime.environment();
      proc = await Process.start(full.first, full.sublist(1), environment: env);
    } else {
      proc = await Process.start(argv.first, argv.sublist(1));
    }
    final outBuf = StringBuffer();
    proc.stdout.transform(utf8.decoder).listen((chunk) {
      outBuf.write(chunk);
      if (captureToInstall) _append(chunk);
    });
    proc.stderr.transform(utf8.decoder).listen((chunk) {
      outBuf.write(chunk);
      if (captureToInstall) _append(chunk);
    });
    final code = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        proc.kill();
        return -1;
      },
    );
    return (exitCode: code, output: outBuf.toString().trim());
  }

  static String _shellQuote(String s) {
    if (RegExp(r'^[\w@./:=-]+$').hasMatch(s)) return s;
    return "'${s.replaceAll("'", r"'\''")}'";
  }
}
