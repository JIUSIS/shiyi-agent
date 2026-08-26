import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/home_list_order.dart';
import 'package:shiyi_agent_app/core/models.dart';

List<String> _applyInserts(List<String> current, List<DshInsertStep> ops) {
  final live = List<String>.from(current);
  for (final op in ops) {
    live.remove(op.sessionId);
    if (op.beforeSessionId == null) {
      live.add(op.sessionId);
    } else {
      final i = live.indexOf(op.beforeSessionId!);
      live.insert(i < 0 ? live.length : i, op.sessionId);
    }
  }
  return live;
}

void main() {
  group('项目 / 会话 id 重排', () {
    test('把首位拖到目标下标 2，最终落在末位', () {
      expect(moveIdToIndex(['a', 'b', 'c'], 'a', 2), ['b', 'c', 'a']);
    });

    test('把末位拖到目标下标 0，最终落在首位', () {
      expect(moveIdToIndex(['a', 'b', 'c'], 'c', 0), ['c', 'a', 'b']);
    });

    test('同一位置不改顺序', () {
      expect(moveIdToIndex(['a', 'b', 'c'], 'b', 1), ['a', 'b', 'c']);
    });

    test('未知 id 原样返回', () {
      expect(moveIdToIndex(['a', 'b'], 'gone', 0), ['a', 'b']);
    });

    test('目标下标超出范围时夹到末尾', () {
      expect(moveIdToIndex(['a', 'b', 'c'], 'a', 99), ['b', 'c', 'a']);
    });
  });

  group('拖拽挤开占位', () {
    test('拖到后一项上半：插到该项前面', () {
      expect(homeDragInsertIndex(from: 0, over: 1, overTopHalf: true), 1);
    });

    test('拖到后一项下半：插到该项后面', () {
      expect(homeDragInsertIndex(from: 0, over: 1, overTopHalf: false), 2);
    });

    test('拖到前一项下半：插到该项后面', () {
      expect(homeDragInsertIndex(from: 2, over: 0, overTopHalf: false), 1);
    });

    test('拖到自己：位置不变', () {
      expect(homeDragInsertIndex(from: 1, over: 1, overTopHalf: true), 1);
      expect(homeDragInsertIndex(from: 1, over: 1, overTopHalf: false), 1);
    });

    test('同列表落点换成去掉拖动项之后的下标', () {
      expect(
        homeDragDestinationIndex(
          from: 0,
          over: 1,
          overTopHalf: false,
          length: 3,
        ),
        1,
      );
      expect(
        homeDragDestinationIndex(
          from: 0,
          over: 2,
          overTopHalf: false,
          length: 3,
        ),
        2,
      );
      expect(
        homeDragDestinationIndex(
          from: 2,
          over: 0,
          overTopHalf: true,
          length: 3,
        ),
        0,
      );
    });

    test('悬停挤开后列表立刻换位，原位腾空', () {
      expect(previewReorder(['a', 'b', 'c'], from: 0, to: 2), ['b', 'c', 'a']);
      expect(previewReorder(['a', 'b', 'c'], from: 2, to: 0), ['c', 'a', 'b']);
    });

    test('原列表渲染时空隙插在正确下标之前', () {
      // [A B C] 把 A 拖到末位 → 空隙在末尾
      expect(homeDragGapBeforeIndex(from: 0, to: 2, length: 3), 3);
      // [A B C] 把 C 拖到首位 → 空隙在开头
      expect(homeDragGapBeforeIndex(from: 2, to: 0, length: 3), 0);
      // [A B C] 把 A 拖到 B 后面 → 空隙在 C 之前
      expect(homeDragGapBeforeIndex(from: 0, to: 1, length: 3), 2);
      // 仍停在自己位置 → 空隙就在原位
      expect(homeDragGapBeforeIndex(from: 1, to: 1, length: 3), 1);
    });

    test('拖到顶部第一条：原第一项必须下移让位', () {
      // [A B C] 把 C 拖到首位：A、B 各下移一格，空隙（C）移到顶部
      expect(homeDragSlotShift(index: 0, from: 2, to: 0), 1);
      expect(homeDragSlotShift(index: 1, from: 2, to: 0), 1);
      expect(homeDragSlotShift(index: 2, from: 2, to: 0), -2);
    });

    test('等高卡片按像素平移：第一项下移一格，被拖项留在原槽避免手势被裁剪', () {
      const heights = [10.0, 10.0, 10.0];
      expect(
        homeDragTranslateY(index: 0, from: 2, to: 0, heights: heights),
        10,
      );
      expect(
        homeDragTranslateY(index: 1, from: 2, to: 0, heights: heights),
        10,
      );
      expect(homeDragTranslateY(index: 2, from: 2, to: 0, heights: heights), 0);
    });

    test('不等高时第一项按下移被拖项的高度，而不是下一项', () {
      const heights = [10.0, 20.0, 30.0];
      expect(
        homeDragTranslateY(index: 0, from: 2, to: 0, heights: heights),
        30,
      );
      expect(
        homeDragTranslateY(index: 1, from: 2, to: 0, heights: heights),
        30,
      );
      expect(homeDragTranslateY(index: 2, from: 2, to: 0, heights: heights), 0);
    });

    test('被拖项飞向落点的终点是空隙中心，不是原槽', () {
      const heights = [10.0, 10.0, 10.0];
      expect(homeDragSlotDestDy(from: 2, to: 0, heights: heights), -20);
      expect(homeDragSlotDestDy(from: 0, to: 2, heights: heights), 20);
    });

    test('松手飞行起点是手指相对原槽中心的偏移', () {
      expect(homeDragFlyStartDy(fingerY: 80, originCenterY: 100), -20);
    });

    test('指针在第一项中心以上时落点是 0', () {
      expect(
        homeDragIndexFromCenters(y: 5, centers: const [20, 60, 100], from: 2),
        0,
      );
    });

    test('指针在第一项中心以下、第二项中心以上时落在 1', () {
      expect(
        homeDragIndexFromCenters(y: 40, centers: const [20, 60, 100], from: 2),
        1,
      );
    });

    test('列表滚动后要用新的中心算插入下标', () {
      expect(
        homeDragInsertIndexFromCenters(
          y: 370,
          centers: const [200, 280, 360, 440],
        ),
        3,
      );
      expect(
        homeDragInsertIndexFromCenters(
          y: 370,
          centers: const [40, 120, 200, 280],
        ),
        4,
      );
      expect(
        homeDragIndexFromCenters(
          y: 370,
          centers: const [40, 120, 200, 280, 360],
          from: 0,
        ),
        4,
      );
    });

    test('跨组插入下标可落到任意空隙，含末尾', () {
      expect(
        homeDragInsertIndexFromCenters(y: 5, centers: const [20, 60, 100]),
        0,
      );
      expect(
        homeDragInsertIndexFromCenters(y: 40, centers: const [20, 60, 100]),
        1,
      );
      expect(
        homeDragInsertIndexFromCenters(y: 80, centers: const [20, 60, 100]),
        2,
      );
      expect(
        homeDragInsertIndexFromCenters(y: 140, centers: const [20, 60, 100]),
        3,
      );
      expect(homeDragInsertIndexFromCenters(y: 10, centers: const []), 0);
    });

    test('写入后目标列表不再套跨组让位，避免按高度弹一下', () {
      expect(
        homeDragAppliesForeignShift(
          dropReadyHere: true,
          originGroup: false,
          draggedAlreadyHere: false,
        ),
        isTrue,
      );
      expect(
        homeDragAppliesForeignShift(
          dropReadyHere: true,
          originGroup: false,
          draggedAlreadyHere: true,
        ),
        isFalse,
      );
      expect(
        homeDragAppliesForeignShift(
          dropReadyHere: true,
          originGroup: true,
          draggedAlreadyHere: false,
        ),
        isFalse,
      );
    });

    test('跨组目标列表按插入下标让位', () {
      expect(
        homeDragForeignTranslateY(index: 0, insertAt: 0, draggedHeight: 76),
        76,
      );
      expect(
        homeDragForeignTranslateY(index: 1, insertAt: 2, draggedHeight: 76),
        0,
      );
      expect(
        homeDragForeignTranslateY(index: 2, insertAt: 2, draggedHeight: 76),
        76,
      );
      expect(
        homeDragForeignTranslateY(index: 0, insertAt: 3, draggedHeight: 76),
        0,
      );
    });

    test('跨组飞入优先目标槽让出的空隙', () {
      expect(
        homeDragCrossInsertLanding(
          headerTopLeft: const Offset(12, 40),
          headerSize: const Size(320, 56),
          gapTopLeft: const Offset(12, 200),
          destSlotTopLeft: const Offset(12, 180),
        ),
        const Offset(12, 180),
      );
      expect(
        homeDragCrossInsertLanding(
          headerTopLeft: const Offset(12, 40),
          headerSize: const Size(320, 56),
          gapTopLeft: const Offset(12, 200),
          destSlotTopLeft: const Offset(12, 180),
          destSlotShiftY: 76,
        ),
        const Offset(12, 104),
      );
      expect(
        homeDragCrossInsertLanding(
          headerTopLeft: const Offset(12, 40),
          headerSize: const Size(320, 56),
          gapTopLeft: const Offset(12, 200),
        ),
        const Offset(12, 200),
      );
    });

    test('松手始终用预览下标提交，不依赖是否停在卡片上', () {
      expect(kHomeDragCommitOnEnd, isTrue);
    });

    test('远放到列表外松手：仍从手指位置飞回空隙，不能瞬移', () {
      // 手指在空隙中心以外（例如拖到很远），起点必须是手指偏移，不是 0。
      expect(homeDragFlyStartDy(fingerY: 800, originCenterY: 100), 700);
      expect(kHomeDragFlyOnCancel, isTrue);
      expect(homeDragShouldFly(from: 1, to: 1), isTrue);
      expect(homeDragShouldFly(from: 2, to: 0), isTrue);
    });

    test('提交贴齐时旧位移立刻归零，禁止反向弹回', () {
      expect(homeDragCommitSnapDy(oldDy: 40, snap: true), 0);
      expect(homeDragCommitSnapDy(oldDy: 40, snap: false), 40);
    });

    test('反馈层必须是独立卡片树，不能和列表共用同一份 State', () {
      expect(kHomeDragFeedbackIsClone, isTrue);
    });

    test('会话拖影高度扣掉列表底部间距，避免首帧被槽位撑高', () {
      expect(homeDragCardBodyHeight(76), 68);
      expect(homeDragCardBodyHeight(8), 8);
      expect(homeDragCardBodyHeight(4), 4);
    });

    test('挤开动画至少 300ms，避免空隙从 0 弹出', () {
      expect(
        kHomeDragSqueezeDuration >= const Duration(milliseconds: 300),
        isTrue,
      );
    });

    test('提交后位移立刻贴齐，禁止反向弹回造成炸一下', () {
      expect(kHomeDragSnapOnCommit, isTrue);
    });

    test('会话卡片拖动时不能被展开动画裁剪命中区域', () {
      expect(kHomeDragSessionHitTestUnclipped, isTrue);
    });

    test('左滑不能进手势竞技场，否则会抢走会话长按拖拽', () {
      expect(kHomeDragSwipeAvoidsArena, isTrue);
    });

    test('拖影宽度不能落到 0', () {
      expect(homeDragFeedbackWidthUsesFallbackWhenZero(0), isTrue);
      expect(homeDragFeedbackWidthUsesFallbackWhenZero(320), isFalse);
    });

    test('拖影全程自建 overlay，松手不卸层再插', () {
      expect(kHomeDragOwnedOverlay, isTrue);
    });

    test('松手飞入空隙的时长与挤开动画同量级', () {
      expect(kHomeDragFlyDuration >= const Duration(milliseconds: 220), isTrue);
    });

    test('跨项目释放必须停顿满一秒进入可释放，远放不能直接移入', () {
      expect(kHomeDragCrossProjectNeedsDropReady, isTrue);
    });

    test('跨项目松手必须飞入目标槽，不能原地缩小后瞬移', () {
      expect(kHomeDragCrossProjectFliesToSlot, isTrue);
    });

    test('展开项目收起后挤开高度改用项目头高度', () {
      expect(homeDragCollapsedProjectSlotHeight(56), 64);
      final heights = [200.0, 80.0, 80.0];
      final centers = [100.0, 240.0, 320.0];
      homeDragCollapseSlot(
        heights: heights,
        centers: centers,
        index: 0,
        collapsedHeight: homeDragCollapsedProjectSlotHeight(56),
      );
      expect(heights, [64.0, 80.0, 80.0]);
      expect(centers[0], 32);
      expect(centers[1], 104);
      expect(centers[2], 184);
      expect(
        homeDragTranslateY(index: 1, from: 0, to: 1, heights: heights),
        -64,
      );
    });

    test('跨项目可释放时目标列表顶部让出被拖项高度', () {
      expect(
        homeDragInsertGapHeight(
          dropReadyId: 'p2',
          groupId: 'p2',
          sessionAlreadyInTarget: false,
          draggedHeight: 76,
        ),
        76,
      );
      expect(
        homeDragInsertGapHeight(
          dropReadyId: 'p2',
          groupId: 'p1',
          sessionAlreadyInTarget: false,
          draggedHeight: 76,
        ),
        0,
      );
      expect(
        homeDragInsertGapHeight(
          dropReadyId: 'p2',
          groupId: 'p2',
          sessionAlreadyInTarget: true,
          draggedHeight: 76,
        ),
        0,
      );
    });

    test('跨项目落点优先空隙顶部，否则项目头下方', () {
      expect(
        homeDragCrossProjectLanding(
          headerTopLeft: const Offset(12, 40),
          headerSize: const Size(320, 56),
          gapTopLeft: const Offset(12, 104),
        ),
        const Offset(12, 104),
      );
      expect(
        homeDragCrossProjectLanding(
          headerTopLeft: const Offset(12, 40),
          headerSize: const Size(320, 56),
        ),
        const Offset(12, 104),
      );
    });
  });

  group('会话跨项目移动', () {
    test('同项目内重排', () {
      final next = moveSessionOrder(
        {
          'p1': ['s1', 's2', 's3'],
          'p2': ['s4'],
        },
        sessionId: 's1',
        fromProjectId: 'p1',
        toProjectId: 'p1',
        toIndex: 2,
      );
      expect(next['p1'], ['s2', 's3', 's1']);
      expect(next['p2'], ['s4']);
    });

    test('拖到另一项目指定位置', () {
      final next = moveSessionOrder(
        {
          'p1': ['s1', 's2'],
          'p2': ['s3', 's4'],
        },
        sessionId: 's1',
        fromProjectId: 'p1',
        toProjectId: 'p2',
        toIndex: 1,
      );
      expect(next['p1'], ['s2']);
      expect(next['p2'], ['s3', 's1', 's4']);
    });

    test('拖到另一项目卡片上（插到该项目开头）', () {
      final next = moveSessionOrder(
        {
          'p1': ['s1'],
          'p2': ['s2', 's3'],
        },
        sessionId: 's1',
        fromProjectId: 'p1',
        toProjectId: 'p2',
        toIndex: 0,
      );
      expect(next['p1'], isEmpty);
      expect(next['p2'], ['s1', 's2', 's3']);
    });

    test('拖到未分类', () {
      final next = moveSessionOrder(
        {
          'p1': ['s1'],
          '': ['s2'],
        },
        sessionId: 's1',
        fromProjectId: 'p1',
        toProjectId: '',
        toIndex: 1,
      );
      expect(next['p1'], isEmpty);
      expect(next[''], ['s2', 's1']);
    });
  });

  group('DSH insertSessionBefore 重排计划', () {
    test('同一顺序不发出任何插入', () {
      expect(
        dshReorderPlanForInsertion(
          current: const ['a', 'b', 'c'],
          desired: const ['a', 'b', 'c'],
        ),
        isEmpty,
      );
    });

    test('把首位挪到末尾：一次插到末尾', () {
      expect(
        dshReorderPlanForInsertion(
          current: const ['a', 'b', 'c'],
          desired: const ['b', 'c', 'a'],
        ),
        [const DshInsertStep('a', null)],
      );
    });

    test('把末位挪到首位：一次插到原首位前面', () {
      expect(
        dshReorderPlanForInsertion(
          current: const ['a', 'b', 'c'],
          desired: const ['c', 'a', 'b'],
        ),
        [const DshInsertStep('c', 'a')],
      );
    });

    test('多步重排后向前推导，尾部不会被前项带偏', () {
      // [A B C D] → [D B C A]：先把 A 插到末尾，再把 D 插到 B 前面。
      final ops = dshReorderPlanForInsertion(
        current: const ['a', 'b', 'c', 'd'],
        desired: const ['d', 'b', 'c', 'a'],
      );
      expect(ops, [
        const DshInsertStep('a', null),
        const DshInsertStep('d', 'b'),
      ]);
      expect(_applyInserts(const ['a', 'b', 'c', 'd'], ops), [
        'd',
        'b',
        'c',
        'a',
      ]);
    });

    test('新会话插入到指定位置', () {
      expect(
        dshReorderPlanForInsertion(
          current: const ['a', 'c'],
          desired: const ['a', 'b', 'c'],
        ),
        [const DshInsertStep('b', 'c')],
      );
    });

    test('新会话插到末尾：before 为 null', () {
      expect(
        dshReorderPlanForInsertion(
          current: const ['a', 'b'],
          desired: const ['a', 'b', 'c'],
        ),
        [const DshInsertStep('c', null)],
      );
    });

    test('空目标不发出插入', () {
      expect(
        dshReorderPlanForInsertion(current: const ['a'], desired: const []),
        isEmpty,
      );
    });

    test('cwd 兜底项不能进入 insert 计划', () {
      final desired = dshAccountedReorderDesired(
        visible: const ['x', 'b', 'a'],
        accounted: const ['a', 'b'],
      );
      expect(desired, ['b', 'a']);
      expect(
        dshReorderPlanForInsertion(current: const ['a', 'b'], desired: desired),
        [const DshInsertStep('a', null)],
      );
    });

    test('未入账会话不会被当成新插入', () {
      expect(
        dshAccountedReorderDesired(
          visible: const ['x', 'y'],
          accounted: const ['a', 'b'],
        ),
        ['a', 'b'],
      );
      expect(
        dshReorderPlanForInsertion(
          current: const ['a', 'b'],
          desired: dshAccountedReorderDesired(
            visible: const ['x', 'y'],
            accounted: const ['a', 'b'],
          ),
        ),
        isEmpty,
      );
    });

    test('按 sessionIds 重排会话，未知 id 接到末尾', () {
      expect(
        orderByIds(
          const ['s2', 's3', 's1', 's4'],
          ids: const ['s1', 's3'],
          idOf: (s) => s,
        ),
        ['s1', 's3', 's2', 's4'],
      );
    });
  });

  group('会话拖到项目卡片上停顿一秒', () {
    test('停顿时长是 1 秒', () {
      expect(kHomeDragHoverDelay, const Duration(seconds: 1));
    });

    test('长按拖起整张卡片，不用半透明标题影子', () {
      expect(kHomeDragLiftWholeCard, isTrue);
    });

    test('未展开项目：停顿未满一秒不自动展开', () {
      final hover = HomeDragHoverController();
      final t0 = DateTime(2026, 8, 25, 12);
      hover.onEnter('p1', t0);
      final tick = hover.tick(
        t0.add(const Duration(milliseconds: 999)),
        expanded: false,
      );
      expect(tick.autoExpand, isFalse);
      expect(tick.dropReady, isFalse);
    });

    test('未展开项目：停顿满一秒自动展开，此时还不是可释放', () {
      final hover = HomeDragHoverController();
      final t0 = DateTime(2026, 8, 25, 12);
      hover.onEnter('p1', t0);
      final tick = hover.tick(
        t0.add(const Duration(seconds: 1)),
        expanded: false,
      );
      expect(tick.autoExpand, isTrue);
      expect(tick.dropReady, isFalse);
    });

    test('已展开项目：停顿满一秒显示可释放反馈', () {
      final hover = HomeDragHoverController();
      final t0 = DateTime(2026, 8, 25, 12);
      hover.onEnter('p1', t0);
      expect(hover.tick(t0, expanded: true).dropReady, isFalse);
      expect(
        hover
            .tick(t0.add(const Duration(milliseconds: 999)), expanded: true)
            .dropReady,
        isFalse,
      );
      expect(
        hover
            .tick(t0.add(const Duration(seconds: 1)), expanded: true)
            .dropReady,
        isTrue,
      );
      expect(
        hover
            .tick(t0.add(const Duration(seconds: 1)), expanded: true)
            .autoExpand,
        isFalse,
      );
    });

    test('拖到其他项目时源列表空占位收起，拖回原项目再打开', () {
      expect(homeDragSourceSlotFactor(originId: 'p1', hoverId: 'p2'), 0);
      expect(homeDragSourceSlotFactor(originId: 'p1', hoverId: 'p1'), 1);
      expect(homeDragSourceSlotFactor(originId: 'p1', hoverId: null), 1);
      expect(
        homeDragSourceSlotFactor(
          originId: 'p1',
          hoverId: 'p2',
          cardGroupId: 'p2',
        ),
        1,
      );
      expect(
        homeDragSourceSlotSnaps(originId: 'p1', cardGroupId: 'p2'),
        isTrue,
      );
      expect(
        homeDragSourceSlotSnaps(originId: 'p1', cardGroupId: 'p1'),
        isFalse,
      );
      expect(
        homeDragSourceSlotKeepCollapsed(
          committing: true,
          originId: 'p1',
          cardGroupId: 'p1',
        ),
        isTrue,
      );
      expect(
        homeDragSourceSlotFactor(
          originId: 'p1',
          hoverId: null,
          cardGroupId: 'p1',
          keepCollapsed: true,
        ),
        0,
      );
      expect(
        homeDragSourceSlotKeepCollapsed(
          committing: true,
          originId: 'p1',
          cardGroupId: 'p2',
        ),
        isFalse,
      );
      expect(
        homeDragCardSlotFactor(
          isDragged: false,
          keepCollapsed: true,
          originId: 'p1',
          hoverId: null,
          cardGroupId: 'p1',
        ),
        1,
      );
      expect(
        homeDragCardSlotFactor(
          isDragged: true,
          keepCollapsed: true,
          originId: 'p1',
          hoverId: null,
          cardGroupId: 'p1',
        ),
        0,
      );
      expect(
        homeDragCardSlotFactor(
          isDragged: false,
          keepCollapsed: false,
          originId: 'p1',
          hoverId: null,
          cardGroupId: 'p1',
        ),
        1,
      );
    });

    test('只有悬停在其他项目才算跨项目移入', () {
      expect(
        homeDragIsCrossProjectHover(currentId: 'p1', hoverId: 'p2'),
        isTrue,
      );
      expect(
        homeDragIsCrossProjectHover(currentId: 'p1', hoverId: 'p1'),
        isFalse,
      );
      expect(
        homeDragIsCrossProjectHover(currentId: 'p1', hoverId: null),
        isFalse,
      );
      expect(homeDragIsCrossProjectHover(currentId: '', hoverId: 'p2'), isTrue);
      expect(homeDragIsCrossProjectHover(currentId: '', hoverId: ''), isFalse);
    });

    test('拖回原项目后必须清掉可释放，不能沿用上一个目标', () {
      final hover = HomeDragHoverController();
      final t0 = DateTime(2026, 8, 26, 12);
      hover.onEnter('p2', t0);
      expect(
        hover.tick(t0.add(kHomeDragHoverDelay), expanded: true).dropReady,
        isTrue,
      );
      expect(
        homeDragIsCrossProjectHover(currentId: 'p1', hoverId: 'p2'),
        isTrue,
      );
      expect(
        homeDragIsCrossProjectHover(currentId: 'p1', hoverId: 'p1'),
        isFalse,
      );
      hover.onLeave();
      expect(
        hover
            .tick(t0.add(const Duration(seconds: 3)), expanded: true)
            .dropReady,
        isFalse,
      );
    });

    test('离开项目卡片后取消展开和可释放', () {
      final hover = HomeDragHoverController();
      final t0 = DateTime(2026, 8, 25, 12);
      hover.onEnter('p1', t0);
      hover.onLeave();
      final tick = hover.tick(
        t0.add(const Duration(seconds: 2)),
        expanded: false,
      );
      expect(tick.autoExpand, isFalse);
      expect(tick.dropReady, isFalse);
    });

    test('换到另一个项目会重置停顿计时', () {
      final hover = HomeDragHoverController();
      final t0 = DateTime(2026, 8, 25, 12);
      hover.onEnter('p1', t0);
      hover.onEnter('p2', t0.add(const Duration(milliseconds: 800)));
      expect(
        hover
            .tick(t0.add(const Duration(seconds: 1)), expanded: false)
            .autoExpand,
        isFalse,
      );
      expect(
        hover
            .tick(t0.add(const Duration(milliseconds: 1800)), expanded: false)
            .autoExpand,
        isTrue,
      );
    });

    test('未展开项目自动展开后继续停顿一秒才可释放', () {
      final hover = HomeDragHoverController();
      final t0 = DateTime(2026, 8, 25, 12);
      hover.onEnter('p1', t0);
      expect(
        hover.tick(t0.add(kHomeDragHoverDelay), expanded: false).autoExpand,
        isTrue,
      );
      hover.onExpanded('p1', t0.add(kHomeDragHoverDelay));
      expect(
        hover.tick(t0.add(kHomeDragHoverDelay), expanded: true).dropReady,
        isFalse,
      );
      expect(
        hover
            .tick(t0.add(const Duration(seconds: 2)), expanded: true)
            .dropReady,
        isTrue,
      );
    });
  });

  group('sort_order 序列化', () {
    test('Session 读写 sortOrder', () {
      final s = Session(
        id: 's1',
        title: 't',
        model: 'm',
        createdAt: 1,
        updatedAt: 2,
        sortOrder: 7,
      );
      expect(s.toMap()['sort_order'], 7);
      expect(Session.fromMap(s.toMap()).sortOrder, 7);
    });

    test('Session 缺列时 sortOrder 为 0', () {
      expect(
        Session.fromMap({
          'id': 's1',
          'title': 't',
          'model': 'm',
          'created_at': 1,
          'updated_at': 2,
        }).sortOrder,
        0,
      );
    });

    test('Project 读写 sortOrder', () {
      final p = Project(id: 'p1', name: 'n', createdAt: 1, sortOrder: 3);
      expect(p.toMap()['sort_order'], 3);
      expect(Project.fromMap(p.toMap()).sortOrder, 3);
    });

    test('Project 缺列时 sortOrder 为 0', () {
      expect(
        Project.fromMap({'id': 'p1', 'name': 'n', 'created_at': 1}).sortOrder,
        0,
      );
    });
  });
}
