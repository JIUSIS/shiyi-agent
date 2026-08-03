import 'package:flutter/material.dart';

/// 欢迎页图片的圆角矩形头像：
/// 主页空状态、会话空对话、会话列表头像统一使用。
/// 圆角半径按尺寸比例（size * 0.25），大图小图观感一致。
class WelcomeAvatar extends StatelessWidget {
  final double size;

  /// 图片资源，默认欢迎页原图；小尺寸场景可传派生的小图（如 assets/avatar.png）。
  final String asset;
  const WelcomeAvatar({
    super.key,
    required this.size,
    this.asset = 'assets/welcome.png',
  });

  @override
  Widget build(BuildContext context) {
    final img = Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.cover,
      cacheWidth: (size * 3).round(), // 按显示尺寸解码，避免大图全量解码
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: img,
    );
  }
}
