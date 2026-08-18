import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/models.dart';

/// ChatMessage.fromMap 脏数据兜底测试：迁移/损坏库读出 null 或错误类型
/// 时不抛异常，取默认值（与 Session/MemoryEntry 的 tryParse 风格一致）。
void main() {
  test('字段缺失取默认值，不抛异常', () {
    final m = ChatMessage.fromMap(const {});
    expect(m.id, '');
    expect(m.sessionId, '');
    expect(m.role, 'user');
    expect(m.createdAt, 0);
    expect(m.archived, isFalse);
    expect(m.toolCalls, isEmpty);
  });

  test('错误类型不抛异常（created_at 为字符串等）', () {
    final m = ChatMessage.fromMap(const {
      'id': 12345,
      'session_id': 678,
      'role': 'assistant',
      'created_at': '1710000000000',
      'archived': '1',
    });
    expect(m.id, '12345');
    expect(m.sessionId, '678');
    expect(m.role, 'assistant');
    expect(m.createdAt, 1710000000000); // 数字字符串可解析
    expect(m.archived, isTrue); // 数字字符串 '1' 解析为 1
  });

  test('正常数据往返不受影响', () {
    final m = ChatMessage.fromMap(const {
      'id': 'm1',
      'session_id': 's1',
      'role': 'user',
      'content': '你好',
      'created_at': 1710000000000,
      'archived': 0,
    });
    expect(m.id, 'm1');
    expect(m.sessionId, 's1');
    expect(m.role, 'user');
    expect(m.content, '你好');
    expect(m.createdAt, 1710000000000);
  });

  test('role 为 null 时取 user 默认（toApiMap 不会发出 null role）', () {
    final m = ChatMessage.fromMap(const {
      'id': 'm2',
      'session_id': 's1',
      'created_at': 0,
    });
    expect(m.role, 'user');
    final api = m.toApiMap();
    expect(api['role'], 'user');
  });

  test('子代理结果可落库往返，但不进入模型上下文', () {
    final original = ChatMessage(
      id: 'm3',
      sessionId: 's1',
      role: 'assistant',
      content: '正文',
      subagentResult: '子代理报告',
      createdAt: 0,
    );
    final restored = ChatMessage.fromMap(original.toMap());

    expect(restored.subagentResult, '子代理报告');
    expect(restored.toApiMap().containsKey('subagent_result'), isFalse);
  });
}
