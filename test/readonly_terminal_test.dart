import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/core/app_state.dart';

/// 只读代理终端拦截测试：写命令/重定向必须被拒，纯只读命令必须放行。
void main() {
  String? reject(String command) =>
      ShiyiState.rejectWriteCommandForTest(jsonEncode({'command': command}));

  group('写命令拦截', () {
    test('行首写命令被拒', () {
      expect(reject('rm -rf /sdcard/x'), isNotNull);
      expect(reject('mv a b'), isNotNull);
      expect(reject('mkdir x'), isNotNull);
      expect(reject('wget http://x'), isNotNull);
      expect(reject('pkg install vim'), isNotNull);
    });

    test('分隔符后的写命令被拒', () {
      expect(reject('ls; rm a'), isNotNull);
      expect(reject('cat a && mv a b'), isNotNull);
      expect(reject('grep x f || touch y'), isNotNull);
    });

    test('普通只读命令放行', () {
      expect(reject('ls -la'), isNull);
      expect(reject('find . -name "*.dart"'), isNull);
      expect(reject('grep -r foo lib'), isNull);
      expect(reject('cat file.txt'), isNull);
      expect(reject('head -n 20 log'), isNull);
      expect(reject('git status'), isNull);
      expect(reject('wc -l a b'), isNull);
    });
  });

  group('重定向拦截', () {
    test('普通命令后的重定向必须被拒（历史漏网场景）', () {
      expect(reject('ls > /sdcard/x.txt'), isNotNull, reason: '普通 > 漏网');
      expect(reject('cat a > b'), isNotNull);
      expect(reject('ls >> /sdcard/x.txt'), isNotNull, reason: '>> 追加漏网');
      expect(reject('cat a >> b'), isNotNull);
      expect(reject('echo hi > f'), isNotNull);
      expect(reject('ls 2>/dev/null'), isNotNull);
      expect(reject('cmd >& f'), isNotNull);
    });

    test('fd 合并（2>&1）是只读用法，放行', () {
      expect(reject('ls 2>&1'), isNull);
      expect(reject('grep x f 1>&2'), isNull);
      expect(reject('cat a 2>&1 | head'), isNull);
    });

    test('行首重定向被拒', () {
      expect(reject('> f echo hi'), isNotNull);
      expect(reject('>> f cat a'), isNotNull);
    });
  });

  group('参数边界', () {
    test('空/缺参数放行（交给执行层处理）', () {
      expect(ShiyiState.rejectWriteCommandForTest('{}'), isNull);
      expect(ShiyiState.rejectWriteCommandForTest('bad json'), isNull);
      expect(reject(''), isNull);
    });
  });
}
