// 语音播报服务（单例）：使用 Microsoft Edge 在线 TTS（免费）合成 MP3 并播放。
// 朗读前自动清理 Markdown 与图片标记；合成/播放失败会通过 lastError 上报。
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_edge_tts/flutter_edge_tts.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final AudioPlayer _player = AudioPlayer();
  FlutterEdgeTts? _edge;

  /// 当前正在朗读的消息 id，null 表示未在朗读。
  final ValueNotifier<String?> speakingId = ValueNotifier<String?>(null);

  /// 最近一次朗读错误信息（成功朗读会清空），用于界面提示。
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// 代际计数：stop 或新一次 speak 会使旧任务失效。
  int _generation = 0;
  String? _lastFile;

  Future<FlutterEdgeTts> _ensureEdge() {
    final existing = _edge;
    if (existing != null) return Future.value(existing);
    final edge = FlutterEdgeTts(voice: 'zh-CN-XiaoxiaoNeural');
    _edge = edge;
    // 播放结束/被系统停止时清空朗读状态。
    _player.onPlayerComplete.listen((_) => _clearIfSpeaking());
    _player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.stopped || state == PlayerState.completed) {
        _clearIfSpeaking();
      }
    });
    return Future.value(edge);
  }

  void _clearIfSpeaking() {
    if (speakingId.value != null) speakingId.value = null;
  }

  /// 去掉 Markdown、图片标记等，只保留适合朗读的纯文本。
  String cleanText(String raw) {
    var t = raw;
    t = t.replaceAll(imageMarkerRegExp, '');
    t = t.replaceAll(RegExp(r'```[\s\S]*?```'), '（代码块省略）');
    t = t.replaceAll(RegExp(r'`[^`\n]+`'), '');
    t = t.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    t = t.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
    t = t.replaceAll(RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1');
    t = t.replaceAll(RegExp(r'[*_~]{1,3}'), '');
    t = t.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
    t = t.replaceAll(RegExp(r'^\s*\d+\.\s+', multiLine: true), '');
    t = t.replaceAll(RegExp(r'[>|]'), '');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  /// 把 0.5~1.5 的倍速换算成 Edge SSML 的百分数（1.0 → "+0%"）。
  String _rateToEdge(double rate) {
    final pct = ((rate.clamp(0.5, 2.0) - 1.0) * 100).round();
    return pct >= 0 ? '+$pct%' : '$pct%';
  }

  /// 朗读一条消息；会先停止当前朗读，同一时间只播一条。
  Future<void> speak(String id, String raw, {double rate = 1.0}) async {
    await stop();
    final generation = ++_generation;
    final text = cleanText(raw);
    if (text.isEmpty) return;
    try {
      final edge = await _ensureEdge();
      if (generation != _generation) return;
      speakingId.value = id;
      lastError.value = null;
      final result = await edge.synthesize(
        text,
        prosody: EdgeTtsProsody(rate: _rateToEdge(rate), volume: '100'),
      );
      if (generation != _generation) return;
      if (result.audioBytes.isEmpty) {
        _fail('Edge TTS 没有返回音频');
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/shiyi_tts_$generation.mp3');
      await file.writeAsBytes(result.audioBytes, flush: true);
      if (generation != _generation) return;
      // 清理上一次的临时文件，避免堆积。
      if (_lastFile != null && _lastFile != file.path) {
        try {
          final old = File(_lastFile!);
          if (old.existsSync()) old.deleteSync();
        } catch (_) {}
      }
      _lastFile = file.path;
      await _player.play(DeviceFileSource(file.path));
    } catch (e) {
      if (generation == _generation) _fail('语音合成失败：$e');
    }
  }

  void _fail(String msg) {
    speakingId.value = null;
    lastError.value = msg;
  }

  Future<void> stop() async {
    _generation++;
    try {
      await _player.stop();
    } catch (_) {}
    speakingId.value = null;
  }

  /// 应用退出时释放资源。
  Future<void> dispose() async {
    _generation++;
    try {
      await _player.dispose();
    } catch (_) {}
    try {
      await _edge?.close();
    } catch (_) {}
    _edge = null;
    speakingId.value = null;
  }
}
