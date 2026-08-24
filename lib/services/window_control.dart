import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/painting.dart';

/// 无边框窗口控制（macOS 风格红黄绿三键）：
/// 与 windows/runner 的 MethodChannel 'shiyi/window' 通信。
/// Android 不调用（无此 channel，调用会抛 MissingPluginException，已捕获）。
class WindowControl {
  WindowControl._();
  static final WindowControl instance = WindowControl._();

  static const MethodChannel _channel = MethodChannel('shiyi/window');

  /// 最大化状态（启动时查询，WM_SIZE 变化由原生端推送同步）。
  final ValueNotifier<bool> isMaximized = ValueNotifier<bool>(false);
  bool _initialized = false;

  /// 注册原生端回调并查询初始最大化状态（幂等）。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'windowStateChanged') {
        bool? maximized;
        if (call.arguments is Map) {
          maximized = (call.arguments as Map)['maximized'] as bool?;
        }
        if (maximized != null) isMaximized.value = maximized;
      }
      return null;
    });
    try {
      final v = await _channel.invokeMethod<bool>('isMaximized');
      if (v != null) isMaximized.value = v;
    } catch (_) {}
  }

  Future<void> minimize() async {
    try {
      await _channel.invokeMethod('minimize');
    } catch (_) {}
  }

  Future<void> toggleMaximize() async {
    try {
      await _channel.invokeMethod('toggleMaximize');
      // 原生端会推送状态，这里再主动查询一次兜底（响应即时性）。
      final v = await _channel.invokeMethod<bool>('isMaximized');
      if (v != null) isMaximized.value = v;
    } catch (_) {}
  }

  Future<void> close() async {
    try {
      await _channel.invokeMethod('close');
    } catch (_) {}
  }

  /// Native title-bar overlay color (ARGB). Keeps the Win32 strip in
  /// sync with Flutter's scaffold so it is not the system dark caption.
  Future<void> setTitleBarColor(Color color) async {
    try {
      await _channel.invokeMethod('setTitleBarColor', {
        'color': color.toARGB32(),
      });
    } catch (_) {}
  }
}
