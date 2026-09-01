import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/group_chat.dart';
import '../core/mac_page_route.dart';
import '../services/group_chat_store.dart';
import '../widgets/bagua_icon.dart';
import '../widgets/group_project_picker.dart';
import '../widgets/group_room_tile.dart';
import '../widgets/ios_style.dart';
import '../widgets/mac_action_button.dart';
import '../widgets/traffic_lights_button.dart';
import 'group_chat_screen.dart';
import 'group_chat_setup_screen.dart';

class GroupChatListScreen extends StatefulWidget {
  final ShiyiState shiyi;
  const GroupChatListScreen({super.key, required this.shiyi});

  @override
  State<GroupChatListScreen> createState() => _GroupChatListScreenState();
}

class _GroupChatListScreenState extends State<GroupChatListScreen> {
  List<GroupRoom> _rooms = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final rooms = await GroupChatStore.instance.listRooms();
    if (!mounted) return;
    setState(() {
      _rooms = rooms;
      _loading = false;
    });
  }

  Future<void> _afterRoute() async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (mounted) await _reload();
  }

  Future<void> _create() async {
    final created = await Navigator.push<bool>(
      context,
      MacPageRoute(builder: (_) => GroupChatSetupScreen(shiyi: widget.shiyi)),
    );
    if (created == true) await _afterRoute();
  }

  Future<void> _open(GroupRoom room) async {
    await Navigator.push<void>(
      context,
      MacPageRoute(
        builder: (_) => GroupChatScreen(shiyi: widget.shiyi, roomId: room.id),
      ),
    );
    await _afterRoute();
  }

  Future<void> _edit(GroupRoom room) async {
    final changed = await Navigator.push<bool>(
      context,
      MacPageRoute(
        builder: (_) => GroupChatSetupScreen(shiyi: widget.shiyi, room: room),
      ),
    );
    if (changed == true) await _afterRoute();
  }

  Future<void> _changeProject(GroupRoom room) async {
    final selected = await showGroupProjectPicker(
      context,
      widget.shiyi,
      currentProjectId: room.projectId.isEmpty ? null : room.projectId,
    );
    if (selected == null || !mounted) return;
    await GroupChatStore.instance.setRoomProject(
      room.id,
      selected.isEmpty ? null : selected,
    );
    await _reload();
    if (!mounted) return;
    showCupertinoDialog<void>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(selected.isEmpty ? '已移动到未分类' : '已移动到项目'),
        actions: [
          CupertinoDialogAction(
            child: const Text('好'),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(GroupRoom room) async {
    final ok = await showIosConfirmDialog(
      context: context,
      title: '删除群聊',
      message: '「${room.title}」和里面的消息都会删掉。',
      confirmLabel: '删除',
      isDestructiveAction: true,
    );
    if (!ok) return;
    await GroupChatStore.instance.deleteRoom(room.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MacBackFade(
      child: CupertinoTheme(
        data: iosCupertinoTheme(context),
        child: Scaffold(
          backgroundColor: iosGroupedBackground(context),
          appBar: AppBar(
            leadingWidth: 72,
            leading: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Platform.isWindows
                  ? MacActionButton(
                      icon: CupertinoIcons.plus,
                      tooltip: '新建群聊',
                      onTap: _create,
                    )
                  : TrafficLightsButton(
                      busy: widget.shiyi.isBusy,
                      tooltip: '新建群聊',
                      onTap: _create,
                    ),
            ),
            toolbarHeight: 64,
            centerTitle: true,
            backgroundColor: theme.scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            clipBehavior: Clip.none,
            title: const Text(
              '群聊',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
            ),
          ),
          body: _loading
              ? const Center(child: CupertinoActivityIndicator())
              : _rooms.isEmpty
              ? _EmptyGroupChats(onCreate: _create)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
                  children: [
                    for (final room in _rooms)
                      GroupRoomTile(
                        room: room,
                        onTap: () => _open(room),
                        onEdit: () => _edit(room),
                        onDelete: () => _delete(room),
                        onChangeProject: () => _changeProject(room),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _EmptyGroupChats extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyGroupChats({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BaguaIcon(size: 56, color: CupertinoColors.systemGrey3),
            const SizedBox(height: 12),
            const Text(
              '还没有群聊',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              '点左上角红绿灯新建，也可以贴思维导图生成 Agent',
              textAlign: TextAlign.center,
              style: TextStyle(color: CupertinoColors.secondaryLabel),
            ),
            const SizedBox(height: 18),
            CupertinoButton.filled(
              onPressed: onCreate,
              child: const Text('新建群聊'),
            ),
          ],
        ),
      ),
    );
  }
}
