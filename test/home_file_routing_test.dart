import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/screens/dsh_files_tab.dart';
import 'package:shiyi_agent_app/screens/files_screen.dart';
import 'package:shiyi_agent_app/screens/home_screen.dart';

void main() {
  test('DSH engine selects the host file page', () {
    final shiyi = ShiyiState()..settings.agentEngine = 'dsh';

    expect(buildFilesTabForEngine(shiyi), isA<DshFilesTab>());
    shiyi.dispose();
  });

  test('拾忆 engine keeps the local file page', () {
    final shiyi = ShiyiState()..settings.agentEngine = 'shiyi';

    expect(buildFilesTabForEngine(shiyi), isA<FilesScreen>());
    shiyi.dispose();
  });
}
