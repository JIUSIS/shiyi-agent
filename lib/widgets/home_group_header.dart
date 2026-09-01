import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

const kHomeGroupAccent = Color(0xFF0A84FF);

/// 主页项目 / DSH 工作区分组头。可释放时高亮「松开以移入」。
class HomeGroupHeader extends StatelessWidget {
  final String name;
  final int count;
  final bool expanded;
  final bool dropReady;
  final VoidCallback onTap;
  final IconData? leadingIcon;
  final String? countText;
  final Widget? leading;
  const HomeGroupHeader({
    super.key,
    required this.name,
    required this.count,
    required this.expanded,
    required this.onTap,
    this.dropReady = false,
    this.leadingIcon,
    this.countText,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: dropReady
              ? kHomeGroupAccent.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: dropReady ? kHomeGroupAccent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  leading ??
                      Icon(
                        leadingIcon ??
                            (expanded
                                ? CupertinoIcons.folder_open
                                : CupertinoIcons.folder),
                        size: 18,
                        color: kHomeGroupAccent,
                      ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    dropReady ? '松开以移入' : (countText ?? '$count 个会话'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: dropReady
                          ? kHomeGroupAccent
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: dropReady ? FontWeight.w700 : null,
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeInOutCubic,
                    child: const Icon(
                      CupertinoIcons.chevron_down,
                      size: 18,
                      color: CupertinoColors.systemGrey,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
