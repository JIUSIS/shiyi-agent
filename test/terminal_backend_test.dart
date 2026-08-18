import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/services/termux_runtime.dart';

/// Windows 终端后端选择逻辑（纯函数，不依赖真实 wsl/pwsh 探测）。
void main() {
  group('resolveBackendChoice', () {
    test('显式 pwsh / cmd 直接生效，不依赖探测结果', () {
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
    });

    test('auto：WSL2 可用时优先于 Windows shell', () {
      expect(
        TermuxRuntime.resolveBackendChoice('auto', 'wsl2', 'pwsh'),
        'wsl2',
      );
      expect(
        TermuxRuntime.resolveBackendChoice('auto', 'wsl2', 'cmd'),
        'wsl2',
      );
    });

    test('auto：WSL 不可用或仅 WSL1 时回退 Windows shell', () {
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

    test('显式 wsl2：WSL2 可用时生效，否则回退 Windows shell', () {
      expect(
        TermuxRuntime.resolveBackendChoice('wsl2', 'wsl2', 'cmd'),
        'wsl2',
      );
      expect(
        TermuxRuntime.resolveBackendChoice('wsl2', 'none', 'pwsh'),
        'pwsh',
      );
      expect(
        TermuxRuntime.resolveBackendChoice('wsl2', 'wsl1', 'cmd'),
        'cmd',
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
    });
  });
}
