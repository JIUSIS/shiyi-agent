import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/slash_trigger.dart';

void main() {
  group('技能斜杠触发', () {
    test('单独的 / 才弹技能，路径里的 / 不弹', () {
      expect(isSkillSlashTrigger('/'), isTrue);
      expect(isSkillSlashTrigger(' /'), isTrue);
      expect(isSkillSlashTrigger('abcd /'), isTrue);
      expect(isSkillSlashTrigger('abcd/'), isFalse);
      expect(isSkillSlashTrigger('path/to/'), isFalse);
      expect(isSkillSlashTrigger(''), isFalse);
    });

    test('删触发斜杠时保留前面的空格和正文', () {
      expect(stripSkillSlashTrigger('abcd /'), 'abcd ');
      expect(stripSkillSlashTrigger('/'), '');
      expect(stripSkillSlashTrigger(' /'), ' ');
      expect(stripSkillSlashTrigger('abcd/'), 'abcd/');
      expect(stripSkillSlashTrigger('hello'), 'hello');
    });
  });
}
