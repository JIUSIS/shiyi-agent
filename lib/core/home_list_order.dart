/// 拾忆主页项目 / 会话长按拖拽排序与跨项目移动。
library;

import 'dart:ui' show Offset, Size;

const Duration kHomeDragHoverDelay = Duration(seconds: 1);

/// 长按拖起整张卡片（头像/标题/背景），不用半透明标题影子。
const bool kHomeDragLiftWholeCard = true;

const Duration kHomeDragSqueezeDuration = Duration(milliseconds: 320);

/// 展开项目长按后的快速收起时长。
const Duration kHomeDragFastCollapseDuration = Duration(milliseconds: 170);

/// 松手飞入空隙的时长。
const Duration kHomeDragFlyDuration = Duration(milliseconds: 320);

/// 拖起 / 归位的缩放反馈时长，与飞行动画尾段对齐。
const Duration kHomeDragScaleDuration = Duration(milliseconds: 180);

/// 会话列表项底部间距。槽位高度含这段空隙，拖影必须只按卡片本体约束。
const double kHomeDragSessionGap = 8;

/// 从列表槽位高度得到会话卡片本体高度。
/// 拖影若按槽位高度紧约束，首帧会把卡片撑高一段，看起来像掉帧。
double homeDragCardBodyHeight(double slotHeight) {
  if (slotHeight > kHomeDragSessionGap) {
    return slotHeight - kHomeDragSessionGap;
  }
  return slotHeight;
}

/// 松手时用预览下标提交，不依赖手指是否停在某张卡片上。
const bool kHomeDragCommitOnEnd = true;

/// 远放 / 取消拖拽也要飞入空隙，不能卸 overlay 后瞬移。
const bool kHomeDragFlyOnCancel = true;

/// 拖拽反馈层必须是独立卡片树，不能和列表项共用同一份 State。
const bool kHomeDragFeedbackIsClone = true;

/// 提交后位移立刻贴齐，禁止旧位移套在新顺序上反向弹回。
const bool kHomeDragSnapOnCommit = true;

/// 会话拖动时去掉展开动画的裁剪，避免命中区域被 SizeTransition 吃掉后卡住。
const bool kHomeDragSessionHitTestUnclipped = true;

/// 左滑不能进手势竞技场，否则会和 LongPressDraggable 互抢、会话拖起来就卡住。
const bool kHomeDragSwipeAvoidsArena = true;

/// 测到的宽度 ≤1 时拖影必须走屏幕宽度兜底，否则 release 下拖着空气。
bool homeDragFeedbackWidthUsesFallbackWhenZero(double width) => width <= 1;

/// 长按立刻用自建 overlay 跟手，松手就地飞入；禁止系统拖影卸掉后再插一层（会闪）。
const bool kHomeDragOwnedOverlay = true;

/// 跨项目释放必须停顿满一秒进入可释放；远放不能直接移入别的项目。
const bool kHomeDragCrossProjectNeedsDropReady = true;

/// 只有悬停在其他项目时才进入跨项目移入。
/// 拖回原项目或空白处必须清掉「松开以移入」，不能沿用上一个目标。
bool homeDragIsCrossProjectHover({
  required String? currentId,
  required String? hoverId,
}) {
  return currentId != null && hoverId != null && hoverId != currentId;
}

/// 拖到其他项目时源列表空占位收起；拖回原项目再打开。
/// 已经出现在目标列表里的卡片不能再收成 0，否则归位会从下往上弹。
bool homeDragSourceSlotSnaps({required String? originId, String? cardGroupId}) {
  return cardGroupId != null && originId != null && cardGroupId != originId;
}

bool homeDragSourceSlotKeepCollapsed({
  required bool committing,
  required String? originId,
  String? cardGroupId,
}) {
  if (!committing) return false;
  return originId != null && cardGroupId != null && originId == cardGroupId;
}

double homeDragSourceSlotFactor({
  required String? originId,
  required String? hoverId,
  String? cardGroupId,
  bool keepCollapsed = false,
}) {
  if (homeDragSourceSlotSnaps(originId: originId, cardGroupId: cardGroupId)) {
    return 1.0;
  }
  if (keepCollapsed) return 0.0;
  return homeDragIsCrossProjectHover(currentId: originId, hoverId: hoverId)
      ? 0.0
      : 1.0;
}

/// 只有被拖的那张走源槽高度。提交中 keepCollapsed 不能套到同组其它卡片，
/// 否则 BCD 会整组收成 0，清拖拽态再长回来。源名单里的被拖项靠乐观移除。
double homeDragCardSlotFactor({
  required bool isDragged,
  required bool keepCollapsed,
  required String? originId,
  required String? hoverId,
  String? cardGroupId,
}) {
  if (!isDragged) return 1.0;
  return homeDragSourceSlotFactor(
    originId: originId,
    hoverId: hoverId,
    cardGroupId: cardGroupId,
    keepCollapsed: keepCollapsed,
  );
}

/// 跨项目松手必须从手指飞入目标槽，不能在原地缩小后瞬移。
const bool kHomeDragCrossProjectFliesToSlot = true;

/// 展开项目长按收起后，把被拖项高度改成项目头高度，并上移后续中心。
void homeDragCollapseSlot({
  required List<double> heights,
  required List<double> centers,
  required int index,
  required double collapsedHeight,
}) {
  if (index < 0 || index >= heights.length || index >= centers.length) return;
  final oldHeight = heights[index];
  if (collapsedHeight <= 0 || collapsedHeight >= oldHeight) return;
  final delta = oldHeight - collapsedHeight;
  heights[index] = collapsedHeight;
  centers[index] = centers[index] - delta / 2;
  for (var i = index + 1; i < centers.length; i++) {
    centers[i] -= delta;
  }
}

/// 收起后的项目槽高度：项目头 + 卡片间距，不能沿用展开块。
double homeDragCollapsedProjectSlotHeight(double headerHeight) {
  if (headerHeight <= 1) return 56 + kHomeDragSessionGap;
  return headerHeight + kHomeDragSessionGap;
}

/// 跨项目可释放时，目标列表顶部让出被拖会话的高度。
double homeDragInsertGapHeight({
  required String? dropReadyId,
  required String groupId,
  required bool sessionAlreadyInTarget,
  required double draggedHeight,
}) {
  if (dropReadyId == null || dropReadyId != groupId) return 0;
  if (sessionAlreadyInTarget) return 0;
  if (draggedHeight <= 0) return 0;
  return draggedHeight;
}

/// 跨项目落点：优先已打开的空隙顶部，否则项目头下方。
Offset homeDragCrossProjectLanding({
  required Offset headerTopLeft,
  required Size headerSize,
  Offset? gapTopLeft,
  double belowHeader = kHomeDragSessionGap,
}) {
  if (gapTopLeft != null) return gapTopLeft;
  return Offset(
    headerTopLeft.dx,
    headerTopLeft.dy + headerSize.height + belowHeader,
  );
}

/// 目标列表不含被拖项：指针相对各卡片中心，插入下标为 0..length（length 表示插到末尾）。
int homeDragInsertIndexFromCenters({
  required double y,
  required List<double> centers,
}) {
  var dest = 0;
  for (final c in centers) {
    if (y > c) dest++;
  }
  return dest;
}

/// 跨组插入时，目标列表第 [index] 项应下移的像素。
/// 跨组让位只在目标列表还没有被拖项时生效。
/// 写入后如果还让位，新卡片会带着被拖项高度出现，下一帧清掉就会往上弹。
bool homeDragAppliesForeignShift({
  required bool dropReadyHere,
  required bool originGroup,
  required bool draggedAlreadyHere,
}) {
  return dropReadyHere && !originGroup && !draggedAlreadyHere;
}

/// 落点之前的卡片不动，[insertAt] 及之后的卡片让出被拖项高度。
double homeDragForeignTranslateY({
  required int index,
  required int insertAt,
  required double draggedHeight,
}) {
  if (draggedHeight <= 0 || insertAt < 0) return 0;
  if (index >= insertAt) return draggedHeight;
  return 0;
}

/// 跨组飞入落点：有目标槽则飞到该槽布局位置（槽位 key 在 Transform 外，默认不再扣位移）。
Offset homeDragCrossInsertLanding({
  required Offset headerTopLeft,
  required Size headerSize,
  Offset? gapTopLeft,
  Offset? destSlotTopLeft,
  double destSlotShiftY = 0,
  double belowHeader = kHomeDragSessionGap,
}) {
  if (destSlotTopLeft != null) {
    return Offset(destSlotTopLeft.dx, destSlotTopLeft.dy - destSlotShiftY);
  }
  return homeDragCrossProjectLanding(
    headerTopLeft: headerTopLeft,
    headerSize: headerSize,
    gapTopLeft: gapTopLeft,
    belowHeader: belowHeader,
  );
}

/// 拖到 [over] 项的上半或下半时，相对原列表的插入下标（未去掉拖动项）。
int homeDragInsertIndex({
  required int from,
  required int over,
  required bool overTopHalf,
}) {
  if (from == over) return from;
  return overTopHalf ? over : over + 1;
}

/// 同列表最终落点：去掉拖动项之后的插入下标，可直接交给 [moveIdToIndex]。
int homeDragDestinationIndex({
  required int from,
  required int over,
  required bool overTopHalf,
  required int length,
}) {
  if (from == over) return from;
  var insert = homeDragInsertIndex(
    from: from,
    over: over,
    overTopHalf: overTopHalf,
  );
  if (from < insert) insert -= 1;
  if (insert < 0) insert = 0;
  final max = length <= 0 ? 0 : length - 1;
  if (insert > max) insert = max;
  return insert;
}

/// 拖动过程中列表立刻换位（原位腾空，目标处挤开）。
List<String> previewReorder(
  List<String> ids, {
  required int from,
  required int to,
}) {
  if (from < 0 || from >= ids.length) return List<String>.from(ids);
  return moveIdToIndex(ids, ids[from], to);
}

/// 原列表仍按旧顺序渲染时，空隙应插在哪一项之前（[length] 表示可插到末尾）。
int homeDragGapBeforeIndex({
  required int from,
  required int to,
  required int length,
}) {
  var dest = to;
  if (dest < 0) dest = 0;
  if (dest > length) dest = length;
  if (from < dest) return dest + 1;
  return dest;
}

/// 拖动项从 [from] 预览到 [to] 时，原列表第 [index] 项应平移几格。
/// 正数下移，负数上移。被拖项跟着空隙走，其它项给它让位。
int homeDragSlotShift({
  required int index,
  required int from,
  required int to,
}) {
  if (from == to) return 0;
  if (index == from) return to - from;
  if (from < to) {
    if (index > from && index <= to) return -1;
  } else {
    if (index >= to && index < from) return 1;
  }
  return 0;
}

/// 等高或不等高列表里，第 [index] 项应平移的像素（正数下移）。
/// 让位项平移被拖项高度；被拖项留在原槽（位移 0），避免手势被裁剪。
double homeDragTranslateY({
  required int index,
  required int from,
  required int to,
  required List<double> heights,
}) {
  if (from == to) return 0;
  if (from < 0 || from >= heights.length) return 0;
  if (index == from) return 0;
  final draggedH = heights[from];
  if (from < to) {
    if (index > from && index <= to) return -draggedH;
  } else {
    if (index >= to && index < from) return draggedH;
  }
  return 0;
}

/// 被拖项从原槽飞到预览落点时，相对原槽中心的终点位移。
double homeDragSlotDestDy({
  required int from,
  required int to,
  required List<double> heights,
}) {
  if (from == to) return 0;
  if (from < 0 || from >= heights.length) return 0;
  var y = 0.0;
  if (from < to) {
    for (var i = from + 1; i <= to && i < heights.length; i++) {
      y += heights[i];
    }
  } else {
    for (var i = to; i < from && i < heights.length; i++) {
      y -= heights[i];
    }
  }
  return y;
}

/// 松手瞬间：卡片应从手指位置飞向空隙，而不是从原槽瞬移。
double homeDragFlyStartDy({
  required double fingerY,
  required double originCenterY,
}) => fingerY - originCenterY;

/// 提交贴齐：旧位移立刻归零，禁止套在新顺序上反向弹回。
double homeDragCommitSnapDy({required double oldDy, required bool snap}) =>
    snap ? 0 : oldDy;

/// 松手是否飞入空隙：换位要飞；远放/取消也要飞，不能卸 overlay 后瞬移。
bool homeDragShouldFly({required int? from, required int? to}) {
  if (!kHomeDragCommitOnEnd) return false;
  if (from == null || to == null) return false;
  if (from != to) return true;
  return kHomeDragFlyOnCancel;
}

/// 用各卡片中心 Y 判断落点：指针在第一项中心以上就是 0。
/// [from] 是被拖项，计算时跳过它的中心。
int homeDragIndexFromCenters({
  required double y,
  required List<double> centers,
  required int from,
}) {
  if (centers.isEmpty) return 0;
  var dest = 0;
  for (var i = 0; i < centers.length; i++) {
    if (i == from) continue;
    if (y > centers[i]) dest++;
  }
  final max = centers.length - 1;
  if (dest < 0) return 0;
  if (dest > max) return max;
  return dest;
}

/// 把 [id] 从原位置挪到 [toIndex]（按移动后列表下标）。
List<String> moveIdToIndex(List<String> ids, String id, int toIndex) {
  final next = List<String>.from(ids);
  final from = next.indexOf(id);
  if (from < 0) return next;
  next.removeAt(from);
  var dest = toIndex;
  if (dest < 0) dest = 0;
  if (dest > next.length) dest = next.length;
  next.insert(dest, id);
  return next;
}

/// 会话在项目分组内重排，或拖到另一项目的 [toIndex]。
Map<String, List<String>> moveSessionOrder(
  Map<String, List<String>> byProject, {
  required String sessionId,
  required String fromProjectId,
  required String toProjectId,
  required int toIndex,
}) {
  final next = <String, List<String>>{
    for (final e in byProject.entries) e.key: List<String>.from(e.value),
  };
  next.putIfAbsent(fromProjectId, () => <String>[]);
  next.putIfAbsent(toProjectId, () => <String>[]);
  next[fromProjectId]!.remove(sessionId);
  final destList = next[toProjectId]!;
  var dest = toIndex;
  if (dest < 0) dest = 0;
  if (dest > destList.length) dest = destList.length;
  destList.insert(dest, sessionId);
  return next;
}

/// 按 [ids] 重排 [items]；未出现在 [ids] 里的项保持原相对顺序，接到末尾。
List<T> orderByIds<T>(
  List<T> items, {
  required List<String> ids,
  required String Function(T) idOf,
}) {
  final byId = <String, T>{};
  for (final item in items) {
    byId.putIfAbsent(idOf(item), () => item);
  }
  final seen = <String>{};
  final out = <T>[];
  for (final id in ids) {
    final item = byId[id];
    if (item == null || !seen.add(id)) continue;
    out.add(item);
  }
  for (final item in items) {
    if (seen.add(idOf(item))) out.add(item);
  }
  return out;
}

/// 把 [movedId] 插到 [next] 里后一项前面；已经在末位则 before 为 null。
String? homeDragBeforeId(List<String> next, String movedId) {
  final i = next.indexOf(movedId);
  if (i < 0 || i + 1 >= next.length) return null;
  return next[i + 1];
}

/// DSH `insertSessionBefore` 只能移动已经记在工作区 `sessionIds` 里的会话。
/// 可见列表里按 cwd 兜底进来的 id 必须先丢掉（或先 `session.create(workspaceId)` 入账），
/// 不能当移动主体或锚点，否则服务端会回 `workspace-move-invalid`。
List<String> dshAccountedReorderDesired({
  required List<String> visible,
  required List<String> accounted,
}) {
  final seen = <String>{};
  final desired = <String>[];
  final accountedSet = accounted.toSet();
  for (final id in visible) {
    if (accountedSet.contains(id) && seen.add(id)) desired.add(id);
  }
  for (final id in accounted) {
    if (seen.add(id)) desired.add(id);
  }
  return desired;
}

/// 一次 `workspace.insertSessionBefore`：把 [sessionId] 插到 [beforeSessionId] 前面。
/// [beforeSessionId] 为 null 表示插到工作区末尾。
class DshInsertStep {
  final String sessionId;
  final String? beforeSessionId;
  const DshInsertStep(this.sessionId, this.beforeSessionId);

  @override
  bool operator ==(Object other) =>
      other is DshInsertStep &&
      other.sessionId == sessionId &&
      other.beforeSessionId == beforeSessionId;

  @override
  int get hashCode => Object.hash(sessionId, beforeSessionId);

  @override
  String toString() => 'DshInsertStep($sessionId, before: $beforeSessionId)';
}

/// 把 [current] 变成 [desired] 的 `insertSessionBefore` 序列。
///
/// 以两边最长连续公共段为锚点，只移动锚点之外的项：锚点之后后向前
/// 插到末尾，锚点之前后向前插到后继前面。这样尾部移动是「插到末尾」
/// (before=null)，不会被前项挪动带偏。
/// [desired] 里多出来的 id 视为尚未入区，会发出插入；[current] 里多
/// 出来的 id 不删除，只保证 [desired] 的相对顺序。
List<DshInsertStep> dshReorderPlanForInsertion({
  required List<String> current,
  required List<String> desired,
}) {
  if (desired.isEmpty) return const [];
  final desiredSet = desired.toSet();
  final live = [
    for (final id in current)
      if (desiredSet.contains(id)) id,
  ];
  var anchorLen = 0;
  var anchorStart = 0;
  for (var di = 0; di < desired.length; di++) {
    for (var ci = 0; ci < live.length; ci++) {
      var len = 0;
      while (di + len < desired.length &&
          ci + len < live.length &&
          desired[di + len] == live[ci + len]) {
        len++;
      }
      if (len > anchorLen) {
        anchorLen = len;
        anchorStart = di;
      }
    }
  }

  final ops = <DshInsertStep>[];
  void ensure(int i) {
    final id = desired[i];
    final before = i + 1 < desired.length ? desired[i + 1] : null;
    final idx = live.indexOf(id);
    final already = before == null
        ? live.isNotEmpty && live.last == id
        : idx >= 0 && idx + 1 < live.length && live[idx + 1] == before;
    if (already) return;
    ops.add(DshInsertStep(id, before));
    if (idx >= 0) live.removeAt(idx);
    if (before == null) {
      live.add(id);
    } else {
      final bi = live.indexOf(before);
      live.insert(bi < 0 ? live.length : bi, id);
    }
  }

  for (var i = desired.length - 1; i >= anchorStart + anchorLen; i--) {
    ensure(i);
  }
  for (var i = anchorStart - 1; i >= 0; i--) {
    ensure(i);
  }
  return ops;
}

class HomeDragHoverTick {
  final bool autoExpand;
  final bool dropReady;
  const HomeDragHoverTick({this.autoExpand = false, this.dropReady = false});
}

/// 会话拖到项目卡片上停顿 1 秒：未展开则自动展开，已展开则显示可释放反馈。
class HomeDragHoverController {
  String? _projectId;
  DateTime? _enteredAt;
  DateTime? _expandedAt;

  void onEnter(String projectId, DateTime now) {
    if (_projectId == projectId) return;
    _projectId = projectId;
    _enteredAt = now;
    _expandedAt = null;
  }

  void onLeave() {
    _projectId = null;
    _enteredAt = null;
    _expandedAt = null;
  }

  void onExpanded(String projectId, DateTime now) {
    if (_projectId != projectId) return;
    _expandedAt = now;
  }

  HomeDragHoverTick tick(DateTime now, {required bool expanded}) {
    final entered = _enteredAt;
    if (_projectId == null || entered == null) {
      return const HomeDragHoverTick();
    }
    if (!expanded) {
      return HomeDragHoverTick(
        autoExpand: !now.isBefore(entered.add(kHomeDragHoverDelay)),
      );
    }
    final readyFrom = _expandedAt ?? entered;
    return HomeDragHoverTick(
      dropReady: !now.isBefore(readyFrom.add(kHomeDragHoverDelay)),
    );
  }
}
