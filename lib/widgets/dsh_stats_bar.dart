import 'package:flutter/material.dart';

import '../services/dsh_api.dart';
import 'chat_liquid_glass.dart';

/// DSH 统计栏：输入框上方，格式与官方 StatsLine 中文一致。
class DshStatsBar extends StatelessWidget {
  final DshSessionSummary? summary;
  const DshStatsBar({super.key, this.summary});

  static String _fmtDuration(num ms) {
    final s = ms / 1000;
    if (s < 60) return '${(s * 10).round() / 10}s';
    final whole = s.round();
    return '${whole ~/ 60}m${whole % 60}s';
  }

  static String _fmtTokens(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final v = n / 1000;
      return v >= 100 ? '${v.round()}K' : '${(v * 10).round() / 10}K';
    }
    final v = n / 1000000;
    return v >= 100 ? '${v.round()}M' : '${(v * 10).round() / 10}M';
  }

  static String _fmtTps(double v) =>
      v >= 100 ? '${v.round()}' : '${(v * 10).round() / 10}';

  @override
  Widget build(BuildContext context) {
    final s = summary;
    if (s == null || s.stepCount <= 0) return const SizedBox.shrink();
    final groups = detailGroups(s);
    return ChatStatsChip(label: compactLabel(s), detail: groups.join(' | '));
  }

  static String compactLabel(DshSessionSummary s) {
    if (s.hasBilling && s.billedInputTokens > 0) {
      return '缓存 ${(s.cacheReadTokens / s.billedInputTokens * 100).round()}%';
    }
    return '${s.turnCount} 轮';
  }

  static bool hasContent(DshSessionSummary? s) => s != null && s.stepCount > 0;

  static List<String> detailGroups(DshSessionSummary s) {
    final groups = <String>['${s.turnCount} 轮 · ${s.stepCount} 步'];
    final durations = <String>[];
    if (s.llmMs > 0) durations.add('LLM ${_fmtDuration(s.llmMs)}');
    if (s.toolMs > 0) durations.add('工具调用 ${_fmtDuration(s.toolMs)}');
    if (durations.isNotEmpty) groups.add(durations.join(' · '));
    final speeds = <String>[];
    if (s.ttftSteps > 0) {
      speeds.add('首 token 平均 ${_fmtDuration(s.ttftMs / s.ttftSteps)}');
    }
    if (s.decodeMs > 0 && s.decodeTokens > 0) {
      speeds.add('${_fmtTps(s.decodeTokens / (s.decodeMs / 1000))} tok/s');
    }
    if (speeds.isNotEmpty) groups.add(speeds.join(' · '));
    if (s.hasBilling) {
      if (s.billedInputTokens > 0) {
        final pct = (s.cacheReadTokens / s.billedInputTokens * 100).round();
        groups.add('缓存命中 $pct%');
      }
      groups.add(
        '输入 ${_fmtTokens(s.billedInputTokens)} tok · 输出 ${_fmtTokens(s.outputTokens)} tok',
      );
    }
    return groups;
  }
}
