import 'dart:math' as math;

import 'package:flutter/material.dart';

const _baguaInk = Color(0xFF16120C);
const _baguaGold = Color(0xFFD6B25E);

/// 后天八卦方位，从上（南）起顺时针：离坤兑乾坎艮震巽。
/// 每爻从下到上，1 为阳（连），0 为阴（断）。
const _laterHeaven = <List<int>>[
  [1, 0, 1], // 离
  [0, 0, 0], // 坤
  [1, 1, 0], // 兑
  [1, 1, 1], // 乾
  [0, 1, 0], // 坎
  [0, 0, 1], // 艮
  [1, 0, 0], // 震
  [0, 1, 1], // 巽
];

/// 群聊徽章：圆角太极八卦图，尺寸和 [WelcomeAvatar] 对齐。
class BaguaAvatar extends StatelessWidget {
  final double size;
  const BaguaAvatar({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: SizedBox(
        width: size,
        height: size,
        child: const CustomPaint(painter: BaguaPainter(emblem: true)),
      ),
    );
  }
}

/// 单色八卦图标，给分组头、空态和设置行用。
class BaguaIcon extends StatelessWidget {
  final double size;
  final Color color;
  const BaguaIcon({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: BaguaPainter(emblem: false, color: color)),
    );
  }
}

class BaguaPainter extends CustomPainter {
  final bool emblem;
  final Color color;
  const BaguaPainter({required this.emblem, this.color = _baguaGold});

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    if (side <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = side / 2;
    if (emblem) {
      _paintEmblem(canvas, size, center, radius);
    } else {
      _paintTinted(canvas, center, radius);
    }
  }

  void _paintEmblem(Canvas canvas, Size size, Offset center, double radius) {
    final bg = Paint()
      ..shader = RadialGradient(
        colors: const [Color(0xFF2A2318), _baguaInk],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, bg);

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.1, radius * 0.045)
      ..color = _baguaGold.withValues(alpha: 0.92);
    canvas.drawCircle(center, radius * 0.96, ring);

    if (radius >= 11) {
      _paintTrigrams(canvas, center, radius, color: _baguaGold, filled: true);
    }
    _paintTaiji(
      canvas,
      center,
      radius * (radius >= 11 ? 0.38 : 0.62),
      emblem: true,
    );
  }

  void _paintTinted(Canvas canvas, Offset center, double radius) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, radius * 0.08)
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawCircle(center, radius * 0.96, stroke);
    if (radius >= 11) {
      _paintTrigrams(canvas, center, radius, color: color, filled: false);
    }
    _paintTaiji(
      canvas,
      center,
      radius * (radius >= 11 ? 0.38 : 0.62),
      emblem: false,
      tint: color,
    );
  }

  void _paintTrigrams(
    Canvas canvas,
    Offset center,
    double radius, {
    required Color color,
    required bool filled,
  }) {
    final paint = Paint()
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, radius * 0.028)
      ..strokeCap = StrokeCap.round
      ..color = color;
    for (var i = 0; i < _laterHeaven.length; i++) {
      final angle = -math.pi / 2 + i * (math.pi / 4);
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      _drawTrigram(canvas, radius, _laterHeaven[i], paint, filled);
      canvas.restore();
    }
  }

  void _drawTrigram(
    Canvas canvas,
    double radius,
    List<int> yao,
    Paint paint,
    bool filled,
  ) {
    final half = radius * 0.16;
    final thickness = math.max(1.1, radius * 0.032);
    final gap = radius * 0.042;
    final inner = radius * 0.48;
    for (var i = 0; i < 3; i++) {
      final x = inner + i * (thickness + gap);
      final yang = yao[i] == 1;
      if (filled) {
        if (yang) {
          canvas.drawRRect(
            RRect.fromLTRBR(
              x - thickness / 2,
              -half,
              x + thickness / 2,
              half,
              Radius.circular(thickness / 2),
            ),
            paint,
          );
        } else {
          final split = half * 0.22;
          canvas.drawRRect(
            RRect.fromLTRBR(
              x - thickness / 2,
              -half,
              x + thickness / 2,
              -split,
              Radius.circular(thickness / 2),
            ),
            paint,
          );
          canvas.drawRRect(
            RRect.fromLTRBR(
              x - thickness / 2,
              split,
              x + thickness / 2,
              half,
              Radius.circular(thickness / 2),
            ),
            paint,
          );
        }
      } else if (yang) {
        canvas.drawLine(Offset(x, -half), Offset(x, half), paint);
      } else {
        final split = half * 0.22;
        canvas.drawLine(Offset(x, -half), Offset(x, -split), paint);
        canvas.drawLine(Offset(x, split), Offset(x, half), paint);
      }
    }
  }

  void _paintTaiji(
    Canvas canvas,
    Offset center,
    double radius, {
    required bool emblem,
    Color? tint,
  }) {
    final tone = tint ?? color;
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    );
    if (emblem) {
      final white = Paint()..color = Colors.white;
      final black = Paint()..color = Colors.black;
      canvas.drawCircle(center, radius, white);
      canvas.drawRect(
        Rect.fromLTRB(
          center.dx - radius,
          center.dy - radius,
          center.dx,
          center.dy + radius,
        ),
        black,
      );
      canvas.drawCircle(
        Offset(center.dx, center.dy - radius / 2),
        radius / 2,
        black,
      );
      canvas.drawCircle(
        Offset(center.dx, center.dy + radius / 2),
        radius / 2,
        white,
      );
      canvas.drawCircle(
        Offset(center.dx, center.dy - radius / 2),
        radius * 0.14,
        white,
      );
      canvas.drawCircle(
        Offset(center.dx, center.dy + radius / 2),
        radius * 0.14,
        black,
      );
    } else {
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, radius * 0.12)
        ..color = tone;
      canvas.drawCircle(center, radius, stroke);
      canvas.drawArc(
        Rect.fromCircle(
          center: Offset(center.dx, center.dy - radius / 2),
          radius: radius / 2,
        ),
        -math.pi / 2,
        math.pi,
        false,
        stroke,
      );
      canvas.drawArc(
        Rect.fromCircle(
          center: Offset(center.dx, center.dy + radius / 2),
          radius: radius / 2,
        ),
        math.pi / 2,
        math.pi,
        false,
        stroke,
      );
      canvas.drawCircle(
        Offset(center.dx, center.dy - radius / 2),
        radius * 0.12,
        Paint()..color = tone,
      );
      canvas.drawCircle(
        Offset(center.dx, center.dy + radius / 2),
        radius * 0.12,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.0, radius * 0.1)
          ..color = tone,
      );
    }
    canvas.restore();
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, radius * 0.06)
      ..color = emblem ? _baguaGold : tone;
    canvas.drawCircle(center, radius, outline);
  }

  @override
  bool shouldRepaint(covariant BaguaPainter oldDelegate) =>
      oldDelegate.emblem != emblem || oldDelegate.color != color;
}
