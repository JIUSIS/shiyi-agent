import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/media_query_fix.dart';

void main() {
  test('正常状态栏 padding 原样保留', () {
    const data = MediaQueryData(
      size: Size(400, 860),
      padding: EdgeInsets.fromLTRB(0, 38.7, 0, 16),
      viewPadding: EdgeInsets.fromLTRB(0, 38.7, 0, 16),
    );
    final out = sanitizeMediaQuery(data);
    expect(out.padding.top, closeTo(38.7, 0.001));
    expect(out.padding.bottom, closeTo(16, 0.001));
    expect(identical(out, data), isTrue);
  });

  test('小米小窗把 top 报成窗口高度时夹住，SafeArea 还能剩空间', () {
    const data = MediaQueryData(
      size: Size(400, 640),
      padding: EdgeInsets.only(top: 640),
      viewPadding: EdgeInsets.only(top: 640),
    );
    final out = sanitizeMediaQuery(data);
    expect(out.padding.top, lessThanOrEqualTo(80));
    expect(out.viewPadding.top, lessThanOrEqualTo(80));
    expect(640 - out.padding.vertical, greaterThan(400));
  });

  testWidgets('异常 padding 下 SafeArea 子组件仍有高度', (tester) async {
    late double childHeight;
    await tester.pumpWidget(
      MediaQuery(
        data: sanitizeMediaQuery(
          const MediaQueryData(
            size: Size(400, 640),
            padding: EdgeInsets.only(top: 640),
            viewPadding: EdgeInsets.only(top: 640),
          ),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                childHeight = constraints.maxHeight;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    expect(childHeight, greaterThan(400));
  });

  test('没有文本输入焦点时清掉 HyperOS 僵尸键盘高度', () {
    const data = MediaQueryData(
      size: Size(400, 869),
      viewInsets: EdgeInsets.only(bottom: 273),
    );
    final out = sanitizeMediaQuery(data, keyboardExpected: false);
    expect(out.viewInsets.bottom, 0);
  });

  test('文本输入仍有焦点时保留正常键盘高度', () {
    const data = MediaQueryData(
      size: Size(400, 869),
      viewInsets: EdgeInsets.only(bottom: 273),
    );
    final out = sanitizeMediaQuery(data, keyboardExpected: true);
    expect(out.viewInsets.bottom, 273);
    expect(identical(out, data), isTrue);
  });

  test('窄屏只压住过大的字体缩放，正常小字号原样保留', () {
    const normal = MediaQueryData(
      size: Size(360, 640),
      textScaler: TextScaler.linear(0.8),
    );
    expect(identical(adaptSmallScreenText(normal), normal), isTrue);

    const large = MediaQueryData(
      size: Size(360, 640),
      textScaler: TextScaler.linear(1.2),
    );
    expect(
      adaptSmallScreenText(large).textScaler.scale(1),
      closeTo(0.92, 0.001),
    );
  });

  test('宽屏不改系统字体缩放', () {
    const data = MediaQueryData(
      size: Size(840, 1960),
      textScaler: TextScaler.linear(1.2),
    );
    expect(identical(adaptSmallScreenText(data), data), isTrue);
  });
}
