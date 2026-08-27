import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/home_list_order.dart';
import 'package:shiyi_agent_app/widgets/home_drag.dart';
import 'package:shiyi_agent_app/widgets/staggered_sessions.dart';
import 'package:shiyi_agent_app/widgets/swipe_actions.dart';

void main() {
  test('已完全展开且静止时不播入场滑入', () {
    expect(
      staggeredSessionsPlaysEnterSlide(isAnimating: false, animationValue: 1),
      isFalse,
    );
    expect(
      staggeredSessionsPlaysEnterSlide(isAnimating: true, animationValue: 1),
      isTrue,
    );
    expect(
      staggeredSessionsPlaysEnterSlide(isAnimating: false, animationValue: 0.4),
      isTrue,
    );
  });

  test('展开过程仍要用 SizeTransition；只有完全展开且 unclipped 才去掉裁剪', () {
    expect(
      staggeredSessionsUsesSizeClip(unclipped: true, animationValue: 0.4),
      isTrue,
    );
    expect(
      staggeredSessionsUsesSizeClip(unclipped: true, animationValue: 1),
      isFalse,
    );
    expect(
      staggeredSessionsUsesSizeClip(unclipped: false, animationValue: 0.4),
      isTrue,
    );
  });

  testWidgets('已展开且 unclipped 时不裁剪命中区', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StaggeredSessions(
          expanded: true,
          unclipped: true,
          children: [SizedBox(key: Key('card'), width: 80, height: 40)],
        ),
      ),
    );
    expect(find.byKey(const Key('card')), findsOneWidget);
    final clips = tester.widgetList<ClipRect>(find.byType(ClipRect));
    expect(clips, isNotEmpty);
    expect(clips.every((c) => c.clipBehavior == Clip.none), isTrue);
  });

  testWidgets('从未展开到展开的过程中会裁剪高度，完成后再放开裁剪', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StaggeredSessions(
          expanded: false,
          unclipped: false,
          children: [SizedBox(key: Key('card'), width: 80, height: 40)],
        ),
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: StaggeredSessions(
          expanded: true,
          unclipped: true,
          children: [SizedBox(key: Key('card'), width: 80, height: 40)],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      tester
          .widgetList<ClipRect>(find.byType(ClipRect))
          .any((c) => c.clipBehavior == Clip.hardEdge),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<ClipRect>(find.byType(ClipRect))
          .every((c) => c.clipBehavior == Clip.none),
      isTrue,
    );
  });

  testWidgets('收起时高度从满高往下收，不能瞬间跳成 0', (tester) async {
    Widget box({required bool expanded}) => MaterialApp(
      home: Center(
        child: StaggeredSessions(
          expanded: expanded,
          unclipped: expanded,
          children: const [SizedBox(key: Key('card'), width: 80, height: 40)],
        ),
      ),
    );
    await tester.pumpWidget(box(expanded: true));
    await tester.pumpAndSettle();
    final openH = tester.getSize(find.byType(StaggeredSessions)).height;
    expect(openH, greaterThan(30));
    await tester.pumpWidget(box(expanded: false));
    await tester.pump();
    final firstFrameH = tester.getSize(find.byType(StaggeredSessions)).height;
    expect(firstFrameH, closeTo(openH, 2));
    await tester.pump(const Duration(milliseconds: 80));
    final midH = tester.getSize(find.byType(StaggeredSessions)).height;
    expect(midH, lessThan(firstFrameH));
    expect(midH, greaterThan(0));
  });

  testWidgets('StaggeredSessions 里的共享长按手势能开始并结束拖拽', (tester) async {
    var started = false;
    var moved = false;
    var ended = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StaggeredSessions(
            expanded: true,
            unclipped: kHomeDragSessionHitTestUnclipped,
            children: [
              HomeLongPressDrag(
                onDragStart: (_) => started = true,
                onDragUpdate: (_) => moved = true,
                onDragEnd: (_) => ended = true,
                child: const ColoredBox(
                  key: Key('drag'),
                  color: Color(0xFF000000),
                  child: SizedBox(width: 80, height: 40),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byKey(const Key('drag')));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 360));
    await gesture.moveBy(const Offset(0, 50));
    await tester.pump();
    expect(started, isTrue);
    await gesture.up();
    await tester.pump();
    expect(moved, isTrue);
    expect(ended, isTrue);
  });

  testWidgets('左滑卡片不会抢走共享长按拖拽', (tester) async {
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StaggeredSessions(
            expanded: true,
            unclipped: true,
            children: [
              HomeLongPressDrag(
                onDragStart: (_) => started = true,
                onDragUpdate: (_) {},
                onDragEnd: (_) {},
                child: SwipeActions(
                  desktopOverride: false,
                  actionWidth: 56,
                  actions: const [],
                  child: const ColoredBox(
                    key: Key('swipe-drag'),
                    color: Color(0xFF000000),
                    child: SizedBox(width: 120, height: 48),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byKey(const Key('swipe-drag')));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveBy(const Offset(0, 50));
    await tester.pump();
    expect(started, isTrue);
    await gesture.up();
  });

  testWidgets('长按窗口后的横向抖动不能自动打开左滑', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SwipeActions(
            desktopOverride: false,
            actionWidth: 56,
            actions: const [],
            child: const ColoredBox(
              key: Key('hold-swipe'),
              color: Colors.black,
              child: SizedBox(width: 120, height: 48),
            ),
          ),
        ),
      ),
    );
    final card = find.byKey(const Key('hold-swipe'));
    final start = tester.getTopLeft(card);
    final gesture = await tester.startGesture(tester.getCenter(card));
    await tester.pump(const Duration(milliseconds: 320));
    await gesture.moveBy(const Offset(-36, 0));
    await tester.pump();
    expect(tester.getTopLeft(card).dx, closeTo(start.dx, 0.1));
    await gesture.up();
  });

  testWidgets('长按窗口内的明确横滑仍可打开左滑', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SwipeActions(
            desktopOverride: false,
            actionWidth: 56,
            actions: const [],
            child: const ColoredBox(
              key: Key('quick-swipe'),
              color: Colors.black,
              child: SizedBox(width: 120, height: 48),
            ),
          ),
        ),
      ),
    );
    final card = find.byKey(const Key('quick-swipe'));
    final start = tester.getTopLeft(card);
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(-36, 0));
    await tester.pump();
    expect(tester.getTopLeft(card).dx, lessThan(start.dx - 20));
    await gesture.up();
  });

  testWidgets('拖拽禁用左滑时立即清零残留位移', (tester) async {
    var disableSwipe = false;
    final openNotifier = ValueNotifier<String?>('reset-swipe');
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SwipeActions(
                disableSwipe: disableSwipe,
                desktopOverride: false,
                openNotifier: openNotifier,
                swipeKey: 'reset-swipe',
                actionWidth: 56,
                actions: const [],
                child: const ColoredBox(
                  key: Key('reset-swipe'),
                  color: Colors.black,
                  child: SizedBox(width: 120, height: 48),
                ),
              );
            },
          ),
        ),
      ),
    );
    final card = find.byKey(const Key('reset-swipe'));
    final start = tester.getTopLeft(card);
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(-36, 0));
    await tester.pump();
    expect(tester.getTopLeft(card).dx, lessThan(start.dx - 20));
    await gesture.up();

    rebuild(() => disableSwipe = true);
    await tester.pump();
    expect(tester.getTopLeft(card).dx, closeTo(start.dx, 0.1));
    expect(openNotifier.value, isNull);
    openNotifier.dispose();
  });

  testWidgets('左滑卡片销毁时延后通知父级，避免锁树期间 setState', (tester) async {
    var visible = true;
    Rect? openRect;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: visible
                  ? SwipeActions(
                      desktopOverride: false,
                      actions: const [],
                      onOpenRectChanged: (rect) {
                        setState(() => openRect = rect);
                      },
                      child: const SizedBox(width: 120, height: 48),
                    )
                  : const SizedBox.shrink(),
            );
          },
        ),
      ),
    );

    rebuild(() => visible = false);
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(openRect, isNull);
  });

  testWidgets('跨项目写入后高度因子贴齐，不从 0 长回来', (tester) async {
    const card = SizedBox(width: 80, height: 40);
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topCenter,
          child: HomeDragHeightFactor(factor: 0, child: card),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(HomeDragHeightFactor)).height, 0);

    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topCenter,
          child: HomeDragHeightFactor(factor: 1, snap: true, child: card),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.getSize(find.byType(HomeDragHeightFactor)).height,
      closeTo(40, 0.5),
    );
  });

  testWidgets('已展开列表新增卡片不从下方滑入', (tester) async {
    var children = const [SizedBox(key: Key('a'), width: 80, height: 40)];
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topCenter,
          child: StaggeredSessions(
            expanded: true,
            unclipped: true,
            children: children,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final firstTop = tester.getTopLeft(find.byKey(const Key('a'))).dy;

    children = const [
      SizedBox(key: Key('b'), width: 80, height: 40),
      SizedBox(key: Key('a'), width: 80, height: 40),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topCenter,
          child: StaggeredSessions(
            expanded: true,
            unclipped: true,
            children: children,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const Key('b'))).dy,
      closeTo(firstTop, 0.5),
    );
  });
}
