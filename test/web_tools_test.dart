import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/web_tools.dart';

void main() {
  group('WebTools.htmlToText', () {
    test('strips script/style and keeps visible text', () {
      const html = '''
<html>
  <head><style>.a{color:red}</style><script>alert(1)</script></head>
  <body><h1>标题</h1><p>正文 <b>加粗</b> &amp; 实体</p></body>
</html>
''';

      final text = WebTools.htmlToText(html);

      expect(text, contains('标题'));
      expect(text, contains('正文'));
      expect(text, contains('加粗'));
      expect(text, contains('& 实体'));
      expect(text, isNot(contains('<script')));
      expect(text, isNot(contains('alert')));
    });

    test('block tags become line breaks', () {
      final text = WebTools.htmlToText('<div>a</div><p>b</p><li>c</li>');

      expect(text, contains('\n'));
    });

    test('plain text without tags is trimmed', () {
      expect(WebTools.htmlToText('  纯文本  '), '纯文本');
    });
  });
}
