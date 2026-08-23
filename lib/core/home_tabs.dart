import 'package:flutter/cupertino.dart';

/// 主页底部 / 侧栏的一个入口。
class HomeTabSpec {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  const HomeTabSpec(this.icon, this.selectedIcon, this.label);
}

/// 拾忆 / DSH 主页 Tab。两端最后一栏都是终端（接入内嵌 proot）。
class HomeTabs {
  HomeTabs._();

  static const int terminalIndex = 3;

  /// 切引擎时保留这些 tab（终端接同一套 Alpine，不能因重建而发 Ctrl+C）。
  static const keepAcrossEngineSwitch = [terminalIndex];

  static const shiyi = <HomeTabSpec>[
    HomeTabSpec(
      CupertinoIcons.chat_bubble_2,
      CupertinoIcons.chat_bubble_2_fill,
      '会话',
    ),
    HomeTabSpec(
      CupertinoIcons.square_grid_2x2,
      CupertinoIcons.square_grid_2x2_fill,
      '功能',
    ),
    HomeTabSpec(CupertinoIcons.folder, CupertinoIcons.folder_fill, '文件'),
    HomeTabSpec(
      CupertinoIcons.desktopcomputer,
      CupertinoIcons.desktopcomputer,
      '终端',
    ),
  ];

  static const dsh = <HomeTabSpec>[
    HomeTabSpec(
      CupertinoIcons.archivebox,
      CupertinoIcons.archivebox_fill,
      '工作数据',
    ),
    HomeTabSpec(
      CupertinoIcons.square_grid_2x2,
      CupertinoIcons.square_grid_2x2_fill,
      '功能',
    ),
    HomeTabSpec(CupertinoIcons.folder, CupertinoIcons.folder_fill, '文件'),
    HomeTabSpec(
      CupertinoIcons.desktopcomputer,
      CupertinoIcons.desktopcomputer,
      '终端',
    ),
  ];
}
