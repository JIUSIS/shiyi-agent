import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/dsh_api.dart';

void main() {
  // 形状取自 DSH 0.1.1-rc.2 schemastery 真实序列化（z.union + z.const）。
  const schemaJson = '''
  {
    "uid": 8,
    "refs": {
      "1": {"type": "const", "meta": {"description": "Read Only"}, "value": "read-only"},
      "3": {"type": "const", "meta": {"description": "Workspace Write"}, "value": "workspace-write"},
      "5": {"type": "const", "meta": {"description": "Full access"}, "value": "danger-full-access"},
      "7": {"type": "union", "meta": {"required": true}, "list": [1, 3, 5]},
      "8": {"type": "object", "meta": {"default": {}}, "dict": {"defaultPreset": 7}}
    }
  }
  ''';

  test('从 schema 引用图解析权限预设表（键 + 官方标签）', () {
    final options = DshApiClient.permissionOptionsFromSchema(
      (jsonDecode(schemaJson) as Map).cast<String, dynamic>(),
    );
    expect(options, hasLength(3));
    expect(options[0].key, 'read-only');
    expect(options[0].label, 'Read Only');
    expect(options[1].key, 'workspace-write');
    expect(options[2].key, 'danger-full-access');
    expect(options[2].label, 'Full access');
  });

  test('缺 description 时回退用预设键当标签', () {
    final options = DshApiClient.permissionOptionsFromSchema(
      (jsonDecode('''
      {
        "uid": 3,
        "refs": {
          "1": {"type": "const", "value": "workspace-write"},
          "2": {"type": "union", "list": [1]},
          "3": {"type": "object", "dict": {"defaultPreset": 2}}
        }
      }
      ''') as Map).cast<String, dynamic>(),
    );
    expect(options, hasLength(1));
    expect(options.single.key, 'workspace-write');
    expect(options.single.label, 'workspace-write');
  });

  test('旧版 / 形状对不上时返回空列表，不硬编码预设名', () {
    expect(
      DshApiClient.permissionOptionsFromSchema(const {}),
      isEmpty,
    );
    expect(
      DshApiClient.permissionOptionsFromSchema({
        'uid': 1,
        'refs': {
          '1': {'type': 'object', 'dict': {"other": 2}},
        },
      }),
      isEmpty,
    );
    expect(
      DshApiClient.permissionOptionsFromSchema({
        'uid': 1,
        'refs': {
          '1': {'type': 'object'},
        },
      }),
      isEmpty,
    );
  });

  test('从 history 事件流折叠最后一次 permission/preset', () {
    const value = {
      'events': [
        {'event': {'type': 'turn/start', 'seq': 1}},
        {'event': {'type': 'permission/preset', 'data': {'preset': 'read-only'}, 'seq': 2}},
        {'event': {'type': 'assistant/message', 'seq': 3}},
        {'event': {'type': 'permission/preset', 'data': {'preset': 'danger-full-access'}, 'seq': 4}},
      ],
    };
    expect(DshApiClient.permissionPresetFromValue(value), 'danger-full-access');
    expect(DshApiClient.permissionPresetFromValue(const {'events': []}), isNull);
    expect(DshApiClient.permissionPresetFromValue(const {}), isNull);
  });
}
