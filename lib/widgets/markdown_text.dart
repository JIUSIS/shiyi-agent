import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Lightweight Markdown renderer: code blocks, inline code, bold, italic,
/// headings, bullet/numbered lists, tables, quotes, links, task lists,
/// strikethrough, nested indentation, images, footnotes, definition lists,
/// keyboard keys, highlight, GitHub alerts, and LaTeX.
class MarkdownText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  const MarkdownText(this.data, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final footnotes = markdownCollectFootnotes(data);
    final blocks = splitMarkdownBlocks(data);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks)
          if (block.trim().isNotEmpty)
            MarkdownBlock(block, style: style, footnotes: footnotes),
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
  var inMath = false;
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
    if (inCode) {
      buf.writeln(line);
      continue;
    }
    if (inMath) {
      buf.writeln(line);
      if (line.trim() == r'$$') {
        _flushBuf(out, buf);
        inMath = false;
      }
      continue;
    }
    final trimmedLine = line.trim();
    if (trimmedLine.startsWith(r'$$')) {
      _flushBuf(out, buf);
      _flushTable(out, tableBuf);
      tableBuf = null;
      _flushQuote(out, quoteBuf);
      quoteBuf = null;
      if (trimmedLine.length > 2 && trimmedLine.endsWith(r'$$')) {
        out.add('$trimmedLine\n');
      } else {
        buf.writeln(line);
        inMath = true;
      }
      continue;
    }
    if (markdownIsFootnoteDefinition(line)) {
      _flushBuf(out, buf);
      _flushTable(out, tableBuf);
      tableBuf = null;
      _flushQuote(out, quoteBuf);
      quoteBuf = null;
      out.add('${line.trim()}\n');
      continue;
    }
    // 独立分隔线单独成块，避免和前后段落糊成一段原文。
    if (_isRuleLine(line)) {
      _flushBuf(out, buf);
      _flushTable(out, tableBuf);
      tableBuf = null;
      _flushQuote(out, quoteBuf);
      quoteBuf = null;
      out.add('$trimmedLine\n');
      continue;
    }
    // 标题行立即独立成块，避免混在段落里被当成普通文字原样显示
    if (RegExp(r'^#{1,6}(?=\s|$)').hasMatch(line)) {
      _flushBuf(out, buf);
      _flushTable(out, tableBuf);
      tableBuf = null;
      _flushQuote(out, quoteBuf);
      quoteBuf = null;
      out.add('$line\n');
      continue;
    }
    if (_isTableRow(line)) {
      _flushBuf(out, buf);
      _flushQuote(out, quoteBuf);
      quoteBuf = null;
      tableBuf = '${tableBuf ?? ''}$line\n';
      continue;
    }
    if (line.trimLeft().startsWith('>')) {
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
  final cells = t
      .replaceAll(RegExp(r'^\|'), '')
      .replaceAll(RegExp(r'\|$'), '')
      .split('|');
  return cells.length >= 2;
}

bool _isTableBlock(String b) {
  final first = b
      .split('\n')
      .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  return first.isNotEmpty && _isTableRow(first);
}

/// 代码围栏 / 表格在流式揭示时整块淡入，不按字符拆。
bool isAtomicMarkdownBlock(String block) {
  final t = block.trimLeft();
  return t.startsWith('```') || t.startsWith(r'$$') || _isTableBlock(t);
}

bool _isListBlock(String b) =>
    b.split('\n').any((l) => RegExp(r'^(\s*[-*•]|\d+[.)、\.])\s').hasMatch(l));

bool _isRuleLine(String line) =>
    RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(line.trim());

bool _isRule(String t) => _isRuleLine(t);

bool _isMathBlock(String b) => b.trim().startsWith(r'$$');

final _defListLinePattern = RegExp(r'^\s*[:：]\s+\S');
final _defListCapturePattern = RegExp(r'^\s*[:：]\s+(.*)$');

bool markdownIsDefListLine(String line) => _defListLinePattern.hasMatch(line);

bool _isDefListBlock(String b) {
  final lines = b.split('\n');
  for (var i = 1; i < lines.length; i++) {
    if (!markdownIsDefListLine(lines[i])) continue;
    var j = i - 1;
    while (j >= 0 && lines[j].trim().isEmpty) {
      j--;
    }
    if (j >= 0 && !markdownIsDefListLine(lines[j])) return true;
  }
  return false;
}

final _imagePattern = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
final _footnotePattern = RegExp(r'\[\^([^\]]+)\]\(([^)]+)\)');
final _footnoteRefPattern = RegExp(r'\[\^([^\]]+)\]');
final _footnoteDefPattern = RegExp(r'^\[\^([^\]]+)\]:\s*(.*)$');
final _kbdPattern = RegExp(r'<kbd>([^<]+)</kbd>', caseSensitive: false);
final _chordPattern = RegExp(
  r'\b(Ctrl|Control|Cmd|Command|Alt|Option|Shift|Win|Meta)\s*\+\s*(Enter|Return|Tab|Esc|Escape|Space|Delete|Backspace|Home|End|[A-Za-z0-9])\b',
  caseSensitive: false,
);
final _alertPattern = RegExp(
  r'^\[!(NOTE|TIP|WARNING|IMPORTANT|CAUTION)\]\s*$',
  caseSensitive: false,
);

class MarkdownFootnoteMatch {
  final String id;
  final String content;
  const MarkdownFootnoteMatch({required this.id, required this.content});
}

String markdownFootnoteDecode(String raw) {
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

MarkdownFootnoteMatch? markdownFootnoteMatch(String text) {
  final m = _footnotePattern.firstMatch(text);
  if (m == null) return null;
  return MarkdownFootnoteMatch(
    id: m.group(1)!,
    content: markdownFootnoteDecode(m.group(2)!),
  );
}

List<MarkdownFootnoteMatch> markdownFootnotes(String text) {
  return [
    for (final m in _footnotePattern.allMatches(text))
      MarkdownFootnoteMatch(
        id: m.group(1)!,
        content: markdownFootnoteDecode(m.group(2)!),
      ),
  ];
}

bool markdownIsFootnoteDefinition(String line) =>
    _footnoteDefPattern.hasMatch(line.trim());

List<String> markdownFootnoteRefIds(String text) {
  final ids = <String>[];
  for (final m in _footnoteRefPattern.allMatches(text)) {
    if (text.substring(m.end).startsWith(':')) continue;
    ids.add(m.group(1)!);
  }
  return ids;
}

Map<String, String> markdownCollectFootnotes(String md) {
  final notes = <String, String>{};
  for (final line in md.split('\n')) {
    final def = _footnoteDefPattern.firstMatch(line.trim());
    if (def != null) {
      notes[def.group(1)!] = markdownFootnoteDecode(def.group(2) ?? '');
    }
  }
  for (final note in markdownFootnotes(md)) {
    notes.putIfAbsent(note.id, () => note.content);
  }
  return notes;
}

String markdownStripFootnoteDefinitions(String block) {
  return block
      .split('\n')
      .where((line) => !markdownIsFootnoteDefinition(line))
      .join('\n');
}

bool _isOnlyFootnoteDefinitions(String block) {
  final lines = block
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty);
  return lines.isNotEmpty && lines.every(markdownIsFootnoteDefinition);
}

const _latexCommands = <String, String>{
  r'\int': '∫',
  r'\sum': '∑',
  r'\prod': '∏',
  r'\infty': '∞',
  r'\pi': 'π',
  r'\theta': 'θ',
  r'\alpha': 'α',
  r'\beta': 'β',
  r'\gamma': 'γ',
  r'\Delta': 'Δ',
  r'\times': '×',
  r'\cdot': '·',
  r'\leq': '≤',
  r'\geq': '≥',
  r'\neq': '≠',
  r'\pm': '±',
  r'\rightarrow': '→',
  r'\leftarrow': '←',
  r'\Rightarrow': '⇒',
  r'\ldots': '…',
  r'\cdots': '⋯',
};

final _latexCommandPattern = RegExp(
  _latexCommands.keys.map(RegExp.escape).join('|'),
);

/// 把常见 LaTeX 转成可读文本（不引入公式排版引擎）。
String markdownLatexPlain(String latex) {
  var s = latex.trim();
  if (s.startsWith(r'$$') && s.endsWith(r'$$') && s.length >= 4) {
    s = s.substring(2, s.length - 2).trim();
  }
  if (s.startsWith(r'$') && s.endsWith(r'$') && s.length >= 2) {
    s = s.substring(1, s.length - 1).trim();
  }
  s = s.replaceAllMapped(RegExp(r'\\begin\{bmatrix\}([\s\S]*?)\\end\{bmatrix\}'), (
    m,
  ) {
    return markdownLatexMatrix(m.group(1)!)
        .map((row) => row.join('  '))
        .join('\n');
  });
  s = s.replaceAllMapped(RegExp(r'\\sqrt\{([^}]*)\}'), (m) {
    final inner = m.group(1) ?? '';
    return inner.isEmpty ? '√' : '√$inner';
  });
  s = s.replaceAllMapped(_latexCommandPattern, (m) => _latexCommands[m.group(0)!]!);
  s = s.replaceAllMapped(RegExp(r'\^\{([^}]*)\}'), (m) => '^${m.group(1)}');
  s = s.replaceAllMapped(RegExp(r'_\{([^}]*)\}'), (m) => '_${m.group(1)}');
  s = s.replaceAll(r'\\', '\n');
  s = s.replaceAllMapped(RegExp(r'\\([A-Za-z]+)'), (m) => m.group(1) ?? '');
  return s.trim();
}

List<List<String>> markdownLatexMatrix(String body) {
  final rows = <List<String>>[];
  for (final raw in body.split(RegExp(r'\\\\|\n'))) {
    var line = raw.trim();
    if (line.endsWith('\\')) {
      line = line.substring(0, line.length - 1).trim();
    }
    if (line.isEmpty) continue;
    final cells = [
      for (final cell in line.split('&'))
        if (cell.trim().isNotEmpty) markdownLatexPlain(cell.trim()),
    ];
    if (cells.isNotEmpty) rows.add(cells);
  }
  return rows;
}

/// 渲染单个 Markdown 块（代码块 / 列表 / 标题 / 分隔线 / 段落）。
/// 与 MarkdownText 同款渲染逻辑，可配合 ListView.builder 做懒加载。
class MarkdownBlock extends StatelessWidget {
  final String block;
  final TextStyle? style;
  final Map<String, String> footnotes;
  const MarkdownBlock(
    this.block, {
    super.key,
    this.style,
    this.footnotes = const {},
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base =
        style ??
        DefaultTextStyle.of(context).style.copyWith(fontSize: 15, height: 1.45);
    final accent = theme.colorScheme.primary;
    if (_isOnlyFootnoteDefinitions(block)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in block.split('\n'))
            if (_footnoteDefPattern.firstMatch(line.trim()) case final def?)
              _FootnoteNote(
                id: def.group(1)!,
                content: markdownFootnoteDecode(def.group(2) ?? ''),
                base: base,
              ),
        ],
      );
    }
    final trimmed = markdownStripFootnoteDefinitions(block).trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();
    if (trimmed.startsWith('```')) {
      return _CodeBlock(block: block, base: base);
    }
    if (_isTableBlock(trimmed)) {
      return _TableBlock(
        block: trimmed,
        base: base,
        accent: accent,
        footnotes: footnotes,
      );
    }
    if (trimmed.startsWith('>')) {
      return _QuoteBlock(
        block: trimmed,
        base: base,
        accent: accent,
        footnotes: footnotes,
      );
    }
    if (_isMathBlock(trimmed)) {
      return _MathBlock(block: trimmed, base: base, accent: accent);
    }
    if (_isDefListBlock(trimmed)) {
      return _DefListBlock(
        block: trimmed,
        base: base,
        accent: accent,
        footnotes: footnotes,
      );
    }
    if (_isListBlock(trimmed)) {
      return _ListBlock(
        block: trimmed,
        base: base,
        accent: accent,
        footnotes: footnotes,
      );
    }
    if (trimmed.startsWith('#')) {
      return _Heading(
        text: trimmed,
        base: base,
        accent: accent,
        footnotes: footnotes,
      );
    }
    if (_isRule(trimmed)) {
      return Divider(height: 16, color: accent.withValues(alpha: .3));
    }
    final onlyImage = _imagePattern.firstMatch(trimmed);
    if (onlyImage != null &&
        trimmed.replaceFirst(_imagePattern, '').trim().isEmpty) {
      return _MarkdownImage(
        alt: onlyImage.group(1) ?? '',
        url: onlyImage.group(2)!,
        base: base,
      );
    }
    final inlineNotes = markdownFootnotes(trimmed);
    final paragraph = Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text.rich(
        TextSpan(
          children: _renderInline(trimmed, base, accent, footnotes: footnotes),
        ),
        style: base,
      ),
    );
    if (inlineNotes.isEmpty) return paragraph;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        paragraph,
        for (final note in inlineNotes)
          if (!footnotes.containsKey(note.id) ||
              footnotes[note.id] == note.content)
            _FootnoteNote(id: note.id, content: note.content, base: base),
      ],
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

  /// 流式中：只画纯文本，不拆 Markdown，避免每个 token 重建卡顿。
  /// 结束后再按长度决定完整渲染或懒加载。
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
    if (isStreaming) {
      return Text(data, style: style);
    }
    final footnotes = markdownCollectFootnotes(data);
    if (data.length > lazyThreshold) {
      final blocks = splitMarkdownBlocks(data);
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 400),
        child: ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: blocks.length,
          itemBuilder: (context, i) => MarkdownBlock(
            blocks[i],
            style: style,
            footnotes: footnotes,
          ),
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
      TextSpan(
        children: _renderInline(
          data,
          base,
          accent,
          footnotes: markdownCollectFootnotes(data),
        ),
      ),
      style: base,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

List<InlineSpan> _renderInline(
  String text,
  TextStyle base,
  Color accent, {
  Map<String, String> footnotes = const {},
}) {
  final spans = <InlineSpan>[];
  final regex = RegExp(
    r'(`[^`]+`'
    r'|\*\*[^*]+\*\*'
    r'|__[^_]+__'
    r'|~~[^~]+~~'
    r'|==[^=]+=='
    r'|!\[[^\]]*\]\([^)\s]+\)'
    r'|\[\^[^\]]+\](?:\([^)]+\))?'
    r'|\[[^\]]+\]\([^)\s]+\)'
    r'|<kbd>[^<]+</kbd>'
    r'|\$[^$\n]+\$'
    r'|\*[^*]+\*'
    r'|_[^_]+_'
    r'|\b(?:Ctrl|Control|Cmd|Command|Alt|Option|Shift|Win|Meta)\s*\+\s*(?:Enter|Return|Tab|Esc|Escape|Space|Delete|Backspace|Home|End|[A-Za-z0-9])\b'
    r')',
    caseSensitive: false,
  );
  var pos = 0;
  for (final m in regex.allMatches(text)) {
    if (m.start > pos) {
      spans.add(TextSpan(text: text.substring(pos, m.start), style: base));
    }
    final group = m.group(0)!;
    if (group.startsWith('`')) {
      spans.add(
        TextSpan(
          text: group.substring(1, group.length - 1),
          style: base.copyWith(
            fontFamily: 'monospace',
            fontSize: (base.fontSize ?? 14) - 1.5,
            color: accent,
            backgroundColor: accent.withValues(alpha: .08),
          ),
        ),
      );
    } else if (group.startsWith('**') || group.startsWith('__')) {
      spans.add(
        TextSpan(
          text: group.substring(2, group.length - 2),
          style: base.copyWith(fontWeight: FontWeight.bold),
        ),
      );
    } else if (group.startsWith('~~')) {
      spans.add(
        TextSpan(
          text: group.substring(2, group.length - 2),
          style: base.copyWith(decoration: TextDecoration.lineThrough),
        ),
      );
    } else if (group.startsWith('==')) {
      spans.add(
        TextSpan(
          text: group.substring(2, group.length - 2),
          style: base.copyWith(
            backgroundColor: const Color(0xFFFFF59D).withValues(alpha: .85),
          ),
        ),
      );
    } else if (group.startsWith('![')) {
      final img = _imagePattern.firstMatch(group);
      if (img != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _MarkdownImage(
              alt: img.group(1) ?? '',
              url: img.group(2)!,
              base: base,
              compact: true,
            ),
          ),
        );
      } else {
        spans.add(TextSpan(text: group, style: base));
      }
    } else if (group.startsWith('[^')) {
      final inline = markdownFootnoteMatch(group);
      final id = inline?.id ?? _footnoteRefPattern.firstMatch(group)?.group(1);
      if (id != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.top,
            child: Transform.translate(
              offset: const Offset(0, -2),
              child: Text(
                '[$id]',
                style: base.copyWith(
                  color: accent,
                  fontSize: ((base.fontSize ?? 15) * 0.72).clamp(10.0, 12.0),
                  height: 1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        );
      } else {
        spans.add(TextSpan(text: group, style: base));
      }
    } else if (group.startsWith('[')) {
      final m2 = RegExp(r'^\[([^\]]+)\]\(([^)\s]+)\)$').firstMatch(group);
      if (m2 != null) {
        final url = m2.group(2)!;
        spans.add(
          TextSpan(
            text: m2.group(1),
            style: base.copyWith(
              color: accent,
              decoration: TextDecoration.underline,
              decorationColor: accent,
            ),
            recognizer: TapGestureRecognizer()..onTap = () => _openUrl(url),
          ),
        );
      } else {
        spans.add(TextSpan(text: group, style: base));
      }
    } else if (group.toLowerCase().startsWith('<kbd>')) {
      final kbd = _kbdPattern.firstMatch(group);
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _KbdChip(label: (kbd?.group(1) ?? group).trim(), base: base),
        ),
      );
    } else if (group.startsWith(r'$')) {
      final inner = group.substring(1, group.length - 1);
      spans.add(
        TextSpan(
          text: markdownLatexPlain(inner),
          style: base.copyWith(
            fontStyle: FontStyle.italic,
            fontFamily: 'monospace',
            color: accent,
          ),
        ),
      );
    } else if (group.startsWith('*') || group.startsWith('_')) {
      spans.add(
        TextSpan(
          text: group.substring(1, group.length - 1),
          style: base.copyWith(fontStyle: FontStyle.italic),
        ),
      );
    } else {
      final chord = _chordPattern.firstMatch(group);
      if (chord != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _KbdChip(label: chord.group(1)!, base: base),
          ),
        );
        spans.add(TextSpan(text: ' + ', style: base));
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _KbdChip(label: chord.group(2)!.toUpperCase(), base: base),
          ),
        );
      } else {
        spans.add(TextSpan(text: group, style: base));
      }
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

enum MarkdownTableColumnKind { serial, title, compact, body }

class MarkdownTableColumnSpec {
  final MarkdownTableColumnKind kind;
  final int flex;
  final double fontSize;
  final bool vertical;
  final TextAlign textAlign;
  const MarkdownTableColumnSpec({
    required this.kind,
    required this.flex,
    required this.fontSize,
    required this.vertical,
    required this.textAlign,
  });
}

final _indexHeader = RegExp(r'^(序号|#|no\.?|编号|id)$', caseSensitive: false);
final _titleHeader = RegExp(
  r'^(标题|title|名称|name|项目|模块|功能)$',
  caseSensitive: false,
);
final _compactHeader = RegExp(
  r'^(状态|status|阶段|stage|类型|type|等级|level|优先级|priority)$',
  caseSensitive: false,
);
final _bodyHeader = RegExp(
  r'正文|内容|说明|描述|body|content|detail',
  caseSensitive: false,
);
final _indexCell = RegExp(r'^\d{1,4}$');

const int _tableDenseMinChars = 16;
const int _tableTitleMaxChars = 12;
const int _tableCompactMaxChars = 4;

/// 短列竖排：每个字单独一行，把列宽压到约一个汉字。
String markdownTableStackChars(String text) {
  final t = text.trim();
  if (t.length <= 1) return t;
  return t.split('').join('\n');
}

int markdownTableMaxChars(Iterable<String> values) {
  var maxLen = 0;
  for (final v in values) {
    final n = v.trim().length;
    if (n > maxLen) maxLen = n;
  }
  return maxLen;
}

/// 整表有足够长的单元格才进入压缩布局；水果/产地/价格这种短表保持正常横排。
bool markdownTableIsDense({
  required List<String> headers,
  required List<List<String>> body,
}) {
  var maxLen = markdownTableMaxChars(headers);
  for (final row in body) {
    final n = markdownTableMaxChars(row);
    if (n > maxLen) maxLen = n;
  }
  return maxLen >= _tableDenseMinChars;
}

MarkdownTableColumnKind markdownTableColumnKind(
  String header,
  List<String> cells,
) {
  final h = header.trim();
  if (_indexHeader.hasMatch(h)) return MarkdownTableColumnKind.serial;
  if (_titleHeader.hasMatch(h)) return MarkdownTableColumnKind.title;
  if (_compactHeader.hasMatch(h)) return MarkdownTableColumnKind.compact;
  if (_bodyHeader.hasMatch(h)) return MarkdownTableColumnKind.body;
  final values = cells.map((c) => c.trim()).where((c) => c.isNotEmpty);
  if (values.isNotEmpty &&
      values.every(_indexCell.hasMatch) &&
      (h.isEmpty || _indexHeader.hasMatch(h))) {
    return MarkdownTableColumnKind.serial;
  }
  final maxLen = markdownTableMaxChars([h, ...cells]);
  if (maxLen <= _tableCompactMaxChars) return MarkdownTableColumnKind.compact;
  if (maxLen <= _tableTitleMaxChars) return MarkdownTableColumnKind.title;
  return MarkdownTableColumnKind.body;
}

/// 短表正常横排；长表才把序号/状态竖排收窄，标题短语保持横排把宽度让给正文。
List<MarkdownTableColumnSpec> markdownTableColumnSpecs({
  required List<String> headers,
  required List<List<String>> body,
  double baseFontSize = 15,
}) {
  final dense = markdownTableIsDense(headers: headers, body: body);
  final colCount = headers.length;
  final specs = <MarkdownTableColumnSpec>[];
  for (var i = 0; i < colCount; i++) {
    final header = headers[i];
    final cells = [for (final row in body) i < row.length ? row[i] : ''];
    final kind = markdownTableColumnKind(header, cells);
    final maxChars = markdownTableMaxChars([header, ...cells]);
    final vertical =
        dense &&
        (kind == MarkdownTableColumnKind.serial ||
            kind == MarkdownTableColumnKind.compact) &&
        maxChars <= _tableCompactMaxChars;
    final flex = vertical
        ? 1
        : switch (kind) {
            MarkdownTableColumnKind.body => maxChars.clamp(8, 14),
            MarkdownTableColumnKind.title => maxChars.clamp(3, 6),
            MarkdownTableColumnKind.serial ||
            MarkdownTableColumnKind.compact => maxChars.clamp(2, 4),
          };
    final fontSize = vertical
        ? (baseFontSize - 5).clamp(10.0, 11.0)
        : dense && kind == MarkdownTableColumnKind.body
        ? (baseFontSize - 3).clamp(12.0, 13.0)
        : (baseFontSize - 3).clamp(12.0, 14.0);
    specs.add(
      MarkdownTableColumnSpec(
        kind: kind,
        flex: flex,
        fontSize: fontSize,
        vertical: vertical,
        textAlign: TextAlign.center,
      ),
    );
  }
  return specs;
}

/// 表格块：`| a | b |` GitHub 风格表格（含分隔行），列宽按内容自适应。
class _TableBlock extends StatelessWidget {
  final String block;
  final TextStyle base;
  final Color accent;
  final Map<String, String> footnotes;
  const _TableBlock({
    required this.block,
    required this.base,
    required this.accent,
    this.footnotes = const {},
  });

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
    final paddedHeader = [
      for (var i = 0; i < colCount; i++) i < header.length ? header[i] : '',
    ];
    final paddedBody = [
      for (final r in body)
        [for (var i = 0; i < colCount; i++) i < r.length ? r[i] : ''],
    ];
    final specs = markdownTableColumnSpecs(
      headers: paddedHeader,
      body: paddedBody,
      baseFontSize: base.fontSize ?? 15,
    );
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
          _tableRow(paddedHeader, specs: specs, isHeader: true),
          for (final r in paddedBody)
            _tableRow(r, specs: specs, isHeader: false),
        ],
      ),
    );
  }

  Widget _tableRow(
    List<String> cells, {
    required List<MarkdownTableColumnSpec> specs,
    required bool isHeader,
  }) {
    return Container(
      color: isHeader ? accent.withValues(alpha: .08) : null,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < specs.length; i++)
              _tableCell(
                cells[i],
                spec: specs[i],
                isHeader: isHeader,
                key: isHeader ? ValueKey('md-col-$i') : null,
                padRight: i != specs.length - 1,
              ),
          ],
        ),
      ),
    );
  }

  Widget _tableCell(
    String text, {
    required MarkdownTableColumnSpec spec,
    required bool isHeader,
    Key? key,
    required bool padRight,
  }) {
    final style =
        (isHeader ? base.copyWith(fontWeight: FontWeight.bold) : base).copyWith(
          fontSize: spec.fontSize,
          height: spec.vertical ? 1.15 : 1.35,
        );
    final Widget child;
    if (spec.vertical) {
      child = Text(
        markdownTableStackChars(text),
        textAlign: TextAlign.center,
        style: style,
      );
    } else {
      child = Text.rich(
        TextSpan(
          children: _renderInline(text, style, accent, footnotes: footnotes),
        ),
        style: style,
        textAlign: spec.textAlign,
      );
    }
    final padded = Padding(
      padding: EdgeInsets.only(right: padRight ? 4 : 0),
      child: Align(
        alignment: Alignment.center,
        child: spec.vertical
            ? child
            : SizedBox(width: double.infinity, child: child),
      ),
    );
    if (spec.vertical) {
      return KeyedSubtree(key: key, child: padded);
    }
    return Expanded(key: key, flex: spec.flex, child: padded);
  }
}

const _alertLabels = <String, String>{
  'NOTE': '注意',
  'TIP': '提示',
  'WARNING': '警告',
  'IMPORTANT': '重要',
  'CAUTION': '小心',
};

Color _alertColor(String type, Color fallback) {
  return switch (type) {
    'TIP' => const Color(0xFF1B7F4E),
    'WARNING' || 'CAUTION' => const Color(0xFFB45309),
    'IMPORTANT' => const Color(0xFF7C3AED),
    'NOTE' => const Color(0xFF2563EB),
    _ => fallback,
  };
}

/// 引用块：`> 引用`，左侧竖线 + 浅色底；识别 GitHub Alert。
class _QuoteBlock extends StatelessWidget {
  final String block;
  final TextStyle base;
  final Color accent;
  final Map<String, String> footnotes;
  const _QuoteBlock({
    required this.block,
    required this.base,
    required this.accent,
    this.footnotes = const {},
  });

  @override
  Widget build(BuildContext context) {
    final lines = block
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^>\s?'), ''))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return const SizedBox.shrink();
    String? alert;
    final first = _alertPattern.firstMatch(lines.first.trim());
    if (first != null) {
      alert = first.group(1)!.toUpperCase();
      lines.removeAt(0);
    }
    final color = alert == null ? accent : _alertColor(alert, accent);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.only(left: 10, top: 6, bottom: 6, right: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(color: color.withValues(alpha: .7), width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (alert != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                _alertLabels[alert] ?? alert,
                style: base.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontSize: (base.fontSize ?? 15) - 1,
                ),
              ),
            ),
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text.rich(
                TextSpan(
                  children: _renderInline(
                    l,
                    base,
                    color,
                    footnotes: footnotes,
                  ),
                ),
                style: base,
              ),
            ),
        ],
      ),
    );
  }
}

class _KbdChip extends StatelessWidget {
  final String label;
  final TextStyle base;
  const _KbdChip({required this.label, required this.base});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      child: Text(
        label,
        style: base.copyWith(
          fontFamily: 'monospace',
          fontSize: ((base.fontSize ?? 15) - 1.5).clamp(11.0, 13.0),
          height: 1.2,
        ),
      ),
    );
  }
}

class _FootnoteNote extends StatelessWidget {
  final String id;
  final String content;
  final TextStyle base;
  const _FootnoteNote({
    required this.id,
    required this.content,
    required this.base,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
      child: Text(
        '[$id] $content',
        style: base.copyWith(
          fontSize: ((base.fontSize ?? 15) - 1).clamp(12.0, 13.5),
          color: base.color?.withValues(alpha: .72) ?? Colors.grey.shade700,
          height: 1.35,
        ),
      ),
    );
  }
}

class _MarkdownImage extends StatelessWidget {
  final String alt;
  final String url;
  final TextStyle base;
  final bool compact;
  const _MarkdownImage({
    required this.alt,
    required this.url,
    required this.base,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final uri = Uri.tryParse(url);
    final network =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    final image = network
        ? Image.network(
            url,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                alignment: Alignment.center,
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: .5,
                ),
                child: Icon(
                  Icons.broken_image_outlined,
                  color: theme.colorScheme.outline,
                ),
              );
            },
          )
        : const SizedBox.shrink();
    final caption = alt.trim().isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              alt,
              style: base.copyWith(
                fontSize: ((base.fontSize ?? 15) - 2).clamp(11.0, 13.0),
                color: base.color?.withValues(alpha: .7),
              ),
            ),
          );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 2 : 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (network)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: compact ? 120 : 200,
                  maxWidth: compact ? 220 : double.infinity,
                ),
                child: SizedBox(width: double.infinity, child: image),
              ),
            ),
          caption,
        ],
      ),
    );
  }
}

class _DefListBlock extends StatelessWidget {
  final String block;
  final TextStyle base;
  final Color accent;
  final Map<String, String> footnotes;
  const _DefListBlock({
    required this.block,
    required this.base,
    required this.accent,
    this.footnotes = const {},
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    String? term;
    final defs = <String>[];
    void flush() {
      if (term == null) return;
      if (defs.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text.rich(
              TextSpan(
                children: _renderInline(
                  term!,
                  base,
                  accent,
                  footnotes: footnotes,
                ),
              ),
              style: base,
            ),
          ),
        );
      } else {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text.rich(
              TextSpan(
                children: _renderInline(
                  term!,
                  base.copyWith(fontWeight: FontWeight.w700),
                  accent,
                  footnotes: footnotes,
                ),
              ),
            ),
          ),
        );
        for (final def in defs) {
          children.add(
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 2),
              child: Text.rich(
                TextSpan(
                  children: _renderInline(
                    def,
                    base,
                    accent,
                    footnotes: footnotes,
                  ),
                ),
                style: base,
              ),
            ),
          );
        }
      }
      term = null;
      defs.clear();
    }

    for (final line in block.split('\n')) {
      final defM = _defListCapturePattern.firstMatch(line);
      if (defM != null) {
        defs.add(defM.group(1) ?? '');
        continue;
      }
      if (line.trim().isEmpty) {
        flush();
        continue;
      }
      if (term != null) flush();
      term = line.trim();
    }
    flush();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _MathBlock extends StatelessWidget {
  final String block;
  final TextStyle base;
  final Color accent;
  const _MathBlock({
    required this.block,
    required this.base,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    var inner = block.trim();
    if (inner.startsWith(r'$$')) inner = inner.substring(2);
    if (inner.endsWith(r'$$')) {
      inner = inner.substring(0, inner.length - 2);
    }
    inner = inner.trim();
    final matrix = RegExp(
      r'\\begin\{bmatrix\}([\s\S]*?)\\end\{bmatrix\}',
    ).firstMatch(inner);
    if (matrix != null) {
      final rows = markdownLatexMatrix(matrix.group(1)!);
      if (rows.isNotEmpty) {
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final cell in row)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            cell,
                            style: base.copyWith(
                              fontStyle: FontStyle.italic,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      }
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        markdownLatexPlain(inner),
        textAlign: TextAlign.center,
        style: base.copyWith(
          fontStyle: FontStyle.italic,
          fontFamily: 'monospace',
          height: 1.5,
        ),
      ),
    );
  }
}

TextStyle markdownCodeBlockStyle({
  required double baseFontSize,
  Color? color,
}) {
  return TextStyle(
    fontFamily: 'monospace',
    fontSize: (baseFontSize - 4).clamp(11.0, 12.5),
    height: 1.25,
    letterSpacing: -0.2,
    color: color,
  );
}

const _codeKeywords = {
  'and',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'def',
  'default',
  'defer',
  'del',
  'elif',
  'else',
  'enum',
  'except',
  'export',
  'extends',
  'false',
  'False',
  'finally',
  'fn',
  'for',
  'from',
  'func',
  'function',
  'go',
  'if',
  'impl',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'lambda',
  'late',
  'let',
  'mixin',
  'mod',
  'mut',
  'new',
  'None',
  'not',
  'null',
  'or',
  'override',
  'package',
  'pass',
  'private',
  'protected',
  'pub',
  'public',
  'return',
  'static',
  'struct',
  'super',
  'switch',
  'this',
  'throw',
  'trait',
  'true',
  'True',
  'try',
  'type',
  'typedef',
  'typeof',
  'use',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

String _codeCommentPattern(String language) {
  final lang = language.toLowerCase();
  if (lang == 'text' || lang == 'plain' || lang == 'json') return '';
  if (lang == 'python' ||
      lang == 'py' ||
      lang == 'yaml' ||
      lang == 'yml' ||
      lang == 'bash' ||
      lang == 'sh' ||
      lang == 'shell' ||
      lang == 'toml' ||
      lang == 'dockerfile') {
    return r'#[^\n]*';
  }
  if (lang == 'sql') return r'--[^\n]*|/\*[\s\S]*?\*/';
  if (lang == 'html' || lang == 'xml') return r'<!--[\s\S]*?-->';
  if (lang == 'css') return r'/\*[\s\S]*?\*/';
  return r'#[^\n]*|//[^\n]*|/\*[\s\S]*?\*/|--[^\n]*';
}

/// 轻量分色：关键字 / 字符串 / 注释 / 数字，不引入第三方高亮库。
List<TextSpan> markdownHighlightSpans(
  String code, {
  String language = '',
  Brightness brightness = Brightness.light,
  TextStyle? base,
}) {
  final dark = brightness == Brightness.dark;
  final keywordColor = dark
      ? const Color(0xFF79C0FF)
      : const Color(0xFF0550AE);
  final stringColor = dark
      ? const Color(0xFF7EE787)
      : const Color(0xFF0A7A3E);
  final commentColor = dark
      ? const Color(0xFF8B949E)
      : const Color(0xFF6E7781);
  final numberColor = dark
      ? const Color(0xFFFFA657)
      : const Color(0xFFB35900);
  final comment = _codeCommentPattern(language);
  final hasComment = comment.isNotEmpty;
  final pattern = [
    if (hasComment) '(?<comment>(?:$comment))',
    r'''(?<string>'''
        r"'''[\s\S]*?'''|"
        r'"""[\s\S]*?"""|'
        r"'[^'\\]*(?:\\.[^'\\]*)*'|"
        r'"[^"\\]*(?:\\.[^"\\]*)*"'
        r')',
    r'(?<number>\b\d+(?:\.\d+)?\b)',
    r'(?<ident>\b[A-Za-z_][A-Za-z0-9_]*\b)',
  ].join('|');
  final re = RegExp(pattern, multiLine: true);
  final spans = <TextSpan>[];
  var pos = 0;
  for (final m in re.allMatches(code)) {
    if (m.start > pos) {
      spans.add(TextSpan(text: code.substring(pos, m.start), style: base));
    }
    final text = m.group(0)!;
    Color? color;
    if (hasComment && m.namedGroup('comment') != null) {
      color = commentColor;
    } else if (m.namedGroup('string') != null) {
      color = stringColor;
    } else if (m.namedGroup('number') != null) {
      color = numberColor;
    } else if (_codeKeywords.contains(text)) {
      color = keywordColor;
    }
    spans.add(
      TextSpan(
        text: text,
        style: color == null
            ? base
            : (base ?? const TextStyle()).copyWith(color: color),
      ),
    );
    pos = m.end;
  }
  if (pos < code.length) {
    spans.add(TextSpan(text: code.substring(pos), style: base));
  }
  if (spans.isEmpty) {
    spans.add(TextSpan(text: code, style: base));
  }
  return spans;
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
    final style = markdownCodeBlockStyle(
      baseFontSize: base.fontSize ?? 15,
      color: theme.colorScheme.onSurface,
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: .25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                lang,
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.2,
                  color: theme.colorScheme.primary,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => Clipboard.setData(ClipboardData(text: code)),
                child: Icon(
                  Icons.copy_rounded,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              style: style,
              children: () {
                try {
                  return markdownHighlightSpans(
                    code,
                    language: lang,
                    brightness: theme.brightness,
                    base: style,
                  );
                } catch (_) {
                  return [TextSpan(text: code, style: style)];
                }
              }(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ListBlock extends StatelessWidget {
  final String block;
  final TextStyle base;
  final Color accent;
  final Map<String, String> footnotes;
  const _ListBlock({
    required this.block,
    required this.base,
    required this.accent,
    this.footnotes = const {},
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final line in block.split('\n')) {
      if (markdownIsFootnoteDefinition(line)) continue;
      final m = RegExp(r'^(\s*)([-*•]|\d+[.)、\.])\s+(.*)$').firstMatch(line);
      if (m == null) {
        // 混合块中非列表行不能丢，按普通段落保留，避免内容缺失
        if (line.trim().isNotEmpty) {
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text.rich(
                TextSpan(
                  children: _renderInline(
                    line.trim(),
                    base,
                    accent,
                    footnotes: footnotes,
                  ),
                ),
                style: base,
              ),
            ),
          );
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
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                      children: _renderInline(
                        taskM.group(2)!,
                        base,
                        accent,
                        footnotes: footnotes,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }
      final bullet = isNumbered
          ? '${prefix.replaceAll(RegExp(r'[.)、。）]'), '')}.'
          : prefix;
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: indentPx),
              SizedBox(
                width: 22,
                child: Text(
                  bullet,
                  style: base.copyWith(
                    color: accent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: _renderInline(
                      content,
                      base,
                      accent,
                      footnotes: footnotes,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  final TextStyle base;
  final Color accent;
  final Map<String, String> footnotes;
  const _Heading({
    required this.text,
    required this.base,
    required this.accent,
    this.footnotes = const {},
  });

  @override
  Widget build(BuildContext context) {
    final m = RegExp(r'^#+').firstMatch(text);
    final level = m == null ? 1 : m.group(0)!.length;
    final content = text.substring(level).trimLeft();
    final size = level == 1 ? 20.0 : (level == 2 ? 17.0 : 15.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 3,
            height: size * 1.2,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: _renderInline(
                  content,
                  base.copyWith(fontSize: size, fontWeight: FontWeight.bold),
                  accent,
                  footnotes: footnotes,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
