import 'dart:async';
import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import '../core/models.dart';

String toolEventLabel(String name) => switch (name) {
  'web_search' => '搜索',
  'web_extract' => '抓取',
  'save_memory' => '记忆',
  'search_memory' => '检索',
  'run_skill' => '技能',
  'run_terminal' => '终端',
  'read_file' => '读文件',
  'write_file' => '写文件',
  'list_dir' => '列目录',
  _ => name,
};

IconData toolEventIcon(String name) => switch (name) {
  'web_search' => Icons.travel_explore,
  'web_extract' => Icons.web_asset,
  'save_memory' => Icons.bookmark_add_outlined,
  'search_memory' => Icons.manage_search,
  'run_skill' => Icons.bolt,
  'run_terminal' => Icons.terminal,
  'read_file' => Icons.description_outlined,
  'write_file' => Icons.edit_note,
  _ => Icons.construction,
};

BoxShadow _toolPillShadow(BuildContext context) {
  final isLight = Theme.of(context).brightness == Brightness.light;
  return BoxShadow(
    color: Colors.black.withValues(alpha: isLight ? 0.16 : 0.35),
    blurRadius: 12,
    offset: const Offset(0, 3),
  );
}

Color _toolPillBackground(BuildContext context) {
  final isLight = Theme.of(context).brightness == Brightness.light;
  return Colors.white.withValues(alpha: isLight ? 0.40 : 0.10);
}

LiquidGlassStyle _toolPillStyle(
  BuildContext context, {
  double cornerRadius = 14,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return LiquidGlassStyle(
    shape: LiquidGlassShape.continuousRoundedRectangle(
      cornerRadius: cornerRadius,
      borderWidth: 1,
      borderColor: Colors.white.withValues(alpha: dark ? .16 : .52),
      lightIntensity: .8,
      lightDirection: 110,
    ),
    appearance: LiquidGlassAppearance(
      color: _toolPillBackground(context),
      blur: const LiquidGlassBlur(sigmaX: 16, sigmaY: 16),
      saturation: 1.1,
    ),
    refraction: const LiquidGlassRefraction(
      distortion: .06,
      distortionWidth: 18,
      magnification: 1.01,
      chromaticAberration: .001,
    ),
  );
}

Widget toolPillShell({
  required BuildContext context,
  required VoidCallback onTap,
  required Widget child,
}) {
  return Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      boxShadow: [_toolPillShadow(context)],
    ),
    child: LiquidGlassLens(
      style: _toolPillStyle(context),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: child,
        ),
      ),
    ),
  );
}

/// 待机状态的工具胶囊：灰色圆点 + 「工具」字样。
class ToolPillIdle extends StatelessWidget {
  final VoidCallback onTap;
  const ToolPillIdle({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return toolPillShell(
      context: context,
      onTap: onTap,
      child: SizedBox(
        width: 104,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '工具',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.hintColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              Text(
                '0.0s',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 右上角胶囊：最近一条工具调用状态。
class ToolPill extends StatefulWidget {
  final ToolEvent event;
  final int index;
  final int total;
  final VoidCallback onTap;
  const ToolPill({
    super.key,
    required this.event,
    required this.index,
    required this.total,
    required this.onTap,
  });

  @override
  State<ToolPill> createState() => _ToolPillState();
}

class _ToolPillState extends State<ToolPill> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant ToolPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  void _syncTimer() {
    if (widget.event.done) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final event = widget.event;
    final elapsedSec =
        ((DateTime.now().millisecondsSinceEpoch - event.startedAt) / 1000)
            .clamp(0, double.infinity);
    return toolPillShell(
      context: context,
      onTap: widget.onTap,
      child: SizedBox(
        width: 104,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!event.done)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.primary,
                  ),
                )
              else
                Icon(
                  event.ok ? Icons.check_circle : Icons.error,
                  size: 14,
                  color: event.ok ? const Color(0xFF28C840) : cs.error,
                ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  event.done
                      ? toolEventLabel(event.name)
                      : '${toolEventLabel(event.name)} ${widget.index}/${widget.total}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.hintColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                event.done && event.durationMs != null
                    ? '${(event.durationMs! / 1000).toStringAsFixed(1)}s'
                    : event.done
                    ? '完成'
                    : '${elapsedSec.toStringAsFixed(0)}s',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 工具调用信息流面板。
class ToolLogPanel extends StatelessWidget {
  final List<ToolEvent> events;
  final VoidCallback onClose;
  const ToolLogPanel({super.key, required this.events, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [_toolPillShadow(context)],
      ),
      child: LiquidGlassLens(
        style: _toolPillStyle(context, cornerRadius: 16),
        child: Material(
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
                child: Row(
                  children: [
                    Icon(Icons.bolt, size: 15, color: cs.primary),
                    const SizedBox(width: 6),
                    Text(
                      '工具调用',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      tooltip: '收起',
                      visualDensity: VisualDensity.compact,
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: events.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
                          child: Text(
                            '暂无工具调用',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.hintColor,
                            ),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                          itemCount: events.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) => _ToolLogItem(
                            event: events[events.length - 1 - i],
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolLogItem extends StatelessWidget {
  final ToolEvent event;
  const _ToolLogItem({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    const okColor = Color(0xFF28C840);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: !event.done
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: cs.primary,
                    ),
                  )
                : Icon(
                    event.ok ? Icons.check_circle : Icons.error,
                    size: 15,
                    color: event.ok ? okColor : cs.error,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      toolEventIcon(event.name),
                      size: 14,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      toolEventLabel(event.name),
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (event.done)
                      Text(
                        event.durationMs == null
                            ? '完成'
                            : '${(event.durationMs! / 1000).toStringAsFixed(1)}s',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      )
                    else
                      Text(
                        '运行中',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.primary,
                        ),
                      ),
                  ],
                ),
                if (event.argsSummary.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    event.argsSummary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ],
                if (event.summary != null && event.summary!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    event.summary!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
