import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/tool_result_pruner.dart';

void main() {
  group('ToolResultPruner', () {
    const pruner = ToolResultPruner(
      thresholdChars: 100,
      headChars: 40,
      tailChars: 20,
    );

    test('未超阈值：原样返回（同一引用）', () {
      final text = 'a' * 100;
      expect(pruner.prune(text), same(text));
    });

    test('恰好阈值：不裁剪', () {
      final text = 'x' * 100;
      expect(pruner.prune(text), same(text));
    });

    test('超阈值：保留头部 + 标记 + 尾部', () {
      final text = 'A' * 60 + 'B' * 40 + 'C' * 60;
      final out = pruner.prune(text);
      expect(out, startsWith('A' * 40));
      expect(out, endsWith('C' * 20));
      expect(out, contains('[... 已裁剪中间内容 ...]'));
      expect(out.length, lessThan(100));
    });

    test('中文按码点计数，不按 UTF-16 单元', () {
      // 40 个中文 = 40 个码点（UTF-16 也是 40，用 emoji 测差异更明显）。
      final text = '汉' * 60 + '文' * 60;
      final out = pruner.prune(text);
      expect(out, startsWith('汉' * 40));
      expect(out, endsWith('文' * 20));
    });

    test('emoji（代理对）不会被切坏', () {
      // 每个 emoji 在 UTF-16 里占 2 个单元；runes 按码点切，不会劈开代理对。
      final text = '${'😀' * 60}中间${'🚀' * 60}';
      final out = pruner.prune(text);
      expect(out, startsWith('😀' * 40));
      expect(out, endsWith('🚀' * 20));
      // 不允许出现半个代理对（孤立代理单元）。
      expect(
        out.runes.any((r) => r >= 0xD800 && r <= 0xDFFF),
        isFalse,
        reason: '裁剪边界劈开了 emoji 代理对',
      );
    });

    test('结尾报错信息保留（掐头去尾的意义）', () {
      final body = '正常输出\n' * 50;
      final err = 'Error: fail (exit 1)'; // 19 码点，可完整落在 20 码点尾部内
      final out = pruner.prune(body + err);
      expect(out, endsWith(err));
      // 中间正文被裁剪掉，不会整体原样保留。
      expect(out.length, lessThan(body.length));
    });

    test('默认参数：32KB 阈值，16KB 头 + 4KB 尾', () {
      const def = ToolResultPruner();
      final text = 'a' * 40000 + '错误结尾';
      final out = def.prune(text);
      expect(out, startsWith('a' * 16384));
      expect(out, endsWith('错误结尾'));
    });
  });
}
