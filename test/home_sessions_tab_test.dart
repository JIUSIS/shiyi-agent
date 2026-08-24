import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyi_agent_app/screens/home_screen.dart';

void main() {
  group('拾忆项目卡片展开状态持久化', () {
    test('保存后能按项目 id 原样读回（排序去重）', () async {
      SharedPreferences.setMockInitialValues({});
      await shiyiSaveExpandedProjectIds(['p2', 'p1', 'p2', '']);
      expect(await shiyiLoadExpandedProjectIds(), ['', 'p1', 'p2']);
    });

    test('首次启动没有偏好时返回 null（默认展开未分类）', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await shiyiLoadExpandedProjectIds(), isNull);
    });

    test('保存空列表表示全部收起，不回到默认展开未分类', () async {
      SharedPreferences.setMockInitialValues({});
      await shiyiSaveExpandedProjectIds(const []);
      expect(await shiyiLoadExpandedProjectIds(), isEmpty);
    });

    test('首次无偏好只展开未分类', () {
      expect(
        shiyiRestoreExpandedProjectIds(
          saved: null,
          knownProjectIds: const ['p1', 'p2'],
        ),
        {''},
      );
    });

    test('已保存的展开 id 只保留仍存在的项目和未分类', () {
      expect(
        shiyiRestoreExpandedProjectIds(
          saved: const ['p1', 'gone', ''],
          knownProjectIds: const ['p1', 'p2'],
        ),
        {'p1', ''},
      );
    });

    test('已保存空列表全部收起', () {
      expect(
        shiyiRestoreExpandedProjectIds(
          saved: const [],
          knownProjectIds: const ['p1'],
        ),
        isEmpty,
      );
    });
  });

  group('拾忆会话卡片左滑', () {
    test('左滑操作含复制 ID，删除仍在最右', () {
      expect(shiyiSessionSwipeLabels, ['重命名', '项目', '复制 ID', '删除']);
    });
  });
}
