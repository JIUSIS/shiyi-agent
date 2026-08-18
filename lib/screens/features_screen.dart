import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/mac_page_route.dart';
import '../widgets/ios_style.dart';
import '../widgets/traffic_lights_button.dart';
import 'memory_screen.dart';
import 'skills_screen.dart';

const _memoryBlue = Color(0xFF0A84FF);
const _skillPurple = Color(0xFFAF52DE);

class FeaturesScreen extends StatelessWidget {
  final ShiyiState shiyi;
  const FeaturesScreen({super.key, required this.shiyi});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: shiyi,
      builder: (context, _) => CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: Scaffold(
          backgroundColor: iosGroupedBackground(context),
          appBar: AppBar(
            leadingWidth: 72,
            // Windows：窗口三键已在全局标题栏，页面内红绿灯（仅 busy 指示）
            // 不再需要；手机端保留。
            leading: Platform.isWindows
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: TrafficLightsButton(
                      tooltip: '',
                      busy: shiyi.isBusy,
                    ),
                  ),
            toolbarHeight: 64,
            centerTitle: true,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            clipBehavior: Clip.none,
            title: const Text(
              '功能',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.only(top: 4, bottom: 28),
            children: [
              CupertinoListSection.insetGrouped(
                margin: iosSectionMargin,
                decoration: iosSectionDecoration(context),
                header: const Text('功能'),
                children: [
                  _FeatureTile(
                    icon: CupertinoIcons.heart_fill,
                    color: _memoryBlue,
                    title: '长期记忆',
                    subtitle: '搜索并管理对话中沉淀的重要信息',
                    count: shiyi.memories.length,
                    onTap: () => Navigator.push(
                      context,
                      MacPageRoute(builder: (_) => MemoryScreen(shiyi: shiyi)),
                    ),
                  ),
                  _FeatureTile(
                    icon: CupertinoIcons.rocket_fill,
                    color: _skillPurple,
                    title: '技能',
                    subtitle: '导入、编辑并复用可调用的技能包',
                    count: shiyi.skills.length,
                    onTap: () => Navigator.push(
                      context,
                      MacPageRoute(builder: (_) => SkillsScreen(shiyi: shiyi)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final int count;
  final VoidCallback onTap;
  const _FeatureTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoListTile(
      leading: Container(
        width: 31,
        height: 31,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Icon(icon, size: 17, color: CupertinoColors.white),
      ),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$count',
            style: TextStyle(
              fontSize: 15,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(CupertinoIcons.chevron_right, size: 16),
        ],
      ),
      onTap: onTap,
    );
  }
}
