import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shiyi_agent_app/core/app_state.dart';
import 'package:shiyi_agent_app/core/models.dart';
import 'package:shiyi_agent_app/widgets/group_project_picker.dart';

class _TestShiyiState extends ShiyiState {
  @override
  Future<Project> addProject(String name, {String workspaceDir = ''}) async {
    final project = Project(
      id: 'p-custom',
      name: name.trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      workspaceDir: workspaceDir.trim(),
    );
    projects = [...projects, project];
    notifyListeners();
    return project;
  }

  @override
  Future<void> deleteProject(String id) async {
    projects = [
      for (final project in projects)
        if (project.id != id) project,
    ];
    notifyListeners();
  }
}

class _MockFilePicker extends FilePicker {
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => '/storage/emulated/0/Agent/自定义项目';
}

void main() {
  testWidgets('项目文件夹选择器可以新建并自动选中', (tester) async {
    FilePicker.platform = _MockFilePicker();
    final shiyi = _TestShiyiState()
      ..projects = [
        Project(
          id: 'p-old',
          name: '旧项目',
          createdAt: 1,
          workspaceDir: '/storage/emulated/0/Agent/旧项目',
        ),
      ];
    String? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CupertinoButton(
              onPressed: () async {
                selected = await showGroupProjectPicker(
                  tester.element(find.text('打开选择器')),
                  shiyi,
                );
              },
              child: const Text('打开选择器'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    expect(find.text('旧项目'), findsOneWidget);
    expect(find.text('/storage/emulated/0/Agent/旧项目'), findsOneWidget);
    expect(find.text('新建项目文件夹'), findsOneWidget);

    await tester.tap(find.text('新建项目文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('选择文件夹位置'), findsOneWidget);

    await tester.tap(find.text('选择文件夹位置'));
    await tester.pumpAndSettle();
    expect(find.text('/storage/emulated/0/Agent/自定义项目'), findsOneWidget);

    await tester.enterText(find.byType(CupertinoTextField), ' 自定义项目 ');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(selected, 'p-custom');
    expect(shiyi.projects.last.name, '自定义项目');
  });

  testWidgets('左滑确认后删除项目，但不自动选中', (tester) async {
    final shiyi = _TestShiyiState()
      ..projects = [Project(id: 'p-old', name: '旧项目', createdAt: 1)];
    String? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CupertinoButton(
              onPressed: () async {
                selected = await showGroupProjectPicker(
                  tester.element(find.text('打开选择器')),
                  shiyi,
                );
              },
              child: const Text('打开选择器'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await tester.drag(find.text('旧项目'), const Offset(-360, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(shiyi.projects, isEmpty);
    expect(find.text('旧项目'), findsNothing);
    expect(selected, isNull);
  });
}
