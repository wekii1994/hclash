import 'dart:async';

/// Shares only identical in-flight operations. Invalidating does not cancel I/O.
class SingleFlight<K, V> {
  final Map<K, Future<V>> _pending = {};
  int _generation = 0;

  int get generation => _generation;
  int get pendingCount => _pending.length;

  Future<V> run(K key, FutureOr<V> Function() action) {
    final existing = _pending[key];
    if (existing != null) return existing;
    final completer = Completer<V>();
    final future = completer.future;
    // Register before invoking action, including synchronous actions.
    _pending[key] = future;
    Future<V>.sync(action).then<void>(
      (value) {
        if (identical(_pending[key], future)) _pending.remove(key);
        completer.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_pending[key], future)) _pending.remove(key);
        completer.completeError(error, stack);
      },
    );
    return future;
  }

  void invalidate() {
    _generation++;
    _pending.clear();
  }
}
