import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 小米 HyperOS 小窗 / 自由窗口会把 [MediaQueryData.viewPadding] 报成
/// 接近窗口高度（实测 top≈640，窗口高也是 640）。SafeArea 吃掉整屏，
/// 看起来像没画面、点不动。
///
/// Flutter issue: https://github.com/flutter/flutter/issues/161086
MediaQueryData sanitizeMediaQuery(
  MediaQueryData data, {
  bool keyboardExpected = true,
}) {
  final size = data.size;
  if (size.width <= 1 || size.height <= 1) return data;

  final maxTop = math.min(80.0, size.height * 0.2);
  final maxBottom = math.min(80.0, size.height * 0.2);
  final maxH = math.min(48.0, size.width * 0.2);

  bool tooLarge(EdgeInsets e) {
    return e.top > maxTop ||
        e.bottom > maxBottom ||
        e.left > maxH ||
        e.right > maxH ||
        e.vertical >= size.height * 0.4 ||
        e.horizontal >= size.width * 0.4;
  }

  EdgeInsets clampInsets(EdgeInsets e) {
    return EdgeInsets.only(
      left: e.left.clamp(0.0, maxH),
      top: e.top.clamp(0.0, maxTop),
      right: e.right.clamp(0.0, maxH),
      bottom: e.bottom.clamp(0.0, maxBottom),
    );
  }

  var padding = data.padding;
  var viewPadding = data.viewPadding;
  var viewInsets = data.viewInsets;
  var changed = false;

  if (tooLarge(padding) || tooLarge(viewPadding)) {
    padding = clampInsets(padding);
    viewPadding = clampInsets(viewPadding);
    changed = true;
  }

  final maxInsetBottom = size.height * 0.7;
  if (!keyboardExpected && viewInsets.bottom > 0) {
    // HyperOS 偶尔会在输入法已经隐藏、页面也没有文本焦点时继续上报
    // 上一次的 IME 高度，Scaffold 因此把底部输入区挤出可视区域。
    viewInsets = viewInsets.copyWith(bottom: 0);
    changed = true;
  } else if (viewInsets.bottom > maxInsetBottom) {
    viewInsets = viewInsets.copyWith(bottom: maxInsetBottom);
    changed = true;
  }

  if (!changed) return data;
  return data.copyWith(
    padding: padding,
    viewPadding: viewPadding,
    viewInsets: viewInsets,
  );
}

/// 窄屏只压住过大的系统字体缩放，正常字号不被主动改小。
/// 宽屏和已经较小的系统字号原样保留，避免影响无障碍设置。
MediaQueryData adaptSmallScreenText(MediaQueryData data) {
  if (data.size.width >= 380) return data;
  final scale = data.textScaler.scale(1.0);
  if (scale <= 0.92) return data;
  return data.copyWith(textScaler: TextScaler.linear(0.92));
}
