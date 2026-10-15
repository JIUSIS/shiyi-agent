import 'package:flutter/widgets.dart';

/// 应用是否在前台。
///
/// 给 `AppState` 这类没有 widget `context` 的代码用：`WidgetsBinding` /
/// `AppLifecycleState` 的可见性只在 widget 层能拿到，这里收口成一个函数。
/// `lifecycle == null`（启动首帧尚未上报）按前台处理。
bool dshAppForeground() {
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  return lifecycle == null || lifecycle == AppLifecycleState.resumed;
}

/// DSH 页面轮询的可见性判定。
///
/// 真机发热复盘（docs/fix-log.md #393）：应用退到后台（前台是桌面）时，
/// `dsh_chat_screen` 里那个 500ms 的 `subagent.list` 定时器**没有**可见性
/// 判断，只要会话在 running 就一直 2Hz 拉，叠加历史/会话列表约 2.3 请求/秒，
/// 边充电边跑 → 电池 56.7°C。
///
/// 规则：应用必须在前台（`resumed`）且页面在被推栈最前；`lifecycle` 还没
/// 上报（null）时按可见处理，避免误伤启动首帧。
bool dshPollVisible({
  required bool mounted,
  required AppLifecycleState? lifecycle,
  required bool routeIsCurrent,
}) {
  if (!mounted) return false;
  if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return false;
  return routeIsCurrent;
}
