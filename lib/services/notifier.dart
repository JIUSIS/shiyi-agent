import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// 拾忆任务通知服务：agent 在后台完成长任务时给用户推送一条通知。
/// 依赖 flutter_local_notifications（Android 通道）+ permission_handler（Android 13+ 通知权限）。
class Notifier {
  Notifier._();
  static final Notifier instance = Notifier._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const String _channelId = 'shiyi_tasks';
  static const String _channelName = '拾忆任务通知';
  static const String _channelDesc = '拾忆 agent 长任务完成等通知';

  /// 初始化通知通道（app 启动时调用一次，幂等）。
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await _plugin.initialize(settings: settings);
      if (kIsWeb) {
        _initialized = true;
        return;
      }
      // Android 13（API 33）+ 需要在运行时请求通知权限；其他平台跳过。
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          final status = await Permission.notification.status;
          if (!status.isGranted && !status.isPermanentlyDenied) {
            await Permission.notification.request();
          }
        } catch (_) {
          // 部分 ROM 权限接口异常不影响通知通道初始化。
        }
      }
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
  }) async {
    if (!_initialized) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
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
