import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/storage_scope.dart';

void main() {
  group('StorageScope', () {
    test('normalize 去掉尾斜杠，不动根', () {
      expect(StorageScope.normalize('/storage/emulated/0/'), '/storage/emulated/0');
      expect(StorageScope.normalize('/'), '/');
      expect(StorageScope.normalize(r'C:\Temp\\'), 'C:/Temp');
    });

    test('SD 根及以下无需 Root', () {
      expect(StorageScope.isWithinSdRoot('/storage/emulated/0'), isTrue);
      expect(StorageScope.isWithinSdRoot('/storage/emulated/0/agent'), isTrue);
      expect(StorageScope.isWithinSdRoot('/sdcard/Download'), isTrue);
      expect(StorageScope.isWithinSdRoot('/storage/self/primary/DCIM'), isTrue);
    });

    test('SD 以上需要 Root', () {
      expect(StorageScope.isWithinSdRoot('/storage/emulated'), isFalse);
      expect(StorageScope.isWithinSdRoot('/storage'), isFalse);
      expect(StorageScope.isWithinSdRoot('/data'), isFalse);
      expect(StorageScope.isWithinSdRoot('/'), isFalse);
      expect(StorageScope.isWithinSdRoot('/data/data/com.shiyi.agent'), isFalse);
    });

    test('非 Android 不限制', () {
      expect(StorageScope.isWithinSdRoot('/data', android: false), isTrue);
    });

    test('parentOf / 文件系统根', () {
      expect(StorageScope.parentOf('/storage/emulated/0/agent'), '/storage/emulated/0');
      expect(StorageScope.parentOf('/storage/emulated/0'), '/storage/emulated');
      expect(StorageScope.parentOf('/'), '/');
      expect(StorageScope.isFilesystemRoot('/'), isTrue);
      expect(StorageScope.isFilesystemRoot('/storage'), isFalse);
      expect(StorageScope.isFilesystemRoot('C:'), isTrue);
    });

    test('从 SD 根往上跳过不可列出的 /storage/emulated', () {
      expect(
        StorageScope.visibleParent('/storage/emulated/0'),
        '/storage',
      );
      expect(StorageScope.visibleParent('/sdcard'), '/storage');
      expect(
        StorageScope.visibleParent('/storage/self/primary'),
        '/storage',
      );
      expect(StorageScope.resolveListable('/storage/emulated'), '/storage/emulated/0');
      expect(StorageScope.visibleParent('/storage'), '/');
    });

    test('离开 SD 树才算越界', () {
      expect(
        StorageScope.leavesSdRoot('/storage/emulated/0/agent', '/storage/emulated/0'),
        isFalse,
      );
      expect(
        StorageScope.leavesSdRoot('/storage/emulated/0', '/storage/emulated'),
        isTrue,
      );
    });

    test('parseListing 识别 ls -1F 的目录斜杠', () {
      const out = 'adb/\nbuild.prop\nbin*\n';
      final parsed = RootAccess.parseListing(out);
      expect(parsed.map((e) => (e.name, e.isDir)).toList(), [
        ('adb', true),
        ('build.prop', false),
        ('bin', false),
      ]);
    });

    test('parseListing 识别 ls -l 首字符', () {
      const out =
          'total 8\n'
          'drwxr-xr-x 2 root root 4096 2026-01-01 16:29 data\n'
          '-rw-r--r-- 1 root root  123 2026-01-01 16:29 build.prop\n';
      final parsed = RootAccess.parseListing(out);
      expect(parsed.map((e) => (e.name, e.isDir)).toList(), [
        ('data', true),
        ('build.prop', false),
      ]);
    });
  });
}
