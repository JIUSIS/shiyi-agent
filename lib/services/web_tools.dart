import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 单条搜索结果。
class WebSearchResult {
  final String title;
  final String url;
  final String snippet;

  /// 来源发布日期（Bing 解析为 YYYY-MM-DD，DuckDuckGo 可能是相对时间/原文），解析失败为 null。
  final String? date;
  WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
    this.date,
  });
}

/// 联网工具：web_search（DuckDuckGo/Bing 自动切换，零配置）与
/// web_extract（直连优先，Jina Reader 兜底，零配置）。
class WebTools {
  static const Duration _searchTimeout = Duration(seconds: 12);
  static const Duration _probeTimeout = Duration(seconds: 4);
  static const Duration _extractTimeout = Duration(seconds: 15);
  static const int _maxSearch = 5;

  // DuckDuckGo 连通性探测结果缓存（用于判断代理是否生效），10 分钟内不重复探测。
  static bool? _ddgReachable;
  static DateTime? _ddgProbeAt;
  static const Duration _probeTtl = Duration(minutes: 10);

  static const Map<String, String> _ua = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 14) ShiYi/1.0',
  };

  /// 联网搜索，返回结构化结果列表。
  /// 先探测 DuckDuckGo：能访问（开了代理）直接用 DuckDuckGo，被墙则用 Bing；
  /// 首选源失败时自动降级到另一个。
  static Future<List<WebSearchResult>> search(
    String query, {
    int maxResults = _maxSearch,
  }) async {
    final q = Uri.encodeQueryComponent(query);
    final limit = maxResults.clamp(1, 10);
    final useDdg = await _probeDuckDuckGo();
    var out = useDdg
        ? await _trySearch(() => _searchDuckDuckGo(q, limit))
        : await _trySearch(() => _searchBing(q, limit));
    if (out != null) return out;
    // 首选源失败 → 降级到另一个。
    out = useDdg
        ? await _trySearch(() => _searchBing(q, limit))
        : await _trySearch(() => _searchDuckDuckGo(q, limit));
    if (out != null) return out;
    throw Exception('联网搜索失败（网络不可用或搜索服务拒绝请求）');
  }

  /// 抓取网页正文，返回文本，超长自动截断。
  /// 直连目标站优先：r.jina.ai 在部分网络不可达，不能作为唯一通道。
  static Future<String> extract(String url, {int maxChars = 8000}) async {
    final u = Uri.parse(url);
    if (u.scheme != 'http' && u.scheme != 'https') {
      throw Exception('不支持的链接：$url');
    }
    final errors = <String>[];
    try {
      return await _fetchDirect(u, maxChars);
    } catch (e) {
      errors.add('直连: $e');
    }
    try {
      return await _fetchViaJina(u, maxChars);
    } catch (e) {
      errors.add('Jina: $e');
    }
    throw Exception('网页抓取失败（直连与 Jina Reader 均失败）：\n${errors.join('\n')}');
  }

  static Future<String> _fetchDirect(Uri u, int maxChars) async {
    final resp = await http
        .get(
          u,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14; ShiYi/1.0) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,text/plain,*/*',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
          },
        )
        .timeout(_extractTimeout);
    if (resp.statusCode == 403) {
      throw Exception('HTTP 403：站点启用了防爬（拒绝自动抓取）。');
    }
    if (resp.statusCode == 429) {
      throw Exception('HTTP 429：请求频率受限。');
    }
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}。');
    }
    final raw = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final text = htmlToText(raw);
    if (text.isEmpty) {
      throw Exception('网页内容为空（可能是 JS 渲染页面或防爬空页）。');
    }
    return _truncate(text, maxChars);
  }

  static Future<String> _fetchViaJina(Uri u, int maxChars) async {
    http.Response resp;
    try {
      resp = await http
          .get(
            Uri.parse('https://r.jina.ai/${u.toString()}'),
            headers: {
              'User-Agent': 'Mozilla/5.0 (Linux; Android 14) ShiYi/1.0',
              'Accept': 'text/plain, text/markdown',
            },
          )
          .timeout(_extractTimeout);
    } on TimeoutException {
      throw Exception('Jina 抓取超时（15 秒）：目标站点可能响应慢或被防爬拦截（验证码/Cloudflare 等）。');
    }
    if (resp.statusCode == 403) {
      throw Exception('HTTP 403：站点启用了防爬（拒绝自动抓取）。');
    }
    if (resp.statusCode == 429) {
      throw Exception('HTTP 429：请求频率受限。先停下，换一个目标站点。');
    }
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}。');
    }
    var text = resp.body.trim();
    if (text.isEmpty) {
      throw Exception('网页内容为空（可能是防爬返回的空页面）。建议换站点。');
    }
    return _truncate(text, maxChars);
  }

  static String _truncate(String text, int maxChars) => text.length <= maxChars
      ? text
      : '${text.substring(0, maxChars)}\n…（内容过长已截断）';

  /// 轻量 HTML 正文提取：去掉 script/style，块级标签转成换行后剥离标签。
  static String htmlToText(String html) {
    var s = html.replaceAll(
      RegExp(
        r'<script\b[^>]*>.*?</script>',
        caseSensitive: false,
        dotAll: true,
      ),
      ' ',
    );
    s = s.replaceAll(
      RegExp(r'<style\b[^>]*>.*?</style>', caseSensitive: false, dotAll: true),
      ' ',
    );
    s = s.replaceAll(
      RegExp(
        r'<(br|/p|/div|/li|/tr|/h[1-6]|/blockquote|/pre)[^>]*>',
        caseSensitive: false,
      ),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = _unescape(s);
    s = s
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n\s*\n+'), '\n');
    return s.trim();
  }

  // ---------------- Bing ----------------

  static Future<List<WebSearchResult>> _searchBing(String q, int limit) async {
    final urls = <String>[
      'https://www.bing.com/search?q=$q&format=rss&count=$limit&mkt=zh-CN&setlang=zh-hans',
      'https://cn.bing.com/search?q=$q&format=rss&count=$limit&mkt=zh-CN&setlang=zh-hans',
    ];
    http.Response? resp;
    for (final u in urls) {
      try {
        resp = await http
            .get(Uri.parse(u), headers: _ua)
            .timeout(_searchTimeout);
        if (resp.statusCode == 200) break;
      } catch (_) {
        resp = null;
      }
    }
    if (resp == null || resp.statusCode != 200) {
      throw Exception('Bing 搜索失败');
    }
    return parseBingRss(resp.body, maxResults: limit);
  }

  /// 解析 Bing RSS 搜索结果。
  static List<WebSearchResult> parseBingRss(
    String body, {
    int maxResults = _maxSearch,
  }) {
    final out = <WebSearchResult>[];
    final itemRe = RegExp(r'<item>([\s\S]*?)</item>', caseSensitive: false);
    for (final m in itemRe.allMatches(body)) {
      final item = m.group(1) ?? '';
      final title = _stripTags(_extractTag(item, 'title'));
      final link = _extractTag(item, 'link').trim();
      final snippet = _stripTags(_extractTag(item, 'description'));
      final date = _formatDate(_extractTag(item, 'pubDate'));
      if (title.isEmpty && link.isEmpty) continue;
      out.add(
        WebSearchResult(title: title, url: link, snippet: snippet, date: date),
      );
      if (out.length >= maxResults) break;
    }
    return out;
  }

  // ---------------- DuckDuckGo ----------------

  /// 探测 DuckDuckGo 连通性；结果缓存 10 分钟。force 可强制重新探测。
  static Future<bool> _probeDuckDuckGo({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _ddgReachable != null &&
        _ddgProbeAt != null &&
        now.difference(_ddgProbeAt!) < _probeTtl) {
      return _ddgReachable!;
    }
    var reachable = false;
    try {
      final resp = await http
          .get(Uri.parse('https://duckduckgo.com/'), headers: _ua)
          .timeout(_probeTimeout);
      reachable = resp.statusCode == 200;
    } catch (_) {
      reachable = false;
    }
    _ddgReachable = reachable;
    _ddgProbeAt = now;
    return reachable;
  }

  static Future<List<WebSearchResult>> _searchDuckDuckGo(
    String q,
    int limit,
  ) async {
    final resp = await http
        .get(Uri.parse('https://html.duckduckgo.com/html/?q=$q'), headers: _ua)
        .timeout(_searchTimeout);
    if (resp.statusCode != 200) {
      throw Exception('DuckDuckGo 搜索失败：HTTP ${resp.statusCode}');
    }
    return parseDuckDuckGoHtml(resp.body, maxResults: limit);
  }

  /// 解析 DuckDuckGo HTML 搜索结果（标题、跳转链接、摘要）。
  static List<WebSearchResult> parseDuckDuckGoHtml(
    String body, {
    int maxResults = _maxSearch,
  }) {
    final out = <WebSearchResult>[];
    final aRe = RegExp(
      r'<a[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    );
    final snippetRe = RegExp(
      r'class="result__snippet"[^>]*>([\s\S]*?)</a>',
      caseSensitive: false,
    );
    for (final m in aRe.allMatches(body)) {
      final title = _stripTags(_unescape(m.group(2) ?? '')).trim();
      final url = _decodeDdgUrl(m.group(1) ?? '');
      if (title.isEmpty && url.isEmpty) continue;
      // 取该条结果标题之后最近的摘要（避免串到下一条）。
      var snippet = '';
      final sm = snippetRe.firstMatch(body.substring(m.end));
      if (sm != null && sm.start < 5000) {
        snippet = _stripTags(_unescape(sm.group(1) ?? '')).trim();
      }
      out.add(
        WebSearchResult(
          title: title,
          url: url,
          snippet: snippet,
          date: _extractDdgDate(body, m.start, snippet),
        ),
      );
      if (out.length >= maxResults) break;
    }
    return out;
  }

  /// 从 DuckDuckGo 结果区提取发布时间：优先 result__timestamp，其次常见绝对日期格式。
  static String? _extractDdgDate(String body, int start, String snippet) {
    final zone = body.substring(start, (start + 3000).clamp(0, body.length));
    final ts = RegExp(
      r'result__timestamp[^>]*>([\s\S]*?)<',
      caseSensitive: false,
    ).firstMatch(zone);
    if (ts != null) {
      final t = _stripTags(_unescape(ts.group(1) ?? '')).trim();
      if (t.isNotEmpty) return t;
    }
    final abs = RegExp(
      r'\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w*\s+\d{1,2},?\s+\d{4}\b|\d{4}年\d{1,2}月\d{1,2}日|\d{4}-\d{1,2}-\d{1,2}',
    ).firstMatch(snippet);
    return abs?.group(0)?.trim();
  }

  /// 把 RSS pubDate 解析为 YYYY-MM-DD；支持 RFC822 / ISO8601；失败返回 null。
  static String? _formatDate(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final dt = DateTime.tryParse(s);
    if (dt != null) {
      return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    }
    final m = RegExp(r'(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})').firstMatch(s);
    if (m != null) {
      const months = {
        'Jan': 1,
        'Feb': 2,
        'Mar': 3,
        'Apr': 4,
        'May': 5,
        'Jun': 6,
        'Jul': 7,
        'Aug': 8,
        'Sep': 9,
        'Oct': 10,
        'Nov': 11,
        'Dec': 12,
      };
      final mo = months[m.group(2)];
      if (mo != null) {
        return '${m.group(3)}-${mo.toString().padLeft(2, '0')}-${int.tryParse(m.group(1) ?? '')?.toString().padLeft(2, '0') ?? ''}';
      }
    }
    return null;
  }

  /// 解码 DuckDuckGo 的 /l/?uddg=... 跳转链接；无跳转则原样返回（补全协议）。
  static String _decodeDdgUrl(String rawHref) {
    var href = _unescape(rawHref.trim());
    if (href.startsWith('//')) href = 'https:$href';
    final m = RegExp(r'[?&]uddg=([^&]+)').firstMatch(href);
    if (m != null) {
      try {
        return Uri.decodeQueryComponent(m.group(1) ?? '');
      } catch (_) {
        return href;
      }
    }
    return href;
  }

  // ---------------- 通用 ----------------

  static Future<List<WebSearchResult>?> _trySearch(
    Future<List<WebSearchResult>> Function() fn,
  ) async {
    try {
      return await fn();
    } catch (_) {
      return null;
    }
  }

  static String _extractTag(String xml, String tag) {
    final re = RegExp('<$tag[^>]*>([\\s\\S]*?)</$tag>', caseSensitive: false);
    final m = re.firstMatch(xml);
    if (m == null) return '';
    return _unescape(m.group(1) ?? '');
  }

  static String _stripTags(String s) =>
      s.replaceAll(RegExp(r'<[^>]+>'), '').trim();

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&');
}
