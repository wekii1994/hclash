import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:path/path.dart' as p;

class _AggItem {
  int up = 0;
  int down = 0;
  int hits = 0;
  String path = '';
  final Map<String, _AggItem> subs = {};

  int get total => up + down;

  Map<String, dynamic> toJson() => {
        'up': up,
        'down': down,
        'hits': hits,
        if (path.isNotEmpty) 'path': path,
        if (subs.isNotEmpty)
          'subs': subs.map((k, v) => MapEntry(k, v.toJson())),
      };

  static _AggItem fromJson(Map<String, dynamic> json) {
    final item = _AggItem()
      ..up = (json['up'] as num?)?.toInt() ?? 0
      ..down = (json['down'] as num?)?.toInt() ?? 0
      ..hits = (json['hits'] as num?)?.toInt() ?? 0
      ..path = json['path'] as String? ?? '';
    final rawSubs = json['subs'];
    if (rawSubs is Map) {
      for (final entry in rawSubs.entries) {
        if (entry.value is Map) {
          item.subs[entry.key.toString()] = _AggItem.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
    }
    return item;
  }
}

class _DayBucket {
  final String date; // YYYY-MM-DD
  int up = 0;
  int down = 0;
  int proxyUp = 0;
  int proxyDown = 0;
  int ruleHits = 0;

  final Map<int, ({int up, int down})> hourly = {};
  final Map<String, _AggItem> hosts = {};
  final Map<String, _AggItem> processes = {};
  final Map<String, _AggItem> nodes = {};
  final Map<String, _AggItem> rules = {};
  final Map<String, _AggItem> profiles = {};

  _DayBucket(this.date);

  Map<String, dynamic> toJson() => {
        'date': date,
        'up': up,
        'down': down,
        'proxyUp': proxyUp,
        'proxyDown': proxyDown,
        'ruleHits': ruleHits,
        'hourly': hourly.map(
            (k, v) => MapEntry(k.toString(), {'up': v.up, 'down': v.down})),
        'hosts': hosts.map((k, v) => MapEntry(k, v.toJson())),
        'processes': processes.map((k, v) => MapEntry(k, v.toJson())),
        'nodes': nodes.map((k, v) => MapEntry(k, v.toJson())),
        'rules': rules.map((k, v) => MapEntry(k, v.toJson())),
        'profiles': profiles.map((k, v) => MapEntry(k, v.toJson())),
      };

  static _DayBucket fromJson(Map<String, dynamic> json) {
    final bucket = _DayBucket(json['date'] as String? ?? '')
      ..up = (json['up'] as num?)?.toInt() ?? 0
      ..down = (json['down'] as num?)?.toInt() ?? 0
      ..proxyUp = (json['proxyUp'] as num?)?.toInt() ?? 0
      ..proxyDown = (json['proxyDown'] as num?)?.toInt() ?? 0
      ..ruleHits = (json['ruleHits'] as num?)?.toInt() ?? 0;

    final rawHourly = json['hourly'];
    if (rawHourly is Map) {
      for (final entry in rawHourly.entries) {
        final hour = int.tryParse(entry.key.toString());
        if (hour != null && entry.value is Map) {
          final m = entry.value as Map;
          bucket.hourly[hour] = (
            up: (m['up'] as num?)?.toInt() ?? 0,
            down: (m['down'] as num?)?.toInt() ?? 0,
          );
        }
      }
    }

    void parseItems(dynamic raw, Map<String, _AggItem> target) {
      if (raw is Map) {
        for (final entry in raw.entries) {
          if (entry.value is Map) {
            target[entry.key.toString()] = _AggItem.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
          }
        }
      }
    }

    parseItems(json['hosts'], bucket.hosts);
    parseItems(json['processes'], bucket.processes);
    parseItems(json['nodes'], bucket.nodes);
    parseItems(json['rules'], bucket.rules);
    parseItems(json['profiles'], bucket.profiles);

    return bucket;
  }
}

class TrafficStatsEngine {
  static TrafficStatsEngine? _instance;
  static TrafficStatsEngine get instance =>
      _instance ??= TrafficStatsEngine._();

  TrafficStatsEngine._();

  TrafficStatsOptions _options =
      const TrafficStatsOptions(enable: true, detail: true);
  final Map<String, _DayBucket> _buckets = {};
  final Map<int, ({int up, int down})> _activeCounters = {};
  Timer? _flushTimer;
  bool _dirty = false;
  bool _loaded = false;

  TrafficStatsOptions get options => _options;

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    await _loadFromDisk();
  }

  void configure(TrafficStatsOptions options) {
    _options = options;
    _pruneOldDays();
    _scheduleFlush();
  }

  void recordTraffic({
    required int connectionId,
    required TrackerInfo tracker,
    required int totalUp,
    required int totalDown,
    bool isClosed = false,
  }) {
    if (!_options.enable) {
      if (isClosed) _activeCounters.remove(connectionId);
      return;
    }

    final prev = _activeCounters[connectionId] ?? (up: 0, down: 0);
    final upDiff = math.max(totalUp - prev.up, 0);
    final downDiff = math.max(totalDown - prev.down, 0);

    if (isClosed) {
      _activeCounters.remove(connectionId);
    } else {
      _activeCounters[connectionId] = (up: totalUp, down: totalDown);
    }

    if (upDiff == 0 && downDiff == 0) return;

    final now = DateTime.now();
    final dayKey = _formatDate(now);
    final bucket = _buckets.putIfAbsent(dayKey, () => _DayBucket(dayKey));

    bucket.up += upDiff;
    bucket.down += downDiff;

    final isProxy = tracker.chains.isNotEmpty &&
        tracker.chains.first.toUpperCase() != 'DIRECT' &&
        tracker.chains.first.toUpperCase() != 'REJECT';

    if (isProxy) {
      bucket.proxyUp += upDiff;
      bucket.proxyDown += downDiff;
    }

    final hour = now.hour;
    final hPrev = bucket.hourly[hour] ?? (up: 0, down: 0);
    bucket.hourly[hour] = (up: hPrev.up + upDiff, down: hPrev.down + downDiff);

    if (_options.detail) {
      final host = tracker.metadata.host.isNotEmpty
          ? tracker.metadata.host
          : tracker.metadata.destinationIP;
      if (host.isNotEmpty) {
        _accumulateItem(bucket.hosts, host, upDiff, downDiff);
      }

      final process = tracker.metadata.process;
      if (process.isNotEmpty) {
        _accumulateItem(bucket.processes, process, upDiff, downDiff);
      }

      final node = tracker.chains.isNotEmpty ? tracker.chains.first : 'DIRECT';
      _accumulateItem(bucket.nodes, node, upDiff, downDiff);

      final rule = tracker.rule.isNotEmpty ? tracker.rule : 'Match';
      _accumulateItem(bucket.rules, rule, upDiff, downDiff);
      bucket.ruleHits += 1;
    }

    _dirty = true;
    _scheduleFlush();
  }

  void _accumulateItem(
      Map<String, _AggItem> map, String key, int up, int down) {
    final item = map.putIfAbsent(key, () => _AggItem());
    item.up += up;
    item.down += down;
    item.hits += 1;
  }

  TrafficStatsResult query({required String start, required String end}) {
    _pruneOldDays();

    int totalUp = 0;
    int totalDown = 0;
    int totalProxyUp = 0;
    int totalProxyDown = 0;
    int totalRuleHits = 0;

    final isSingleDay = start == end;
    final seriesMap = <String, ({int up, int down})>{};
    final aggHosts = <String, _AggItem>{};
    final aggProcesses = <String, _AggItem>{};
    final aggNodes = <String, _AggItem>{};
    final aggRules = <String, _AggItem>{};
    final aggProfiles = <String, _AggItem>{};

    for (final entry in _buckets.entries) {
      final date = entry.key;
      if (date.compareTo(start) >= 0 && date.compareTo(end) <= 0) {
        final b = entry.value;
        totalUp += b.up;
        totalDown += b.down;
        totalProxyUp += b.proxyUp;
        totalProxyDown += b.proxyDown;
        totalRuleHits += b.ruleHits;

        if (isSingleDay) {
          for (var h = 0; h < 24; h++) {
            final label = '${h.toString().padLeft(2, '0')}:00';
            final cur = seriesMap[label] ?? (up: 0, down: 0);
            final hVal = b.hourly[h] ?? (up: 0, down: 0);
            seriesMap[label] =
                (up: cur.up + hVal.up, down: cur.down + hVal.down);
          }
        } else {
          final cur = seriesMap[date] ?? (up: 0, down: 0);
          seriesMap[date] = (up: cur.up + b.up, down: cur.down + b.down);
        }

        void merge(Map<String, _AggItem> src, Map<String, _AggItem> dst) {
          for (final s in src.entries) {
            final d = dst.putIfAbsent(s.key, () => _AggItem());
            d.up += s.value.up;
            d.down += s.value.down;
            d.hits += s.value.hits;
            if (s.value.path.isNotEmpty) d.path = s.value.path;
          }
        }

        merge(b.hosts, aggHosts);
        merge(b.processes, aggProcesses);
        merge(b.nodes, aggNodes);
        merge(b.rules, aggRules);
        merge(b.profiles, aggProfiles);
      }
    }

    final series = seriesMap.entries
        .map((e) =>
            TrafficStatsPoint(label: e.key, up: e.value.up, down: e.value.down))
        .toList();

    List<TrafficStatsItem> toSortedList(Map<String, _AggItem> map) {
      final list = map.entries
          .map((e) => TrafficStatsItem(
                name: e.key,
                up: e.value.up,
                down: e.value.down,
                hits: e.value.hits,
                path: e.value.path,
              ))
          .toList();
      list.sort((a, b) => b.total.compareTo(a.total));
      return list;
    }

    return TrafficStatsResult(
      up: totalUp,
      down: totalDown,
      proxyUp: totalProxyUp,
      proxyDown: totalProxyDown,
      series: series,
      hosts: toSortedList(aggHosts),
      processes: toSortedList(aggProcesses),
      nodes: toSortedList(aggNodes),
      rules: toSortedList(aggRules),
      profiles: toSortedList(aggProfiles),
      ruleHits: totalRuleHits,
      since: _buckets.keys.isEmpty ? '' : _buckets.keys.first,
    );
  }

  Future<void> clear() async {
    _buckets.clear();
    _activeCounters.clear();
    _dirty = false;
    final file = await _getDbFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  void _pruneOldDays() {
    final days = _options.retentionDays;
    if (days <= 0) return;
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final cutoffKey = _formatDate(cutoff);
    _buckets.removeWhere((key, _) => key.compareTo(cutoffKey) < 0);
  }

  String _formatDate(DateTime d) {
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<File> _getDbFile() async {
    final home = await appPath.homeDirPath;
    return File(p.join(home, 'traffic_stats_db.json'));
  }

  Future<void> _loadFromDisk() async {
    try {
      final file = await _getDbFile();
      if (!await file.exists()) return;
      final content = await file.readAsString();
      if (content.isEmpty) return;
      final json = jsonDecode(content);
      if (json is Map && json['buckets'] is Map) {
        final bMap = json['buckets'] as Map;
        for (final entry in bMap.entries) {
          if (entry.value is Map) {
            _buckets[entry.key.toString()] = _DayBucket.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
          }
        }
      }
    } catch (_) {}
  }

  void _scheduleFlush() {
    if (_flushTimer?.isActive ?? false) return;
    _flushTimer = Timer(const Duration(seconds: 15), () {
      flush();
    });
  }

  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      final file = await _getDbFile();
      final data = {
        'version': 1,
        'buckets': _buckets.map((k, v) => MapEntry(k, v.toJson())),
      };
      await file.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }
}
