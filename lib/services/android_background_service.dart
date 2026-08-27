import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'runtime_logger.dart';

/// Android 生成任务的前台承载控制器。
///
/// 前台服务只负责让系统把当前 app 视为正在执行的用户可见任务；
/// 网络请求、流式解析和落库仍由现有 Dart 生成链路完成。
class AndroidBackgroundService {
  AndroidBackgroundService._();

  static final AndroidBackgroundService instance = AndroidBackgroundService._();

  static const MethodChannel _channel = MethodChannel(
    'shiyi/background_service',
  );

  Future<void> _tail = Future<void>.value();
  int? _desiredActiveSessions;
  int? _appliedActiveSessions;

  /// 同步当前活跃会话数。0 会停止服务，>0 会启动/更新常驻通知。
  Future<void> sync({required int activeSessions}) {
    if (!Platform.isAndroid) return Future<void>.value();
    final normalized = activeSessions < 0 ? 0 : activeSessions;
    _desiredActiveSessions = normalized;
    if (_desiredActiveSessions == _appliedActiveSessions) {
      return _tail;
    }
    _tail = _tail.then((_) async {
      final desired = _desiredActiveSessions;
      if (desired == null || desired == _appliedActiveSessions) return;
      try {
        await _channel.invokeMethod<void>('sync', {'activeSessions': desired});
        _appliedActiveSessions = desired;
        unawaited(
          RuntimeLogger.instance.info(
            '后台',
            'foreground_service.synced',
            data: {
              'activeSessions': desired,
              'state': desired > 0 ? 'running' : 'stopped',
            },
          ),
        );
      } on MissingPluginException {
        // Windows、测试环境或旧热重载引擎没有原生通道时静默降级。
      } on PlatformException catch (e) {
        // 前台服务只是承载增强，不能阻塞现有生成链路。
        unawaited(
          RuntimeLogger.instance.warn(
            '后台',
            'foreground_service.sync_failed',
            result: 'failed',
            data: {'error': e.message ?? e.code, 'activeSessions': desired},
          ),
        );
      }
    });
    return _tail;
  }
}
