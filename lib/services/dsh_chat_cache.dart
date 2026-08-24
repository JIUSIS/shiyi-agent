import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';
import 'dsh_api.dart';

const dshCachedLiveMessageId = 'dsh-cached-live';

class DshChatSnapshot {
  final List<ChatMessage> messages;
  final String title;
  final String model;
  final String cwd;
  final bool running;
  final DshSessionSummary? summary;

  const DshChatSnapshot({
    required this.messages,
    this.title = '',
    this.model = '',
    this.cwd = '',
    this.running = false,
    this.summary,
  });

  bool get hasUiData =>
      messages.isNotEmpty ||
      title.isNotEmpty ||
      model.isNotEmpty ||
      cwd.isNotEmpty ||
      summary != null;

  Map<String, dynamic> toJson() => {
    'version': 2,
    'messages': messages.map(_messageToJson).toList(),
    'title': title,
    'model': model,
    'cwd': cwd,
    'running': running,
    if (summary != null) 'summary': summary!.toJson(),
  };

  factory DshChatSnapshot.fromJson(Map<String, dynamic> json) {
    final summaryJson = json['summary'];
    return DshChatSnapshot(
      messages: ((json['messages'] as List?) ?? const [])
          .map((e) => _messageFromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      title: (json['title'] ?? '').toString(),
      model: (json['model'] ?? '').toString(),
      cwd: (json['cwd'] ?? '').toString(),
      running: json['running'] == true,
      summary: summaryJson is Map
          ? DshSessionSummary.fromJson(summaryJson.cast<String, dynamic>())
          : null,
    );
  }
}

class DshChatCache {
  static const _snapshotPrefix = 'dsh_chat_snapshot_cache_v2_';
  static const _legacyPrefix = 'dsh_chat_history_cache_v1_';
  static const _contextLimitPrefix = 'dsh_session_context_limit_v1_';

  /// DSH 会话自定义上下文（token）。0 / 缺失 = 跟随全局新建会话默认。
  static Future<int> readContextLimit(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_contextLimitPrefix$sessionId') ?? 0;
  }

  static Future<void> writeContextLimit(String sessionId, int limit) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      '$_contextLimitPrefix$sessionId',
      sanitizeLoadedContextLimit(limit),
    );
  }

  static Future<int> effectiveContextLimitFor(
    String sessionId,
    int globalDefault,
  ) async {
    return effectiveContextLimit(
      sessionContextLimit: await readContextLimit(sessionId),
      globalDefault: globalDefault,
    );
  }

  static Future<DshChatSnapshot?> read(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_snapshotPrefix$sessionId');
    if (raw != null && raw.isNotEmpty) {
      try {
        return DshChatSnapshot.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        );
      } catch (_) {
        // 损坏的新缓存继续尝试旧版消息缓存。
      }
    }
    final legacy = prefs.getString('$_legacyPrefix$sessionId');
    if (legacy == null || legacy.isEmpty) return null;
    try {
      final messages = (jsonDecode(legacy) as List)
          .map((e) => _messageFromJson((e as Map).cast<String, dynamic>()))
          .toList();
      return DshChatSnapshot(messages: messages);
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String sessionId, DshChatSnapshot snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    final messages = snapshot.messages.length <= 200
        ? snapshot.messages
        : snapshot.messages.sublist(snapshot.messages.length - 200);
    final stored = DshChatSnapshot(
      messages: messages,
      title: snapshot.title,
      model: snapshot.model,
      cwd: snapshot.cwd,
      running: snapshot.running,
      summary: snapshot.summary,
    );
    await prefs.setString(
      '$_snapshotPrefix$sessionId',
      jsonEncode(stored.toJson()),
    );
  }

  static Future<void> clear(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_snapshotPrefix$sessionId');
    await prefs.remove('$_legacyPrefix$sessionId');
  }

  static List<ChatMessage> materializeMessages({
    required String sessionId,
    required List<ChatMessage> messages,
    String liveText = '',
    String liveReasoning = '',
    List<ToolCall> liveToolCalls = const [],
  }) {
    ChatMessage? previousLive;
    ChatMessage? streaming;
    final stable = <ChatMessage>[];
    for (final message in messages) {
      if (message.id == dshCachedLiveMessageId) {
        previousLive = message;
      } else if (message.streaming) {
        streaming = message;
      } else {
        stable.add(_copyMessage(message));
      }
    }
    final text = liveText.isNotEmpty
        ? liveText
        : streaming?.content.isNotEmpty == true
        ? streaming!.content
        : previousLive?.content ?? '';
    final reasoning = liveReasoning.isNotEmpty
        ? liveReasoning
        : streaming?.reasoning.isNotEmpty == true
        ? streaming!.reasoning
        : previousLive?.reasoning ?? '';
    final runtimeContext = streaming?.runtimeContext.isNotEmpty == true
        ? streaming!.runtimeContext
        : previousLive?.runtimeContext ?? '';
    final subagentSummary = streaming?.subagentSummary.isNotEmpty == true
        ? streaming!.subagentSummary
        : previousLive?.subagentSummary ?? '';
    final tools = liveToolCalls.isNotEmpty
        ? liveToolCalls
        : streaming?.toolCalls.isNotEmpty == true
        ? streaming!.toolCalls
        : previousLive?.toolCalls ?? const <ToolCall>[];
    if (text.isNotEmpty ||
        reasoning.isNotEmpty ||
        runtimeContext.isNotEmpty ||
        subagentSummary.isNotEmpty ||
        tools.isNotEmpty) {
      stable.add(
        ChatMessage(
          id: dshCachedLiveMessageId,
          sessionId: sessionId,
          role: 'assistant',
          content: text,
          reasoning: reasoning,
          runtimeContext: runtimeContext,
          subagentSummary: subagentSummary,
          toolCalls: List<ToolCall>.of(tools),
          createdAt:
              streaming?.createdAt ??
              previousLive?.createdAt ??
              DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    return stable;
  }
}

/// 缓存只负责首帧。只有 DSH 会话仍在运行时才暂时保留尚未落盘的
/// 本地进度；会话结束后由调用方传 false，完全以 DSH history 为准。
List<ChatMessage> dshMergeHistoryPreservingProgress({
  required List<ChatMessage> current,
  required List<ChatMessage> incoming,
  required bool preserveLocalProgress,
  bool incomingLiveVisible = false,
}) {
  final pending = current.where((m) => m.id.startsWith('dsh-opt-')).toList();
  final next = List<ChatMessage>.of(incoming);
  final previous = current
      .where(
        (m) =>
            !m.id.startsWith('dsh-opt-') &&
            !m.streaming &&
            (!incomingLiveVisible || m.id != dshCachedLiveMessageId),
      )
      .toList();
  var prefix = 0;
  final common = previous.length < next.length ? previous.length : next.length;
  while (prefix < common &&
      _sameMessageIdentity(previous[prefix], next[prefix])) {
    // 历史刷新可能先返回正文，再补齐 reasoning/context；相同消息只合并
    // 已确认字段，避免折叠内容被一次短响应清空。
    next[prefix] = _mergeSameMessage(previous[prefix], next[prefix]);
    prefix++;
  }
  if (preserveLocalProgress) {
    if (!incomingLiveVisible &&
        prefix == next.length &&
        previous.length > next.length) {
      next
        ..clear()
        ..addAll(previous.map(_copyMessage));
    }
  }

  final currentConfirmed = <String, int>{};
  for (final message in current) {
    if (message.id.startsWith('dsh-opt-') ||
        message.streaming ||
        message.role != 'user') {
      continue;
    }
    final key = message.content.trim();
    currentConfirmed[key] = (currentConfirmed[key] ?? 0) + 1;
  }
  final incomingCount = <String, int>{};
  for (final message in incoming) {
    if (message.role != 'user') continue;
    final key = message.content.trim();
    incomingCount[key] = (incomingCount[key] ?? 0) + 1;
  }
  final newConfirmed = <String, int>{};
  for (final entry in incomingCount.entries) {
    final before = currentConfirmed[entry.key] ?? 0;
    newConfirmed[entry.key] = (entry.value - before)
        .clamp(0, entry.value)
        .toInt();
  }
  for (final message in pending) {
    final key = message.content.trim();
    final count = newConfirmed[key] ?? 0;
    if (count > 0) {
      newConfirmed[key] = count - 1;
    } else {
      next.add(message);
    }
  }
  return next;
}

/// 判断 DSH history 是否仍是当前 UI 的旧前缀。只用于 turn/end 后短时
/// 等待 DSH 落盘，不能据此长期拒绝 DSH 的最终结果。
bool dshHistoryRegressed({
  required List<ChatMessage> current,
  required List<ChatMessage> incoming,
}) {
  final previous = current
      .where((m) => !m.id.startsWith('dsh-opt-') && !m.streaming)
      .toList();
  if (previous.isEmpty) return false;
  final common = previous.length < incoming.length
      ? previous.length
      : incoming.length;
  for (var i = 0; i < common; i++) {
    if (!_sameMessageIdentity(previous[i], incoming[i])) return false;
    if (incoming[i].content.length < previous[i].content.length ||
        incoming[i].reasoning.length < previous[i].reasoning.length ||
        incoming[i].runtimeContext.length < previous[i].runtimeContext.length ||
        incoming[i].subagentSummary.length <
            previous[i].subagentSummary.length ||
        incoming[i].toolCalls.length < previous[i].toolCalls.length) {
      return true;
    }
  }
  return incoming.length < previous.length && common == incoming.length;
}

bool _sameMessageIdentity(ChatMessage a, ChatMessage b) {
  if (a.id.isNotEmpty && b.id.isNotEmpty) return a.id == b.id;
  return a.role == b.role && a.createdAt == b.createdAt;
}

ChatMessage _mergeSameMessage(ChatMessage previous, ChatMessage incoming) {
  return ChatMessage(
    id: incoming.id.isNotEmpty ? incoming.id : previous.id,
    sessionId: incoming.sessionId.isNotEmpty
        ? incoming.sessionId
        : previous.sessionId,
    role: incoming.role,
    content: incoming.content.length >= previous.content.length
        ? incoming.content
        : previous.content,
    reasoning: incoming.reasoning.length >= previous.reasoning.length
        ? incoming.reasoning
        : previous.reasoning,
    toolCalls: incoming.toolCalls.length >= previous.toolCalls.length
        ? List<ToolCall>.of(incoming.toolCalls)
        : List<ToolCall>.of(previous.toolCalls),
    toolCallId: incoming.toolCallId.isNotEmpty
        ? incoming.toolCallId
        : previous.toolCallId,
    createdAt: incoming.createdAt != 0
        ? incoming.createdAt
        : previous.createdAt,
    archived: incoming.archived,
    runtimeContext:
        incoming.runtimeContext.length >= previous.runtimeContext.length
        ? incoming.runtimeContext
        : previous.runtimeContext,
    subagentSummary:
        incoming.subagentSummary.length >= previous.subagentSummary.length
        ? incoming.subagentSummary
        : previous.subagentSummary,
  );
}

ChatMessage _copyMessage(ChatMessage message) => ChatMessage(
  id: message.id,
  sessionId: message.sessionId,
  role: message.role,
  content: message.content,
  reasoning: message.reasoning,
  toolCalls: List<ToolCall>.of(message.toolCalls),
  toolCallId: message.toolCallId,
  createdAt: message.createdAt,
  streaming: message.streaming,
  archived: message.archived,
  runtimeContext: message.runtimeContext,
  subagentSummary: message.subagentSummary,
);

Map<String, dynamic> _messageToJson(ChatMessage message) => {
  ...message.toMap(),
  'streaming': message.streaming,
  'runtime_context': message.runtimeContext,
  'subagent_summary': message.subagentSummary,
};

ChatMessage _messageFromJson(Map<String, dynamic> json) {
  final message = ChatMessage.fromMap(json);
  message.streaming = json['streaming'] == true;
  message.runtimeContext = (json['runtime_context'] ?? '').toString();
  message.subagentSummary = (json['subagent_summary'] ?? '').toString();
  // DSH cache 的 reasoning 是 UI 折叠内容，不沿用普通数据库兼容逻辑把
  // “正文为空 + reasoning” 改写成普通正文。
  final rawReasoning = (json['reasoning'] ?? '').toString();
  if (message.role == 'assistant' && rawReasoning.isNotEmpty) {
    message.content = (json['content'] ?? '').toString();
    message.reasoning = rawReasoning;
  }
  return message;
}
