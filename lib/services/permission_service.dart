import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 文件访问权限管理：终端工具读写手机存储（/sdcard）需要系统授权。
class PermissionService {
  static const String _notifAskedKey = 'notification_permission_asked_v1';

  /// App 启动时调用：请求媒体权限，并首次引导开启「所有文件访问权限」。
  static Future<void> ensureOnLaunch() async {
    if (!Platform.isAndroid) return;
    SharedPreferences? prefs;
    try {
      // 通知权限必须最先申请：后面的「所有文件访问」会打开系统设置页，
      // app 一退后台，再弹的通知权限请求会被系统直接吞掉。
      prefs = await SharedPreferences.getInstance();
      final notifAsked = prefs.getBool(_notifAskedKey) ?? false;
      if (!notifAsked) {
        final status = await Permission.notification.status;
        if (!status.isGranted && !status.isPermanentlyDenied) {
          await Permission.notification.request();
        }
        await prefs.setBool(_notifAskedKey, true);
      }

      // Android 13+ 自动走媒体权限，旧版本走存储权限。
      await Permission.storage.request();
      await Permission.photos.request();
      await Permission.videos.request();
      await Permission.audio.request();
    } catch (_) {}

    // 首次引导开启「所有文件访问权限」，让终端能浏览整个 /sdcard。
    try {
      if (prefs == null) return;
      final asked = prefs.getBool('asked_all_files_access') ?? false;
      if (!asked) {
        await prefs.setBool('asked_all_files_access', true);
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
