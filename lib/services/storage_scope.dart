import 'dart:io';

/// SD 卡可见范围与「往上走要不要 Root」的纯规则。
/// Android 无 root 只能在 SD 根目录及以下；离开这棵树必须先拿到 Root。
class StorageScope {
  static const androidSdRoots = <String>[
    '/storage/emulated/0',
    '/sdcard',
    '/storage/self/primary',
  ];

  static String normalize(String path) {
    var s = path.trim().replaceAll('\\', '/');
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static bool isFilesystemRoot(String path) {
    final n = normalize(path);
    if (n.isEmpty || n == '/') return true;
    return RegExp(r'^[a-zA-Z]:$').hasMatch(n);
  }

  /// 是否仍在 SD 卡树内（含 SD 根本身）。非 Android 一律视为「在范围内」。
  static bool isWithinSdRoot(String path, {bool android = true}) {
    if (!android) return true;
    final n = normalize(path);
    for (final root in androidSdRoots) {
      if (n == root || n.startsWith('$root/')) return true;
    }
    return false;
  }

  static String parentOf(String path) {
    final n = normalize(path);
    if (isFilesystemRoot(n)) return n;
    final i = n.lastIndexOf('/');
    if (i <= 0) return '/';
    return n.substring(0, i);
  }

  /// Android 上 /storage/emulated 即使 root 也只能穿过、不能 ls。
  /// 从 SD 根再往上，直接跳到可列出的 /storage。
  static const unlistableDirs = <String>{'/storage/emulated'};

  static const _sdUpTarget = '/storage';

  /// 文件页「上一级」用的可见父目录（跳过不可列出的中间层）。
  static String visibleParent(String path, {bool android = true}) {
    final n = normalize(path);
    if (android && androidSdRoots.contains(n)) return _sdUpTarget;
    var p = parentOf(n);
    if (android) {
      while (unlistableDirs.contains(p) && !isFilesystemRoot(p)) {
        p = parentOf(p);
      }
    }
    return p;
  }

  /// 点进不可列出的目录时，落到其中已知的可列子路径。
  static String resolveListable(String path, {bool android = true}) {
    final n = normalize(path);
    if (android && n == '/storage/emulated') return '/storage/emulated/0';
    return n;
  }

  /// 从 [from] 走到 [to] 是否离开 SD 树。
  static bool leavesSdRoot(String from, String to, {bool android = true}) {
    return isWithinSdRoot(from, android: android) &&
        !isWithinSdRoot(to, android: android);
  }
}

/// Magisk / KernelSU 等：跑一次 `su -c id` 会弹出授权框。
class RootAccess {
  static bool? granted;

  static const _suCandidates = <String>[
    'su',
    '/product/bin/su',
    '/system/bin/su',
    '/system/xbin/su',
    '/sbin/su',
  ];
  static String? _suBin;

  static Future<bool> request() async {
    if (!Platform.isAndroid) return false;
    if (granted == true) return true;
    try {
      final r = await _su('id');
      final out = '${r.stdout}${r.stderr}';
      granted = r.exitCode == 0 && out.contains('uid=0');
    } catch (_) {
      granted = false;
    }
    return granted == true;
  }

  /// 解析 `ls -1F` / `ls -1p` / `ls -l` 输出，分辨目录与文件。
  static List<({String name, bool isDir})> parseListing(String stdout) {
    final out = <({String name, bool isDir})>[];
    for (final raw in stdout.split('\n')) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') continue;
      if (RegExp(r'^total\s+\d+\s*$').hasMatch(trimmed)) continue;

      // ls -l：首字符 d/-/l
      if (trimmed.length > 20 &&
          RegExp(r'^[-dlcbps][-r][-w][-xsS]').hasMatch(trimmed)) {
        var name = trimmed;
        final arrow = name.indexOf(' -> ');
        if (arrow > 0) name = name.substring(0, arrow);
        final parts = name.split(RegExp(r'\s+'));
        if (parts.length >= 8) {
          final entry = parts.sublist(7).join(' ');
          if (entry.isNotEmpty && entry != '.' && entry != '..') {
            out.add((name: entry, isDir: trimmed.startsWith('d')));
          }
          continue;
        }
      }

      // ls -1F / ls -1p：目录名带 /
      var name = trimmed;
      var isDir = false;
      if (name.endsWith('/')) {
        isDir = true;
        name = name.substring(0, name.length - 1);
      } else if (name.endsWith('*') ||
          name.endsWith('@') ||
          name.endsWith('|') ||
          name.endsWith('=')) {
        name = name.substring(0, name.length - 1);
      }
      if (name.isEmpty || name == '.' || name == '..') continue;
      out.add((name: name, isDir: isDir));
    }
    return out;
  }

  static Future<List<FileSystemEntity>> list(String path) async {
    final n = StorageScope.resolveListable(path);
    final quoted = _shQuote(n);
    var r = await _su('ls -1F $quoted');
    if (r.exitCode != 0) {
      r = await _su('ls -lp $quoted');
    }
    if (r.exitCode != 0) {
      r = await _su('ls -l $quoted');
    }
    if (r.exitCode != 0) {
      final err = '${r.stderr}${r.stdout}'.trim();
      throw FileSystemException('Root 读取目录失败：$err', n);
    }
    final out = <FileSystemEntity>[];
    for (final e in parseListing(r.stdout.toString())) {
      final child = n == '/' ? '/${e.name}' : '$n/${e.name}';
      out.add(e.isDir ? Directory(child) : File(child));
    }
    out.sort((a, b) {
      final ad = a is Directory ? 0 : 1;
      final bd = b is Directory ? 0 : 1;
      if (ad != bd) return ad - bd;
      return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });
    return out;
  }

  static Future<String> readString(String path, {int maxBytes = 512 * 1024}) async {
    final n = StorageScope.normalize(path);
    final quoted = _shQuote(n);
    final sizeR = await _su('wc -c < $quoted');
    final size = int.tryParse(sizeR.stdout.toString().trim()) ?? 0;
    if (size > maxBytes) {
      return '(文件过大，超过 ${maxBytes ~/ 1024}KB，无法预览)';
    }
    final r = await _su('cat $quoted');
    if (r.exitCode != 0) {
      throw FileSystemException('Root 读取失败：${r.stderr}'.trim(), n);
    }
    return r.stdout.toString();
  }

  static Future<void> createDir(String path) async {
    final r = await _su('mkdir -p ${_shQuote(StorageScope.normalize(path))}');
    if (r.exitCode != 0) {
      throw FileSystemException('Root 创建失败：${r.stderr}'.trim(), path);
    }
  }

  static Future<void> delete(String path, {required bool recursive}) async {
    final flag = recursive ? '-rf' : '-f';
    final r = await _su('rm $flag ${_shQuote(StorageScope.normalize(path))}');
    if (r.exitCode != 0) {
      throw FileSystemException('Root 删除失败：${r.stderr}'.trim(), path);
    }
  }

  static String _shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  static Future<ProcessResult> _su(String script) async {
    final bins = <String>[
      ?_suBin,
      ..._suCandidates,
    ];
    Object? last;
    for (final bin in bins) {
      try {
        final r = await Process.run(bin, ['-c', script])
            .timeout(const Duration(seconds: 20));
        _suBin = bin;
        return r;
      } catch (e) {
        last = e;
      }
    }
    throw FileSystemException('无法执行 su：$last');
  }
}
