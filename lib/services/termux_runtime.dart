import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 内嵌 Termux 运行时：把 assets 里的 bootstrap 解压到应用私有目录，
/// 提供完整 Linux 环境（bash / apt / pkg），无需安装 Termux。
class TermuxRuntime {
  static const MethodChannel _channel = MethodChannel('shiyi/skillpack');

  static const String _assetPath = 'assets/termux/bootstrap-aarch64.zip';

  /// 环境版本号：bootstrap 内容/结构变更时递增，写进 .env_version 强制重新部署。
  static const String _envVersion = 'v12';

  /// 环境根目录（app 私有 files 目录下的固定 termux 目录，无版本后缀）。
  static Future<String> _baseDir() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/termux';
  }

  /// usr 目录（bootstrap 解压后的 PREFIX）。
  static Future<String> usrDir() async => '${await _baseDir()}/usr';

  static Future<String> shellPath() async => '${await usrDir()}/bin/bash';

  static Future<String> prefixDir() async => _baseDir();

  static Future<String> _versionFilePath() async =>
      '${await _baseDir()}/.env_version';

  /// 是否已安装且版本匹配（bash 存在 + 版本文件一致）。
  static Future<bool> isInstalled() async {
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

  /// 确保已安装：未安装则解压；无论是否已安装都执行运行时补丁（幂等）：
  /// 清理 bootstrap 残留脚本 + 生成 bin-shim 包装器 + 重写 termux-apt 动态版
  /// + 修复损坏链接 + 替换 etc 旧包名路径。
  static Future<void> ensureInstalled() async {
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

  /// 内嵌 Termux 的执行环境变量（run_terminal / 终端页每次执行都注入，
  /// 不依赖 profile —— 非登录 bash -c 不会加载 profile）。
  static Future<Map<String, String>> environment() async {
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
    };
  }

  /// termux-apt 动态版：shebang 用 /system/bin/sh，proot ARGS 补 /tmp 映射，
  /// 按命令名分发；proot 环境内 PATH 去掉 bin-shim（避免 apt-key 等内部命令
  /// 再次触发 proot 嵌套）；apt 失败时自动轮换国内镜像源。
  static const String _termuxAptScript = r'''#!/system/bin/sh
# termux-apt: run apt/pkg/dpkg through proot (dynamic prefix resolution)
# 第一个参数是要执行的命令名（由 bin-shim/proot-exec 或直接调用传入）。
SELF=$0
ROOTFS=$(dirname "$(dirname "$(dirname "$SELF")")")
mkdir -p "$ROOTFS/tmp" "$ROOTFS/cache" "$ROOTFS/usr/tmp"
export LD_LIBRARY_PATH=$ROOTFS/usr/lib
export PERL5LIB=$ROOTFS/usr/lib/perl5/site_perl/5.42.0/aarch64-android:$ROOTFS/usr/lib/perl5/site_perl/5.42.0:$ROOTFS/usr/lib/perl5/vendor_perl/5.42.0/aarch64-android:$ROOTFS/usr/lib/perl5/vendor_perl/5.42.0:$ROOTFS/usr/lib/perl5/5.42.0/aarch64-android:$ROOTFS/usr/lib/perl5/5.42.0
export PROOT_TMP_DIR=$ROOTFS/tmp
export PROOT_LOADER=$ROOTFS/usr/libexec/proot/loader
# proot 内 PATH 不含 bin-shim：避免 apt-key/apt-config 等内部命令嵌套拉起 proot。
export PATH=$ROOTFS/usr/bin:/system/bin
export HOME=$ROOTFS/home
ARGS="-r $ROOTFS -b /system:/system -b /vendor:/vendor -b /data:/data -b /dev:/dev -b /proc:/proc -b /sys:/sys -b /apex:/apex -b $ROOTFS:/data/data/com.termux/files -b $ROOTFS/cache:/data/data/com.termux/cache -b $ROOTFS/tmp:/tmp"
CMD="$1"; shift

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

cur_mirror() {
  grep -oE "https?://[^ /]*(/termux)?/apt/termux-main" $SRC_FILE 2>/dev/null | head -1
}

set_mirror() {
  printf 'deb %s stable main\n' "$1" > $SRC_FILE
}

# 执行一次 proot 命令。返回 0 = 正常结束（命令成功或失败都不轮换）；
# 返回 1 = 网络错误（触发镜像轮换）。RC 始终为命令真实退出码。
run_once() {
  OUT=$("$ROOTFS/usr/bin/proot" $ARGS -w / /usr/bin/$CMD "$@" 2>&1)
  RC=$?
  printf '%s\n' "$OUT"
  if printf '%s\n' "$OUT" | grep -qE "Failed to fetch|Could not resolve|Connection timed out|Temporary failure|Name or service not known|Err:|404 Not Found|does not have a Release file|Could not connect"; then
    return 1
  fi
  return 0
}

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
# 全部失败：恢复原源
set_mirror "$CUR"
exit $RC
''';

  /// bin-shim 通用包装器：按自身 basename 分发到 termux-apt。
  /// 注意：必须用 `basename "$0"`（不解析符号链接），否则链接名会丢失。
  static const String _prootExecScript = r'''#!/system/bin/sh
SELF=$0
ROOTFS=$(dirname "$(dirname "$SELF")")
CMD=$(basename "$SELF")
exec "$ROOTFS/usr/bin/termux-apt" "$CMD" "$@"
''';

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

  /// 生成/刷新 bin-shim：termux-apt 动态版 + 通用 proot-exec + 符号链接。
  static Future<void> _writeShims() async {
    final usr = await usrDir();
    final prefix = await prefixDir();
    File('$usr/bin/termux-apt').writeAsStringSync(_termuxAptScript);
    final shim = Directory('$prefix/bin-shim');
    shim.createSync(recursive: true);
    File('${shim.path}/proot-exec').writeAsStringSync(_prootExecScript);
    for (final name in _shimCommands) {
      final link = Link('${shim.path}/$name');
      if (!link.existsSync()) link.createSync('proot-exec');
    }
    try {
      await Process.run('/system/bin/chmod', [
        '755',
        '$usr/bin/termux-apt',
        '${shim.path}/proot-exec',
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
