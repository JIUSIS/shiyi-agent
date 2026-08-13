import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 文本快照断言：
/// - 快照文件不存在：写入并跳过（首次生成）
/// - 已存在：必须逐字节一致，不一致即失败
///
/// 确认变更属预期时，删除对应快照文件后重跑测试即可重新生成。
void expectSnapshot(String actual, String path) {
  final file = File(path);
  if (!file.existsSync()) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(actual);
    // ignore: avoid_print
    print('快照已生成（首次）: $path');
    return;
  }
  expect(
    actual,
    file.readAsStringSync(),
    reason: '快照不一致: $path\n如确认是预期变更：删除该文件后重跑测试重新生成。',
  );
}
