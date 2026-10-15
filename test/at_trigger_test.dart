import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/at_trigger.dart';

/// @-引用触发（官方 @-引用：`fileReferences/list` +
/// `sessionReferenceResolver/candidates`）。
void main() {
  test('独立 @ 才触发（行首或空白之后）', () {
    expect(atReferenceQuery('@'), '');
    expect(atReferenceQuery('看看 @main'), 'main');
    expect(atReferenceQuery('@lib/'), 'lib/');
    expect(isAtReferenceTrigger('帮我改 @a'), isTrue);
    expect(isAtReferenceTrigger('帮我改@a'), isFalse); // 句中 @ 不触发
    expect(isAtReferenceTrigger('a@b.com'), isFalse); // 邮件不触发
    expect(isAtReferenceTrigger('没有 at'), isFalse);
    expect(atReferenceQuery('@a @b'), 'b');
  });

  test('选中后把末尾 @词 换成 @引用 + 空格，保留正文', () {
    expect(replaceAtReference('看看 @ma', 'src/main.dart'), '看看 @src/main.dart ');
    expect(replaceAtReference('@', 'a.txt'), '@a.txt ');
    expect(replaceAtReference('没有引用', 'a.txt'), '没有引用');
    expect(replaceAtReference('看看 @ma', ''), '看看 @ma');
  });
}
