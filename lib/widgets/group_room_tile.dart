import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/group_chat.dart';
import 'bagua_icon.dart';
import 'home_group_header.dart';
import 'ios_style.dart';
import 'swipe_actions.dart';

const _iosGray = Color(0xFF8E8E93);
const _iosRed = Color(0xFFFF3B30);
const _iosIndigo = Color(0xFF5856D6);

class GroupRoomTile extends StatelessWidget {
  final GroupRoom room;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onChangeProject;
  final ValueNotifier<String?>? openSwipeKey;
  final ValueChanged<Rect?>? onOpenRectChanged;
  final bool disableSwipe;
  final bool visualOnly;

  const GroupRoomTile({
    super.key,
    required this.room,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    this.onChangeProject,
    this.openSwipeKey,
    this.onOpenRectChanged,
    this.disableSwipe = false,
    this.visualOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = room.title.isEmpty ? '未命名群聊' : room.title;
    final tile = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          const BaguaIcon(size: 36, color: kHomeGroupAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 15.5,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  groupChatRoomSubtitle(room),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            CupertinoIcons.chevron_right,
            size: 16,
            color: CupertinoColors.systemGrey,
          ),
        ],
      ),
    );
    if (visualOnly) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: iosSectionBackground(context),
            borderRadius: BorderRadius.circular(14),
          ),
          child: tile,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SwipeActions(
        key: ValueKey(room.id),
        openNotifier: openSwipeKey,
        onOpenRectChanged: onOpenRectChanged,
        swipeKey: 'group-${room.id}',
        disableSwipe: disableSwipe,
        actionWidth: 168,
        onTap: onTap,
        actions: [
          CircularSwipeAction(
            icon: CupertinoIcons.folder,
            label: '项目',
            backgroundColor: _iosIndigo,
            foregroundColor: Colors.white,
            onTap: () {
              openSwipeKey?.value = null;
              onChangeProject?.call();
            },
          ),
          CircularSwipeAction(
            icon: CupertinoIcons.pencil,
            label: '编辑',
            backgroundColor: _iosGray,
            foregroundColor: Colors.white,
            onTap: () {
              openSwipeKey?.value = null;
              onEdit();
            },
          ),
          CircularSwipeAction(
            icon: CupertinoIcons.trash,
            label: '删除',
            backgroundColor: _iosRed,
            foregroundColor: Colors.white,
            onTap: () {
              openSwipeKey?.value = null;
              onDelete();
            },
          ),
        ],
        child: tile,
      ),
    );
  }
}
