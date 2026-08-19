import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';
import 'package:shiyi_agent_app/services/dsh_chat_cache.dart';

ChatMessage _message(
  String id,
  String role,
  String content, {
  String reasoning = '',
  bool streaming = false,
}) => ChatMessage(
  id: id,
  sessionId: 's1',
  role: role,
  content: content,
  reasoning: reasoning,
  streaming: streaming,
  createdAt: int.tryParse(id.replaceAll(RegExp(r'\D'), '')) ?? 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('聊天快照往返保留消息、模型与统计栏', () async {
    final message = _message('m1', 'assistant', '回复', reasoning: '思考')
      ..runtimeContext = '运行时上下文'
      ..subagentSummary = '子代理总结';
    final summary = DshSessionSummary(
      sessionId: 's1',
      title: '会话标题',
      updatedAt: 1,
      running: true,
      blank: false,
      cwd: '/agent',
      turnCount: 2,
      stepCount: 3,
      outputTokens: 20,
    );
    await DshChatCache.write(
      's1',
      DshChatSnapshot(
        messages: [message],
        title: '会话标题',
        model: 'deepseek-chat',
        cwd: '/agent',
        running: true,
        summary: summary,
      ),
    );

    final restored = await DshChatCache.read('s1');
    expect(restored, isNotNull);
    expect(restored!.messages.single.content, '回复');
    expect(restored.messages.single.reasoning, '思考');
    expect(restored.messages.single.runtimeContext, '运行时上下文');
    expect(restored.messages.single.subagentSummary, '子代理总结');
    expect(restored.model, 'deepseek-chat');
    expect(restored.cwd, '/agent');
    expect(restored.running, isTrue);
    expect(restored.summary!.stepCount, 3);
    expect(restored.summary!.outputTokens, 20);
  });

  test('空正文的思考消息缓存往返后仍保持折叠字段', () async {
    await DshChatCache.write(
      's1',
      DshChatSnapshot(
        messages: [_message('m1', 'assistant', '', reasoning: '独立思考内容')],
      ),
    );

    final restored = await DshChatCache.read('s1');
    expect(restored, isNotNull);
    expect(restored!.messages.single.content, isEmpty);
    expect(restored.messages.single.reasoning, '独立思考内容');
  });

  test('流式正文固化为重启后可见的临时助手消息', () {
    final messages = [
      _message('u1', 'user', '问题'),
      _message('live', 'assistant', '', streaming: true),
    ];
    final snapshot = DshChatCache.materializeMessages(
      sessionId: 's1',
      messages: messages,
      liveText: '尚未收口的回复',
      liveReasoning: '尚未收口的思考',
    );

    expect(snapshot, hasLength(2));
    expect(snapshot.last.id, dshCachedLiveMessageId);
    expect(snapshot.last.content, '尚未收口的回复');
    expect(snapshot.last.reasoning, '尚未收口的思考');
    expect(snapshot.last.streaming, isFalse);
  });

  test('流式固化保留消息自身的思考、上下文与子代理总结', () {
    final streaming =
        _message('live', 'assistant', '', reasoning: '流式思考', streaming: true)
          ..runtimeContext = '注入上下文'
          ..subagentSummary = '子代理总结';

    final snapshot = DshChatCache.materializeMessages(
      sessionId: 's1',
      messages: [streaming],
    );

    expect(snapshot, hasLength(1));
    expect(snapshot.single.content, isEmpty);
    expect(snapshot.single.reasoning, '流式思考');
    expect(snapshot.single.runtimeContext, '注入上下文');
    expect(snapshot.single.subagentSummary, '子代理总结');
  });

  test('历史刷新不用空字段覆盖本地折叠内容', () {
    final current = _message('a1', 'assistant', '回复', reasoning: '思考')
      ..runtimeContext = '注入上下文'
      ..subagentSummary = '子代理总结';
    final incoming = _message('a1', 'assistant', '回复');

    final merged = dshMergeHistoryPreservingProgress(
      current: [current],
      incoming: [incoming],
      preserveLocalProgress: false,
    );

    expect(merged.single.reasoning, '思考');
    expect(merged.single.runtimeContext, '注入上下文');
    expect(merged.single.subagentSummary, '子代理总结');
  });

  test('会话运行中，DSH 只返回旧前缀时暂时保留流式进度', () {
    final current = [
      _message('u1', 'user', '问题'),
      _message('a2', 'assistant', '完整回复'),
    ];
    final incoming = [_message('u1', 'user', '问题')];

    final merged = dshMergeHistoryPreservingProgress(
      current: current,
      incoming: incoming,
      preserveLocalProgress: true,
    );
    expect(merged.map((m) => m.content), ['问题', '完整回复']);
  });

  test('同一消息内容变短时保留较完整版本', () {
    final merged = dshMergeHistoryPreservingProgress(
      current: [_message('a1', 'assistant', '已经显示的完整回复')],
      incoming: [_message('a1', 'assistant', '较短')],
      preserveLocalProgress: true,
    );
    expect(merged.single.content, '已经显示的完整回复');
  });

  test('正式助手消息到达后替换流式临时快照', () {
    final current = [
      _message('u1', 'user', '问题'),
      _message(dshCachedLiveMessageId, 'assistant', '部分回复'),
    ];
    final incoming = [
      _message('u1', 'user', '问题'),
      _message('a2', 'assistant', '最终完整回复'),
    ];

    final merged = dshMergeHistoryPreservingProgress(
      current: current,
      incoming: incoming,
      preserveLocalProgress: false,
    );
    expect(merged.map((m) => m.id), ['u1', 'a2']);
    expect(merged.last.content, '最终完整回复');
  });

  test('实时流仍活跃时不保留缓存助手消息，避免同一回复显示两份', () {
    final current = [
      _message('u1', 'user', '问题'),
      _message(dshCachedLiveMessageId, 'assistant', '同一段回复'),
      _message('live', 'assistant', '', streaming: true),
    ];
    final incoming = [_message('u1', 'user', '问题')];

    final merged = dshMergeHistoryPreservingProgress(
      current: current,
      incoming: incoming,
      preserveLocalProgress: true,
      incomingLiveVisible: true,
    );

    expect(merged.map((m) => m.id), ['u1']);
    expect(merged.where((m) => m.id == dshCachedLiveMessageId), isEmpty);
  });

  test('相同旧问题不会误确认刚发送的乐观消息', () {
    final old = _message('u1', 'user', '重复问题');
    final pending = _message('dsh-opt-2', 'user', '重复问题');

    final notConfirmed = dshMergeHistoryPreservingProgress(
      current: [old, pending],
      incoming: [_message('u1', 'user', '重复问题')],
      preserveLocalProgress: false,
    );
    expect(notConfirmed.any((m) => m.id == pending.id), isTrue);

    final confirmed = dshMergeHistoryPreservingProgress(
      current: [old, pending],
      incoming: [
        _message('u1', 'user', '重复问题'),
        _message('u2', 'user', '重复问题'),
      ],
      preserveLocalProgress: false,
    );
    expect(confirmed.any((m) => m.id == pending.id), isFalse);
  });

  test('会话结束后完全以 DSH history 为准', () {
    final merged = dshMergeHistoryPreservingProgress(
      current: [
        _message('u1', 'user', '问题'),
        _message('a2', 'assistant', '只存在于缓存的内容'),
      ],
      incoming: [_message('u1', 'user', '问题')],
      preserveLocalProgress: false,
    );
    expect(merged.map((m) => m.id), ['u1']);
  });

  test('识别 DSH 尚未落盘的旧前缀，供 turn/end 短时重试', () {
    expect(
      dshHistoryRegressed(
        current: [
          _message('u1', 'user', '问题'),
          _message(dshCachedLiveMessageId, 'assistant', '部分回复'),
        ],
        incoming: [_message('u1', 'user', '问题')],
      ),
      isTrue,
    );
    expect(
      dshHistoryRegressed(
        current: [
          _message('u1', 'user', '问题'),
          _message(dshCachedLiveMessageId, 'assistant', '部分回复'),
        ],
        incoming: [
          _message('u1', 'user', '问题'),
          _message('a2', 'assistant', 'DSH 最终回复'),
        ],
      ),
      isFalse,
    );
  });

  test('clear 使压缩前的新旧缓存同时失效', () async {
    await DshChatCache.write(
      's1',
      DshChatSnapshot(messages: [_message('m1', 'assistant', '旧历史')]),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('dsh_chat_history_cache_v1_s1', '[]');
    expect(await DshChatCache.read('s1'), isNotNull);

    await DshChatCache.clear('s1');

    expect(await DshChatCache.read('s1'), isNull);
    expect(prefs.getString('dsh_chat_history_cache_v1_s1'), isNull);
  });
}
