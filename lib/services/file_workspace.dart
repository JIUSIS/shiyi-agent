import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 智能体工作目录管理：
/// Android 默认在 SD 根目录创建 agent 文件夹；
/// Windows 默认在本机「文档/agent」，不沿用 Android / 临时目录。
/// 用户也可以在「文件」页创建其他文件夹并切换为工作目录。
class FileWorkspace {
  static const String _prefKey = 'agent_workspace_path';

  /// 默认工作目录。Windows 用「文档\agent」，Android 用存储根下 agent。
  static String get defaultWorkspacePath => defaultWorkspacePathFrom(
    android: Platform.isAndroid,
    documentsDirectory: _windowsDocumentsDir(),
  );

  /// 纯函数，便于单测。
  static String defaultWorkspacePathFrom({
    required bool android,
    required String documentsDirectory,
  }) {
    if (android) return '/storage/emulated/0/agent';
    return p.join(documentsDirectory, 'agent');
  }

  static String _windowsDocumentsDir() {
    final profile = Platform.environment['USERPROFILE'] ?? '';
    if (profile.isNotEmpty) return p.join(profile, 'Documents');
    return p.join(Directory.systemTemp.path, 'Documents');
  }

  /// 旧版 Windows 默认 `%TEMP%\agent`：视为未自定义，改走文档目录。
  static bool isLegacyTempAgentPath(
    String path, {
    required String systemTempPath,
  }) {
    final a = p.normalize(path).replaceAll('/', '\\').toLowerCase();
    final b = p
        .normalize(p.join(systemTempPath, 'agent'))
        .replaceAll('/', '\\')
        .toLowerCase();
    return a == b;
  }

  /// 当前工作目录（用户可自定义，未设置时用默认）。
  static Future<String> current() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved != null && saved.isNotEmpty) {
        if (isLegacyTempAgentPath(
          saved,
          systemTempPath: Directory.systemTemp.path,
        )) {
          return defaultWorkspacePath;
        }
        return saved;
      }
    } catch (_) {}
    return defaultWorkspacePath;
  }

  /// 保存用户自定义工作目录。
  static Future<void> setPath(String path) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, path);
    } catch (_) {}
  }

  /// 确保目录存在（不存在则递归创建），返回目录路径。
  static Future<String> ensure() async {
    final dir = await current();
    try {
      Directory(dir).createSync(recursive: true);
    } catch (_) {}
    return dir;
  }

  /// 把外部文件复制到工作目录的 attachments/ 下并返回新路径，
  /// 让模型可以用 run_terminal 读取；复制失败返回 null。
  static Future<String?> copyToAttachments(
    String srcPath, {
    String? workspacePath,
  }) async {
    try {
      final selected = workspacePath?.trim() ?? '';
      final base = selected.isEmpty ? await current() : selected;
      final dir = Directory('$base/attachments');
      dir.createSync(recursive: true);
      final src = File(srcPath);
      if (!src.existsSync()) return null;
      final dest = '${dir.path}/${p.basename(srcPath)}';
      await src.copy(dest);
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// 把外部文件夹递归复制到工作目录的 attachments/ 下并返回新路径；
  /// 同名已存在或复制失败返回 null（避免覆盖已有内容）。
  static Future<String?> copyDirectoryToAttachments(String srcPath) async {
    try {
      final base = await current();
      final dir = Directory('$base/attachments');
      dir.createSync(recursive: true);
      final src = Directory(srcPath);
      if (!src.existsSync()) return null;
      final name = p.basename(srcPath);
      final dest = Directory('${dir.path}/$name');
      if (dest.existsSync()) return null;
      await _copyDirRecursive(src, dest);
      return dest.path;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _copyDirRecursive(Directory src, Directory dest) async {
    dest.createSync(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      if (e is Directory) {
        await _copyDirRecursive(
          e,
          Directory('${dest.path}/${p.basename(e.path)}'),
        );
      } else if (e is File) {
        await e.copy('${dest.path}/${p.basename(e.path)}');
      }
    }
  }
}
