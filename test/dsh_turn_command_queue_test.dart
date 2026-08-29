import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:shiyi_agent_app/services/dsh_turn_command_queue.dart';

void main() {
  test('DSH cancel completes before replacement prompt', () async {
    final queue = DshTurnCommandQueue();
    final cancelDone = Completer<void>();
    final order = <String>[];

    final cancel = queue.enqueue(() async {
      order.add('cancel-start');
      await cancelDone.future;
      order.add('cancel-end');
    });
    final prompt = queue.enqueue(() async {
      order.add('prompt');
    });

    await Future<void>.delayed(Duration.zero);
    expect(order, ['cancel-start']);
    cancelDone.complete();
    await Future.wait([cancel, prompt]);
    expect(order, ['cancel-start', 'cancel-end', 'prompt']);
  });

  test('a failed DSH command does not permanently block the queue', () async {
    final queue = DshTurnCommandQueue();
    final order = <String>[];

    final failed = queue.enqueue<void>(() async {
      order.add('failed');
      throw StateError('cancel failed');
    });
    final next = queue.enqueue(() async {
      order.add('next');
    });

    await expectLater(failed, throwsStateError);
    await next;
    expect(order, ['failed', 'next']);
  });
}
