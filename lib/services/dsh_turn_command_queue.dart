/// Serializes DSH turn-control RPCs that must not race each other.
///
/// In particular, an interruption must reach `session.cancel` before the
/// replacement `session.prompt`; otherwise a late cancel can stop the new
/// turn as well.
class DshTurnCommandQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> enqueue<T>(Future<T> Function() action) {
    final operation = _tail.then<T>((_) => action());
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }
}
