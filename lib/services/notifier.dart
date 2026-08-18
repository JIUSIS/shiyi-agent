import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 拾忆任务通知服务：agent 在后台完成长任务时给用户推送一条通知。
/// Android：flutter_local_notifications（通道）+ permission_handler（13+ 通知权限）。
/// Windows：flutter_local_notifications 的 WinRT 实现（appName/appUserModelId/guid）。
class Notifier {
  Notifier._();
  static final Notifier instance = Notifier._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const String _channelId = 'shiyi_tasks';
  static const String _channelName = '拾忆任务通知';
  static const String _channelDesc = '拾忆 agent 长任务完成等通知';

  /// Windows 通知身份：固定 GUID（安装后不变，卸载重装也沿用）。
  static const String _windowsGuid = 'c4a7d0e2-9f3b-4a5c-b6d7-8e9f0a1b2c3d';

  /// 初始化通知通道（app 启动时调用一次，幂等）。
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    try {
      final settings = InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(
          appName: '拾忆',
          appUserModelId: 'com.shiyi.agent',
          guid: _windowsGuid,
        ),
      );
      await _plugin.initialize(settings: settings);
      if (kIsWeb) {
        _initialized = true;
        return;
      }
      // Android 13+ 通知权限统一在 PermissionService.ensureOnLaunch()
      // 首启时申请，避免与媒体/文件权限的系统页并发冲突；这里只建通道。
      _initialized = true;
    } catch (_) {
      // 初始化失败（如模拟器不支持）不阻塞 app。
      _initialized = true;
    }
  }

  /// 发送一条通知。失败静默（通知只是辅助，不影响主流程）。
  Future<void> show({
    required int id,
    required String title,
    required String body,
    int? progress,
    int? maxProgress,
  }) async {
    if (!_initialized) return;
    try {
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
          showProgress: progress != null,
          maxProgress: maxProgress ?? 0,
          progress: progress ?? 0,
          indeterminate: false,
          onlyAlertOnce: true,
        ),
        windows: const WindowsNotificationDetails(),
      );
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (_) {}
  }
}
