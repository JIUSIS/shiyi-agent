import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/dsh_api.dart';

/// 默认预设要写进哪个 settings 命名空间：rc.2 由插件名派生，不能写死。
/// 见 docs/fix-log.md #396。
void main() {
  test('挑名字里含 preset 的命名空间', () {
    expect(
      DshApiClient.pickAgentPresetNamespace([
        {'ns': 'deepseek-official'},
        {'ns': 'agent-preset-registry'},
        {'ns': 'llm-pi-ai'},
      ]),
      'agent-preset-registry',
    );
    expect(
      DshApiClient.pickAgentPresetNamespace([
        {'ns': 'permission'},
        {'ns': 'AgentPresets'},
      ]),
      'AgentPresets',
    );
  });

  test('没有候选就返回 null（调用方退回老名字）', () {
    expect(DshApiClient.pickAgentPresetNamespace(const []), isNull);
    expect(
      DshApiClient.pickAgentPresetNamespace([
        {'ns': 'deepseek-official'},
      ]),
      isNull,
    );
    expect(DshApiClient.pickAgentPresetNamespace(null), isNull);
    expect(DshApiClient.pickAgentPresetNamespace('nope'), isNull);
  });
}
