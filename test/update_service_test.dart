import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/update_service.dart';

void main() {
  group('UpdateService.compareVersion', () {
    test('相等版本返回 0', () {
      expect(UpdateService.compareVersion('1.1.5', '1.1.5'), 0);
    });

    test('高版本返回 1', () {
      expect(UpdateService.compareVersion('1.2.0', '1.1.9'), 1);
      expect(UpdateService.compareVersion('1.1.10', '1.1.9'), 1);
      expect(UpdateService.compareVersion('2.0.0', '1.9.9'), 1);
    });

    test('低版本返回 -1', () {
      expect(UpdateService.compareVersion('1.1.9', '1.2.0'), -1);
    });

    test('v 前缀不影响比较', () {
      expect(UpdateService.compareVersion('v1.1.5', '1.1.5'), 0);
      expect(UpdateService.compareVersion('v1.2.0', '1.1.5'), 1);
    });
  });
}
