import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/termux_runtime.dart';

/// Windows 终端后端选择逻辑（纯函数，不依赖真实 wsl/pwsh 探测）。
void main() {
  group('resolveBackendChoice', () {
    test('显式 pwsh / cmd / gitbash 直接生效，不依赖探测结果', () {
      expect(
        TermuxRuntime.resolveBackendChoice('pwsh', 'wsl2', 'pwsh'),
        'pwsh',
      );
      expect(
        TermuxRuntime.resolveBackendChoice('pwsh', 'none', 'cmd'),
        'pwsh',
      );
      expect(
        TermuxRuntime.resolveBackendChoice('cmd', 'wsl2', 'pwsh'),
        'cmd',
      );
      expect(
        TermuxRuntime.resolveBackendChoice(
          'gitbash',
          'wsl2',
          'pwsh',
          gitBash: true,
        ),
        'gitbash',
      );
    });

    test('auto：WSL2 可用时优先于 Git Bash 与 Windows shell', () {
      expect(
        TermuxRuntime.resolveBackendChoice('auto', 'wsl2', 'pwsh'),
        'wsl2',
      );
      expect(
        TermuxRuntime.resolveBackendChoice(
          'auto',
          'wsl2',
          'cmd',
          gitBash: true,
        ),
        'wsl2',
      );
    });

    test('auto：无 WSL2 时 Git Bash 优先于 PowerShell / cmd', () {
      expect(
        TermuxRuntime.resolveBackendChoice(
          'auto',
          'none',
          'pwsh',
          gitBash: true,
        ),
        'gitbash',
      );
      expect(
        TermuxRuntime.resolveBackendChoice(
          'auto',
          'wsl1',
          'cmd',
          gitBash: true,
        ),
        'gitbash',
      );
    });

    test('auto：WSL 与 Git Bash 都没有时回退 Windows shell', () {
      expect(
        TermuxRuntime.resolveBackendChoice('auto', 'none', 'pwsh'),
        'pwsh',
      );
      expect(
        TermuxRuntime.resolveBackendChoice('auto', 'wsl1', 'cmd'),
        'cmd',
      );
      expect(
        TermuxRuntime.resolveBackendChoice('auto', 'none', 'cmd'),
        'cmd',
      );
    });

    test('显式 wsl2：WSL2 可用时生效，否则回退 Git Bash 或 Windows shell', () {
      expect(
        TermuxRuntime.resolveBackendChoice('wsl2', 'wsl2', 'cmd'),
        'wsl2',
      );
      expect(
        TermuxRuntime.resolveBackendChoice(
          'wsl2',
          'none',
          'pwsh',
          gitBash: true,
        ),
        'gitbash',
      );
      expect(
        TermuxRuntime.resolveBackendChoice('wsl2', 'wsl1', 'cmd'),
        'cmd',
      );
    });

    test('显式 gitbash：未安装时回退 Windows shell', () {
      expect(
        TermuxRuntime.resolveBackendChoice('gitbash', 'none', 'pwsh'),
        'pwsh',
      );
    });
  });

  group('terminalBackend 设置持久化', () {
    test('默认 auto，随设置 JSON 往返', () {
      expect(AppSettings().terminalBackend, 'auto');
      expect(AppSettings.fromJson({}).terminalBackend, 'auto');
      expect(
        AppSettings.fromJson({'terminalBackend': 'wsl2'}).terminalBackend,
        'wsl2',
      );
      expect(
        AppSettings.fromJson({'terminalBackend': 'cmd'}).terminalBackend,
        'cmd',
      );
      final saved = AppSettings(terminalBackend: 'wsl2').toJson();
      expect(AppSettings.fromJson(saved).terminalBackend, 'wsl2');
      expect(
        AppSettings.fromJson({'terminalBackend': 'gitbash'}).terminalBackend,
        'gitbash',
      );
    });
  });

  group('工具描述按平台隔离，不把两端写进同一段', () {
    test('Windows 的 run_terminal 只写本机后端，不出现 Alpine / apk', () {
      final tool = ShiyiState.buildToolRegistryForTest(windows: true)
          .firstWhere((t) => t.name == 'run_terminal');
      expect(tool.description, contains('WSL2'));
      expect(tool.description, contains('Git Bash'));
      expect(tool.description, contains('PowerShell'));
      expect(tool.description, contains(r'文档\agent'));
      expect(tool.description, isNot(contains('Alpine')));
      expect(tool.description, isNot(contains('apk')));
      expect(tool.description, isNot(contains('proot')));
    });

    test('Android 的 run_terminal 只写 Alpine / apk，不出现 Windows 后端', () {
      final tool = ShiyiState.buildToolRegistryForTest(windows: false)
          .firstWhere((t) => t.name == 'run_terminal');
      expect(tool.description, contains('Alpine'));
      expect(tool.description, contains('apk'));
      expect(tool.description, isNot(contains('WSL2')));
      expect(tool.description, isNot(contains('Git Bash')));
      expect(tool.description, isNot(contains('PowerShell')));
      expect(tool.description, isNot(contains(r'文档\agent')));
    });

    test('Windows 的 file_write 路径示例只给文档\\agent', () {
      final tool = ShiyiState.buildToolRegistryForTest(windows: true)
          .firstWhere((t) => t.name == 'file_write');
      final desc = tool.parameters.toString();
      expect(desc, contains(r'文档\agent'));
      expect(desc, isNot(contains('/storage/emulated/0/agent')));
    });

    test('Android 的 file_write 路径示例只给存储根 agent', () {
      final tool = ShiyiState.buildToolRegistryForTest(windows: false)
          .firstWhere((t) => t.name == 'file_write');
      final desc = tool.parameters.toString();
      expect(desc, contains('/storage/emulated/0/agent'));
      expect(desc, isNot(contains(r'文档\agent')));
    });
  });
}
