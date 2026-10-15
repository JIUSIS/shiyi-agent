import 'package:flutter/material.dart';

import '../core/code_change.dart';
import 'tool_glass.dart';

export '../core/code_change.dart'
    show codeChangePreview, codeChangeToolNames, isCodeChangeTool, toolArgsSummary;

/// 代码改动块：等宽字体，`+` 行绿、`-` 行红、其余灰。
class CodeChangeBlock extends StatelessWidget {
  final String preview;
  final double maxHeight;

  const CodeChangeBlock({
    super.key,
    required this.preview,
    this.maxHeight = 220,
  });

  static bool _isAdd(String line) =>
      line.startsWith('+') || line.startsWith('✚');
  static bool _isRemove(String line) => line.startsWith('- ');
  static bool _isMeta(String line) =>
      line.startsWith('📄') ||
      line.startsWith('@@') ||
      line.startsWith('***') ||
      line.startsWith('…');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['NotoSansSC', 'Menlo', 'Consolas'],
      fontSize: 11.5,
      height: 1.45,
      color: dark ? const Color(0xFFD6D6D6) : const Color(0xFF3A3A3C),
    );
    final addColor = dark ? const Color(0xFF6EE7A8) : const Color(0xFF1B7F4B);
    final removeColor = dark ? const Color(0xFFFF8A8A) : const Color(0xFFB3261E);
    final metaColor = theme.hintColor;
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: dark ? const Color(0x14FFFFFF) : const Color(0x0A000000),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in preview.split('\n'))
              Text(
                line,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: mono.copyWith(
                  color: _isMeta(line)
                      ? metaColor
                      : _isAdd(line)
                      ? addColor
                      : _isRemove(line)
                      ? removeColor
                      : null,
                  fontWeight: _isMeta(line) ? FontWeight.w600 : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 成员气泡里的一个工具调用胶囊：折叠时一行摘要，**展开后是完整入参与完整输出**。
class GroupToolPill extends StatefulWidget {
  final String name;
  final String argsSummary;
  final String summary;

  /// 完整入参（JSON）与完整输出：展开后原样显示，不截断（见 docs/fix-log.md #413）。
  final String argsJson;
  final String result;
  final bool ok;
  final bool done;

  const GroupToolPill({
    super.key,
    required this.name,
    this.argsSummary = '',
    this.summary = '',
    this.argsJson = '',
    this.result = '',
    this.ok = true,
    this.done = false,
  });

  @override
  State<GroupToolPill> createState() => _GroupToolPillState();
}

class _GroupToolPillState extends State<GroupToolPill> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isChange = isCodeChangeTool(widget.name);
    final label = toolEventLabelSafe(widget.name);
    final status = !widget.done
        ? '运行中'
        : (widget.ok ? '完成' : '失败');
    final canExpand =
        widget.summary.trim().isNotEmpty ||
        widget.result.trim().isNotEmpty ||
        widget.argsJson.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 胶囊外壳复用拾忆信息流那套液态玻璃（toolPillShell），不另画一套样式。
          toolPillShell(
            context: context,
            onTap: canExpand ? () => setState(() => _open = !_open) : () {},
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isChange ? Icons.edit_note : Icons.construction,
                    size: 13,
                    color: theme.hintColor,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (widget.argsSummary.trim().isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        widget.argsSummary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Text(
                    status,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: widget.done && !widget.ok
                          ? theme.colorScheme.error
                          : theme.hintColor,
                    ),
                  ),
                  if (canExpand) ...[
                    const SizedBox(width: 4),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 13,
                      color: theme.hintColor,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_open) ...[
            const SizedBox(height: 6),
            // 展开 = 完整内容，不再截断（见 docs/fix-log.md #413）：
            // ① 完整入参 ② 代码改动（写入类）或完整输出。
            if (widget.argsJson.trim().isNotEmpty)
              _DetailBlock(title: '入参', body: widget.argsJson.trim()),
            if (isChange && widget.summary.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              CodeChangeBlock(preview: widget.summary),
            ] else if (widget.result.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              _DetailBlock(title: '输出', body: widget.result.trim()),
            ] else ...[
              const SizedBox(height: 4),
              Text(
                widget.done ? '（无输出）' : '执行中…',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 展开里的一个"标题 + 完整正文"块：等宽、可选中、限高可滚。
class _DetailBlock extends StatelessWidget {
  final String title;
  final String body;

  const _DetailBlock({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.hintColor,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 3),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: toolGlassPanel(
            context: context,
            cornerRadius: 12,
            child: SingleChildScrollView(
              child: SelectableText(
                body,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['NotoSansSC', 'Menlo', 'Consolas'],
                  fontSize: 11.5,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 工具中文名（与 `tool_pill.dart` 的映射保持一致，避免循环依赖在此重复一份）。
String toolEventLabelSafe(String name) => switch (name) {
  'web_search' => '联网搜索',
  'web_extract' => '网页抓取',
  'save_memory' => '写入记忆',
  'search_memory' => '搜索记忆',
  'search_sessions' => '跨会话搜索',
  'read_session' => '阅读会话',
  'run_skill' => '运行技能',
  'run_terminal' => '终端命令',
  'read_file' || 'file_read' => '读取文件',
  'write_file' || 'file_write' || 'create_file' => '写入文件',
  'file_edit' || 'edit_file' || 'replace_in_file' || 'str_replace' => '编辑文件',
  'apply_patch' => '应用补丁',
  _ => name.isEmpty ? '工具' : name,
};
