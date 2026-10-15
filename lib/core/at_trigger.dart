/// 输入 `@词` 打开引用选择（官方 @-引用：`fileReferences/list` +
/// `sessionReferenceResolver/candidates`）。
///
/// 只认"行首或空白之后的 `@`"，邮件地址 / 句中的 `a@b` 不触发。
String? atReferenceQuery(String text) {
  if (text.isEmpty) return null;
  final match = RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(text);
  return match?.group(1);
}

bool isAtReferenceTrigger(String text) => atReferenceQuery(text) != null;

/// 选中引用后，把末尾的 `@词` 换成 `@路径 `（保留前面的正文）。
String replaceAtReference(String text, String reference) {
  if (reference.isEmpty) return text;
  final replaced = text.replaceFirst(RegExp(r'@[^\s@]*$'), '@$reference ');
  return replaced;
}
