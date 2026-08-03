import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Lightweight Markdown renderer: code blocks, inline code, bold, italic,
/// headings, bullet/numbered lists.
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

/// 解析 Markdown 文本为块列表（代码块 / 标题 / 列表 / 段落）。
List<String> splitMarkdownBlocks(String md) {
  final out = <String>[];
  final lines = md.split('\n');
  final buf = StringBuffer();
  var inCode = false;
  for (final line in lines) {
    if (line.startsWith('```')) {
      if (inCode) {
        buf.writeln(line);
        out.add(buf.toString());
        buf.clear();
        inCode = false;
      } else {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
        buf.writeln(line);
        inCode = true;
      }
      continue;
    }
    // 标题行立即独立成块，避免混在段落里被当成普通文字原样显示
    if (!inCode && RegExp(r'^#{1,6}(?=\s|$)').hasMatch(line)) {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
      out.add('$line\n');
      continue;
    }
    buf.writeln(line);
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
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
  const AdaptiveMarkdownText(
    this.data, {
    super.key,
    this.style,
    this.lazyThreshold = 15000,
  });

  @override
  Widget build(BuildContext context) {
    if (data.length <= lazyThreshold) {
      return MarkdownText(data, style: style);
    }
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
  final regex =
      RegExp(r'(`[^`]+`|\*\*[^*]+\*\*|__[^_]+__|\*[^*]+\*|_[^_]+_)');
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
    if (lines.isNotEmpty) {
      final first = lines.first.trim();
      // 首行若是语言标识（如 python / dart），不当作代码内容
      if (first.isNotEmpty && RegExp(r'^[A-Za-z0-9_+#.-]+$').hasMatch(first)) {
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
          Text('代码',
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
      final m = RegExp(r'^\s*([-*•]|\d+[.)、\.])\s+(.*)$').firstMatch(line);
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
      final prefix = m.group(1)!;
      final isNumbered = RegExp(r'^\d').hasMatch(prefix);
      final bullet = isNumbered ? '${prefix.replaceAll(RegExp(r'[.)、。）]'), '')}.' : prefix;
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 22,
            child: Text(bullet,
                style: base.copyWith(color: accent, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(children: _renderInline(m.group(2)!, base, accent)),
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
