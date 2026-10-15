import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiyi_agent_app/services/llm_client.dart';

/// 证明群聊「多线程」是**真并发**，不是一次请求让模型扮演多人：
/// 每个成员 = 一条独立 HTTP 请求（自带人设与模型），一批里的请求在时间上重叠。
/// 用的就是会话页同一套 `LlmClient` + `Future.wait` 形状（docs/fix-log.md #404）。
void main() {
  test('一批 N 个成员 = N 条并行请求，各自带自己人设与模型', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final members = ['组长甲', '组员乙', '组员丙', '组员丁'];
    final arrivals = <String, DateTime>{};
    final finished = <String, DateTime>{};
    final models = <String>[];

    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final messages = (body['messages'] as List).cast<Map>();
      final system = (messages.first['content'] ?? '').toString();
      // 从 system 里取出这个人是谁（人设是每个成员各自的）
      final hit = members.firstWhere(
        (name) => system.contains('「$name」'),
        orElse: () => '?',
      );
      models.add((body['model'] ?? '').toString());
      arrivals[hit] = DateTime.now();
      // 每个请求都压 400ms 再回，制造重叠窗口：真并发时总耗时应 ≈400ms 而不是 4×400ms
      await Future<void>.delayed(const Duration(milliseconds: 400));
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        )
        ..write('data: {"choices":[{"delta":{"content":"收到"}}]}\n\n')
        ..write('data: [DONE]\n\n');
      await request.response.close();
      finished[hit] = DateTime.now();
    });

    final started = DateTime.now();
    await Future.wait([
      for (var i = 0; i < members.length; i++)
        LlmClient(
          baseUrl: 'http://${server.address.host}:${server.port}/v1',
          apiKey: 'test-key',
          model: 'model-$i', // 每个成员可以有自己的模型
          temperature: 0.2,
          maxTokens: 256,
          tools: const [],
          onTurn: (_) {},
        ).send([
          {'role': 'system', 'content': '你是拾忆群聊里的独立成员「${members[i]}」。'},
          {'role': 'user', 'content': '开工'},
        ]),
    ]);
    final elapsed = DateTime.now().difference(started);
    // 等客户端读完 [DONE] 后，服务端的收尾写入可能还差一拍。
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (finished.length < members.length &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await server.close(force: true);

    // ① 4 个成员 = 4 条独立请求，每条带自己的人设
    expect(arrivals.keys.toSet(), members.toSet());
    // ② 每条请求带自己的模型（不是一次调用扮演四个角色）
    expect(models.toSet(), {'model-0', 'model-1', 'model-2', 'model-3'});
    // ③ 时间上真的重叠：最晚到达 < 最早结束
    final lastArrival = arrivals.values.reduce((a, b) => a.isAfter(b) ? a : b);
    final firstFinish = finished.values.reduce((a, b) => a.isBefore(b) ? a : b);
    expect(
      lastArrival.isBefore(firstFinish),
      isTrue,
      reason: '四个请求必须在时间上重叠（真并发），而不是排队',
    );
    // ④ 总耗时接近单个请求（400ms），远小于串行的 4×400ms
    expect(
      elapsed.inMilliseconds,
      lessThan(900),
      reason: '真并发总耗时≈400ms；串行会 ≥1600ms，实测 ${elapsed.inMilliseconds}ms',
    );
    // ⑤ 每个成员各自收到自己那份回复
    expect(finished.length, members.length);
  });
}
