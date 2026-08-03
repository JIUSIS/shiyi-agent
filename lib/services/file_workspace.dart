import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 智能体工作目录管理：
/// 默认在 SD 根目录创建 agent 文件夹，所有生成/调用的文件都放这里；
/// 用户也可以在「文件」页创建其他文件夹并切换为工作目录。
class FileWorkspace {
  static const String _prefKey = 'agent_workspace_path';

  /// 默认工作目录（SD 根目录下的 agent 文件夹）。
  static String get defaultWorkspacePath {
    if (Platform.isAndroid) return '/storage/emulated/0/agent';
    return '${Directory.systemTemp.path}/agent';
  }

  /// 当前工作目录（用户可自定义，未设置时用默认）。
  static Future<String> current() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved != null && saved.isNotEmpty) return saved;
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
}

