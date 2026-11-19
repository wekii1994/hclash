import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';

import '../traffic_stats_engine.dart';
import 'core_api.dart';
import 'dto.dart';
import 'mapping.dart';

typedef ConnectionChange = ({
  List<TrackerInfo> opened,
  Map<int, RequestTraffic> counters,
});

/// While no view shows per-connection traffic, the Core is not asked for counters.
class CounterDemand extends ChangeNotifier {
  int _holders = 0;

  bool get wanted => _holders > 0;

  void acquire() {
    if (_holders++ == 0) {
      notifyListeners();
    }
  }

  void release() {
    if (--_holders == 0) {
      notifyListeners();
    }
  }
}

class ConnectionBook {
  final _open = <int, TrackerInfo>{};

  final demand = CounterDemand();

  int get count => _open.length;

  void clear() => _open.clear();

  /// A snapshot replaces the set; only the connections new to the book are
  /// reported as opened, so a resync does not repeat the ones already seen,
  /// and the ones already seen report the totals they have reached since.
  ConnectionChange apply(ConnectionUpdate update) {
    switch (update) {
      case ConnectionsReset(:final snapshot):
        final previous = Map.of(_open);
        _open.clear();
        final opened = <TrackerInfo>[];
        final counters = <int, RequestTraffic>{};
        final currentIds = <int>{};
        for (final info in snapshot.connections) {
          currentIds.add(info.id);
          final known = previous[info.id];
          if (known != null) {
            _open[info.id] = known.copyWith(
              upload: info.upload,
              download: info.download,
            );
            if (known.upload != info.upload ||
                known.download != info.download) {
              counters[info.id] = (
                upload: info.upload,
                download: info.download,
              );
              TrafficStatsEngine.instance.recordTraffic(
                connectionId: info.id,
                tracker: _open[info.id]!,
                totalUp: info.upload,
                totalDown: info.download,
              );
            }
            continue;
          }
          final tracker = trackerOf(info);
          _open[info.id] = tracker;
          opened.add(tracker);
          if (info.upload > 0 || info.download > 0) {
            TrafficStatsEngine.instance.recordTraffic(
              connectionId: info.id,
              tracker: tracker,
              totalUp: info.upload,
              totalDown: info.download,
            );
          }
        }
        for (final entry in previous.entries) {
          if (!currentIds.contains(entry.key)) {
            TrafficStatsEngine.instance.recordTraffic(
              connectionId: entry.key,
              tracker: entry.value,
              totalUp: entry.value.upload,
              totalDown: entry.value.download,
              isClosed: true,
            );
          }
        }
        return (opened: opened, counters: counters);
      case ConnectionsChanged(:final delta):
        return _change(delta);
    }
  }

  ConnectionChange _change(ConnectionDelta delta) {
    final opened = <TrackerInfo>[];
    for (final info in delta.opened) {
      final tracker = trackerOf(info);
      _open[info.id] = tracker;
      opened.add(tracker);
    }
    final counters = <int, RequestTraffic>{};
    for (final counter in delta.counters) {
      counters[counter.id] = (
        upload: counter.upload,
        download: counter.download,
      );
      final tracker = _open[counter.id];
      if (tracker != null) {
        _open[counter.id] = tracker.copyWith(
          upload: counter.upload,
          download: counter.download,
        );
        TrafficStatsEngine.instance.recordTraffic(
          connectionId: counter.id,
          tracker: tracker,
          totalUp: counter.upload,
          totalDown: counter.download,
        );
      }
    }
    for (final id in delta.closed) {
      final tracker = _open.remove(id);
      if (tracker != null) {
        TrafficStatsEngine.instance.recordTraffic(
          connectionId: id,
          tracker: tracker,
          totalUp: tracker.upload,
          totalDown: tracker.download,
          isClosed: true,
        );
      }
    }
    return (opened: opened, counters: counters);
  }

  List<TrackerInfo> list() => _open.values.toList(growable: false);
}
