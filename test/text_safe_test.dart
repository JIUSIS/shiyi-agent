import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/text_safe.dart';

/// UTF-16 安全层（docs/fix-log.md #405）：
/// 按码元截断会切出孤立代理项 → Flutter 文字引擎崩溃 + 请求体非法 UTF-8 被断连。
void main() {
  // 🎯 = U+1F3AF（一对代理项）；😀 = U+1F600
  const dart = '🎯';
  const grin = '😀';

  test('hasLoneSurrogate：成对 emoji 正常，孤立代理项被识别', () {
    expect(hasLoneSurrogate('hello $dart world'), isFalse);
    expect(hasLoneSurrogate('纯中文😀emoji'), isFalse);
    // 手动切一半
    expect(hasLoneSurrogate(dart.substring(0, 1)), isTrue);
    expect(hasLoneSurrogate(dart.substring(1, 2)), isTrue);
    expect(hasLoneSurrogate('${dart.substring(0, 1)}tail'), isTrue);
  });

  test('sanitizeUtf16：孤立代理项换成 U+FFFD，成对的不动', () {
    final broken = 'a${dart.substring(0, 1)}b${dart.substring(1, 2)}c';
    final fixed = sanitizeUtf16(broken);
    expect(hasLoneSurrogate(fixed), isFalse);
    expect(fixed, 'a\uFFFDb\uFFFDc');
    // 正常文本原样返回（含 emoji）
    expect(sanitizeUtf16('保留 $dart $grin'), '保留 $dart $grin');
    expect(sanitizeUtf16(''), '');
  });

  test('cutRunes：不会把 emoji 劈成两半', () {
    final text = 'abc$dart$grin'; // 码点：a b c 🎯 😀 = 5 个
    expect(cutRunes(text, 10), text);
    final cut3 = cutRunes(text, 3, ellipsis: '');
    expect(cut3, 'abc');
    final cut4 = cutRunes(text, 4, ellipsis: '');
    expect(cut4, 'abc$dart'); // 第 4 个码点整个 emoji
    expect(hasLoneSurrogate(cut4), isFalse);
    // 旧写法会切出半个：text.substring(0, 4) 正好劈开 🎯
    expect(hasLoneSurrogate(text.substring(0, 4)), isTrue);
    expect(cutRunes(text, 4), 'abc$dart…');
  });

  test('tailRunes：尾部截取同样不劈 emoji', () {
    final text = '$dart$grin-abc'; // 🎯 😀 - a b c = 6 码点
    final tail = tailRunes(text, 4, ellipsis: '');
    expect(tail, '-abc');
    final tail2 = tailRunes(text, 5, ellipsis: '');
    expect(tail2, '$grin-abc'); // 第 5 个码点是整个 😀
    expect(hasLoneSurrogate(tail2), isFalse);
    // 旧写法：text.substring(len-5) 正好劈开 😀
    expect(hasLoneSurrogate(text.substring(text.length - 5)), isTrue);
  });

  test('超长文本（真实场景：流式正文里混 emoji）净化后一定合法', () {
    // 让第 300 个码元正好落在 🎯 的代理对中间：299 个 'a' + 🎯
    final raw = '${'a' * 299}$dart${'b' * 60}';
    final broken = raw.substring(0, 300) + raw.substring(raw.length - 40);
    expect(hasLoneSurrogate(broken), isTrue);
    final fixed = sanitizeUtf16(broken);
    expect(hasLoneSurrogate(fixed), isFalse);
    // 净化后能安全取码元（= 可安全编码成 UTF-8 发请求）
    expect(() => fixed.codeUnits, returnsNormally);
  });
}
