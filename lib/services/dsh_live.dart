import 'dart:convert';
import 'dart:io';

import '../core/models.dart';

/// DSH 下行帧与 live token 组装。不改 DSH 源码，只消费官方 mux/host。
///
/// 浏览器走 WebSocket：/api/events.mux、/api/events.host。
/// 每条文本消息是一个完整 ServerRequest：
/// {type: server-request, rpcId, method, payload}，method 即帧类型。
/// assistant/chunk 就是 token 流，没有另一套 delta 帧。
class DshHistoryBundle {
  final List<ChatMessage> messages;
  final DshLiveTurn live;
  final Set<String> responseModels;
  final bool turnEnded;
  const DshHistoryBundle({
    required this.messages,
    required this.live,
    this.responseModels = const <String>{},
    this.turnEnded = false,
  });
}

/// 当前未收口回合的流式缓冲。
class DshLiveTurn {
  String text = '';
  String rawText = '';
  String reasoning = '';
  final List<ToolCall> toolCalls = [];
  int lastSeq = -1;
  bool open = false;

  bool get hasVisible =>
      text.isNotEmpty || reasoning.isNotEmpty || toolCalls.isNotEmpty;

  void reset() {
    text = '';
    rawText = '';
    reasoning = '';
    toolCalls.clear();
    open = false;
  }

  void begin() {
    reset();
    open = true;
  }

  /// 一个 assistant/message 只结束当前 LLM 步骤；整轮可能还会继续跑工具
  /// 并产生下一条助手消息。正文与工具按步骤重置，但 reasoning 按整轮累积，
  /// 这样工具步骤之间的“思考中”面板不会突然变空。
  void continueTurn() {
    text = '';
    rawText = '';
    toolCalls.clear();
    open = true;
  }

  void replaceWith(DshLiveTurn other) {
    text = other.text;
    rawText = other.rawText.isNotEmpty ? other.rawText : other.text;
    reasoning = other.reasoning;
    toolCalls
      ..clear()
      ..addAll(other.toolCalls);
    lastSeq = other.lastSeq;
    open = other.open;
  }

  /// 合并 history 轮询得到的 live 快照，同时保证当前可见内容不会倒退。
  ///
  /// WebSocket 通常比 session.history 更快；旧快照只能被忽略。关闭状态则
  /// 必须由调用方在确认正式 history 已落盘后通过 [allowClose] 显式接纳。
  bool mergeProgressFrom(DshLiveTurn other, {bool allowClose = false}) {
    // session.history 请求可能并发返回；一份较早快照不能在收口后把
    // 已清空的 live 缓冲重新打开，否则最终 assistant/message 会出现重复气泡。
    if (lastSeq >= 0 && other.lastSeq >= 0 && other.lastSeq < lastSeq) {
      return false;
    }
    if (!other.open) {
      if (!allowClose && (open || hasVisible)) return false;
      final changed =
          text != other.text ||
          reasoning != other.reasoning ||
          toolCalls.length != other.toolCalls.length ||
          lastSeq != other.lastSeq ||
          open != other.open;
      replaceWith(other);
      return changed;
    }

    if (!open && !hasVisible) {
      replaceWith(other);
      return true;
    }

    final textMovesForward = other.text.startsWith(text);
    final reasoningMovesForward = other.reasoning.startsWith(reasoning);
    final toolsMoveForward = toolCalls.every(
      (current) =>
          other.toolCalls.any((incoming) => _sameTool(current, incoming)),
    );
    if (!textMovesForward ||
        !reasoningMovesForward ||
        !toolsMoveForward ||
        other.lastSeq < lastSeq) {
      return false;
    }

    final changed =
        text != other.text ||
        reasoning != other.reasoning ||
        toolCalls.length != other.toolCalls.length ||
        lastSeq != other.lastSeq ||
        open != other.open;
    replaceWith(other);
    return changed;
  }

  static bool _sameTool(ToolCall a, ToolCall b) {
    if (a.id.isNotEmpty || b.id.isNotEmpty) return a.id == b.id;
    return a.name == b.name && a.arguments == b.arguments;
  }

  /// 从 session.history 的 value 重建未收口 live（只保留末尾还在流的那一轮）。
  static DshLiveTurn fromHistoryValue(Map<String, dynamic> value) {
    final live = DshLiveTurn();
    final entries = (value['events'] as List?) ?? const [];
    for (final entry in entries) {
      final ev = ((entry as Map)['event'] as Map?)?.cast<String, dynamic>();
      if (ev != null) live.ingest(ev);
    }
    return live;
  }

  /// 吃一条 SessionEvent 或 mux 的 session/event 帧。
  /// 返回是否改变了 live 缓冲。
  bool ingest(Map<String, dynamic> raw) {
    var ev = raw;
    if (ev['type']?.toString() == 'session/event' && ev['event'] is Map) {
      ev = (ev['event'] as Map).cast<String, dynamic>();
    }
    final type = ev['type']?.toString() ?? '';
    final seq = (ev['seq'] as num?)?.toInt();
    if (seq != null) {
      if (seq <= lastSeq) return false;
      lastSeq = seq;
    }
    final data = (ev['data'] as Map?)?.cast<String, dynamic>() ?? const {};

    if (type == 'assistant/chunk') {
      final chunk =
          (data['chunk'] as Map?)?.cast<String, dynamic>() ?? const {};
      return _ingestChunk(chunk);
    }
    if (type == 'tool/call') {
      if (!open) return false;
      final id = data['callId']?.toString() ?? '';
      if (id.isNotEmpty && toolCalls.any((t) => t.id == id)) return false;
      toolCalls.add(
        ToolCall(
          id: id,
          name: data['name']?.toString() ?? '',
          arguments: data['arguments']?.toString() ?? '',
        ),
      );
      return true;
    }
    if (type == 'assistant/message') {
      final changed = text.isNotEmpty || toolCalls.isNotEmpty || !open;
      continueTurn();
      return changed;
    }
    if (type == 'turn/end') {
      final wasOpen = open || hasVisible;
      text = '';
      reasoning = '';
      toolCalls.clear();
      open = false;
      return wasOpen;
    }
    return false;
  }

  bool _ingestChunk(Map<String, dynamic> chunk) {
    final ct = chunk['type']?.toString() ?? '';
    if (ct == 'text-delta') {
      final piece = chunk['text']?.toString() ?? '';
      if (piece.isEmpty) return false;
      open = true;
      rawText += piece;
      final split = splitThinkTags(rawText);
      final nextText = split.text;
      final nextReasoning = mergeReasoning(reasoning, split.reasoning);
      if (nextText == text && nextReasoning == reasoning) return false;
      text = nextText;
      reasoning = nextReasoning;
      return true;
    }
    if (ct == 'reasoning-delta') {
      final raw = chunk['text'] ?? chunk['content'] ?? chunk['delta'];
      final piece = raw is String
          ? raw
          : raw is Map
          ? (raw['text']?.toString() ?? '')
          : '';
      if (piece.isEmpty) return false;
      open = true;
      reasoning += piece;
      return true;
    }
    // block-start / block-end / tool-call-delta / usage / finish 忽略。
    return false;
  }
}

/// mux / host WebSocket 下行。
class DshWsDownlink {
  static Uri uriFor(String httpBase, String path) {
    final base = Uri.parse(httpBase);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    final suffix = path.startsWith('/') ? path : '/api/$path';
    var root = base.path;
    if (root.endsWith('/') && root.length > 1) {
      root = root.substring(0, root.length - 1);
    }
    final fullPath = (root.isEmpty || root == '/') ? suffix : '$root$suffix';
    return base.replace(scheme: scheme, path: fullPath);
  }

  /// 解开一条下行文本。兼容 ServerRequest 信封、裸 MuxFrame、SSE data: 行。
  static Map<String, dynamic>? decodeFrame(String raw) {
    var src = raw.trim();
    if (src.startsWith('data:')) {
      src = src.substring(5).trim();
    }
    if (src.isEmpty || src == '[DONE]') return null;
    final Object decoded;
    try {
      decoded = jsonDecode(src);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final map = decoded.cast<String, dynamic>();
    if (map['type']?.toString() == 'server-request') {
      final method = map['method']?.toString() ?? '';
      final payload = map['payload'];
      if (payload is Map) {
        final p = payload.cast<String, dynamic>();
        if (p['type'] != null) return _withRpcId(p, map);
        if (method.isNotEmpty) {
          return _withRpcId(<String, dynamic>{'type': method, ...p}, map);
        }
        return _withRpcId(p, map);
      }
      if (method.isNotEmpty) {
        return _withRpcId(<String, dynamic>{'type': method}, map);
      }
      return null;
    }
    if (map['type'] != null) return map;
    return null;
  }

  /// 透传 server-request 的 rpcId（question/requested 等应答型帧需要回显）。
  static Map<String, dynamic> _withRpcId(
    Map<String, dynamic> map,
    Map<String, dynamic> frame,
  ) => frame['rpcId'] == null
      ? map
      : <String, dynamic>{'rpcId': frame['rpcId'], ...map};

  static Stream<Map<String, dynamic>> connect(
    String httpBase,
    String path, {
    Future<WebSocket> Function(Uri uri)? open,
    Map<String, dynamic>? headers,
  }) async* {
    final uri = uriFor(httpBase, path);
    final httpScheme = uri.scheme == 'wss' ? 'https' : 'http';
    final origin = '$httpScheme://${uri.authority}';
    final merged = <String, dynamic>{'Origin': origin, ...?headers};
    final ws = open != null
        ? await open(uri)
        : await WebSocket.connect(uri.toString(), headers: merged);
    try {
      await for (final raw in ws) {
        if (raw is! String) continue;
        final frame = decodeFrame(raw);
        if (frame != null) yield frame;
      }
    } finally {
      try {
        await ws.close();
      } catch (_) {}
    }
  }
}
