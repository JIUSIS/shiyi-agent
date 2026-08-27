import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/tool_output_spill.dart';
import 'package:shiyi_agent_app/core/tool_result_pruner.dart';

void main() {
  group('ToolOutputSpill', () {
    test('未超阈值不落地，返回原文引用', () async {
      final dir = Directory.systemTemp.createTempSync('shiyi-spill-');
      addTearDown(() => dir.deleteSync(recursive: true));
      const text = 'short';
      final out = await ToolOutputSpill.maybeSpill(
        text: text,
        toolName: 'run_terminal',
        workspaceDir: dir.path,
      );
      expect(out, same(text));
      expect(
        Directory('${dir.path}/${ToolOutputSpill.relativeDir}').existsSync(),
        isFalse,
      );
    });

    test('超阈值写全文，模型只看到头尾和路径', () async {
      final dir = Directory.systemTemp.createTempSync('shiyi-spill-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final text = '${'A' * 3000}MIDDLE${'Z' * 3000}';
      final at = DateTime.utc(2026, 8, 27, 4, 0, 0);
      final out = await ToolOutputSpill.maybeSpill(
        text: text,
        toolName: 'run_terminal',
        workspaceDir: dir.path,
        at: at,
      );
      expect(out, isNot(contains('MIDDLE')));
      expect(out, contains(ToolOutputSpill.spilledMarker));
      expect(out, startsWith('A' * 2400));
      expect(out, contains('Z' * 1200));
      final listed = RegExp(
        '${ToolOutputSpill.spilledMarker} (.+?)，共',
      ).firstMatch(out);
      expect(listed, isNotNull);
      expect(File(listed!.group(1)!).readAsStringSync(), text);
    });

    test('已经是 spill 信封时不再复制', () async {
      final dir = Directory.systemTemp.createTempSync('shiyi-spill-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final text = 'x' * 5000 + '\n完整输出已写入 /tmp/a.txt';
      final out = await ToolOutputSpill.maybeSpill(
        text: text,
        toolName: 'web_extract',
        workspaceDir: dir.path,
      );
      expect(out, same(text));
    });

    test('file_read 超长只裁预览，不要求复制', () {
      final text = '${'H' * 7000}SKIP${'T' * 5000}';
      final out = ToolOutputSpill.boundLoadedFile(
        text: text,
        path: '/storage/emulated/0/agent/a.dart',
        byteLength: text.length,
      );
      expect(out, startsWith('H' * 6000));
      expect(out, endsWith('T' * 3000));
      expect(out, isNot(contains('SKIP')));
      expect(out, contains(ToolOutputSpill.fileOnDiskMarker));
      expect(out, contains('/storage/emulated/0/agent/a.dart'));
    });

    test('file_read 未超预算原样返回', () {
      const text = 'hello';
      expect(
        ToolOutputSpill.boundLoadedFile(
          text: text,
          path: '/tmp/a.txt',
          byteLength: 5,
        ),
        same(text),
      );
    });
  });

  group('compactOldToolOutputs', () {
    Map<String, dynamic> asst(String id) => {
      'role': 'assistant',
      'content': '',
      'tool_calls': [
        {
          'id': id,
          'type': 'function',
          'function': {'name': 'file_read', 'arguments': '{}'},
        },
      ],
    };

    test('超过 3 组时只截断较早 tool 输出，不抽轮', () {
      final long = 'x' * 4000;
      final msgs = <Map<String, dynamic>>[
        {'role': 'system', 'content': 'FROZEN'},
        {'role': 'user', 'content': 'go'},
        for (var i = 1; i <= 5; i++) ...[
          asst('c$i'),
          {'role': 'tool', 'content': long, 'tool_call_id': 'c$i'},
        ],
      ];
      final out = ToolOutputSpill.compactOldToolOutputs(msgs);
      final tools = out.where((m) => m['role'] == 'tool').toList();
      expect(tools.length, 5);
      expect(out.where((m) => m['role'] == 'assistant').length, 5);
      expect((tools[0]['content'] as String).length, lessThan(long.length));
      expect(tools[0]['content'], contains('已裁剪中间内容'));
      expect(tools[4]['content'], long);
      expect(out.first['content'], 'FROZEN');
    });

    test('不超过 3 组时返回原列表', () {
      final msgs = [
        {'role': 'user', 'content': 'a'},
        asst('c1'),
        {'role': 'tool', 'content': 'one', 'tool_call_id': 'c1'},
      ];
      expect(ToolOutputSpill.compactOldToolOutputs(msgs), same(msgs));
    });
  });

  group('ToolCallScheduler', () {
    test('多个只读工具才并行，写入或终端保持串行', () {
      expect(
        ToolCallScheduler.runInParallel(['file_read', 'web_search']),
        isTrue,
      );
      expect(
        ToolCallScheduler.runInParallel(['file_read', 'run_terminal']),
        isFalse,
      );
      expect(ToolCallScheduler.runInParallel(['file_read']), isFalse);
      expect(
        ToolCallScheduler.runInParallel(['file_write', 'file_read']),
        isFalse,
      );
    });

    test('只读白名单与工具注册表一致（加工具时两边一起改）', () {
      final registry = ShiyiState.buildToolRegistryForTest(windows: false);
      expect({
        for (final t in registry)
          if (t.readOnly) t.name,
      }, ToolCallScheduler.readOnlyToolNames);
    });
  });

  test('takeHead/takeTail 不劈开 emoji', () {
    const text = '😀🚀汉';
    expect(ToolOutputSpill.takeHead(text, 2), '😀🚀');
    expect(ToolOutputSpill.takeTail(text, 1), '汉');
    expect(
      ToolResultPruner.codePointLength(ToolOutputSpill.takeHead(text, 2)),
      2,
    );
  });
}
