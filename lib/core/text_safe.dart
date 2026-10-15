/// UTF-16 安全文本工具。
///
/// Dart 的 `String` 是 UTF-16；按**码元**截断（`substring`）一旦落在一个
/// emoji / 增补平面字符的代理对中间，就会切出「孤立代理项（lone surrogate）」：
/// - Flutter 文字引擎遇到它会抛 `Invalid argument(s): string is not well-formed UTF-16`
///   （`_NativeParagraphBuilder.addText`），整条消息列表渲染失败；
/// - 这种字符串 `jsonEncode` 后是非法 UTF-8，请求发出去会被服务端直接断连
///   （日志表现为 `Connection closed before full header was received`
///   → 用户看到「网络连接失败」）。
///
/// 规则：凡是**按长度截断**都要走这里；凡是**来自外部/流式/日志拼装**的文本，
/// 在进入 UI 或请求体前先过 [sanitizeUtf16]。
library;

/// 是否是高位代理项（UTF-16 high surrogate）。
bool _isHigh(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// 是否是低位代理项（UTF-16 low surrogate）。
bool _isLow(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// 字符串里是否存在孤立代理项（快速扫描，正常情况下第一遍就能排除）。
bool hasLoneSurrogate(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (_isHigh(unit)) {
      if (i + 1 >= text.length || !_isLow(text.codeUnitAt(i + 1))) return true;
      i++; // 成对，跳过低位
      continue;
    }
    if (_isLow(unit)) return true;
  }
  return false;
}

/// 把孤立代理项替换成 U+FFFD（替换字符），其余原样保留。
///
/// 成对的代理项不动，所以正常的 emoji 不会被改。
String sanitizeUtf16(String text) {
  if (text.isEmpty) return text;
  if (!hasLoneSurrogate(text)) return text;
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (_isHigh(unit)) {
      if (i + 1 < text.length && _isLow(text.codeUnitAt(i + 1))) {
        out.writeCharCode(unit);
        out.writeCharCode(text.codeUnitAt(i + 1));
        i++;
      } else {
        out.writeCharCode(0xFFFD);
      }
      continue;
    }
    if (_isLow(unit)) {
      out.writeCharCode(0xFFFD);
      continue;
    }
    out.writeCharCode(unit);
  }
  return out.toString();
}

/// 按 **Unicode 码点**安全截取开头 [maxRunes] 个字符（不劈开 emoji）。
String cutRunes(String text, int maxRunes, {String ellipsis = '…'}) {
  if (maxRunes <= 0) return '';
  if (text.length <= maxRunes) return text;
  var count = 0;
  var i = 0;
  while (i < text.length && count < maxRunes) {
    final unit = text.codeUnitAt(i);
    if (_isHigh(unit) && i + 1 < text.length && _isLow(text.codeUnitAt(i + 1))) {
      i += 2;
    } else {
      i += 1;
    }
    count++;
  }
  if (i >= text.length) return text;
  return '${text.substring(0, i)}$ellipsis';
}

/// 按 **Unicode 码点**安全截取结尾 [maxRunes] 个字符（不劈开 emoji）。
String tailRunes(String text, int maxRunes, {String ellipsis = '…'}) {
  if (maxRunes <= 0) return '';
  if (text.length <= maxRunes) return text;
  var count = 0;
  var i = text.length;
  while (i > 0 && count < maxRunes) {
    final unit = text.codeUnitAt(i - 1);
    if (_isLow(unit) && i - 2 >= 0 && _isHigh(text.codeUnitAt(i - 2))) {
      i -= 2;
    } else {
      i -= 1;
    }
    count++;
  }
  if (i <= 0) return text;
  return '$ellipsis${text.substring(i)}';
}
