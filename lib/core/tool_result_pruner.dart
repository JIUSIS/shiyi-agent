/// 工具结果「掐头去尾」裁剪器。
///
/// 借鉴 DeepSeek Harness `compaction-tool-result-pruner` 的设计思路：
/// 输出超过阈值时不再一刀切（只留开头，结尾的报错/结论会被切掉），
/// 而是保留头部 + 尾部，中间用固定标记替换，关键信息不丢。
///
/// 按 Unicode 码点（runes）计数与切片：中文按单码点计、emoji 等代理对
/// 不会被切坏（Dart 的 String.length 是 UTF-16 单元，emoji 算 2）。
class ToolResultPruner {
  /// 超过该长度（Unicode 码点）才裁剪。
  final int thresholdChars;

  /// 保留的头部码点数。
  final int headChars;

  /// 保留的尾部码点数。
  final int tailChars;

  /// 替换中间被裁掉部分的固定标记。
  final String marker;

  const ToolResultPruner({
    this.thresholdChars = 32768,
    this.headChars = 16384,
    this.tailChars = 4096,
    this.marker = '\n\n[... 已裁剪中间内容 ...]\n\n',
  });

  /// 按 Unicode 码点计算文本长度（emoji 算 1，与 UTF-16 单元数不同）。
  static int codePointLength(String text) => text.runes.length;

  /// 裁剪后的文本；未超过阈值时返回原文本（同一引用）。
  String prune(String text) {
    assert(
      headChars + marker.length + tailChars <= thresholdChars,
      'headChars + marker + tailChars 不能超过 thresholdChars',
    );
    final total = text.runes.length;
    if (total <= thresholdChars) return text;
    final points = text.runes.toList();
    final head = String.fromCharCodes(points.take(headChars));
    final tail = String.fromCharCodes(points.skip(total - tailChars));
    return '$head$marker$tail';
  }
}
