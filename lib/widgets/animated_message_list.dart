import 'package:flutter/material.dart';

/// 反向消息列表专用 AnimatedList：新气泡从底部平滑撑开，
/// 老消息被自然顶上去，不再整列瞬移。
class AnimatedMessageList extends StatefulWidget {
  const AnimatedMessageList({
    super.key,
    required this.items,
    required this.controller,
    required this.padding,
    required this.keyOf,
    required this.itemBuilder,
  });

  final List<Object> items;
  final ScrollController controller;
  final EdgeInsetsGeometry padding;
  final String Function(Object item) keyOf;
  final Widget Function(BuildContext context, Object item) itemBuilder;

  @override
  State<AnimatedMessageList> createState() => _AnimatedMessageListState();
}

class _AnimatedMessageListState extends State<AnimatedMessageList> {
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  late List<Object> _items;
  late List<String> _keys;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.items);
    _keys = _items.map(widget.keyOf).toList();
  }

  @override
  void didUpdateWidget(covariant AnimatedMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final state = _listKey.currentState;
    final nextKeys = widget.items.map(widget.keyOf).toList();
    if (state != null) {
      final match = _lcsMatch(_keys, nextKeys);
      for (var i = _keys.length - 1; i >= 0; i--) {
        if (match[i] < 0) {
          final removed = _items[i];
          state.removeItem(
            i,
            (context, animation) => SizeTransition(
              sizeFactor: animation,
              child: widget.itemBuilder(context, removed),
            ),
          );
          _keys.removeAt(i);
          _items.removeAt(i);
        }
      }
      final matchedNew = <int>{for (final m in match) if (m >= 0) m};
      var pointer = 0;
      for (var j = 0; j < nextKeys.length; j++) {
        if (matchedNew.contains(j)) {
          pointer++;
        } else {
          state.insertItem(pointer);
          _keys.insert(pointer, nextKeys[j]);
          _items.insert(pointer, widget.items[j]);
          pointer++;
        }
      }
    }
    _items = List.of(widget.items);
    _keys = nextKeys;
  }

  static List<int> _lcsMatch(List<String> a, List<String> b) {
    final n = a.length;
    final m = b.length;
    final dp = List.generate(n + 1, (_) => List.filled(m + 1, 0));
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        dp[i][j] = a[i] == b[j]
            ? dp[i + 1][j + 1] + 1
            : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
      }
    }
    final match = List.filled(n, -1);
    var i = 0;
    var j = 0;
    while (i < n && j < m) {
      if (a[i] == b[j]) {
        match[i] = j;
        i++;
        j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) {
        i++;
      } else {
        j++;
      }
    }
    return match;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedList(
      key: _listKey,
      controller: widget.controller,
      reverse: true,
      clipBehavior: Clip.none,
      padding: widget.padding,
      initialItemCount: _items.length,
      itemBuilder: (context, index, animation) {
        final item = _items[index];
        return SizeTransition(
          sizeFactor: animation,
          child: widget.itemBuilder(context, item),
        );
      },
    );
  }
}
