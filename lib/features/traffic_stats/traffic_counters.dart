import 'dart:math' as math;

class TrafficCounterDelta {
  const TrafficCounterDelta({
    required this.upload,
    required this.download,
    required this.newCount,
    this.host,
    this.process,
  });
  final int upload;
  final int download;
  final bool newCount;
  final String? host;
  final String? process;
  bool get hasBytes => upload > 0 || download > 0;
}

class _ConnectionCounter {
  _ConnectionCounter(this.upload, this.download);
  int upload;
  int download;
  String? host;
  String? process;
  bool counted = false;
}

/// One book belongs to one Core epoch. Counters are high-water marks.
/// Active counters are never evicted merely to satisfy a display-size limit.
class TrafficCounters {
  final Map<String, _ConnectionCounter> _connections = {};
  int get length => _connections.length;
  Set<String> get activeHosts => {
    for (final entry in _connections.values)
      if (entry.host != null) entry.host!,
  };

  TrafficCounterDelta observe({
    required String id,
    required int upload,
    required int download,
    String? host,
    String? process,
    required bool baselineIfUnknown,
  }) {
    final up = math.max(0, upload);
    final down = math.max(0, download);
    final previous = _connections[id];
    final state =
        previous ??
        _ConnectionCounter(
          baselineIfUnknown ? up : 0,
          baselineIfUnknown ? down : 0,
        );
    _connections[id] = state;
    if (host != null && host.isNotEmpty) state.host = host;
    if (process != null && process.isNotEmpty) state.process ??= process;
    final deltaUp = math.max(0, up - state.upload);
    final deltaDown = math.max(0, down - state.download);
    state.upload = math.max(up, state.upload);
    state.download = math.max(down, state.download);
    final newCount =
        !state.counted &&
        state.host != null &&
        (host != null || deltaUp > 0 || deltaDown > 0);
    if (newCount) state.counted = true;
    return TrafficCounterDelta(
      upload: deltaUp,
      download: deltaDown,
      newCount: newCount,
      host: state.host,
      process: state.process,
    );
  }

  /// A clear starts a new reporting segment; it does not discard I/O baselines.
  void clearReportedCounts() {
    for (final connection in _connections.values) {
      connection.counted = false;
    }
  }

  /// Call only after applying the final cumulative sample for a closed ID.
  void close(String id) => _connections.remove(id);

  /// Only a complete, ordered snapshot from the same epoch may call this.
  /// Do not pass a delta batch or a partial/page-limited UI connection list.
  void reconcileCompleteSnapshot(Set<String> activeIds) {
    _connections.removeWhere((id, _) => !activeIds.contains(id));
  }

  void beginEpoch() => _connections.clear();
}
