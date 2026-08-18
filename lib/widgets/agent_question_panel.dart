import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'chat_liquid_glass.dart';

class AgentQuestionPanel extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> questions;
  final bool busy;
  final bool instantSingleChoice;
  final bool showCustomAnswers;
  final bool showSubmitActions;
  final ValueChanged<List<Map<String, dynamic>>> onSubmit;
  final VoidCallback onCancel;

  const AgentQuestionPanel({
    super.key,
    required this.title,
    required this.questions,
    required this.onSubmit,
    required this.onCancel,
    this.busy = false,
    this.instantSingleChoice = false,
    this.showCustomAnswers = false,
    this.showSubmitActions = false,
  });

  @override
  State<AgentQuestionPanel> createState() => _AgentQuestionPanelState();
}

class _QuestionDraft {
  final String id;
  final Set<String> selected = {};
  String custom = '';
  final TextEditingController controller = TextEditingController();

  _QuestionDraft(this.id);

  void dispose() => controller.dispose();
}

class _AgentQuestionPanelState extends State<AgentQuestionPanel> {
  late final List<_QuestionDraft> _drafts;

  @override
  void initState() {
    super.initState();
    _drafts = [
      for (final q in widget.questions)
        _QuestionDraft((q['id'] ?? '').toString()),
    ];
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  static String _optionLabel(dynamic option) {
    if (option is Map) {
      final label = option['label']?.toString();
      if (label != null && label.isNotEmpty) return label;
    }
    return option.toString();
  }

  bool _isMulti(int index) => widget.questions[index]['multiSelect'] == true;

  void _toggleOption(int index, String label) {
    if (widget.busy) return;
    final draft = _drafts[index];
    if (widget.instantSingleChoice &&
        widget.questions.length == 1 &&
        !_isMulti(index)) {
      widget.onSubmit([
        {
          'id': draft.id,
          'selected': [label],
        },
      ]);
      return;
    }
    setState(() {
      if (_isMulti(index)) {
        if (!draft.selected.remove(label)) draft.selected.add(label);
      } else {
        draft.selected
          ..clear()
          ..add(label);
        draft.custom = '';
        draft.controller.clear();
      }
    });
  }

  void _submit() {
    final answers = <Map<String, dynamic>>[];
    for (var i = 0; i < widget.questions.length; i++) {
      final draft = _drafts[i];
      final custom = draft.custom.trim();
      final selected = custom.isEmpty || _isMulti(i)
          ? draft.selected.toList()
          : <String>[];
      answers.add({
        'id': draft.id,
        'selected': selected,
        if (custom.isNotEmpty) 'custom': custom,
      });
    }
    widget.onSubmit(answers);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final media = MediaQuery.of(context);
    final availableHeight = media.size.height - media.viewInsets.bottom;
    final maxPanelHeight = (availableHeight * .60).clamp(160.0, 420.0);
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxPanelHeight),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .18 : .07),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: LiquidGlassLens(
        style: chatLiquidGlassStyle(
          context,
          cornerRadius: 12,
          tint: dark ? const Color(0x663A3A3C) : const Color(0x70FFFFFF),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(theme),
                const SizedBox(height: 2),
                Flexible(
                  fit: FlexFit.loose,
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < widget.questions.length; i++)
                          _buildQuestion(theme, i),
                      ],
                    ),
                  ),
                ),
                if (widget.showSubmitActions) _buildActions(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Row(
      children: [
        Icon(Icons.help_outline, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall!.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        IconButton(
          onPressed: widget.busy ? null : widget.onCancel,
          icon: const Icon(Icons.close, size: 18),
          tooltip: '取消提问',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ],
    );
  }

  Widget _buildQuestion(ThemeData theme, int index) {
    final question = widget.questions[index];
    final draft = _drafts[index];
    final header = question['header']?.toString() ?? '';
    final detail = question['detail']?.toString() ?? '';
    final text = question['question']?.toString() ?? '';
    final options = ((question['options'] as List?) ?? const []).toList();
    return Padding(
      padding: EdgeInsets.only(
        bottom: index == widget.questions.length - 1 ? 0 : 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header.isNotEmpty)
            Text(
              header,
              style: theme.textTheme.labelMedium!.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          Text(text, style: theme.textTheme.bodyMedium!.copyWith(height: 1.4)),
          if (detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                detail,
                style: theme.textTheme.bodySmall!.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: .72,
                ),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isMulti(index) ? '快捷选项·可多选' : '快捷选项',
                    style: theme.textTheme.labelMedium!.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (
                    var optionIndex = 0;
                    optionIndex < options.length;
                    optionIndex++
                  ) ...[
                    if (optionIndex > 0) const SizedBox(height: 6),
                    _buildOptionButton(
                      theme,
                      index,
                      _optionLabel(options[optionIndex]),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (widget.showCustomAnswers) ...[
            const SizedBox(height: 8),
            TextField(
              enabled: !widget.busy,
              controller: draft.controller,
              minLines: 1,
              maxLines: 3,
              onChanged: (value) => setState(() {
                draft.custom = value;
                if (value.trim().isNotEmpty && !_isMulti(index)) {
                  draft.selected.clear();
                }
              }),
              decoration: InputDecoration(
                hintText: '直接输入你的回答…',
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: .55,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionButton(ThemeData theme, int index, String label) {
    final selected = _drafts[index].selected.contains(label);
    return SizedBox(
      width: double.infinity,
      child: FilledButton.tonal(
        onPressed: widget.busy ? null : () => _toggleOption(index, label),
        style: FilledButton.styleFrom(
          alignment: Alignment.centerLeft,
          backgroundColor: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.secondaryContainer,
          foregroundColor: selected
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSecondaryContainer,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          visualDensity: VisualDensity.compact,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Row(
          children: [
            if (_isMulti(index)) ...[
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 17,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                label,
                textAlign: TextAlign.left,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          TextButton(
            onPressed: widget.busy ? null : widget.onCancel,
            child: const Text('取消'),
          ),
          const Spacer(),
          FilledButton(
            onPressed: widget.busy ? null : _submit,
            child: widget.busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('提交'),
          ),
        ],
      ),
    );
  }
}
