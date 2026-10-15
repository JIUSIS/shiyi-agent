import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/code_change.dart';
import 'package:shiyi_agent_app/core/group_chat.dart';
import 'package:shiyi_agent_app/widgets/code_change_card.dart';

/// 代码改动可见（docs/fix-log.md #410）：
/// 写入类工具的参数要能解析成「路径 + 行数 + -/+ 行」，并且群聊消息的
/// toolCalls 要能落库/读回。
void main() {
  test('file_write：路径 + 行数 + 内容行', () {
    final preview = codeChangePreview(
      'file_write',
      '{"path":"lib/a.dart","content":"line1\\nline2\\nline3"}',
    );
    expect(preview, isNotNull);
    expect(preview!.contains('lib/a.dart'), isTrue);
    expect(preview.contains('写入 3 行'), isTrue);
    expect(preview.contains('+ line1'), isTrue);
    expect(preview.contains('+ line3'), isTrue);
  });

  test('file_edit：旧行标 - 新行标 +', () {
    final preview = codeChangePreview(
      'file_edit',
      '{"path":"a.ts","old_string":"const a = 1;","new_string":"const a = 2;"}',
    );
    expect(preview, isNotNull);
    expect(preview!.contains('a.ts'), isTrue);
    expect(preview.contains('- const a = 1;'), isTrue);
    expect(preview.contains('+ const a = 2;'), isTrue);
  });

  test('apply_patch：只留 +/-/@@ 行', () {
    final preview = codeChangePreview(
      'apply_patch',
      '{"patch":"--- a/x\\n+++ b/x\\n@@ -1 +1 @@\\n-old\\n+new\\ncontext"}',
    );
    expect(preview, isNotNull);
    expect(preview!.contains('-old'), isTrue);
    expect(preview.contains('+new'), isTrue);
    expect(preview.contains('context'), isFalse);
  });

  test('非写入类工具不产生改动块', () {
    expect(codeChangePreview('file_read', '{"path":"a"}'), isNull);
    expect(codeChangePreview('web_search', '{"query":"x"}'), isNull);
    expect(isCodeChangeTool('file_read'), isFalse);
    expect(isCodeChangeTool('file_write'), isTrue);
  });

  test('入参摘要：写入类优先给路径（不再把整篇正文塞进胶囊）', () {
    expect(
      toolArgsSummary('file_write', '{"path":"docs/r.md","content":"很长很长"}'),
      'docs/r.md',
    );
    expect(toolArgsSummary('file_read', '{"path":"a/b.txt"}'), 'a/b.txt');
  });

  test('群聊消息带 toolCalls 能落库读回', () {
    final message = GroupMessage(
      id: 'm1',
      roomId: 'r1',
      role: 'agent',
      agentId: 'a1',
      content: '做完了',
      createdAt: 1,
      toolCalls: [
        GroupToolCall(
          name: 'file_write',
          argsSummary: 'lib/a.dart',
          summary: '📄 lib/a.dart\n✚ 写入 2 行',
          argsJson: '{"path":"lib/a.dart","content":"x"}',
          result: '已写入 /home/u/lib/a.dart（1 字符）',
          done: true,
        ),
        GroupToolCall(name: 'run_terminal', argsSummary: 'ls', summary: 'a b c'),
      ],
    );
    final restored = GroupMessage.fromMap(message.toMap());
    expect(restored.toolCalls.length, 2);
    expect(restored.toolCalls.first.name, 'file_write');
    expect(restored.toolCalls.first.argsSummary, 'lib/a.dart');
    expect(restored.toolCalls.first.summary.contains('写入 2 行'), isTrue);
    expect(restored.toolCalls.first.done, isTrue);
    // 调用日志要的完整入参/输出也要能落库读回
    expect(restored.toolCalls.first.argsJson.contains('"content":"x"'), isTrue);
    expect(restored.toolCalls.first.result.contains('已写入'), isTrue);
    expect(restored.toolCalls.last.name, 'run_terminal');
    // 没有工具时也不能炸
    final plain = GroupMessage.fromMap(
      GroupMessage(id: 'm2', roomId: 'r1', role: 'user', createdAt: 2).toMap(),
    );
    expect(plain.toolCalls, isEmpty);
  });
  testWidgets('工具胶囊展开后是完整入参 + 完整输出（不再截断，#413）', (tester) async {
    const longArgs =
        '{"command":"ls -la pelican_bike.svg && wc -c pelican_bike.svg"}';
    final longResult = List.generate(120, (i) => '输出行 $i').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              GroupToolPill(
                name: 'run_terminal',
                argsSummary: 'ls -la pelican…',
                argsJson: longArgs,
                result: longResult,
                done: true,
              ),
            ],
          ),
        ),
      ),
    );
    // 折叠时只有一行摘要，完整内容不在树里
    expect(find.text(longArgs), findsNothing);
    expect(find.text(longResult), findsNothing);
    // 点开胶囊 → 完整入参与完整输出都出现
    await tester.tap(find.text('终端命令'));
    await tester.pumpAndSettle();
    expect(find.text(longArgs), findsOneWidget);
    expect(find.text(longResult), findsOneWidget);
  });
}