import '../core/models.dart';

/// 会话历史的分页窗口工具。
///
/// 上千轮的长会话不再一次性拉全量历史：首帧与每一拍轮询只读官方
/// `session/page` 的尾部窗口，更早的消息在用户上翻时按页补进来。
/// 这里放与 UI 无关的纯逻辑，方便单测。

/// 把从更早一页读到的消息拼到已加载消息前面。
///
/// - 按 id 去重：相邻两页可能在边界上重叠，重复拼进去会多出一条气泡。
/// - 保持顺序：`older` 内部按时间递增，整体排在 `current` 之前。
List<ChatMessage> dshPrependOlderMessages({
  required List<ChatMessage> older,
  required List<ChatMessage> current,
}) {
  if (older.isEmpty) return List<ChatMessage>.of(current);
  final seen = <String>{for (final message in current) message.id};
  final head = <ChatMessage>[];
  for (final message in older) {
    if (!seen.add(message.id)) continue;
    head.add(message);
  }
  if (head.isEmpty) return List<ChatMessage>.of(current);
  return <ChatMessage>[...head, ...current];
}

/// 上翻到什么位置该补更早的一页。
///
/// reverse 列表里 offset 0 = 最新消息（视觉底部），所以「接近
/// maxScrollExtent」就是在读最老的一段。
bool dshShouldLoadOlder({
  required bool hasMoreOlder,
  required bool loading,
  required double pixels,
  required double maxScrollExtent,
  double threshold = 600,
}) {
  if (!hasMoreOlder || loading) return false;
  if (maxScrollExtent <= 0) return false;
  return pixels >= maxScrollExtent - threshold;
}

/// 用户上翻离开最新位置时，暂停尾部轮询刷新。
///
/// 读历史时还每拍重拉尾部历史并重排列表，是长会话里最直接的卡顿源，
/// 也会把视线拽回底部；回到最新位置后恢复。
bool dshShouldPauseTailRefresh({
  required double pixels,
  double threshold = 80,
}) {
  if (pixels.isNaN) return false;
  return pixels > threshold;
}
