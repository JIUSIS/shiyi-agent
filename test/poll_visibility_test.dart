import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/poll_visibility.dart';

/// 轮询可见性：应用不在前台（含 inactive）或页面被别的 route 盖住时一律不拉。
/// 真机复盘（docs/fix-log.md #393）：后台仍在 0.5s 拉 subagent.list，
/// 边充电边跑 → 电池 56.7°C。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dshAppForeground 在未上报生命周期时按前台处理（AppState 用）', () {
    // 测试环境下 lifecycleState 为 null，等价于"启动首帧尚未上报"
    expect(dshAppForeground(), isTrue);
  });

  test('前台且页面在最前 → 可见', () {
    expect(
      dshPollVisible(
        mounted: true,
        lifecycle: AppLifecycleState.resumed,
        routeIsCurrent: true,
      ),
      isTrue,
    );
  });

  test('应用退到后台的各种状态都不拉', () {
    for (final state in [
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive, // MIUI 切后台常见，旧判定漏了它
      AppLifecycleState.detached,
    ]) {
      expect(
        dshPollVisible(
          mounted: true,
          lifecycle: state,
          routeIsCurrent: true,
        ),
        isFalse,
        reason: '$state',
      );
    }
  });

  test('页面被别的 route 盖住 → 不拉', () {
    expect(
      dshPollVisible(
        mounted: true,
        lifecycle: AppLifecycleState.resumed,
        routeIsCurrent: false,
      ),
      isFalse,
    );
  });

  test('未挂载或 lifecycle 未上报（null）', () {
    expect(
      dshPollVisible(
        mounted: false,
        lifecycle: AppLifecycleState.resumed,
        routeIsCurrent: true,
      ),
      isFalse,
    );
    // 启动首帧还没收到生命周期回调时按可见处理，避免误伤
    expect(
      dshPollVisible(mounted: true, lifecycle: null, routeIsCurrent: true),
      isTrue,
    );
  });
}
