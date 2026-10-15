import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 文件访问权限管理：终端工具读写手机存储（/sdcard）需要系统授权。
class PermissionService {
  static const String _notifAskedKey = 'notification_permission_asked_v1';
  static const String _mediaAskedKey = 'media_permission_asked_v1';
  static const String _allFilesAskedKey = 'asked_all_files_access';

  /// App 启动时调用：请求媒体权限，并首次引导开启「所有文件访问权限」。
  ///
  /// **每一类权限只问一次**（问过就记 prefs）：授权完成后重开 App 不应该
  /// 再弹任何授权，也不应该再显示授权提示。没给到的权限由用户在设置页
  /// 手动补（[requestFullAccess]）。
  static Future<void> ensureOnLaunch() async {
    if (!Platform.isAndroid) return;
    SharedPreferences? prefs;
    try {
      // 通知权限必须最先申请：后面的「所有文件访问」会打开系统设置页，
      // app 一退后台，再弹的通知权限请求会被系统直接吞掉。
      // 「只问一次」的标记先落盘再请求：用户在授权流程中途杀掉 App，
      // 下次冷启动也不会再弹一遍授权。
      prefs = await SharedPreferences.getInstance();
      final notifAsked = prefs.getBool(_notifAskedKey) ?? false;
      if (!notifAsked) {
        await prefs.setBool(_notifAskedKey, true);
        final status = await Permission.notification.status;
        if (!status.isGranted && !status.isPermanentlyDenied) {
          await Permission.notification.request();
        }
      }

      // Android 13+ 自动走媒体权限，旧版本走存储权限。只问一次：
      // 用户拒绝过还每次冷启动重问，就是「授权完了还一直显示授权」。
      final mediaAsked = prefs.getBool(_mediaAskedKey) ?? false;
      if (!mediaAsked) {
        await prefs.setBool(_mediaAskedKey, true);
        await Permission.storage.request();
        await Permission.photos.request();
        await Permission.videos.request();
        await Permission.audio.request();
      }
    } catch (_) {}

    // 首次引导开启「所有文件访问权限」，让终端能浏览整个 /sdcard。
    try {
      if (prefs == null) return;
      final asked = prefs.getBool(_allFilesAskedKey) ?? false;
      if (!asked) {
        await prefs.setBool(_allFilesAskedKey, true);
        if (!await Permission.manageExternalStorage.isGranted) {
          await Permission.manageExternalStorage.request();
        }
      }
    } catch (_) {}
  }

  /// 设置页入口：重新请求全部文件访问权限（跳转系统授权页）。
  static Future<bool> requestFullAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      final status = await Permission.manageExternalStorage.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// 当前是否已获得全部文件访问权限。
  static Future<bool> isFullAccessGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.manageExternalStorage.isGranted;
    } catch (_) {
      return false;
    }
  }
}
