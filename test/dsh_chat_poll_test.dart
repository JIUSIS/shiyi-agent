import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/screens/dsh_chat_screen.dart';

/// 会话页轮询节流。局域网 8080 不做 WS 隧道（#392）→ 没有实时流，全量历史
/// 轮询只有「输出确实在增长」时才值得跑；真机实测按常速跑会到 43.6°C，
/// 强停后 60 秒降到 41.1°C。见 docs/fix-log.md #397。
void main() {
  /// 跑 N 拍（400ms 一拍）统计真正发起轮询的次数。
  int fireCount({
    required int ticks,
    required bool running,
    required bool muxUp,
    bool growing = false,
    bool unreachable = false,
  }) {
    var n = 0;
    for (var i = 1; i <= ticks; i++) {
      if (dshChatPollTick(
        ticks: i,
        running: running,
        muxUp: muxUp,
        growing: growing,
        unreachable: unreachable,
      ).fetch) {
        n++;
      }
    }
    return n;
  }

  test('mux 正常：维持 2s 一拍（25 拍 = 10 秒 → 5 次）', () {
    expect(fireCount(ticks: 25, running: true, muxUp: true), 5);
    expect(fireCount(ticks: 25, running: false, muxUp: true), 5);
  });

  test('mux 不可用 + 正在出字：800ms（25 拍 → 12 次）', () {
    expect(
      fireCount(ticks: 25, running: true, muxUp: false, growing: true),
      12,
    );
  });

  test('mux 不可用 + 回合在跑但没变化：4.8s（25 拍 → 2 次）', () {
    expect(fireCount(ticks: 25, running: true, muxUp: false), 2);
  });

  test('mux 不可用 + 空闲：12s（60 拍 = 24 秒 → 2 次）', () {
    expect(fireCount(ticks: 60, running: false, muxUp: false), 2);
  });

  test('60 秒稳态请求量：旧行为 150 次 → 现在 < 40 次', () {
    // 150 拍 = 60 秒
    final quiet = fireCount(ticks: 150, running: true, muxUp: false);
    final growing = fireCount(
      ticks: 150,
      running: true,
      muxUp: false,
      growing: true,
    );
    expect(quiet, lessThan(20)); // 没动静 → 4.8s 一拍
    expect(growing, lessThan(90)); // 真在出字才 800ms
    expect(growing, lessThan(150));
  });

  test('会话列表只在大拍上拉，不跟历史同频', () {
    final withList = [
      for (var i = 1; i <= 30; i++)
        dshChatPollTick(
          ticks: i,
          running: true,
          muxUp: false,
          growing: true,
        ).withList,
    ];
    // due 是偶数拍、withList 又要求 5 的倍数 → 30 拍里只有第 10/20/30 拍
    expect(withList.where((e) => e).length, 3);
  });

  test('目标不可达：节奏再放慢 5 倍（真机 40 秒 51 次 → 应降到 ~10 次）', () {
    // 150 拍 = 60 秒，正在出字
    final reachable = fireCount(
      ticks: 150,
      running: true,
      muxUp: false,
      growing: true,
    );
    final unreachable = fireCount(
      ticks: 150,
      running: true,
      muxUp: false,
      growing: true,
      unreachable: true,
    );
    expect(unreachable, lessThan(reachable));
    expect(unreachable, lessThan(20));
    // 空闲 + 不可达：1 分钟最多 1 次
    expect(
      fireCount(ticks: 150, running: false, muxUp: false, unreachable: true),
      lessThanOrEqualTo(1),
    );
  });
}
