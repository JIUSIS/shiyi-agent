import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/core/models.dart';

void main() {
  test('extractImagePaths 按顺序提取本地图片路径', () {
    const content = '![图片](/data/user/0/a/app_flutter/images/img_1.jpg)\n'
        '看看这张图\n'
        '![图片](/data/user/0/a/app_flutter/images/img_2.jpg)';
    final paths = extractImagePaths(content);
    expect(paths.length, 2);
    expect(paths[0], '/data/user/0/a/app_flutter/images/img_1.jpg');
    expect(paths[1], '/data/user/0/a/app_flutter/images/img_2.jpg');
  });

  test('stripImageMarkers 去掉标记只留文字', () {
    const content = '![图片](/data/user/0/a/app_flutter/images/img_1.jpg)\n看看这张图';
    expect(stripImageMarkers(content), '看看这张图');
  });

  test('stripImageMarkers 纯图片消息返回空串', () {
    expect(stripImageMarkers('![图片](/data/user/0/a/app_flutter/images/img_1.jpg)'), '');
  });

  test('hasImages 识别带图消息', () {
    final withImg = ChatMessage(
      id: '1',
      sessionId: 's1',
      role: 'user',
      content: '![图片](/data/user/0/a/app_flutter/images/img_1.jpg) hi',
      createdAt: 1,
    );
    expect(withImg.hasImages, isTrue);
    final plain = ChatMessage(
      id: '2',
      sessionId: 's1',
      role: 'user',
      content: 'hi',
      createdAt: 2,
    );
    expect(plain.hasImages, isFalse);
  });
}
