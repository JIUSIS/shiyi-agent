import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/home_list_order.dart';
import '../core/app_state.dart';
import '../core/group_chat.dart';
import '../core/mac_page_route.dart';
import '../screens/group_chat_screen.dart';
import '../screens/group_chat_setup_screen.dart';
import '../services/group_chat_store.dart';
import 'bagua_icon.dart';
import 'group_project_picker.dart';
import 'group_room_tile.dart';
import 'home_drag.dart';
import 'home_group_header.dart';
import 'ios_style.dart';
import 'staggered_sessions.dart';
import 'swipe_actions.dart';

class HomeGroupChats extends StatefulWidget {
  final ShiyiState shiyi;
  final ValueNotifier<String?>? openSwipeKey;
  final ValueChanged<Rect?>? onOpenRectChanged;
  const HomeGroupChats({
    super.key,
    required this.shiyi,
    this.openSwipeKey,
    this.onOpenRectChanged,
  });

  @override
  State<HomeGroupChats> createState() => HomeGroupChatsState();
}

class HomeGroupChatsState extends State<HomeGroupChats> {
  List<GroupRoom> _rooms = const [];
  bool _expanded = true;

  final Map<String, GlobalKey> _roomCardKeys = {};
  final HomeDragOverlay _dragOverlay = HomeDragOverlay();
  final List<double> _roomHeights = [];
  final List<double> _roomCenters = [];
  String? _draggingRoomId;
  int? _roomPreviewFrom;
  int? _roomPreviewTo;
  bool _flying = false;
  bool _snapShift = false;
  bool _dropCommitted = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final rooms = await GroupChatStore.instance.listRooms();
    if (!mounted) return;
    setState(() => _rooms = rooms);
  }

  Future<void> _afterRoute() async {
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (mounted) await reload();
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
    await reload();
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
    await reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(selected.isEmpty ? '已移动到未分类' : '已移动到项目')),
    );
  }

  GlobalKey _keyForRoom(String id) =>
      _roomCardKeys.putIfAbsent(id, GlobalKey.new);

  GroupRoom? _roomById(String id) {
    for (final room in _rooms) {
      if (room.id == id) return room;
    }
    return null;
  }

  double get _draggedRoomHeight {
    final from = _roomPreviewFrom;
    if (from == null || from >= _roomHeights.length) return 68;
    return _roomHeights[from];
  }

  void _removeDragVisuals() {
    _dragOverlay.remove();
  }

  void _clearRoomDragPreview() {
    _draggingRoomId = null;
    _roomPreviewFrom = null;
    _roomPreviewTo = null;
    _flying = false;
    _dropCommitted = false;
  }

  void _showDragOverlay({
    required GlobalKey originKey,
    required Widget card,
    Offset? pointerGlobal,
    double? visualHeight,
  }) {
    if (!kHomeDragOwnedOverlay) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final (originTopLeft, size) = homeDragOriginSlot(originKey);
    if (size == Size.zero) return;
    _dragOverlay.show(
      overlay,
      topLeft: originTopLeft,
      size: size,
      visualHeight: visualHeight,
      pointerGlobal: pointerGlobal,
      child: card,
    );
  }

  void _followDragOverlay(Offset global, {required double height}) {
    if (!kHomeDragOwnedOverlay || !_dragOverlay.isShowing) return;
    _dragOverlay.followGlobal(global);
  }

  void _onRoomDragStarted(String roomId, int index, Offset pointerGlobal) {
    if (_flying) return;
    widget.openSwipeKey?.value = null;
    _dropCommitted = false;
    _snapShift = false;
    _flying = false;
    final ids = [for (final room in _rooms) room.id];
    homeDragReadSlotGeometry(
      [for (final id in ids) _keyForRoom(id)],
      _roomHeights,
      _roomCenters,
    );
    final room = _roomById(roomId);
    if (room != null) {
      final slot = homeDragOriginSlot(_keyForRoom(roomId));
      final feedbackHeight = homeDragCardBodyHeight(slot.$2.height);
      _showDragOverlay(
        originKey: _keyForRoom(roomId),
        pointerGlobal: pointerGlobal,
        visualHeight: feedbackHeight,
        card: homeDragFeedbackClone(
          context,
          width: slot.$2.width,
          height: feedbackHeight,
          child: KeyedSubtree(
            key: ValueKey('lift_room_$roomId'),
            child: _roomCard(room, visualOnly: true),
          ),
        ),
      );
    }
    setState(() {
      _draggingRoomId = roomId;
      _roomPreviewFrom = index;
      _roomPreviewTo = index;
    });
  }

  void _updateRoomPreviewFromGlobal(Offset global) {
    if (_flying || _dropCommitted) return;
    _followDragOverlay(global, height: _draggedRoomHeight);
    final ids = [for (final room in _rooms) room.id];
    homeDragReadSlotGeometry(
      [for (final id in ids) _keyForRoom(id)],
      _roomHeights,
      _roomCenters,
    );
    final from = _roomPreviewFrom;
    if (from == null || _roomCenters.isEmpty) return;
    final dest = homeDragIndexFromCenters(
      y: global.dy,
      centers: _roomCenters,
      from: from,
    );
    if (_roomPreviewTo == dest) return;
    setState(() => _roomPreviewTo = dest);
  }

  Future<void> _flyRoomThen({
    required double destDy,
    required GlobalKey originKey,
    required Widget card,
    required VoidCallback applyOverride,
    required Future<void> Function() persist,
  }) async {
    final (originTopLeft, originSize) = homeDragOriginSlot(originKey);
    final destTop = originTopLeft.dy + destDy;
    final destination = Offset(originTopLeft.dx, destTop);
    setState(() => _flying = true);
    if (kHomeDragOwnedOverlay && _dragOverlay.isShowing) {
      await _dragOverlay.flyTo(destination);
    } else {
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay != null && originSize != Size.zero) {
        _showDragOverlay(originKey: originKey, card: card);
        await _dragOverlay.flyTo(destination);
      }
    }
    if (!mounted) {
      _removeDragVisuals();
      _flying = false;
      return;
    }
    if (kHomeDragSnapOnCommit) {
      _snapShift = true;
      applyOverride();
      _clearRoomDragPreview();
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      await persist();
      if (!mounted) return;
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      return;
    }
    applyOverride();
    _clearRoomDragPreview();
    setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    await persist();
    if (!mounted) return;
    setState(() {});
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _commitRoomDrag([Offset? global]) async {
    if (_dropCommitted) return;
    if (global != null) _updateRoomPreviewFromGlobal(global);
    _dropCommitted = true;
    final from = _roomPreviewFrom;
    final to = _roomPreviewTo;
    final roomId = _draggingRoomId;
    if (roomId != null && homeDragShouldFly(from: from, to: to)) {
      final destDy = homeDragSlotDestDy(
        from: from!,
        to: to!,
        heights: _roomHeights,
      );
      final ids = [for (final room in _rooms) room.id];
      final changed = from != to;
      final next = changed ? moveIdToIndex(ids, ids[from], to) : ids;
      final flyingId = ids[from];
      final room = _roomById(flyingId);
      final flySlot = homeDragOriginSlot(_keyForRoom(flyingId));
      final flyHeight = homeDragCardBodyHeight(flySlot.$2.height);
      await _flyRoomThen(
        destDy: destDy,
        originKey: _keyForRoom(flyingId),
        card: homeDragFeedbackClone(
          context,
          width: flySlot.$2.width,
          height: flyHeight,
          child: KeyedSubtree(
            key: ValueKey('fly_room_$flyingId'),
            child: room == null
                ? const SizedBox.shrink()
                : _roomCard(room, visualOnly: true),
          ),
        ),
        applyOverride: () {
          if (!changed) return;
          setState(() {
            _rooms = orderByIds(_rooms, ids: next, idOf: (room) => room.id);
          });
        },
        persist: () => changed
            ? GroupChatStore.instance.reorderRooms(next)
            : Future.value(),
      );
      return;
    }
    if (!mounted) return;
    await _dragOverlay.land();
    setState(_clearRoomDragPreview);
  }

  Widget _roomCard(GroupRoom room, {bool visualOnly = false}) {
    return GroupRoomTile(
      room: room,
      openSwipeKey: visualOnly ? null : widget.openSwipeKey,
      onOpenRectChanged: visualOnly ? null : widget.onOpenRectChanged,
      disableSwipe: visualOnly || _draggingRoomId == room.id,
      visualOnly: visualOnly,
      onTap: () => _open(room),
      onEdit: () => _edit(room),
      onDelete: () => _delete(room),
      onChangeProject: () => _changeProject(room),
    );
  }

  Widget _shiftedRoomSlot({
    Key? key,
    required double dy,
    required Widget child,
  }) {
    return HomeDragShift(
      key: key,
      dy: dy,
      snap: _snapShift,
      duration: kHomeDragSqueezeDuration,
      child: child,
    );
  }

  Widget _dragRoomCard({required GroupRoom room, required int indexInGroup}) {
    return HomeLongPressDrag(
      key: ValueKey('drag_room_${room.id}'),
      enabled: _draggingRoomId == null || _draggingRoomId == room.id,
      onDragStart: (details) =>
          _onRoomDragStarted(room.id, indexInGroup, details.globalPosition),
      onDragUpdate: (details) =>
          _updateRoomPreviewFromGlobal(details.globalPosition),
      onDragEnd: (details) => _commitRoomDrag(details.globalPosition),
      onDragCancel: _commitRoomDrag,
      onDragSettled: _removeDragVisuals,
      child: Opacity(
        opacity: _draggingRoomId == room.id ? 0 : 1,
        child: _roomCard(room),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SwipeActions(
              key: const ValueKey('group_chat_header_card'),
              openNotifier: widget.openSwipeKey,
              onOpenRectChanged: widget.onOpenRectChanged,
              swipeKey: 'group-header',
              actionWidth: 88,
              actions: [
                CircularSwipeAction(
                  icon: CupertinoIcons.plus,
                  label: '新建群聊',
                  backgroundColor: kHomeGroupAccent,
                  foregroundColor: Colors.white,
                  onTap: () {
                    widget.openSwipeKey?.value = null;
                    _create();
                  },
                ),
              ],
              child: HomeGroupHeader(
                name: '群聊',
                count: _rooms.length,
                expanded: _expanded,
                leading: const BaguaIcon(size: 18, color: kHomeGroupAccent),
                countText: '${_rooms.length} 个群聊',
                onTap: () => setState(() => _expanded = !_expanded),
              ),
            ),
          ),
          if (_rooms.isEmpty && _expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                '还没有群聊。左滑分组头新建，也可以贴思维导图自动生成 Agent。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF8E8E93),
                ),
              ),
            ),
          if (_rooms.isNotEmpty)
            StaggeredSessions(
              expanded: _expanded,
              unclipped: _draggingRoomId != null,
              children: [
                for (var i = 0; i < _rooms.length; i++)
                  _shiftedRoomSlot(
                    key: _keyForRoom(_rooms[i].id),
                    dy: _roomPreviewFrom == null || _roomPreviewTo == null
                        ? 0
                        : homeDragTranslateY(
                            index: i,
                            from: _roomPreviewFrom!,
                            to: _roomPreviewTo!,
                            heights: _roomHeights,
                          ),
                    child: _dragRoomCard(room: _rooms[i], indexInGroup: i),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
