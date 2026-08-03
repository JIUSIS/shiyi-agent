import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 内嵌 Termux 运行时：把 assets 里的 bootstrap 解压到应用私有目录，
/// 提供完整 Linux 环境（bash / apt / pkg），无需安装 Termux。
class TermuxRuntime {
  static const MethodChannel _channel = MethodChannel('shiyi/skillpack');

  static const String _assetPath = 'assets/termux/bootstrap-aarch64.zip';

  /// 环境版本号：bootstrap 内容/结构变更时递增，写进 .env_version 强制重新部署。
  static const String _envVersion = 'v8';

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
    File(await _versionFilePath()).writeAsStringSync(_envVersion);
  }

  /// 确保已安装：未安装则解压，失败抛异常。
  static Future<void> ensureInstalled() async {
    if (await isInstalled()) return;
    await install();
  }

  /// 内嵌 Termux 的执行环境变量。
  static Future<Map<String, String>> environment() async {
    final usr = await usrDir();
    final prefix = await prefixDir();
    return {
      'HOME': '$prefix/home',
      'PREFIX': usr,
      'PATH': '$usr/bin:$usr/bin/applets:/system/bin:/system/xbin',
      'TMPDIR': '$usr/tmp',
      'LD_LIBRARY_PATH': '$usr/lib',
    };
  }
}
