import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/dsh_api.dart';

/// rc.2 的 `credentials/describe` 结果是**按 ref 键控的 record**
/// （`{ref: {configured, source?, writable}}`），不是 `{credentials:{…}}`。
/// 见 docs/fix-log.md #396。
void main() {
  test('rc.2 record 形状：直接按 ref 键读', () {
    final slots = DshCredentialSlot.fromDescribeValue({
      'DEEPSEEK_API_KEY': {'configured': true, 'writable': true},
      'SHIYI_API_KEY': {
        'configured': false,
        'source': 'settings',
        'writable': false,
      },
    });
    expect(slots, hasLength(2));
    final deepseek = slots.firstWhere((s) => s.ref == 'DEEPSEEK_API_KEY');
    expect(deepseek.set, isTrue);
    expect(deepseek.writable, isTrue);
    final shiyi = slots.firstWhere((s) => s.ref == 'SHIYI_API_KEY');
    expect(shiyi.set, isFalse);
    expect(shiyi.writable, isFalse);
  });

  test('旧版包装形状仍然认（credentials / slots）', () {
    final wrapped = DshCredentialSlot.fromDescribeValue({
      'credentials': {
        'A_KEY': {'configured': true},
      },
    });
    expect(wrapped.single.ref, 'A_KEY');
    expect(wrapped.single.set, isTrue);

    final slots = DshCredentialSlot.fromDescribeValue({
      'slots': [
        {
          'path': ['X_KEY'],
          'set': true,
          'writable': true,
        },
      ],
    });
    expect(slots.single.ref, 'X_KEY');
  });

  test('空结果不炸', () {
    expect(DshCredentialSlot.fromDescribeValue(const {}), isEmpty);
  });
}
