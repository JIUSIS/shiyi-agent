import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 运行环境抽象：
/// - Android：内嵌 Termux 运行时（把 assets 里的 bootstrap 解压到应用私有
///   目录，提供完整 Linux 环境 bash / apt / pkg，无需安装 Termux）；
/// - Windows 桌面：PowerShell 7（pwsh，缺失时回退 cmd），无需安装。
class TermuxRuntime {
  static const MethodChannel _channel = MethodChannel('shiyi/skillpack');

  static const String _assetPath = 'assets/termux/bootstrap-aarch64.zip';

  /// 环境版本号：bootstrap 内容/结构变更时递增，写进 .env_version 强制重新部署。
  static const String _envVersion = 'v12';

  static bool get isWindows => Platform.isWindows;

  /// Windows shell 探测结果缓存：'pwsh' 或 'cmd'（null = 尚未探测）。
  static String? _windowsShell;

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
      if (kernel.contains('WSL2') ||
          kernel.contains('microsoft-standard')) {
        return 'wsl2';
      }
      if (kernel.toLowerCase().contains('microsoft')) return 'wsl1';
      return 'none';
    } catch (_) {
      return 'none';
    }
  }

  /// 纯函数：按用户设置与探测结果解析实际后端（便于单测）。
  /// [setting]：auto / pwsh / cmd / wsl2；[wsl]：wsl2 / wsl1 / none；
  /// [shell]：已探测的 Windows shell（pwsh / cmd）。
  /// 返回：wsl2 / pwsh / cmd。
  static String resolveBackendChoice(
    String setting,
    String wsl,
    String shell,
  ) {
    if (setting == 'pwsh' || setting == 'cmd') return setting;
    // auto 与显式 wsl2：WSL2 可用即用 WSL2，否则回退 Windows shell。
    return wsl == 'wsl2' ? 'wsl2' : shell;
  }

  /// Windows 上解析实际生效的终端后端（wsl2 / pwsh / cmd）。
  static Future<String> resolveWindowsBackend(String setting) async {
    if (!isWindows) {
      throw UnsupportedError('resolveWindowsBackend 仅支持 Windows 平台');
    }
    return resolveBackendChoice(
      setting,
      await wslVariant(),
      await windowsShell(),
    );
  }

  /// Windows 桌面 shell：优先 PowerShell 7（pwsh），缺失时回退 cmd。
  static Future<String> windowsShell() async {
    if (!isWindows) {
      throw UnsupportedError('windowsShell 仅支持 Windows 平台');
    }
    final cached = _windowsShell;
    if (cached != null) return cached;
    try {
      final probe = await Process.run(
        'pwsh',
        ['-NoProfile', '-NoLogo', '-Command', 'exit 0'],
      ).timeout(const Duration(seconds: 10));
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
  static Future<String> _baseDir() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/termux';
  }

  /// usr 目录（bootstrap 解压后的 PREFIX）。
  static Future<String> usrDir() async => '${await _baseDir()}/usr';

  static Future<String> shellPath() async {
    if (isWindows) return windowsShell();
    return '${await usrDir()}/bin/bash';
  }

  static Future<String> prefixDir() async => _baseDir();

  static Future<String> _versionFilePath() async =>
      '${await _baseDir()}/.env_version';

  /// 是否已安装且版本匹配（bash 存在 + 版本文件一致）。Windows 恒为 true。
  static Future<bool> isInstalled() async {
    if (isWindows) return true;
    try {
      if (!File(await shellPath()).existsSync()) return false;
      final vf = File(await _versionFilePath());
      if (!vf.existsSync()) return false;
      return (await vf.readAsString()).trim() == _envVersion;
    } catch (_) {
      return false;
    }
  }

  /// 解压 bootstrap 到私有目录（阻塞直到完成），失败抛异常。
  static Future<void> install() async {
    // bootstrap zip 条目相对 PREFIX（bin/、lib/...），解压目标即 usr 目录。
    final destDir = await usrDir();
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'extractTermux',
      {'assetPath': _assetPath, 'destDir': destDir},
    );
    if (res == null) throw Exception('bootstrap 解压失败');
    // 确保 home / tmp / cache 目录存在，并写入版本标记。
    final prefix = await prefixDir();
    Directory('$prefix/home').createSync(recursive: true);
    Directory('$destDir/tmp').createSync(recursive: true);
    Directory('$prefix/tmp').createSync(recursive: true);
    Directory('$prefix/cache').createSync(recursive: true);
    // apt/dpkg 运行必需的目录（空目录不随 tar/zip 保留，这里显式创建）。
    for (final d in const [
      'etc/apt/apt.conf.d',
      'etc/apt/preferences.d',
      'var/lib/dpkg/updates',
      'var/lib/apt/lists/partial',
      'var/cache/apt/archives/partial',
    ]) {
      Directory('$destDir/$d').createSync(recursive: true);
    }
    File(await _versionFilePath()).writeAsStringSync(_envVersion);
    // 重写 profile / home 配置：修正官方模板的 files/usr 错误路径，并固化全部 env。
    await _writeProfile();
  }

  /// 重写 usr/etc/profile 与 home 的 .profile/.bashrc。
  /// 官方 Termux 模板路径含 /files/usr（我们的结构是 usr 直接在根下），
  /// 且 env 需对登录 shell 也可用。
  static Future<void> _writeProfile() async {
    final usr = await usrDir();
    final prefix = await prefixDir();
    final cert = '$usr/etc/tls/cert.pem';
    final profile = '''
# shiyi agent termux profile
for i in $usr/etc/profile.d/*.sh; do
	if [ -r \$i ]; then
		. \$i
	fi
done
unset i

if [ "\$BASH" ]; then
	if [[ "\$-" == *"i"* ]]; then
		if [ -r $usr/etc/bash.bashrc ]; then
			. $usr/etc/bash.bashrc
		fi
		if [ -r $prefix/home/.bashrc ]; then
			. $prefix/home/.bashrc
		fi
	fi
fi

# --- shiyi agent env ---
export ROOTFS="$prefix"
export PREFIX="$usr"
export TERMUX__PREFIX="$usr"
export SHELL="$usr/bin/bash"
export LD_LIBRARY_PATH="$usr/lib"
export PYTHONHOME="$usr"
export CURL_CA_BUNDLE="$cert"
export SSL_CERT_FILE="$cert"
export PROOT_TMP_DIR="$prefix/tmp"
export PROOT_LOADER="$usr/libexec/proot/loader"
export TMPDIR="$prefix/tmp"
export PATH="$prefix/bin-shim:$usr/bin:$usr/bin/applets:/system/bin:/system/xbin"
''';
    File('$usr/etc/profile').writeAsStringSync(profile);
    final homeRc = 'export PATH="$usr/bin:\$PATH"\n';
    File('$prefix/home/.profile').writeAsStringSync(homeRc);
    File('$prefix/home/.bashrc').writeAsStringSync(homeRc);
  }

  /// 确保已安装：Windows 仅探测 pwsh/cmd 可用性；Android 未安装则解压，
  /// 且无论是否已安装都执行运行时补丁（幂等）：
  /// 清理 bootstrap 残留脚本 + 生成 bin-shim 包装器 + 重写 termux-apt 动态版
  /// + 修复损坏链接 + 替换 etc 旧包名路径。
  static Future<void> ensureInstalled() async {
    if (isWindows) {
      // Windows 无需安装 Termux：探测并缓存可用 shell。
      await windowsShell();
      return;
    }
    if (!await isInstalled()) {
      await install();
    }
    await _cleanBootstrapResidual();
    await _writeShims();
    await _fixBrokenLinks();
    await _fixEtcPaths();
    await _fixTermuxScripts();
    await _fixShebangs();
  }

  /// 重写 bin 下所有脚本 shebang：旧包名路径 → 当前 PREFIX。
  /// 覆盖新装的包（perl/gnupg 等带脚本的包），避免宿主直调 127。
  static Future<void> _fixShebangs() async {
    final usr = await usrDir();
    const oldPrefix = '/data/data/com.termux/files/usr/bin';
    final bin = Directory('$usr/bin');
    if (!bin.existsSync()) return;
    final targets = <File>[];
    for (final e in bin.listSync(followLinks: false)) {
      if (e is! File || e.lengthSync() > 1024 * 1024) continue;
      // 跳过 ELF 二进制（\x7fELF）。
      final raf = e.openSync(mode: FileMode.read);
      final head = raf.readSync(4);
      raf.closeSync();
      if (head.length == 4 && head[0] == 0x7F && head[1] == 0x45) continue;
      targets.add(e);
    }
    for (final f in targets) {
      try {
        final s = f.readAsStringSync();
        if (!s.startsWith('#!')) continue;
        // 只重写 shebang 前两行（shebang + perl env 包装），
        // 不全文替换——避免误改脚本正文里作为字符串的旧路径
        // （如 termux-apt 的 OLD 变量、文档注释等）。
        final lines = s.split('\n');
        var changed = false;
        for (var i = 0; i < lines.length && i < 2; i++) {
          if (lines[i].contains(oldPrefix)) {
            lines[i] = lines[i].replaceAll(oldPrefix, '$usr/bin');
            changed = true;
          }
        }
        if (changed) f.writeAsStringSync(lines.join('\n'));
      } catch (_) {}
    }
  }

  /// 修复 bootstrap 里指向旧包名绝对路径的损坏链接（改为相对链接）。
  static Future<void> _fixBrokenLinks() async {
    final usr = await usrDir();
    void rel(String dir, String link, String target) {
      final l = Link('$usr/$dir/$link');
      try {
        if (l.existsSync()) l.deleteSync();
        l.createSync(target);
      } catch (_) {}
    }

    rel('bin', 'bzcmp', 'bzdiff');
    rel('bin', 'bzless', 'bzmore');
    rel('bin', 'zipinfo', 'unzip');
    rel('bin', 'editor', '../etc/alternatives/editor');
    // alternatives/editor 需相对到 usr/bin/nano（多退一层）。
    rel('etc/alternatives', 'editor', '../../bin/nano');
  }

  /// 把 etc 下配置文件里硬编码的旧包名路径替换为当前 rootfs 路径，
  /// 并修复上一轮误产生的 usr/usr 双拼。
  static Future<void> _fixEtcPaths() async {
    final usr = await usrDir();
    final rootfs = await prefixDir();
    const oldPrefix = '/data/data/com.termux/files';
    for (final f in const [
      'etc/bash.bashrc',
      'etc/motd.sh',
      'etc/nanorc',
    ]) {
      final p = File('$usr/$f');
      try {
        if (!p.existsSync()) continue;
        var s = p.readAsStringSync();
        // 旧路径整体替换为 rootfs（原路径剩余 /usr/... 保留，不会双拼）。
        s = s.replaceAll(oldPrefix, rootfs);
        // 兜底修复上一轮用 PREFIX 替换造成的 usr/usr 双拼。
        s = s.replaceAll('$rootfs/usr/usr', '$rootfs/usr');
        if (s != p.readAsStringSync()) p.writeAsStringSync(s);
      } catch (_) {}
    }
  }

  /// 修复 termux 工具脚本：
  /// - termux-open / termux-open-url 重写为系统级 am start（app 无 TermuxOpenReceiver）；
  /// - termux-info 插件包名改当前包名；
  /// - lib 下 .pc/.la/.cmake 等文本文件的旧路径替换。
  static Future<void> _fixTermuxScripts() async {
    final usr = await usrDir();
    final rootfs = await prefixDir();

    // termux-open：系统级打开（文件转 file://，URL 原样）。
    const openScript = r'''#!/system/bin/sh
# shiyi 兼容实现：用系统 am start 打开文件/URL
FILE="$1"
case "$FILE" in
  http://*|https://*) ;;
  *)
    if [ -f "$FILE" ]; then
      FILE="file://$(realpath "$FILE")"
    fi ;;
esac
am start -a android.intent.action.VIEW -d "$FILE" >/dev/null 2>&1
''';
    const openUrlScript = r'''#!/system/bin/sh
am start -a android.intent.action.VIEW -d "$1" >/dev/null 2>&1
''';
    for (final e in const [
      ('bin/termux-open', openScript),
      ('bin/termux-open-url', openUrlScript),
    ]) {
      final p = File('$usr/${e.$1}');
      if (p.existsSync()) p.writeAsStringSync(e.$2);
    }

    // termux-info：插件包名前缀改当前包名。
    final info = File('$usr/bin/termux-info');
    if (info.existsSync()) {
      try {
        final s = info.readAsStringSync();
        final ns = s.replaceAll('"com.termux', '"com.shiyi.agent');
        if (ns != s) info.writeAsStringSync(ns);
      } catch (_) {}
    }

    // 删除污染 bin 目录的 typescript 残留（script 命令默认输出文件）。
    try {
      final ts = File('$usr/bin/typescript');
      if (ts.existsSync()) ts.deleteSync();
    } catch (_) {}

    // P0-1 缓解：bash 编译时硬编码的 SYS_BASHRC 是旧包名路径，读不到；
    // 在 home/.bashrc 里显式加载重写后的 bash.bashrc（交互 shell 生效）。
    try {
      final rc = File('$rootfs/home/.bashrc');
      final line =
          '\n# shiyi: load system bashrc from rewritten path\n'
          'if [ -f "\$PREFIX/etc/bash.bashrc" ]; then . "\$PREFIX/etc/bash.bashrc"; fi\n';
      if (!rc.existsSync()) {
        rc.writeAsStringSync('# ~/.bashrc\n$line');
      } else if (!rc.readAsStringSync().contains('etc/bash.bashrc')) {
        rc.writeAsStringSync('${rc.readAsStringSync()}\n$line');
      }
    } catch (_) {}

    // lib 下文本文件（.pc/.la/.cmake/.txt）批量替换旧路径。
    const oldPrefix = '/data/data/com.termux/files';
    final targets = <File>[];
    void walk(Directory d) {
      try {
        for (final e in d.listSync(followLinks: false)) {
          if (e is Directory) {
            walk(e);
          } else if (e is File) {
            final n = e.path.toLowerCase();
            if (n.endsWith('.pc') ||
                n.endsWith('.la') ||
                n.endsWith('.cmake') ||
                n.endsWith('.txt')) {
              if (e.lengthSync() < 200 * 1024) targets.add(e);
            }
          }
        }
      } catch (_) {}
    }

    walk(Directory('$usr/lib'));
    for (final f in targets) {
      try {
        final s = f.readAsStringSync();
        final ns = s.replaceAll(oldPrefix, rootfs);
        if (ns != s) f.writeAsStringSync(ns);
      } catch (_) {}
    }
  }

  /// 执行环境变量（run_terminal / 终端页每次执行都注入）。
  /// Android：内嵌 Termux 的完整环境（不依赖 profile ——
  /// 非登录 bash -c 不会加载 profile）；Windows：使用进程默认环境。
  static Future<Map<String, String>> environment() async {
    if (isWindows) {
      // Dart 的 environment 参数与父进程环境合并，空 map = 继承全部默认值。
      return const {};
    }
    final usr = await usrDir();
    final prefix = await prefixDir();
    final cert = '$usr/etc/tls/cert.pem';
    return {
      'HOME': '$prefix/home',
      'ROOTFS': prefix,
      'PREFIX': usr,
      'TERMUX__PREFIX': usr,
      'SHELL': '$usr/bin/bash',
      'PATH': '$prefix/bin-shim:$usr/bin:$usr/bin/applets:/system/bin:/system/xbin',
      'TMPDIR': '$prefix/tmp',
      'LD_LIBRARY_PATH': '$usr/lib',
      'PERL5LIB':
          '$usr/lib/perl5/site_perl/5.42.0/aarch64-android:$usr/lib/perl5/site_perl/5.42.0:$usr/lib/perl5/vendor_perl/5.42.0/aarch64-android:$usr/lib/perl5/vendor_perl/5.42.0:$usr/lib/perl5/5.42.0/aarch64-android:$usr/lib/perl5/5.42.0',
      'PYTHONHOME': usr,
      'CURL_CA_BUNDLE': cert,
      'SSL_CERT_FILE': cert,
      'PROOT_TMP_DIR': '$prefix/tmp',
      'PROOT_LOADER': '$usr/libexec/proot/loader',
      // 数据目录环境变量桥（与 bin-shim proot-run 双保险）：
      // figlet 字体 / man 手册 / groff 字体在宿主直跑时也能找到。
      'FIGLET_FONTDIR': '$usr/share/figlet',
      'MANPATH': '$usr/share/man',
      'GROFF_FONT_PATH':
          '$usr/share/groff/site-font:$usr/share/groff/font:$usr/share/groff/current/font',
    };
  }

  /// termux-apt 动态版：shebang 用 /system/bin/sh，proot ARGS 补 /tmp 映射，
  /// 按命令名分发；proot 环境内 PATH 去掉 bin-shim（避免 apt-key 等内部命令
  /// 再次触发 proot 嵌套）；apt 失败时自动轮换国内镜像源。
  static const String _termuxAptScript = r'''#!/system/bin/sh
# termux-apt: run apt/pkg/dpkg through proot (dynamic prefix resolution)
# 第一个参数是要执行的命令名（由 bin-shim/proot-exec 或直接调用传入）。
# ROOTFS/CMD 用纯 shell 参数展开解析（SELF 恒为 .../termux/usr/bin/termux-apt），
# 不用 dirname/basename：app 真实 PATH 里 usr/bin 在 /system/bin 前，
# 外部命令会解析到 termux 的 dirname，链接 libandroid-support.so 失败。
SELF=$0
ROOTFS=${SELF%/usr/bin/*}
CMD=$1
shift
# 立即 export LD_LIBRARY_PATH：脚本内所有 termux 命令（mkdir/grep/cat 等）
# 在 app 真实 PATH（usr/bin 在 /system/bin 前）下会解析到 termux 版本，
# 依赖 libandroid-support.so，必须先设库路径才能宿主直跑。
export LD_LIBRARY_PATH=$ROOTFS/usr/lib
mkdir -p "$ROOTFS/tmp" "$ROOTFS/cache" "$ROOTFS/usr/tmp"
export PERL5LIB=$ROOTFS/usr/lib/perl5/site_perl/5.42.0/aarch64-android:$ROOTFS/usr/lib/perl5/site_perl/5.42.0:$ROOTFS/usr/lib/perl5/vendor_perl/5.42.0/aarch64-android:$ROOTFS/usr/lib/perl5/vendor_perl/5.42.0:$ROOTFS/usr/lib/perl5/5.42.0/aarch64-android:$ROOTFS/usr/lib/perl5/5.42.0
export PROOT_TMP_DIR=$ROOTFS/tmp
export PROOT_LOADER=$ROOTFS/usr/libexec/proot/loader
# proot 内 PATH 不含 bin-shim：避免 apt-key/apt-config 等内部命令嵌套拉起 proot。
export PATH=$ROOTFS/usr/bin:/system/bin
export HOME=$ROOTFS/home
# bind 目标降一级到 com.termux（无 root 环境下 /data/data/com.termux 不存在
# 也无法创建，原 files 级别 bind 会静默失败导致 apt 判定"非 Debian 系统"）；
# proot 会为 /data/data 自动创建虚拟 com.termux 目录，配合 run_once 里
# 的 files -> / 软链，/data/data/com.termux/files/usr 编译前缀可正常解析。
ARGS="-r $ROOTFS -b /system:/system -b /vendor:/vendor -b /data:/data -b /dev:/dev -b /proc:/proc -b /sys:/sys -b /apex:/apex -b $ROOTFS:/data/data/com.termux -b $ROOTFS/cache:/data/data/com.termux/cache -b $ROOTFS/tmp:/tmp"

# 装包/更新后自动重写 bin 脚本 shebang（旧包名 → 当前包名），
# 否则新装包（perl/gnupg/cowsay 等带脚本的包）宿主直调全部 127。
fix_shebangs() {
  OLD=/data/data/com.termux/files/usr/bin
  NEW=$ROOTFS/usr/bin
  for f in "$NEW"/*; do
    [ -f "$f" ] || continue
    if head -1 "$f" | grep -q "$OLD"; then
      sed -i "1s|$OLD|$NEW|g; 2s|$OLD|$NEW|g" "$f"
    fi
  done
}
# 仅在管理类命令（install/update/upgrade/remove 等）后触发，避免每次扫描。
case " $* " in
  *" install "*|*" update "*|*" upgrade "*|*" remove "*|*" autoremove "*|*" reinstall "*)
    trap 'fix_shebangs' EXIT
    ;;
esac

# 镜像源列表（按优先级；apt 失败自动轮换）
MIRRORS="https://mirrors.tuna.tsinghua.edu.cn/apt/termux-main https://mirrors.nju.edu.cn/apt/termux-main https://mirrors.pku.edu.cn/apt/termux-main https://mirrors.ustc.edu.cn/apt/termux-main https://mirrors.hust.edu.cn/apt/termux-main https://mirrors.aliyun.com/termux/apt/termux-main https://packages.termux.dev/apt/termux-main"
SRC_FILE=$ROOTFS/usr/etc/apt/sources.list

# 放宽匹配：兼容自选的非标准镜像路径（如 .../applications/termux/termux-main），
# 避免 CUR 取空导致轮换跳过当前源、恢复时把自选源覆盖成列表首个。
cur_mirror() {
  grep -oE "https?://[^ /]+/.+termux-main" $SRC_FILE 2>/dev/null | head -1
}

set_mirror() {
  printf 'deb %s stable main\n' "$1" > $SRC_FILE
}

# 执行一次 proot 命令。返回 0 = 正常结束（命令成功或失败都不轮换）；
# 返回 1 = 网络错误（触发镜像轮换）。RC 始终为命令真实退出码。
run_once() {
  # 先建前缀软链 files -> /（幂等）：让 apt 编译前缀
  # /data/data/com.termux/files/usr 指向 proot 根 = termux rootfs。
  "$ROOTFS/usr/bin/proot" $ARGS -w / /usr/bin/sh -c 'ln -sfn / /data/data/com.termux/files' 2>/dev/null
  OUT=$("$ROOTFS/usr/bin/proot" $ARGS -w / /usr/bin/$CMD "$@" 2>&1)
  RC=$?
  printf '%s\n' "$OUT"
  # 命令成功直接返回，不做错误检测：否则 dpkg -l 表头的 "Err?" 会被
  # 宽泛的 Err: 模式误判成网络错误，导致每个命令重复执行 8 遍
  #（初始 1 + 7 个镜像轮换各 1 遍）并白打 7 次网络请求。
  [ $RC -eq 0 ] && return 0
  if printf '%s\n' "$OUT" | grep -qE "Failed to fetch|Could not resolve|Connection timed out|Temporary failure|Name or service not known|^E:|404 Not Found|does not have a Release file|Could not connect"; then
    return 1
  fi
  return 0
}

SRC_ORIG=$(cat $SRC_FILE 2>/dev/null)
CUR=$(cur_mirror)
if run_once "$@"; then
  exit $RC
fi
# 网络失败：轮换镜像源并重试一次
[ -n "$CUR" ] || CUR=$(echo $MIRRORS | awk '{print $1}')
for M in $MIRRORS; do
  [ "$M" = "$CUR" ] && continue
  set_mirror "$M"
  echo "[termux-apt] 镜像源不可达，已切换: $M" >&2
  if run_once "$@"; then
    exit $RC
  fi
done
# 全部失败：恢复原源（含非标准镜像，原样写回，不再覆盖成列表首个）
printf '%s\n' "$SRC_ORIG" > $SRC_FILE 2>/dev/null || set_mirror "$CUR"
exit $RC
''';

  /// bin-shim 通用包装器：按自身 basename 分发到 termux-apt。
  /// 注意：必须用 `basename "$0"`（不解析符号链接），否则链接名会丢失。
  static const String _prootExecScript = r'''#!/system/bin/sh
# 参数展开解析（不用 dirname/basename，避免 termux 外部命令链接失败，见 termux-apt 注释）
SELF=$0
ROOTFS=${SELF%/bin-shim/*}
CMD=${SELF##*/}
exec "$ROOTFS/usr/bin/termux-apt" "$CMD" "$@"
''';

  /// proot-run 通用包装：为「硬编码 $PREFIX 数据路径」的命令（figlet/man/vim 等）
  /// 提供 proot 前缀桥。不带镜像轮换，仅建 files 软链后执行真实命令。
  /// bin-shim 目录在 PATH 首位，白名单命令经它进 proot；proot 内 PATH
  /// 不含 bin-shim，杜绝递归拉起。ARGS 比 termux-apt 多绑外部存储，
  /// 让 proot 内可访问 /storage/emulated/0（工作目录语义一致）。
  static const String _prootRunScript = r'''#!/system/bin/sh
SELF=$0
ROOTFS=${SELF%/bin-shim/*}
CMD=${SELF##*/}
# 立即 export LD_LIBRARY_PATH（脚本内 termux 命令依赖 libandroid-support.so）。
export LD_LIBRARY_PATH=$ROOTFS/usr/lib
export PERL5LIB=$ROOTFS/usr/lib/perl5/site_perl/5.42.0/aarch64-android:$ROOTFS/usr/lib/perl5/site_perl/5.42.0:$ROOTFS/usr/lib/perl5/vendor_perl/5.42.0/aarch64-android:$ROOTFS/usr/lib/perl5/vendor_perl/5.42.0:$ROOTFS/usr/lib/perl5/5.42.0/aarch64-android:$ROOTFS/usr/lib/perl5/5.42.0
export PROOT_TMP_DIR=$ROOTFS/tmp
export PROOT_LOADER=$ROOTFS/usr/libexec/proot/loader
export PATH=$ROOTFS/usr/bin:/system/bin
export HOME=$ROOTFS/home
ARGS="-r $ROOTFS -b /system:/system -b /vendor:/vendor -b /data:/data -b /dev:/dev -b /proc:/proc -b /sys:/sys -b /apex:/apex -b /storage/emulated/0:/storage/emulated/0 -b $ROOTFS:/data/data/com.termux -b $ROOTFS/cache:/data/data/com.termux/cache -b $ROOTFS/tmp:/tmp"
# 建前缀软链（幂等）后执行真实命令；CMD 经位置参数传入内层 sh（$1），
# 避免单引号内变量不展开的问题。
"$ROOTFS/usr/bin/proot" $ARGS -w / /usr/bin/sh -c 'ln -sfn / /data/data/com.termux/files 2>/dev/null; exec /usr/bin/$1 "$@"' sh "$CMD" "$@"
''';

  /// 需要 proot 前缀桥的命令白名单（数据目录硬编码前缀；可增删）。
  static const List<String> _prootRunCmds = [
    'figlet', 'toilet', 'lolcat', 'cowsay', // 文本艺术类（字体/台词数据）
    'man', 'groff', 'troff', 'nroff', // 手册/排版（字体与宏包）
    'vim', 'nano', 'less', 'lynx', 'w3m', // 编辑器/浏览器（数据文件）
    'htop', 'screen', 'tmux', // 常用交互工具
  ];

  /// 需要走 proot 包装的管理命令（符号链接到 proot-exec）。
  static const List<String> _shimCommands = [
    'apt',
    'apt-get',
    'pkg',
    'dpkg',
    'dpkg-deb',
    'dpkg-query',
    'dpkg-split',
    'apt-key',
    'apt-cache',
    'apt-config',
    // setarch 系硬编码旧包名路径，只能在 proot 内跑（旧路径被绑定到 rootfs）。
    'setarch',
    'linux64',
    'uname26',
  ];

  /// 生成/刷新 bin-shim：termux-apt 动态版 + 通用 proot-exec/proot-run + 符号链接。
  static Future<void> _writeShims() async {
    final usr = await usrDir();
    final prefix = await prefixDir();
    File('$usr/bin/termux-apt').writeAsStringSync(_termuxAptScript);
    final shim = Directory('$prefix/bin-shim');
    shim.createSync(recursive: true);
    File('${shim.path}/proot-exec').writeAsStringSync(_prootExecScript);
    File('${shim.path}/proot-run').writeAsStringSync(_prootRunScript);
    for (final name in _shimCommands) {
      final link = Link('${shim.path}/$name');
      if (!link.existsSync()) link.createSync('proot-exec');
    }
    // 前缀桥白名单：仅当 usr/bin 下存在对应命令时才建链接，避免链到不存在的命令。
    for (final name in _prootRunCmds) {
      if (!File('$usr/bin/$name').existsSync()) continue;
      final link = Link('${shim.path}/$name');
      if (!link.existsSync()) link.createSync('proot-run');
    }
    try {
      await Process.run('/system/bin/chmod', [
        '755',
        '$usr/bin/termux-apt',
        '${shim.path}/proot-exec',
        '${shim.path}/proot-run',
      ]);
    } catch (_) {}
  }

  /// 清理 bootstrap 残留：硬编码官方路径的 second-stage/init 脚本。
  static Future<void> _cleanBootstrapResidual() async {
    final usr = await usrDir();
    for (final p in const [
      'etc/profile.d/01-termux-bootstrap-second-stage-fallback.sh',
      'etc/profile.d/init-termux-properties.sh',
    ]) {
      final f = File('$usr/$p');
      if (f.existsSync()) f.deleteSync();
    }
    final b = Directory('$usr/etc/termux/bootstrap');
    if (b.existsSync()) b.deleteSync(recursive: true);
  }
}
