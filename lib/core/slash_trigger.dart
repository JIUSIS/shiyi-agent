/// 输入 / 打开技能：只认独立斜杠，不认路径里的 abcd/。
bool isSkillSlashTrigger(String text) {
  if (text.isEmpty || !text.endsWith('/')) return false;
  if (text.length == 1) return true;
  final before = text[text.length - 2];
  return before.trim().isEmpty;
}

/// 选完技能后只删独立触发斜杠，路径斜杠和前面的空格都留下。
String stripSkillSlashTrigger(String text) {
  if (!isSkillSlashTrigger(text)) return text;
  return text.substring(0, text.length - 1);
}
