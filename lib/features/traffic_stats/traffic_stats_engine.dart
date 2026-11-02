import 'dart:async';
import 'dart:math' as math;

import 'domain_classifier.dart';
import 'traffic_counters.dart';
import 'traffic_stats_models.dart';
import 'traffic_stats_persistence.dart';

class TrafficStatsEngine {
  TrafficStatsEngine({
    required TrafficStatsPersistence persistence,
    DateTime Function()? now,
    void Function(String)? log,
    this.onChanged,
  }) : _persistence = persistence,
       _now = now ?? DateTime.now,
       _log = log ?? _discardLog;

  static void _discardLog(String message) {}
  final void Function(String) _log;
  void Function()? onChanged;
  bool get hasListeners => onChanged != null;

  final TrafficStatsPersistence _persistence;
  final DateTime Function() _now;
  final SerialOperations _io = SerialOperations();
  final TrafficCounters _counters = TrafficCounters();
  final Map<String, DailyTrafficData> _dailySummaries = {};
  final Map<String, TargetSiteData> _targetSiteUsages = {};
  Future<void>? _initFuture;
  Future<void>? _saveFuture;
  bool _loaded = false;
  bool _saveAgain = false;
  bool _disposed = false;
  int _historyGeneration = 0;
  int _revision = 0;
  int _cachedAggregatedRevision = -1;
  int _cachedAggregatedLimit = -1;
  List<AggregatedSiteGroup>? _cachedAggregatedSites;
  int _cachedTopSitesRevision = -1;
  int _cachedTopSitesLimit = -1;
  List<TargetSiteData>? _cachedTopSites;
  Object? _coreEpoch;
  Timer? _saveTimer;
  Timer? _notifyTimer;
  Timer? _midnightTimer;
  bool _pendingNotify = false;
  String? _lastPrunedDate;
  Object? lastPersistenceError;

  static const int maxDaysToKeep = 90;
  // Compatibility name: now a DISPLAY limit, never a counter/ledger limit.
  static const int maxSitesToKeep = 200;

  int get trackedConnections => _counters.length;
  Map<String, DailyTrafficData> get dailySummaries => Map.unmodifiable({
    for (final entry in _dailySummaries.entries)
      entry.key: DailyTrafficData.fromJson(entry.value.toJson()),
  });
  Map<String, TargetSiteData> get targetSiteUsages => Map.unmodifiable({
    for (final entry in _targetSiteUsages.entries)
      entry.key: TargetSiteData.fromJson(entry.value.toJson()),
  });

  String _dateKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
  DateTime _dayOffset(DateTime date, int offset) =>
      DateTime(date.year, date.month, date.day + offset);

  Future<void> init() {
    if (_loaded) return Future<void>.value();
    return _initFuture ??= _load();
  }

  Future<void> retryLoad() {
    if (!_loaded) _initFuture = null;
    return init();
  }

  Future<void> _load() async {
    final generation = _historyGeneration;
    try {
      await _io.run(() async {
        final raw = await _persistence.read();
        if (generation != _historyGeneration) return;
        // Decode and validate everything before mutating live aggregates.
        final daily = <String, DailyTrafficData>{};
        final sites = <String, TargetSiteData>{};
        final rawDaily = raw?['daily'];
        final rawSites = raw?['sites'];
        if (rawDaily != null && rawDaily is! Map) {
          throw const FormatException('Invalid daily statistics');
        }
        if (rawSites != null && rawSites is! Map) {
          throw const FormatException('Invalid site statistics');
        }
        if (rawDaily is Map) {
          for (final entry in rawDaily.entries) {
            final key = entry.key.toString();
            final date = DateTime.tryParse(key);
            if (date == null || _dateKey(date) != key || entry.value is! Map) {
              throw const FormatException('Invalid daily entry');
            }
            final value = DailyTrafficData.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
            if (value.date != key ||
                value.upload < 0 ||
                value.download < 0 ||
                value.hourly.entries.any(
                  (e) =>
                      e.key < 0 ||
                      e.key > 23 ||
                      e.value.upload < 0 ||
                      e.value.download < 0,
                )) {
              throw const FormatException('Invalid daily counters');
            }
            daily[key] = value;
          }
        }
        if (rawSites is Map) {
          for (final entry in rawSites.entries) {
            if (entry.value is! Map) {
              throw const FormatException('Invalid site entry');
            }
            final value = TargetSiteData.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
            if (value.host != entry.key ||
                value.upload < 0 ||
                value.download < 0 ||
                value.count < 0) {
              throw const FormatException('Invalid site counters');
            }
            sites[entry.key.toString()] = value;
          }
        }
        // Live events may already have arrived while read() was pending.
        for (final entry in daily.entries) {
          final existing = _dailySummaries[entry.key];
          final loaded = entry.value;
          if (existing != null) {
            loaded.upload += existing.upload;
            loaded.download += existing.download;
            for (final h in existing.hourly.entries) {
              final target = loaded.hourly.putIfAbsent(
                h.key,
                () => HourlyTrafficData(hour: h.key),
              );
              target.upload += h.value.upload;
              target.download += h.value.download;
            }
          }
          _dailySummaries[entry.key] = loaded;
        }
        for (final entry in sites.entries) {
          final existing = _targetSiteUsages[entry.key];
          final loaded = entry.value;
          if (existing != null) {
            loaded.upload += existing.upload;
            loaded.download += existing.download;
            loaded.count += existing.count;
            loaded.lastSeen = math.max(loaded.lastSeen, existing.lastSeen);
            loaded.process ??= existing.process;
          }
          _targetSiteUsages[entry.key] = loaded;
        }
        _revision++;
        _loaded = true;
        lastPersistenceError = null;
        _pruneExpired(_now(), force: true);
      });
    } catch (error) {
      if (generation == _historyGeneration) {
        _loaded = false;
        lastPersistenceError = error;
        _log('Traffic statistics load failed: $error');
      }
    }
    _scheduleMidnight();
    _notifyNow();
  }

  void _pruneExpired(DateTime now, {bool force = false}) {
    final today = _dateKey(now);
    if (!force && today == _lastPrunedDate) return;
    _lastPrunedDate = today;
    final cutoff = _dayOffset(now, -(maxDaysToKeep - 1));
    final key = _dateKey(cutoff);
    _dailySummaries.removeWhere((date, _) => date.compareTo(key) < 0);
    final activeHosts = _counters.activeHosts;
    final beforeCount = _targetSiteUsages.length;
    _targetSiteUsages.removeWhere(
      (host, value) =>
          value.lastSeen < cutoff.millisecondsSinceEpoch &&
          !activeHosts.contains(host),
    );
    if (_targetSiteUsages.length != beforeCount) {
      _revision++;
    }
  }

  Map<String, dynamic> _snapshot() => {
    'schemaVersion': 1,
    'daily': _dailySummaries.map((key, value) => MapEntry(key, value.toJson())),
    'sites': _targetSiteUsages.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
  };

  void scheduleSave() {
    if (_disposed || _saveTimer != null) return;
    _saveTimer = Timer(const Duration(seconds: 30), () {
      _saveTimer = null;
      unawaited(save());
    });
  }

  Future<void> save() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final pending = _saveFuture;
    if (pending != null) {
      _saveAgain = true;
      return pending;
    }
    return _saveFuture = _saveLoop();
  }

  Future<void> _saveLoop() async {
    try {
      await init();
      // Never overwrite unreadable history with a partial/empty live state.
      if (!_loaded) return;
      do {
        _saveAgain = false;
        await _io.run(() async {
          await _persistence.write(_snapshot());
          final hadError = lastPersistenceError != null;
          lastPersistenceError = null;
          if (hadError) _notifyNow();
        });
      } while (_saveAgain);
    } catch (error) {
      lastPersistenceError = error;
      _log('Traffic statistics save failed: $error');
      _notifyNow();
    } finally {
      _saveFuture = null;
    }
  }

  /// Clear boundary = the last sample observed for each live connection.
  /// Bytes after that sample belong to the new reporting segment.
  Future<void> clearAll() {
    _historyGeneration++;
    _loaded = true;
    _initFuture = Future<void>.value();
    _saveTimer?.cancel();
    _saveTimer = null;
    _dailySummaries.clear();
    _targetSiteUsages.clear();
    _revision++;
    _counters.clearReportedCounts();
    final emptySnapshot = _snapshot();
    _notifyNow();
    // Serialize after older writes. Do not clear memory a second time after await.
    return _io.run(() async {
      try {
        await _persistence.write(emptySnapshot);
        final hadError = lastPersistenceError != null;
        lastPersistenceError = null;
        if (hadError) _notifyNow();
      } catch (error) {
        lastPersistenceError = error;
        _log('Traffic statistics clear failed: $error');
        _notifyNow();
        rethrow;
      }
    });
  }

  void beginCoreEpoch(Object epoch) {
    if (_coreEpoch == epoch) return;
    _coreEpoch = epoch;
    _counters.beginEpoch();
  }

  /// Integration must apply the final cumulative sample before this call.
  void recordClosedConnection(String id) => _counters.close(id);

  /// Call only for a proven complete snapshot, after applying its samples.
  void reconcileCompleteSnapshot(Set<String> activeIds) =>
      _counters.reconcileCompleteSnapshot(activeIds);

  // Kept for source compatibility. Aggregates have one event source only.
  void recordTraffic({required int uploadDelta, required int downloadDelta}) {}

  void recordRequestSample({
    required String id,
    required int upload,
    required int download,
    required String host,
    String? process,
  }) {
    _accept(
      _counters.observe(
        id: id,
        upload: upload,
        download: download,
        host: host,
        process: process,
        baselineIfUnknown: false,
      ),
    );
  }

  void recordTrafficSample({
    required String id,
    required int upload,
    required int download,
  }) {
    _accept(
      _counters.observe(
        id: id,
        upload: upload,
        download: download,
        baselineIfUnknown: true,
      ),
    );
    // A batch is NOT assumed to be a complete active-connection snapshot.
  }

  void _accept(TrafficCounterDelta delta) {
    if (!delta.hasBytes && !delta.newCount) return;
    final now = _now();
    _pruneExpired(now);
    if (delta.hasBytes) {
      final date = _dateKey(now);
      final daily = _dailySummaries.putIfAbsent(
        date,
        () => DailyTrafficData(date: date),
      );
      daily.upload += delta.upload;
      daily.download += delta.download;
      final hourly = daily.hourly.putIfAbsent(
        now.hour,
        () => HourlyTrafficData(hour: now.hour),
      );
      hourly.upload += delta.upload;
      hourly.download += delta.download;
    }
    final host = delta.host;
    if (host != null) {
      final site = _targetSiteUsages.putIfAbsent(
        host,
        () => TargetSiteData(
          host: host,
          count: 0,
          lastSeen: now.millisecondsSinceEpoch,
          process: delta.process,
        ),
      );
      site.upload += delta.upload;
      site.download += delta.download;
      if (delta.newCount) site.count++;
      site.lastSeen = now.millisecondsSinceEpoch;
      site.process ??= delta.process;
      _revision++;
    }
    scheduleSave();
    _scheduleNotify();
  }

  void _notifyNow() {
    if (!_disposed) onChanged?.call();
  }

  void _scheduleNotify() {
    if (_disposed || !hasListeners) return;
    if (_notifyTimer?.isActive ?? false) {
      _pendingNotify = true;
      return;
    }
    _notifyNow();
    _pendingNotify = false;
    _notifyTimer = Timer(const Duration(milliseconds: 800), () {
      _notifyTimer = null;
      if (_pendingNotify) {
        _pendingNotify = false;
        _scheduleNotify();
      }
    });
  }

  void _scheduleMidnight() {
    _midnightTimer?.cancel();
    if (_disposed) return;
    final now = _now();
    _midnightTimer = Timer(_dayOffset(now, 1).difference(now), () {
      _pruneExpired(_now());
      _notifyNow();
      _scheduleMidnight();
    });
  }

  DailyTrafficData? get todayData {
    final data = _dailySummaries[_dateKey(_now())];
    return data == null ? null : DailyTrafficData.fromJson(data.toJson());
  }

  int get todayUpload => todayData?.upload ?? 0;
  int get todayDownload => todayData?.download ?? 0;
  int get todayTotal => todayUpload + todayDownload;
  DailyTrafficData? get yesterdayData {
    final data = _dailySummaries[_dateKey(_dayOffset(_now(), -1))];
    return data == null ? null : DailyTrafficData.fromJson(data.toJson());
  }

  int get yesterdayTotal => yesterdayData?.total ?? 0;
  int get differenceFromYesterday => todayTotal - yesterdayTotal;
  int get weekUpload => _sumDays(7, upload: true);
  int get weekDownload => _sumDays(7, upload: false);
  int get weekTotal => weekUpload + weekDownload;
  int get monthTotal =>
      _sumDays(30, upload: true) + _sumDays(30, upload: false);

  int _sumDays(int days, {required bool upload}) {
    final now = _now();
    var total = 0;
    for (var i = 0; i < days; i++) {
      final data = _dailySummaries[_dateKey(_dayOffset(now, -i))];
      total += (upload ? data?.upload : data?.download) ?? 0;
    }
    return total;
  }

  List<ChartBarPoint> getChartPoints(TrafficStatsRange range) {
    final now = _now();
    if (range == TrafficStatsRange.today) {
      final data = _dailySummaries[_dateKey(now)];
      return List.generate(24, (hour) {
        final label = hour.toString().padLeft(2, '0');
        final point = data?.hourly[hour];
        return ChartBarPoint(
          label: hour % 4 == 0 ? '$label:00' : '',
          fullLabel: '$label:00 - $label:59',
          upload: point?.upload ?? 0,
          download: point?.download ?? 0,
          isCurrent: hour == now.hour,
        );
      });
    }
    final days = switch (range) {
      TrafficStatsRange.week => 7,
      TrafficStatsRange.month => 30,
      TrafficStatsRange.all => maxDaysToKeep,
      TrafficStatsRange.today => throw StateError('Handled above'),
    };
    final labelStep = days <= 7 ? 1 : (days <= 30 ? 5 : 15);
    return List.generate(days, (index) {
      final date = _dayOffset(now, index - days + 1);
      final key = _dateKey(date);
      final data = _dailySummaries[key];
      return ChartBarPoint(
        label: (days - index - 1) % labelStep == 0
            ? '${date.month}/${date.day}'
            : '',
        fullLabel: key,
        upload: data?.upload ?? 0,
        download: data?.download ?? 0,
        isCurrent: index == days - 1,
      );
    });
  }

  List<TargetSiteData> getTopSites({int limit = 50}) {
    final effectiveLimit = math.max(0, limit);
    if (_cachedTopSites != null &&
        _cachedTopSitesRevision == _revision &&
        _cachedTopSitesLimit == effectiveLimit) {
      return _cachedTopSites!;
    }
    final sorted = _targetSiteUsages.values.toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    final result = List<TargetSiteData>.unmodifiable(
      sorted.take(effectiveLimit).map((site) => site.clone()).toList(),
    );
    _cachedTopSites = result;
    _cachedTopSitesRevision = _revision;
    _cachedTopSitesLimit = effectiveLimit;
    return result;
  }

  List<AggregatedSiteGroup> getAggregatedSites({int limit = 50}) {
    final effectiveLimit = math.max(0, limit);
    if (_cachedAggregatedSites != null &&
        _cachedAggregatedRevision == _revision &&
        _cachedAggregatedLimit == effectiveLimit) {
      return _cachedAggregatedSites!;
    }
    final groups = DomainClassifier.aggregateSites(_targetSiteUsages.values);
    final result = List<AggregatedSiteGroup>.unmodifiable(
      groups.take(effectiveLimit).toList(),
    );
    _cachedAggregatedSites = result;
    _cachedAggregatedRevision = _revision;
    _cachedAggregatedLimit = effectiveLimit;
    return result;
  }

  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _notifyTimer?.cancel();
    _midnightTimer?.cancel();
    onChanged = null;
  }
}
