import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 桌面右键菜单条目。
class DesktopMenuItem {
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final VoidCallback? onTap;

  const DesktopMenuItem({
    required this.label,
    this.icon,
    this.iconColor,
    this.onTap,
  });
}

/// 在全局坐标 [globalPosition] 处弹出桌面菜单（Windows 专用）。
///
/// 手机端不应调用（用 showIosFadeModalPopup / 长按交互）。
/// 返回菜单关闭后是否执行了某个条目（未选择返回 false）。
Future<bool> showDesktopMenu(
  BuildContext context, {
  required Offset globalPosition,
  required List<DesktopMenuItem> items,
}) async {
  if (items.isEmpty) return false;
  final overlay = Overlay.of(context, rootOverlay: true);
  final box = overlay.context.findRenderObject() as RenderBox;
  final local = box.globalToLocal(globalPosition);
  final sel = await showMenu<int>(
    context: context,
    position: RelativeRect.fromLTRB(
      local.dx,
      local.dy,
      box.size.width - local.dx,
      box.size.height - local.dy,
    ),
    items: [
      for (var i = 0; i < items.length; i++)
        PopupMenuItem<int>(
          value: i,
          height: 38,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (items[i].icon != null) ...[
                Icon(
                  items[i].icon,
                  size: 17,
                  color: items[i].iconColor ?? CupertinoColors.systemBlue,
                ),
                const SizedBox(width: 10),
              ],
              Text(
                items[i].label,
                style: TextStyle(
                  fontSize: 14,
                  color: items[i].iconColor,
                ),
              ),
            ],
          ),
        ),
    ],
  );
  if (sel == null) return false;
  items[sel].onTap?.call();
  return true;
}
