import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/dsh_plugin_store.dart';

const _samplePatch = '''
# top comment preserved

- insert:
    - id: web-search-duckduckgo
      name: '@deepseek-ai/dsh-web-search-duckduckgo'
      config:
        mode: html
        region: wt-wt

    - id: web-search-bing
      name: '@deepseek-ai/dsh-web-search-bing'
      config:
        apiKeyEnv: BING_SEARCH_API_KEY
        prefer: auto

- id: web
  config:
    searchProvider: bing

- id: some-plugin
  name: ./plugins/some-plugin/lib/index.js
''';

void main() {
  group('DshPluginStore.parsePatch', () {
    test('解析 insert 新装条目与顶层 config 覆盖', () {
      final entries = DshPluginStore.parsePatch(_samplePatch);
      final ids = entries.map((e) => e.id).toList();
      expect(ids, [
        'web-search-duckduckgo',
        'web-search-bing',
        'web',
        'some-plugin',
      ]);
      final bing = entries.firstWhere((e) => e.id == 'web-search-bing');
      expect(bing.inserted, isTrue);
      expect(bing.name, '@deepseek-ai/dsh-web-search-bing');
      expect(bing.config['apiKeyEnv'], 'BING_SEARCH_API_KEY');
      expect(bing.config['prefer'], 'auto');
      expect(bing.disabled, isFalse);

      final web = entries.firstWhere((e) => e.id == 'web');
      expect(web.inserted, isFalse);
      expect(web.config['searchProvider'], 'bing');
    });

    test('解析 disabled 标记', () {
      final patch = '''
- id: foo
  name: ./foo.js
  disabled: true
''';
      final e = DshPluginStore.parsePatch(patch).single;
      expect(e.id, 'foo');
      expect(e.disabled, isTrue);
    });

    test('空文本返回空列表', () {
      expect(DshPluginStore.parsePatch(''), isEmpty);
      expect(DshPluginStore.parsePatch('   \n'), isEmpty);
    });

    test('非法 YAML 不崩溃返回空列表', () {
      expect(
        DshPluginStore.parsePatch('this: is: not: a: list: ::[['),
        isEmpty,
      );
    });
  });

  group('DshPluginStore 文本变换', () {
    test('applySetDisabled 给 insert 条目追加 disabled: true', () {
      final next = DshPluginStore.applySetDisabled(
        _samplePatch,
        'web-search-bing',
        true,
      )!;
      expect(next, contains('  disabled: true'));
      // 恢复解析校验。
      final entries = DshPluginStore.parsePatch(next);
      final bing = entries.firstWhere((e) => e.id == 'web-search-bing');
      expect(bing.disabled, isTrue);
      // 其它条目不受影响。
      expect(entries.any((e) => e.id == 'some-plugin' && e.disabled), isFalse);
    });

    test('applySetDisabled 改写已有 disabled 行', () {
      final patch = '''
- id: foo
  name: ./foo.js
  disabled: true
''';
      final next = DshPluginStore.applySetDisabled(patch, 'foo', false)!;
      expect(next, contains('disabled: false'));
      expect(DshPluginStore.parsePatch(next).single.disabled, isFalse);
    });

    test('applySetDisabled 未命中返回 null', () {
      expect(
        DshPluginStore.applySetDisabled(_samplePatch, 'nope', true),
        isNull,
      );
    });

    test('applySetDisabled 处理顶层 entry（缩进 0）', () {
      final next = DshPluginStore.applySetDisabled(_samplePatch, 'web', true)!;
      final entries = DshPluginStore.parsePatch(next);
      final web = entries.firstWhere((e) => e.id == 'web');
      expect(web.disabled, isTrue);
    });

    test('applyRemove 删除 insert 条目并保留其他块', () {
      final next = DshPluginStore.applyRemove(_samplePatch, 'web-search-bing')!;
      final entries = DshPluginStore.parsePatch(next);
      expect(entries.any((e) => e.id == 'web-search-bing'), isFalse);
      expect(entries.any((e) => e.id == 'web-search-duckduckgo'), isTrue);
      expect(entries.any((e) => e.id == 'web'), isTrue);
    });

    test('applySetConfig 替换 config 子块', () {
      final next = DshPluginStore.applySetConfig(_samplePatch, 'web', {
        'searchProvider': 'duckduckgo',
        'retries': 3,
        'flags': ['a', 'b'],
      })!;
      final entries = DshPluginStore.parsePatch(next);
      final web = entries.firstWhere((e) => e.id == 'web');
      expect(web.config['searchProvider'], 'duckduckgo');
      expect(web.config['retries'], 3);
      expect(web.config['flags'], ['a', 'b']);
    });

    test('applySetConfig 在无 config 的条目上追加 config', () {
      final patch = '''
- id: bare
  name: ./bare.js
''';
      final next = DshPluginStore.applySetConfig(patch, 'bare', {
        'enabled': true,
      })!;
      final e = DshPluginStore.parsePatch(next).single;
      expect(e.config['enabled'], true);
    });
  });

  group('DshPluginStore 文件读写', () {
    late Directory tmp;
    late DshPluginStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('dsh-store-');
      final profile = Directory('${tmp.path}/profiles/web');
      await profile.create(recursive: true);
      await File('${profile.path}/package.json').writeAsString('''
{"dsh": {"profile": {"bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]}}}
''');
      await File('${profile.path}/cordis.patch.yml').writeAsString('''
- insert:
    - id: profile-only
      name: ./plugins/profile-only/lib/index.js
''');
      await File('${tmp.path}/cordis.patch.yml').writeAsString(_samplePatch);
      store = DshPluginStore(tmp.path);
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('list 合并内置 bundle 与清单条目', () async {
      final items = await store.list();
      final ids = items.map((e) => e.id).toList();
      expect(ids, contains('dsh-base'));
      expect(ids, contains('dsh-web-app'));
      expect(ids, contains('web-search-bing'));
      expect(ids, contains('profile-only'));
      expect(ids, isNot(contains('web')));
      final builtin = items.firstWhere((e) => e.id == 'dsh-base');
      expect(builtin.builtin, isTrue);
      final bing = items.firstWhere((e) => e.id == 'web-search-bing');
      expect(bing.builtin, isFalse);
      expect(bing.inserted, isTrue);
      expect(bing.source, 'home');
      expect(items.firstWhere((e) => e.id == 'profile-only').source, 'profile');
    });

    test('setDisabled / remove / updateConfig 写回文件', () async {
      await store.setDisabled('web-search-bing', true);
      await store.updateConfig('web', {'searchProvider': 'duckduckgo'});
      await store.remove('web-search-duckduckgo');

      final patched = await File(store.patchPath).readAsString();
      expect(patched, contains('disabled: true'));

      final items = await store.list();
      final byId = {for (final e in items) e.id: e};
      expect(byId['web-search-bing']!.disabled, isTrue);
      expect(byId['web-search-duckduckgo'], isNull);
      final patchEntries = DshPluginStore.parsePatch(
        await File(store.homePatchPath).readAsString(),
      );
      expect(
        patchEntries.firstWhere((e) => e.id == 'web').config['searchProvider'],
        'duckduckgo',
      );
    });

    test('修改 profile 插件时写回条目所在层', () async {
      await store.setDisabled('profile-only', true);
      final patched = await File(store.profilePatchPath).readAsString();
      expect(patched, contains('disabled: true'));
      expect(await File(store.homePatchPath).readAsString(), _samplePatch);
    });

    test('删除未命中抛异常', () async {
      expect(() => store.remove('not-exist'), throwsA(isA<Exception>()));
    });
  });
}
