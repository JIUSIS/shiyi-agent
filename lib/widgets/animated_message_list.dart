import 'package:flutter/material.dart';

/// 反向消息列表。
///
/// 消息会在流式生成期间反复更新和重排，AnimatedList 只支持增删，
/// 不支持安全地移动已有项。这里使用普通列表，让消息顺序始终由
/// 调用方提供的数据决定，避免流式气泡与历史气泡错位或被吞掉。
class AnimatedMessageList extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      reverse: true,
      clipBehavior: Clip.none,
      padding: padding,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return KeyedSubtree(
          key: ValueKey<String>(keyOf(item)),
          child: itemBuilder(context, item),
        );
      },
    );
  }
}
