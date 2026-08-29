import 'models.dart';

/// 会话页子代理状态条 / mini 会话共用的只读快照。
class SubagentLiveSnapshot {
  final String id;
  final String title;
  final String subtitle;
  final String prompt;
  final bool running;
  final List<ChatMessage> messages;
  final String liveContent;
  final String liveReasoning;

  const SubagentLiveSnapshot({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.prompt = '',
    this.running = true,
    this.messages = const [],
    this.liveContent = '',
    this.liveReasoning = '',
  });

  SubagentLiveSnapshot copyWith({
    String? title,
    String? subtitle,
    String? prompt,
    bool? running,
    List<ChatMessage>? messages,
    String? liveContent,
    String? liveReasoning,
  }) {
    return SubagentLiveSnapshot(
      id: id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      prompt: prompt ?? this.prompt,
      running: running ?? this.running,
      messages: messages ?? this.messages,
      liveContent: liveContent ?? this.liveContent,
      liveReasoning: liveReasoning ?? this.liveReasoning,
    );
  }
}

/// 拾忆子代理运行中的可变状态，展示时再冻成 [SubagentLiveSnapshot]。
class SubagentLiveRun {
  SubagentLiveRun({
    required this.id,
    required this.type,
    required this.prompt,
    required this.index,
    required this.total,
    required this.maxTurns,
  }) : round = 0;

  final String id;
  final String type;
  final String prompt;
  final int index;
  final int total;
  int round;
  int maxTurns;
  String lastTool = '';
  bool running = true;
  List<ChatMessage> messages = [];
  String liveContent = '';
  String liveReasoning = '';

  String get statusLine {
    final tool = lastTool.isEmpty ? '思考中' : '正在调用 ' + lastTool;
    final current = round < 1 ? 1 : round;
    return '第 ' + current.toString() + '/' + maxTurns.toString() + ' 轮 · ' + tool;
  }

  SubagentLiveSnapshot toSnapshot() => SubagentLiveSnapshot(
    id: id,
    title: type,
    subtitle: statusLine,
    prompt: prompt,
    running: running,
    messages: List<ChatMessage>.unmodifiable(messages),
    liveContent: liveContent,
    liveReasoning: liveReasoning,
  );
}

/// 把子代理内部 API 消息转成聊天气泡。跳过 system / tool 结果，
/// assistant 的 tool_calls 留在气泡上给 mini 会话画工具条。
List<ChatMessage> subagentTranscriptToMessages(
  String sessionId,
  List<Map<String, dynamic>> msgs,
) {
  final out = <ChatMessage>[];
  var i = 0;
  for (final raw in msgs) {
    final role = (raw['role'] ?? '').toString();
    if (role == 'system' || role == 'tool') continue;
    final mappedRole = role == 'assistant' ? 'assistant' : 'user';
    out.add(
      ChatMessage(
        id: 'sub-' + sessionId + '-' + i.toString(),
        sessionId: sessionId,
        role: mappedRole,
        content: (raw['content'] ?? '').toString(),
        toolCalls: _toolCallsFrom(raw['tool_calls'], i),
        createdAt: 0,
      ),
    );
    i++;
  }
  return out;
}

List<ToolCall> _toolCallsFrom(Object? raw, int index) {
  if (raw is! List || raw.isEmpty) return const [];
  final out = <ToolCall>[];
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map) continue;
    final map = item.cast<Object?, Object?>();
    final fn = map['function'];
    final fnMap = fn is Map ? fn.cast<Object?, Object?>() : map;
    final name = (fnMap['name'] ?? map['name'] ?? '').toString();
    if (name.isEmpty) continue;
    out.add(
      ToolCall(
        id: (map['id'] ?? ('call_sub_' + index.toString() + '_' + i.toString())).toString(),
        name: name,
        arguments: (fnMap['arguments'] ?? map['arguments'] ?? '').toString(),
      ),
    );
  }
  return out;
}
