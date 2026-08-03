import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/web_tools.dart';

void main() {
  test('parseBingRss extracts items and strips HTML', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
<channel>
<title>bing</title>
<item>
<title>Flutter 官网</title>
<link>https://flutter.dev</link>
<description>跨平台 <b>UI</b> 框架 &amp; 工具集</description>
<pubDate>Mon, 03 Aug 2026 08:00:00 GMT</pubDate>
</item>
<item>
<title>Dart 语言</title>
<link>https://dart.dev</link>
<description>客户端优化的编程语言</description>
</item>
</channel>
</rss>
''';
    final results = WebTools.parseBingRss(xml, maxResults: 5);
    expect(results.length, 2);
    expect(results[0].title, 'Flutter 官网');
    expect(results[0].url, 'https://flutter.dev');
    expect(results[0].snippet, '跨平台 UI 框架 & 工具集');
    expect(results[0].date, '2026-08-03');
    expect(results[1].title, 'Dart 语言');
  });

  test('parseBingRss respects maxResults and skips empty items', () {
    const xml = '''
<rss><channel>
<item><title>A</title><link>https://a.com</link></item>
<item><title>B</title><link>https://b.com</link></item>
<item><title>C</title><link>https://c.com</link></item>
</channel></rss>
''';
    final results = WebTools.parseBingRss(xml, maxResults: 2);
    expect(results.length, 2);
  });

  test('parseDuckDuckGoHtml decodes redirect links and extracts snippet', () {
    const html = '''
<div class="result__body">
  <h2 class="result__title"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&amp;rut=abc123">示例标题</a></h2>
  <span class="result__timestamp">2 days ago</span>
  <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage">这是<b>摘要</b>内容。</a>
</div>
<div class="result__body">
  <h2 class="result__title"><a rel="nofollow" class="result__a" href="https://plain.example.org/x">无跳转链接</a></h2>
</div>
''';
    final results = WebTools.parseDuckDuckGoHtml(html);
    expect(results.length, 2);
    expect(results[0].title, '示例标题');
    expect(results[0].url, 'https://example.com/page');
    expect(results[0].snippet, '这是摘要内容。');
    expect(results[0].date, '2 days ago');
    expect(results[1].title, '无跳转链接');
    expect(results[1].url, 'https://plain.example.org/x');
  });

  test('parseDuckDuckGoHtml respects maxResults and skips empty anchors', () {
    const html = '''
<div class="result__body"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.com">A</a></div>
<div class="result__body"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fb.com">B</a></div>
<div class="result__body"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fc.com">C</a></div>
''';
    final results = WebTools.parseDuckDuckGoHtml(html, maxResults: 2);
    expect(results.length, 2);
    expect(results[0].url, 'https://a.com');
    expect(results[1].url, 'https://b.com');
  });
}