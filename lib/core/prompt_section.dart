import 'dart:async';

/// 系统提示词段落：有名字、有顺序，可静态或动态求值。
///
/// 借鉴 DeepSeek Harness 的 PromptSection 设计（name / order / text）：
/// 段落按 [order] 升序组装，「当前时间永远排最后」从注释约定变成排序的代码事实；
/// 新增一种注入 = 注册一个段落，不用改组装主函数。
class PromptSection {
  /// 段落唯一名；同名注册在组装时会被识别（见 [assemblePromptSections] 的查重）。
  final String name;

  /// 组装顺序：升序拼接。约定：
  /// 0 人设 / 100 工具规则 / 200 工作目录 / 300 动态注入（记忆/技能）/
  /// 400 模式注入（计划模式）/ 900 历史归档 / 1000 当前时间。
  final int order;

  /// 静态文本；非空时直接使用，不调用 [builder]。
  final String text;

  /// 动态构建器；[text] 为空时调用。返回空串 = 本段落不参与组装。
  final Future<String> Function()? builder;

  const PromptSection({
    required this.name,
    required this.order,
    this.text = '',
    this.builder,
  }) : assert(text != '' || builder != null, '段落 $name 必须提供 text 或 builder');

  /// 求值本段落；静态文本优先。
  Future<String> build() async {
    if (text.isNotEmpty) return text;
    final b = builder;
    if (b == null) return '';
    return b();
  }
}

/// 按 [PromptSection.order] 升序组装段落：
/// 求值 → 跳过空段落 → 用空行（\n\n）拼接。
///
/// - 段落名重复会抛 [StateError]（DSH 同款约束：同一层内重复注册是配置错误）。
/// - order 相同时按注册顺序保持稳定（不依赖排序算法稳定性）。
Future<String> assemblePromptSections(List<PromptSection> sections) async {
  final names = <String>{};
  for (final s in sections) {
    if (!names.add(s.name)) {
      throw StateError('提示词段落重复注册: ${s.name}');
    }
  }
  final indexed = sections.asMap().entries.toList()
    ..sort((a, b) {
      final c = a.value.order.compareTo(b.value.order);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  final parts = <String>[];
  for (final e in indexed) {
    final text = await e.value.build();
    if (text.trim().isNotEmpty) parts.add(text);
  }
  return parts.join('\n\n');
}

/// 提示词变量插值：把 `{{name}}` 替换为注册变量的值。
///
/// - 严格模式（[strict] = true，内部模板用）：引用未注册变量抛 [StateError]，
///   早发现拼写错误；
/// - 宽容模式（默认，用户自定义提示词 / 技能模板用）：未注册变量原样保留，
///   用户文本里的 `{{...}}` 不会被误伤或弄崩。
String renderPromptVariables(
  String text,
  Map<String, String> variables, {
  bool strict = false,
}) {
  if (!text.contains('{{')) return text;
  return text.replaceAllMapped(RegExp(r'\{\{([a-z][a-z0-9_]*)\}\}'), (m) {
    final name = m.group(1)!;
    final value = variables[name];
    if (value != null) return value;
    if (strict) {
      throw StateError('提示词引用了未注册的变量 {{$name}}');
    }
    return m.group(0)!;
  });
}
