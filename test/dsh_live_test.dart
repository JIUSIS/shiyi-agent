import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/dsh_live.dart';

void main() {
  Map<String, dynamic> ev(String type, int seq, Map<String, dynamic> data) => {
    'type': type,
    'seq': seq,
    'time': 1786000000000 + seq,
    'data': data,
  };

  test('decodeFrame: ServerRequest envelope with typed payload', () {
    const raw =
        '{"type":"server-request","rpcId":"rpc-1","method":"session/event","payload":{"type":"session/event","sessionId":"sess-1","event":{"type":"assistant/chunk","seq":3}}}';
    final frame = DshWsDownlink.decodeFrame(raw);
    expect(frame, isNotNull);
    expect(frame!['type'], 'session/event');
    expect(frame['sessionId'], 'sess-1');
    expect((frame['event'] as Map)['type'], 'assistant/chunk');
  });

  test('decodeFrame: ServerRequest method is the frame type', () {
    const raw =
        '{"type":"server-request","rpcId":"rpc-2","method":"host/session-status","payload":{"sessionId":"sess-1","running":true}}';
    final frame = DshWsDownlink.decodeFrame(raw);
    expect(frame, isNotNull);
    expect(frame!['type'], 'host/session-status');
    expect(frame['sessionId'], 'sess-1');
    expect(frame['running'], true);
  });

  test('decodeFrame: ServerRequest 保留 rpcId 供 question/requested 应答', () {
    const raw =
        '{"type":"server-request","rpcId":"rpc-q1","method":"question/requested","payload":{"type":"question/requested","sessionId":"sess-1","questions":[{"id":"q1","question":"继续？"}]}}';
    final frame = DshWsDownlink.decodeFrame(raw);
    expect(frame, isNotNull);
    expect(frame!['type'], 'question/requested');
    expect(frame['rpcId'], 'rpc-q1');
    expect(frame['questions'], hasLength(1));
  });

  test('decodeFrame: bare MuxFrame and SSE data line', () {
    final bare = DshWsDownlink.decodeFrame(
      '{"type":"session/subscribed","sessionId":"sess-1","lastSeq":12}',
    );
    expect(bare!['type'], 'session/subscribed');
    expect(bare['lastSeq'], 12);

    final sse = DshWsDownlink.decodeFrame(
      'data: {"type":"stream/error","error":{"code":"internal","message":"x"}}',
    );
    expect(sse!['type'], 'stream/error');
  });

  test('decodeFrame: invalid JSON and DONE are ignored', () {
    expect(DshWsDownlink.decodeFrame('not-json'), isNull);
    expect(DshWsDownlink.decodeFrame('data: [DONE]'), isNull);
    expect(DshWsDownlink.decodeFrame(''), isNull);
  });

  test('uriFor: http to ws, https to wss', () {
    expect(
      DshWsDownlink.uriFor('http://127.0.0.1:3080', 'events.mux').toString(),
      'ws://127.0.0.1:3080/api/events.mux',
    );
    expect(
      DshWsDownlink.uriFor('https://example.test', 'events.host').toString(),
      'wss://example.test/api/events.host',
    );
  });

  test(
    'live: text-delta and reasoning-delta accumulate, other chunks ignored',
    () {
      final live = DshLiveTurn();
      expect(
        live.ingest(
          ev('assistant/chunk', 1, {
            'chunk': {
              'type': 'block-start',
              'index': 0,
              'blockType': 'reasoning',
            },
          }),
        ),
        isFalse,
      );
      expect(
        live.ingest(
          ev('assistant/chunk', 2, {
            'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': 'xian'},
          }),
        ),
        isTrue,
      );
      expect(
        live.ingest(
          ev('assistant/chunk', 3, {
            'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': 'xiang'},
          }),
        ),
        isTrue,
      );
      expect(
        live.ingest(
          ev('assistant/chunk', 4, {
            'chunk': {'type': 'text-delta', 'index': 1, 'text': 'ni'},
          }),
        ),
        isTrue,
      );
      expect(
        live.ingest(
          ev('assistant/chunk', 5, {
            'chunk': {'type': 'text-delta', 'index': 1, 'text': 'hao'},
          }),
        ),
        isTrue,
      );
      expect(
        live.ingest(
          ev('assistant/chunk', 6, {
            'chunk': {
              'type': 'usage',
              'usage': {'input': 1},
            },
          }),
        ),
        isFalse,
      );
      expect(
        live.ingest(
          ev('assistant/chunk', 7, {
            'chunk': {'type': 'finish', 'reason': 'stop'},
          }),
        ),
        isFalse,
      );
      expect(live.open, isTrue);
      expect(live.reasoning, 'xianxiang');
      expect(live.text, 'nihao');
    },
  );

  test('live: duplicate seq is ignored', () {
    final live = DshLiveTurn();
    live.ingest(
      ev('assistant/chunk', 8, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': 'A'},
      }),
    );
    expect(
      live.ingest(
        ev('assistant/chunk', 8, {
          'chunk': {'type': 'text-delta', 'index': 0, 'text': 'A'},
        }),
      ),
      isFalse,
    );
    expect(live.text, 'A');
  });

  test('live: 较短或空的 history 快照不能覆盖 WebSocket 进度', () {
    final current = DshLiveTurn();
    current.ingest(
      ev('assistant/chunk', 5, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '已经输出一部分'},
      }),
    );

    final shorter = DshLiveTurn();
    shorter.ingest(
      ev('assistant/chunk', 4, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '已经输出'},
      }),
    );
    expect(current.mergeProgressFrom(shorter), isFalse);
    expect(current.text, '已经输出一部分');
    expect(current.lastSeq, 5);

    final staleClosed = DshLiveTurn()..lastSeq = 6;
    expect(current.mergeProgressFrom(staleClosed), isFalse);
    expect(current.open, isTrue);
    expect(current.text, '已经输出一部分');
  });

  test('live: 更新的 history 快照可以推进正文和 seq', () {
    final current = DshLiveTurn();
    current.ingest(
      ev('assistant/chunk', 5, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '前半段'},
      }),
    );
    final newer = DshLiveTurn();
    newer.ingest(
      ev('assistant/chunk', 5, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '前半段'},
      }),
    );
    newer.ingest(
      ev('assistant/chunk', 6, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '后半段'},
      }),
    );

    expect(current.mergeProgressFrom(newer), isTrue);
    expect(current.text, '前半段后半段');
    expect(current.lastSeq, 6);
  });

  test('live: 只有显式确认后才接纳正式收口', () {
    final current = DshLiveTurn();
    current.ingest(
      ev('assistant/chunk', 7, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '完整回复'},
      }),
    );
    final closed = DshLiveTurn()..lastSeq = 8;

    expect(current.mergeProgressFrom(closed), isFalse);
    expect(current.open, isTrue);
    expect(current.mergeProgressFrom(closed, allowClose: true), isTrue);
    expect(current.open, isFalse);
    expect(current.text, isEmpty);
    expect(current.lastSeq, 8);
  });

  test('live: 空的思考占位也不能被旧 history 提前关闭', () {
    final current = DshLiveTurn()..begin();
    final staleClosed = DshLiveTurn();

    expect(current.mergeProgressFrom(staleClosed), isFalse);
    expect(current.open, isTrue);
    expect(current.hasVisible, isFalse);
  });

  test('live: 收口后的旧 history 不能重新打开流式气泡', () {
    final current = DshLiveTurn();
    current.ingest(
      ev('assistant/chunk', 8, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '已完成'},
      }),
    );
    current.ingest(ev('turn/end', 10, {}));

    final stale = DshLiveTurn();
    stale.ingest(
      ev('assistant/chunk', 9, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '旧快照'},
      }),
    );

    expect(current.mergeProgressFrom(stale), isFalse);
    expect(current.open, isFalse);
    expect(current.text, isEmpty);
    expect(current.lastSeq, 10);
  });

  test('live: continueTurn 清空步骤正文但保留整轮思考', () {
    final live = DshLiveTurn();
    live.ingest(
      ev('assistant/chunk', 7, {
        'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': '先检查'},
      }),
    );
    live.ingest(
      ev('assistant/chunk', 8, {
        'chunk': {'type': 'text-delta', 'index': 1, 'text': '中间结论'},
      }),
    );

    live.continueTurn();

    expect(live.open, isTrue);
    expect(live.text, isEmpty);
    expect(live.reasoning, '先检查');
    expect(live.hasVisible, isTrue);
    expect(live.lastSeq, 8);
    expect(
      live.ingest(
        ev('assistant/chunk', 9, {
          'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': '再确认'},
        }),
      ),
      isTrue,
    );
    expect(live.reasoning, '先检查再确认');
  });

  test('live: text-delta 里的 think 标签拆进 reasoning', () {
    final live = DshLiveTurn();
    live.ingest(
      ev('assistant/chunk', 1, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '<think>先想'},
      }),
    );
    live.ingest(
      ev('assistant/chunk', 2, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': '一下</think>答案'},
      }),
    );
    expect(live.text, '答案');
    expect(live.reasoning, '先想一下');
  });

  test('live: assistant/message 保留思考，turn/end 才关闭整轮缓冲', () {
    final live = DshLiveTurn();
    live.ingest(
      ev('assistant/chunk', 1, {
        'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': '先分析'},
      }),
    );
    live.ingest(
      ev('assistant/chunk', 2, {
        'chunk': {'type': 'text-delta', 'index': 1, 'text': 'half'},
      }),
    );
    expect(live.open, isTrue);
    expect(
      live.ingest(
        ev('assistant/message', 3, {
          'message': {
            'content': [
              {'type': 'text', 'text': 'full'},
            ],
          },
        }),
      ),
      isTrue,
    );
    expect(live.open, isTrue);
    expect(live.text, isEmpty);
    expect(live.reasoning, '先分析');

    live.ingest(
      ev('assistant/chunk', 4, {
        'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': '再处理'},
      }),
    );
    expect(live.reasoning, '先分析再处理');
    live.ingest(
      ev('turn/end', 5, {
        'reason': {'kind': 'completed'},
      }),
    );
    expect(live.open, isFalse);
    expect(live.text, isEmpty);
    expect(live.reasoning, isEmpty);
  });

  test('live: history 重建跨工具步骤累积 reasoning', () {
    final live = DshLiveTurn.fromHistoryValue({
      'events': [
        {
          'event': ev('assistant/chunk', 1, {
            'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': '第一步'},
          }),
        },
        {
          'event': ev('assistant/message', 2, {
            'message': {
              'content': [
                {'type': 'tool-call', 'name': 'read'},
              ],
            },
          }),
        },
        {
          'event': ev('assistant/chunk', 3, {
            'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': '第二步'},
          }),
        },
      ],
    });

    expect(live.open, isTrue);
    expect(live.reasoning, '第一步第二步');
  });

  test('live: tool/call before stream is ignored; after stream is kept', () {
    final live = DshLiveTurn();
    expect(
      live.ingest(
        ev('tool/call', 1, {'callId': 'c1', 'name': 'bash', 'arguments': '{}'}),
      ),
      isFalse,
    );
    live.ingest(
      ev('assistant/chunk', 2, {
        'chunk': {'type': 'text-delta', 'index': 0, 'text': 'look'},
      }),
    );
    expect(
      live.ingest(
        ev('tool/call', 3, {
          'callId': 'c1',
          'name': 'bash',
          'arguments': '{"cmd":"ls"}',
        }),
      ),
      isTrue,
    );
    expect(live.toolCalls, hasLength(1));
    expect(live.toolCalls.first.name, 'bash');
    expect(
      live.ingest(
        ev('tool/call', 4, {
          'callId': 'c1',
          'name': 'bash',
          'arguments': '{"cmd":"ls"}',
        }),
      ),
      isFalse,
    );
  });

  test('fromHistoryValue: only trailing open chunks remain', () {
    final live = DshLiveTurn.fromHistoryValue({
      'events': [
        {
          'event': ev('assistant/chunk', 1, {
            'chunk': {'type': 'text-delta', 'index': 0, 'text': 'old'},
          }),
        },
        {
          'event': ev('assistant/message', 2, {
            'message': {
              'content': [
                {'type': 'text', 'text': 'old-full'},
              ],
            },
          }),
        },
        {
          'event': ev('assistant/chunk', 3, {
            'chunk': {'type': 'reasoning-delta', 'index': 0, 'text': 'think'},
          }),
        },
        {
          'event': ev('assistant/chunk', 4, {
            'chunk': {'type': 'text-delta', 'index': 1, 'text': 'now'},
          }),
        },
      ],
    });
    expect(live.open, isTrue);
    expect(live.reasoning, 'think');
    expect(live.text, 'now');
    expect(live.lastSeq, 4);
  });

  test('ingest: mux session/event wrapper is accepted', () {
    final live = DshLiveTurn();
    expect(
      live.ingest({
        'type': 'session/event',
        'sessionId': 'sess-1',
        'event': ev('assistant/chunk', 9, {
          'chunk': {'type': 'text-delta', 'index': 0, 'text': 'hi'},
        }),
      }),
      isTrue,
    );
    expect(live.text, 'hi');
  });
}
