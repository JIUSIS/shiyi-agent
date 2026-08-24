import 'models.dart';

/// 拾忆跨会话查阅：把本机其他会话搜出来、读出来给模型。
///
/// 用户从会话卡片左滑「复制 ID」得到的是 `s时间戳_随机数`。
/// 另一会话的模型必须能用这个 ID 找到并阅读原文，不能只搜标题/正文。
class SessionBridge {
  SessionBridge._();

  /// 拾忆会话 ID：`s` + 毫秒时间戳 + `_` + 微秒随机数。
  static final RegExp idPattern = RegExp(r's\d+_\d+');

  /// 从用户粘贴的文本里抽出会话 ID；没有则返回 null。
  static String? extractSessionId(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (idPattern.hasMatch(t) && idPattern.stringMatch(t) == t) return t;
    return idPattern.firstMatch(t)?.group(0);
  }

  static String missingSession(String id) =>
      '没有找到会话 $id。请确认这是拾忆会话 ID（主页左滑会话卡片「复制 ID」），'
      '不是 DSH 工作区会话。';

  static String formatSearchResults({
    required String query,
    Session? exact,
    required List<SessionSearchResult> hits,
    String? currentSessionId,
  }) {
    final seen = <String>{};
    final lines = <String>[];

    void add(Session s, {String snippet = ''}) {
      if (!seen.add(s.id)) return;
      final cur = s.id == currentSessionId ? '（当前会话）' : '';
      lines.add(
        '- id=${s.id} 标题=${s.title}$cur 消息=${s.messageCount} 条',
      );
      if (snippet.trim().isNotEmpty) {
        lines.add('  片段：${snippet.trim()}');
      }
    }

    if (exact != null) add(exact);
    for (final h in hits) {
      add(h.session, snippet: h.snippet);
    }
    if (lines.isEmpty) {
      return '没有找到会话「$query」。'
          '请改用完整会话 ID（左滑会话卡片「复制 ID」），或换标题/内容关键词。';
    }
    return '找到 ${seen.length} 个会话：\n${lines.join('\n')}\n'
        '用 read_session 阅读正文，session_id 填上面的 id。';
  }

  static const int defaultMessageLimit = 40;
  static const int maxMessageLimit = 80;
  static const int maxCharsPerMessage = 800;
  static const int maxTotalChars = 12000;

  static String formatTranscript({
    required Session session,
    required List<ChatMessage> messages,
    String? currentSessionId,
    int offset = 0,
    int? limit,
  }) {
    final visible = [
      for (final m in messages)
        if ((m.role == 'user' || m.role == 'assistant') &&
            m.content.trim().isNotEmpty)
          m,
    ];
    final start = offset < 0 ? 0 : (offset > visible.length ? visible.length : offset);
    var take = limit ?? defaultMessageLimit;
    if (take < 1) take = 1;
    if (take > maxMessageLimit) take = maxMessageLimit;
    final slice = visible.skip(start).take(take).toList();

    final sb = StringBuffer()
      ..writeln('会话 id=${session.id} 标题=${session.title}');
    if (session.id == currentSessionId) sb.writeln('（这是当前会话）');
    final summary = session.rollingSummary.trim();
    if (summary.isNotEmpty) sb.writeln('摘要：$summary');
    sb.writeln(
      '对话 ${visible.length} 条，展示 $start–${start + slice.length}',
    );

    var total = 0;
    var shown = 0;
    for (final m in slice) {
      var content = m.content.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (content.length > maxCharsPerMessage) {
        content = '${content.substring(0, maxCharsPerMessage)}…';
      }
      total += content.length;
      if (total > maxTotalChars) {
        sb.writeln('（后续过长已截断，增大 offset 继续阅读）');
        break;
      }
      final role = m.role == 'user' ? '用户' : '助手';
      sb.writeln('[$role] $content');
      shown++;
    }
    final remaining = visible.length - start - shown;
    if (remaining > 0) {
      sb.writeln('还有 $remaining 条，用 offset=${start + shown} 继续。');
    }
    return sb.toString().trimRight();
  }
}
