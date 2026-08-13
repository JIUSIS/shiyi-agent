import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 显式生成模式：首次创建快照时运行
/// `flutter test --dart-define=GENERATE_SNAPSHOTS=true test/<对应测试>`
const bool _generateSnapshots = bool.fromEnvironment('GENERATE_SNAPSHOTS');

/// 文本快照断言：
/// - 快照文件不存在：**失败**（防误删快照后静默重建的假阴性）；
///   首次生成需显式传 `--dart-define=GENERATE_SNAPSHOTS=true`。
/// - 已存在：必须逐字节一致，不一致即失败。
///
/// 确认变更属预期时：删除对应快照文件，再用生成模式重跑。
void expectSnapshot(String actual, String path) {
  final file = File(path);
  if (!file.existsSync()) {
    if (_generateSnapshots) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(actual);
      return;
    }
    fail('快照缺失: $path\n'
        '首次生成请运行：flutter test --dart-define=GENERATE_SNAPSHOTS=true <测试文件>\n'
        '（删除快照文件后也必须用生成模式重建，普通运行不会静默重建）');
  }
  expect(
    actual,
    file.readAsStringSync(),
    reason: '快照不一致: $path\n'
        '如确认是预期变更：删除该文件后用 --dart-define=GENERATE_SNAPSHOTS=true 重建。',
  );
}
