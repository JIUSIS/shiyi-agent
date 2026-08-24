import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiyi_agent_app/services/file_workspace.dart';

void main() {
  group('FileWorkspace 默认目录', () {
    test('Android 仍是存储根下的 agent', () {
      expect(
        FileWorkspace.defaultWorkspacePathFrom(
          android: true,
          documentsDirectory: r'C:\Users\me\Documents',
        ),
        '/storage/emulated/0/agent',
      );
    });

    test('Windows 默认是本机文档下的 agent，不是临时目录', () {
      expect(
        FileWorkspace.defaultWorkspacePathFrom(
          android: false,
          documentsDirectory: r'C:\Users\me\Documents',
        ),
        p.join(r'C:\Users\me\Documents', 'agent'),
      );
      expect(
        FileWorkspace.defaultWorkspacePathFrom(
          android: false,
          documentsDirectory: r'C:\Users\me\Documents',
        ),
        isNot(contains('Temp')),
      );
    });

    test('旧的 TEMP\\agent 视为未自定义，改走文档目录', () {
      expect(
        FileWorkspace.isLegacyTempAgentPath(
          p.join(r'C:\Users\me\AppData\Local\Temp', 'agent'),
          systemTempPath: r'C:\Users\me\AppData\Local\Temp',
        ),
        isTrue,
      );
      expect(
        FileWorkspace.isLegacyTempAgentPath(
          p.join(r'C:\Users\me\Documents', 'agent'),
          systemTempPath: r'C:\Users\me\AppData\Local\Temp',
        ),
        isFalse,
      );
    });
  });
}
