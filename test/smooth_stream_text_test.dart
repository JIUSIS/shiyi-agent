import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/widgets/smooth_stream_text.dart';

void main() {
  testWidgets('流式高度变化用缓动过渡，不瞬跳', (tester) async {
    const key = ValueKey('streamHeightBox');

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SmoothStreamHeight(
            active: true,
            child: SizedBox(key: key, width: 80, height: 20),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(key)).height, 20);

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SmoothStreamHeight(
            active: true,
            child: SizedBox(key: key, width: 80, height: 60),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 40));
    final midHeight = tester.getSize(find.byType(AnimatedSize)).height;
    expect(midHeight, greaterThan(20));
    expect(midHeight, lessThan(60));

    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AnimatedSize)).height, 60);
  });
}
