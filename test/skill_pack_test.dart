import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/skill_pack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('shiyi/skillpack');

  /// 模拟原生解压：在 destDir 下创建文件，并返回 zip 条目清单。
  void mockExtract(List<Map<String, Object>> entries) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'extractZip') return null;
      final destDir = (call.arguments as Map)['destDir'] as String;
      for (final e in entries) {
        final f = File('$destDir/${e['path']}');
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(e['content'] as String);
      }
      return entries
          .map((e) => {'path': e['path'], 'size': e['size']})
          .toList();
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('大技能包：文本文件总量超预算时降级为大文件，files 列保持受控', () async {
    final tmp = Directory.systemTemp.createTempSync('skillpack_big_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final entries = <Map<String, Object>>[
      {
        'path': 'skill/SKILL.md',
        'size': 200,
        'content': '---\nname: 测试大包\n---\n# 测试正文',
      },
    ];
    // 900 个小文本文件，总计约 900KB，远超 500KB 预算。
    for (var i = 0; i < 900; i++) {
      entries.add({
        'path': 'skill/f$i.md',
        'size': 1024,
        'content': 'x' * 1024,
      });
    }
    mockExtract(entries);

    final pack = await SkillPackIO.importZip(
      zipPath: '${tmp.path}/fake.zip',
      destDir: '${tmp.path}/dest',
    );

    expect(pack.name, '测试大包');
    expect(pack.files.length + pack.largeFiles.length, 900);
    expect(pack.largeFiles, isNotEmpty,
        reason: '超出预算的文本文件应降级为磁盘大文件');

    final filesChars =
        pack.files.values.fold<int>(0, (sum, v) => sum + v.length);
    expect(filesChars, lessThanOrEqualTo(500 * 1024));

    // files 列序列化后必须远低于 800K 阈值，否则会被 _pruneOversizedSkills 静默删除。
    final filesJson = jsonEncode(pack.files);
    expect(filesJson.length, lessThan(800000),
        reason: 'files 列 JSON 过大是技能被静默删除的根因');

    // 降级的大文件确实在磁盘上（可读、可导出）。
    for (final p in pack.largeFiles.keys) {
      expect(File('${pack.dirPath}/$p').existsSync(), isTrue);
    }
  });

  test('SKILL.md 用 YAML 块标量 description 时正确解析', () async {
    final tmp = Directory.systemTemp.createTempSync('skillpack_fm_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final entries = <Map<String, Object>>[
      {
        'path': 'SKILL.md',
        'size': 500,
        'content':
            '---\nname: 测试块标量\n'
            'description: |\n'
            '  第一行描述\n'
            '  第二行描述\n'
            '---\n# 正文',
      },
    ];
    mockExtract(entries);

    final pack = await SkillPackIO.importZip(
      zipPath: '${tmp.path}/fake.zip',
      destDir: '${tmp.path}/dest',
    );

    expect(pack.name, '测试块标量');
    expect(pack.description, '第一行描述\n第二行描述');
  });

  test('小技能包：文本文件全部入库，不产生大文件', () async {
    final tmp = Directory.systemTemp.createTempSync('skillpack_small_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    final entries = <Map<String, Object>>[
      {
        'path': 'SKILL.md',
        'size': 200,
        'content': '---\nname: 测试小包\n---\n# 小技能',
      },
      {
        'path': 'references/note.md',
        'size': 100,
        'content': '一行笔记',
      },
    ];
    mockExtract(entries);

    final pack = await SkillPackIO.importZip(
      zipPath: '${tmp.path}/fake.zip',
      destDir: '${tmp.path}/dest',
    );

    expect(pack.name, '测试小包');
    expect(pack.files.length, 1);
    expect(pack.files['references/note.md'], '一行笔记');
    expect(pack.largeFiles, isEmpty);
  });
}

