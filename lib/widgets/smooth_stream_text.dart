import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 流式内容高度变化时平滑撑开，避免换行导致旧内容瞬移。
class SmoothStreamHeight extends StatelessWidget {
  const SmoothStreamHeight({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    return AnimatedSize(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomCenter,
      clipBehavior: Clip.none,
      child: child,
    );
  }
}

/// 流式文本平滑追赶：新 token 不再整段闪现，
/// 而是从上一帧位置继续逐字补齐，落后越多追得越快。
class SmoothStreamText extends StatefulWidget {
  const SmoothStreamText(
    this.text, {
    super.key,
    this.style,
    this.selectable = false,
    this.baseCharsPerSecond = 90,
    this.maxCharsPerSecond = 720,
  });

  final String text;
  final TextStyle? style;
  final bool selectable;
  final double baseCharsPerSecond;
  final double maxCharsPerSecond;

  @override
  State<SmoothStreamText> createState() => _SmoothStreamTextState();
}

class _SmoothStreamTextState extends State<SmoothStreamText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late String _target;
  late String _visible;
  late int _offset;
  Duration? _lastTick;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _target = widget.text;
    _visible = _target;
    _offset = _target.length;
    _maybeStart();
  }

  @override
  void didUpdateWidget(covariant SmoothStreamText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == _target) return;
    if (widget.text.length > _target.length &&
        widget.text.startsWith(_target)) {
      _target = widget.text;
    } else {
      _target = widget.text;
      _visible = '';
      _offset = 0;
    }
    _maybeStart();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _maybeStart() {
    if (_offset < _target.length && !_ticker.isActive) {
      _lastTick = null;
      _ticker.start();
    }
  }

  int _safeOffset(int value) {
    var next = value.clamp(0, _target.length);
    if (next > 0 && next < _target.length) {
      final prev = _target.codeUnitAt(next - 1);
      final current = _target.codeUnitAt(next);
      final insideSurrogate =
          prev >= 0xD800 &&
          prev <= 0xDBFF &&
          current >= 0xDC00 &&
          current <= 0xDFFF;
      if (insideSurrogate) next += 1;
    }
    return next;
  }

  void _onTick(Duration elapsed) {
    final last = _lastTick ?? Duration.zero;
    _lastTick = elapsed;
    if (elapsed <= last) return;
    if (_offset >= _target.length) {
      _ticker.stop();
      return;
    }
    final dt = elapsed - last;
    final backlog = _target.length - _offset;
    final speed =
        widget.baseCharsPerSecond +
        (backlog / 240).clamp(0.0, 3.0) *
            (widget.maxCharsPerSecond - widget.baseCharsPerSecond);
    final step = (speed * dt.inMicroseconds / Duration.microsecondsPerSecond)
        .round()
        .clamp(1, backlog);
    final nextOffset = _safeOffset(_offset + step);
    if (nextOffset == _offset) return;
    setState(() {
      _visible = _target.substring(0, nextOffset);
      _offset = nextOffset;
    });
    if (_offset >= _target.length) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.selectable) {
      return SelectableText(_visible, style: widget.style);
    }
    return Text(_visible, style: widget.style);
  }
}
