import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 图片选择与压缩存储服务。
/// 选图/拍照 → 等比压缩（最长边 <= 1024）→ JPEG 存入应用私有目录，
/// 返回本地绝对路径（DB 只存路径，不存 base64）。
/// 桌面端（Windows）：flutter_image_compress / 相机无实现，自动降级为
/// 相册选图 + 原图保存。
class ImageService {
  static const int maxEdge = 1024;
  static const int quality = 82;

  /// 从相册选图或拍照，压缩后存入应用目录，返回本地路径；取消返回 null。
  static Future<String?> pickAndSave({required bool fromCamera}) async {
    final picker = ImagePicker();
    final XFile? picked;
    try {
      // Windows 桌面端 image_picker 不支持相机，自动降级为相册。
      final source = fromCamera && !Platform.isWindows
          ? ImageSource.camera
          : ImageSource.gallery;
      picked = await picker.pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
      );
    } catch (e) {
      throw Exception('无法打开${fromCamera ? '相机' : '相册'}: $e');
    }
    if (picked == null) return null;

    return _compressAndSave(picked);
  }

  /// 从相册多选图片，逐个压缩后存入应用目录，返回本地路径列表。
  static Future<List<String>> pickMultipleAndSave() async {
    final picker = ImagePicker();
    final List<XFile> picked;
    try {
      picked = await picker.pickMultiImage(
        maxWidth: 2048,
        maxHeight: 2048,
      );
    } catch (e) {
      throw Exception('无法打开相册: $e');
    }
    if (picked.isEmpty) return const [];

    final out = <String>[];
    for (final f in picked) {
      try {
        final p = await _compressAndSave(f);
        if (p != null) out.add(p);
      } catch (_) {
        // 单张失败不影响其余。
      }
    }
    return out;
  }

  static Future<String?> _compressAndSave(XFile picked) async {
    final bytes = await picked.readAsBytes();
    final Uint8List compressed;
    if (Platform.isWindows) {
      // flutter_image_compress 无 Windows 实现：桌面端保留原图字节。
      compressed = bytes;
    } else {
      final c = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: maxEdge,
        minHeight: maxEdge,
        quality: quality,
        format: CompressFormat.jpeg,
      );
      if (c.isEmpty) {
        throw Exception('图片压缩失败');
      }
      compressed = c;
    }

    final dir = await getApplicationDocumentsDirectory();
    final imgDir = Directory(p.join(dir.path, 'images'));
    if (!await imgDir.exists()) {
      await imgDir.create(recursive: true);
    }
    final file = File(p.join(imgDir.path, 'img_${DateTime.now().millisecondsSinceEpoch}.jpg'));
    await file.writeAsBytes(compressed, flush: true);
    return file.path;
  }
}
