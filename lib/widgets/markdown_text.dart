import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Lightweight Markdown renderer: code blocks, inline code, bold, italic,
/// headings, bullet/numbered lists, tables, quotes, links, task lists,
/// strikethrough, nested indentation.
class MarkdownText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  const MarkdownText(this.data, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final blocks = splitMarkdownBlocks(data);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks)
          if (block.trim().isNotEmpty) MarkdownBlock(block, style: style),
      ],
    );
  }
}

/// 解析 Markdown 文本为块列表（代码块 / 标题 / 表格 / 引用 / 列表 / 段落）。
String? _lastBlockSource;
List<String>? _lastBlocks;

/// 只缓存中等长度内容：超长流式文本持有大块列表（全局缓存是单 entry，
/// 限制影响面，避免长消息驻留内存）。
const int _blockCacheMaxChars = 100 * 1024;

List<String> splitMarkdownBlocks(String md) {
  if (md.length <= _blockCacheMaxChars && _lastBlockSource == md) {
    return _lastBlocks!;
  }
  final out = <String>[];
  final lines = md.split('\n');
  final buf = StringBuffer();
  var inCode = false;
  String? tableBuf; // 连续表格行聚合缓冲
  String? quoteBuf; // 连续引用行聚合缓冲
  for (final line in lines) {
    if (line.startsWith('```')) {
      if (inCode) {
        // 闭合围栏：连同开始围栏与正文一起提交，避免把 ``` 单独拆成空代码块。
        buf.writeln(line);
        _commitCodeBlock(out, buf);
        inCode = false;
      } else {
        _flushBuf(out, buf);
        _flushTable(out, tableBuf);
        tableBuf = null;
        _flushQuote(out, quoteBuf);
        quoteBuf = null;
        buf.writeln(line);
        inCode = true;
      }
      continue;
    }
    // 标题行立即独立成块，避免混在段落里被当成普通文字原样显示
    if (!inCode && RegExp(r'^#{1,6}(?=\s|$)').hasMatch(line)) {
      _flushBuf(out, buf);
      _flushTable(out, tableBuf);
      tableBuf = null;
      _flushQuote(out, quoteBuf);
      quoteBuf = null;
      out.add('$line\n');
      continue;
    }
    if (!inCode && _isTableRow(line)) {
      _flushBuf(out, buf);
      _flushQuote(out, quoteBuf);
      quoteBuf = null;
      tableBuf = '${tableBuf ?? ''}$line\n';
      continue;
    }
    if (!inCode && line.trimLeft().startsWith('>')) {
      _flushBuf(out, buf);
      _flushTable(out, tableBuf);
      tableBuf = null;
      quoteBuf = '${quoteBuf ?? ''}$line\n';
      continue;
    }
    // 普通行：结束正在聚合的表格 / 引用
    _flushTable(out, tableBuf);
    tableBuf = null;
    _flushQuote(out, quoteBuf);
    quoteBuf = null;
    buf.writeln(line);
  }
  _flushTable(out, tableBuf);
  _flushQuote(out, quoteBuf);
  if (inCode) {
    _commitCodeBlock(out, buf);
  } else {
    _flushBuf(out, buf);
  }
  if (md.length <= _blockCacheMaxChars) {
    _lastBlockSource = md;
    _lastBlocks = out;
  }
  return out;
}

void _flushBuf(List<String> out, StringBuffer buf) {
  final s = buf.toString();
  buf.clear();
  if (s.trim().isNotEmpty) out.add(s);
}

/// 提交围栏代码块：正文为空（如 ```text\n```）时不生成空代码框。
void _commitCodeBlock(List<String> out, StringBuffer buf) {
  final s = buf.toString();
  buf.clear();
  if (_codeInner(s).isNotEmpty) out.add(s);
}

String _codeInner(String block) {
  final nl = block.indexOf('\n');
  final rest = nl < 0 ? '' : block.substring(nl + 1);
  return rest.replaceAll(RegExp(r'```\s*$'), '').trim();
}

void _flushTable(List<String> out, String? t) {
  if (t != null && t.trim().isNotEmpty) out.add(t);
}

void _flushQuote(List<String> out, String? q) {
  if (q != null && q.trim().isNotEmpty) out.add(q);
}

/// 表格行判定：含 `|` 且分隔出至少 2 列（含 `| a | b |` 与无首尾竖线的写法）。
bool _isTableRow(String line) {
  final t = line.trim();
  if (t.isEmpty || !t.contains('|')) return false;
  if (t.startsWith('#') || t.startsWith('```')) return false;
  final cells = t.replaceAll(RegExp(r'^\|'), '').replaceAll(RegExp(r'\|$'), '').split('|');
  return cells.length >= 2;
}

bool _isTableBlock(String b) {
  final first =
      b.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  return first.isNotEmpty && _isTableRow(first);
}

/// 代码围栏 / 表格在流式揭示时整块淡入，不按字符拆。
bool isAtomicMarkdownBlock(String block) {
  final t = block.trimLeft();
  return t.startsWith('```') || _isTableBlock(t);
}

bool _isListBlock(String b) =>
    b.split('\n').any((l) => RegExp(r'^(\s*[-*•]|\d+[.)、\.])\s').hasMatch(l));

bool _isRule(String t) => t == '---' || t == '***' || t == '___';

/// 渲染单个 Markdown 块（代码块 / 列表 / 标题 / 分隔线 / 段落）。
/// 与 MarkdownText 同款渲染逻辑，可配合 ListView.builder 做懒加载。
class MarkdownBlock extends StatelessWidget {
  final String block;
  final TextStyle? style;
  const MarkdownBlock(this.block, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base =
        style ??
        DefaultTextStyle.of(context).style.copyWith(fontSize: 15, height: 1.45);
    final accent = theme.colorScheme.primary;
    final trimmed = block.trim();
    if (trimmed.startsWith('```')) {
      return _CodeBlock(block: block, base: base);
    }
    if (_isTableBlock(trimmed)) {
      return _TableBlock(block: block, base: base, accent: accent);
    }
    if (trimmed.startsWith('>')) {
      return _QuoteBlock(block: block, base: base, accent: accent);
    }
    if (_isListBlock(trimmed)) {
      return _ListBlock(block: block, base: base, accent: accent);
    }
    if (trimmed.startsWith('#')) {
      return _Heading(text: trimmed, base: base, accent: accent);
    }
    if (_isRule(trimmed)) {
      return Divider(height: 16, color: accent.withValues(alpha: .3));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text.rich(
        TextSpan(children: _renderInline(trimmed, base, accent)),
        style: base,
      ),
    );
  }
}

/// 自适应 Markdown 渲染：短内容一次性渲染（随消息自然展开，保持现有体验），
/// 超长内容自动切换为限高懒加载列表，避免大文本一次性构建卡顿。
class AdaptiveMarkdownText extends StatelessWidget {
  final String data;
  final TextStyle? style;

  /// 超过该字符数时启用懒加载渲染。
  final int lazyThreshold;

  /// 流式中：固定使用 Column 渲染，不跨阈值切换渲染树
  /// （边增长边切换子树会中途重排跳动）；停止后按长度决定懒加载。
  final bool isStreaming;

  const AdaptiveMarkdownText(
    this.data, {
    super.key,
    this.style,
    this.lazyThreshold = 15000,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!isStreaming && data.length > lazyThreshold) {
      final blocks = splitMarkdownBlocks(data);
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 400),
        child: ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: blocks.length,
          itemBuilder: (context, i) => MarkdownBlock(blocks[i], style: style),
        ),
      );
    }
    return MarkdownText(data, style: style);
  }
}

/// 轻量行内 Markdown 文本：粗体 / 斜体 / 行内代码。
/// 单 Text.rich 实现，适合列表、摘要等需要 maxLines 截断且要求流畅的场景。
class MarkdownInlineText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  const MarkdownInlineText(
    this.data, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base =
        style ??
        DefaultTextStyle.of(context).style.copyWith(fontSize: 15, height: 1.45);
    final accent = theme.colorScheme.primary;
    return Text.rich(
      TextSpan(children: _renderInline(data, base, accent)),
      style: base,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

List<InlineSpan> _renderInline(String text, TextStyle base, Color accent) {
  final spans = <InlineSpan>[];
  final regex = RegExp(
      r'(`[^`]+`|\*\*[^*]+\*\*|__[^_]+__|~~[^~]+~~|\[[^\]]+\]\([^)\s]+\)|\*[^*]+\*|_[^_]+_)');
  var pos = 0;
  for (final m in regex.allMatches(text)) {
    if (m.start > pos) {
      spans.add(TextSpan(text: text.substring(pos, m.start), style: base));
    }
    final group = m.group(0)!;
    if (group.startsWith('`')) {
      spans.add(TextSpan(
        text: group.substring(1, group.length - 1),
        style: base.copyWith(
          fontFamily: 'monospace',
          fontSize: (base.fontSize ?? 14) - 1.5,
          color: accent,
          backgroundColor: accent.withValues(alpha: .08),
        ),
      ));
    } else if (group.startsWith('**') || group.startsWith('__')) {
      spans.add(TextSpan(
          text: group.substring(2, group.length - 2),
          style: base.copyWith(fontWeight: FontWeight.bold)));
    } else if (group.startsWith('~~')) {
      spans.add(TextSpan(
          text: group.substring(2, group.length - 2),
          style: base.copyWith(decoration: TextDecoration.lineThrough)));
    } else if (group.startsWith('[')) {
      final m2 = RegExp(r'^\[([^\]]+)\]\(([^)\s]+)\)$').firstMatch(group);
      if (m2 != null) {
        final url = m2.group(2)!;
        spans.add(TextSpan(
          text: m2.group(1),
          style: base.copyWith(
            color: accent,
            decoration: TextDecoration.underline,
            decorationColor: accent,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () => _openUrl(url),
        ));
      } else {
        spans.add(TextSpan(text: group, style: base));
      }
    } else if (group.startsWith('*') || group.startsWith('_')) {
      spans.add(TextSpan(
          text: group.substring(1, group.length - 1),
          style: base.copyWith(fontStyle: FontStyle.italic)));
    } else {
      spans.add(TextSpan(text: group, style: base));
    }
    pos = m.end;
  }
  if (pos < text.length) {
    spans.add(TextSpan(text: text.substring(pos), style: base));
  }
  return spans;
}

Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url);
  // 只放行 http/https：javascript:/file:/intent: 等 scheme 不进入系统 Intent
  //（防 LLM 生成的链接唤起系统文件/内容组件）。
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // 打不开的链接静默忽略，不阻塞消息渲染
  }
}

/// 表格块：`| a | b |` GitHub 风格表格（含分隔行），均分列宽，表头加粗高亮。
class _TableBlock extends StatelessWidget {
  final String block;
  final TextStyle base;
  final Color accent;
  const _TableBlock({required this.block, required this.base, required this.accent});

  List<List<String>> _parseRows() {
    final rows = <List<String>>[];
    for (final line in block.split('\n')) {
      if (line.trim().isEmpty) continue;
      var t = line.trim();
      if (t.startsWith('|')) t = t.substring(1);
      if (t.endsWith('|')) t = t.substring(0, t.length - 1);
      rows.add(t.split('|').map((c) => c.trim()).toList());
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outlineVariant.withValues(alpha: .5);
    final rows = _parseRows();
    if (rows.isEmpty) return const SizedBox.shrink();
    var sep = -1;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r.length >= 2 && r.every((c) => RegExp(r'^:?-+:?$').hasMatch(c))) {
        sep = i;
        break;
      }
    }
    final header = sep > 0 ? rows[0] : rows.first;
    final body = sep >= 0 ? rows.sublist(sep + 1) : rows.sublist(1);
    final colCount = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    if (colCount < 2) {
      // 退化（如 `| a |`）：按普通段落渲染，避免出现奇怪的单列表格
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text.rich(
          TextSpan(children: _renderInline(block.trim(), base, accent)),
          style: base,
        ),
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _tableRow(header, isHeader: true),
          for (final r in body) _tableRow(r, isHeader: false),
        ],
      ),
    );
  }

  Widget _tableRow(List<String> cells, {required bool isHeader}) {
    final cellStyle =
        isHeader ? base.copyWith(fontWeight: FontWeight.bold) : base;
    return Container(
      color: isHeader ? accent.withValues(alpha: .08) : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == cells.length - 1 ? 0 : 8),
                child: Text.rich(
                  TextSpan(
                      children: _renderInline(cells[i], cellStyle, accent)),
                  style: cellStyle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 引用块：`> 引用`，左侧竖线 + 浅色底。
class _QuoteBlock extends StatelessWidget {
  final String block;
  final TextStyle base;
  final Color accent;
  const _QuoteBlock({required this.block, required this.base, required this.accent});

  @override
  Widget build(BuildContext context) {
    final lines = block
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^>\s?'), ''))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.only(left: 10, top: 6, bottom: 6, right: 8),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(color: accent.withValues(alpha: .6), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text.rich(
                TextSpan(children: _renderInline(l, base, accent)),
                style: base,
              ),
            ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  final String block;
  final TextStyle base;
  const _CodeBlock({required this.block, required this.base});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = block
        .substring(3)
        .replaceAll(RegExp(r'```\s*$'), '')
        .trimRight();
    final lines = body.split('\n');
    var code = body;
    var lang = '代码';
    if (lines.isNotEmpty) {
      final first = lines.first.trim();
      // 首行若是语言标识（如 python / dart），不当作代码内容，并显示为语言标签
      if (first.isNotEmpty && RegExp(r'^[A-Za-z0-9_+#.-]+$').hasMatch(first)) {
        lang = first;
        code = lines.sublist(1).join('\n').trimRight();
      }
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.primary.withValues(alpha: .25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(lang,
              style: TextStyle(fontSize: 11, letterSpacing: 1, color: theme.colorScheme.primary)),
          const Spacer(),
          GestureDetector(
            onTap: () => Clipboard.setData(ClipboardData(text: code)),
            child: Icon(Icons.copy_rounded, size: 15, color: theme.colorScheme.primary),
          ),
        ]),
        const SizedBox(height: 6),
        Text(code,
            style: TextStyle(fontFamily: 'monospace', fontSize: base.fontSize, height: 1.4)),
      ]),
    );
  }
}

class _ListBlock extends StatelessWidget {
  final String block;
  final TextStyle base;
  final Color accent;
  const _ListBlock({required this.block, required this.base, required this.accent});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final line in block.split('\n')) {
      final m =
          RegExp(r'^(\s*)([-*•]|\d+[.)、\.])\s+(.*)$').firstMatch(line);
      if (m == null) {
        // 混合块中非列表行不能丢，按普通段落保留，避免内容缺失
        if (line.trim().isNotEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text.rich(
              TextSpan(children: _renderInline(line.trim(), base, accent)),
              style: base,
            ),
          ));
        }
        continue;
      }
      final indentPx = (m.group(1) ?? '').replaceAll('\t', '    ').length * 5.0;
      final prefix = m.group(2)!;
      final isNumbered = RegExp(r'^\d').hasMatch(prefix);
      final content = m.group(3)!;
      // 任务列表：- [x] 完成 / - [ ] 待办
      final taskM = RegExp(r'^\[([ xX])\]\s+(.*)$').firstMatch(content);
      if (taskM != null && !isNumbered) {
        final checked = taskM.group(1)!.toLowerCase() == 'x';
        children.add(Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: indentPx),
            Icon(
              checked
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 19,
              color: checked ? accent : Colors.grey.shade500,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(
                    children: _renderInline(taskM.group(2)!, base, accent)),
              ),
            ),
          ]),
        ));
        continue;
      }
      final bullet = isNumbered
          ? '${prefix.replaceAll(RegExp(r'[.)、。）]'), '')}.'
          : prefix;
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: indentPx),
          SizedBox(
            width: 22,
            child: Text(bullet,
                style: base.copyWith(color: accent, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(children: _renderInline(content, base, accent)),
            ),
          ),
        ]),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

class _Heading extends StatelessWidget {
  final String text;
  final TextStyle base;
  final Color accent;
  const _Heading({required this.text, required this.base, required this.accent});

  @override
  Widget build(BuildContext context) {
    final m = RegExp(r'^#+').firstMatch(text);
    final level = m == null ? 1 : m.group(0)!.length;
    final content = text.substring(level).trimLeft();
    final size = level == 1 ? 20.0 : (level == 2 ? 17.0 : 15.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(
            width: 3,
            height: size * 1.2,
            margin: const EdgeInsets.only(right: 8),
            decoration:
                BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2))),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: _renderInline(
                  content, base.copyWith(fontSize: size, fontWeight: FontWeight.bold), accent),
            ),
          ),
        ),
      ]),
    );
  }
}
