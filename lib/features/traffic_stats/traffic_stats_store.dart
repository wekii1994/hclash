import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';

import 'traffic_stats_models.dart';

class TrafficStatsStore extends ChangeNotifier {
  static TrafficStatsStore? _instance;
  static TrafficStatsStore get instance => _instance ??= TrafficStatsStore._();

  TrafficStatsStore._();

  final Map<String, DailyTrafficData> _dailySummaries = {};
  final Map<String, TargetSiteData> _targetSiteUsages = {};
  final Map<String, String> _requestIdToHost = {};
  final Map<String, ({int upload, int download})> _requestIdToTraffic = {};

  bool _isLoaded = false;
  Timer? _saveDebounceTimer;
  DateTime? _lastSaveTime;
  Timer? _uiThrottleTimer;
  bool _needsNotify = false;

  static const int maxDaysToKeep = 90;
  static const int maxSitesToKeep = 200;

  Map<String, DailyTrafficData> get dailySummaries => _dailySummaries;
  Map<String, TargetSiteData> get targetSiteUsages => _targetSiteUsages;

  String _dateKey(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<File> _getFile() async {
    final homeDirPath = await appPath.homeDirPath;
    return File(join(homeDirPath, 'traffic_statistics.json'));
  }

  Future<void> init() async {
    if (_isLoaded) return;
    try {
      final file = await _getFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final data = json.decode(content);
          if (data is Map) {
            final rawDaily = data['daily'];
            if (rawDaily is Map) {
              rawDaily.forEach((k, v) {
                if (v is Map) {
                  final loaded = DailyTrafficData.fromJson(
                    Map<String, dynamic>.from(v),
                  );
                  final existing = _dailySummaries[k.toString()];
                  if (existing != null) {
                    loaded.upload += existing.upload;
                    loaded.download += existing.download;
                    existing.hourly.forEach((hour, hData) {
                      final targetH = loaded.hourly.putIfAbsent(
                        hour,
                        () => HourlyTrafficData(hour: hour),
                      );
                      targetH.upload += hData.upload;
                      targetH.download += hData.download;
                    });
                  }
                  _dailySummaries[k.toString()] = loaded;
                }
              });
            }
            final rawSites = data['sites'];
            if (rawSites is Map) {
              rawSites.forEach((k, v) {
                if (v is Map) {
                  final loaded = TargetSiteData.fromJson(
                    Map<String, dynamic>.from(v),
                  );
                  final existing = _targetSiteUsages[k.toString()];
                  if (existing != null) {
                    loaded.upload += existing.upload;
                    loaded.download += existing.download;
                    loaded.count += existing.count;
                    if ((loaded.process == null || loaded.process!.isEmpty) &&
                        existing.process != null) {
                      loaded.process = existing.process;
                    }
                  }
                  _targetSiteUsages[k.toString()] = loaded;
                }
              });
            }
          }
        }
      }
      _pruneOldData();
      _reconcileTodayData();
      _isLoaded = true;
      notifyListeners();
    } catch (e) {
      commonPrint.log('TrafficStatsStore init error: $e');
      _isLoaded = true;
    }
  }

  void _pruneOldData() {
    final cutoff = DateTime.now().subtract(const Duration(days: maxDaysToKeep));
    final cutoffKey = _dateKey(cutoff);
    _dailySummaries.removeWhere((key, _) => key.compareTo(cutoffKey) < 0);

    if (_targetSiteUsages.length > maxSitesToKeep) {
      final sortedEntries = _targetSiteUsages.entries.toList()
        ..sort((a, b) => b.value.total.compareTo(a.value.total));
      _targetSiteUsages.clear();
      for (final entry in sortedEntries.take(maxSitesToKeep)) {
        _targetSiteUsages[entry.key] = entry.value;
      }
    }
  }

  void scheduleSave() {
    final now = DateTime.now();
    if (_lastSaveTime != null &&
        now.difference(_lastSaveTime!) > const Duration(seconds: 60)) {
      save();
      return;
    }
    _saveDebounceTimer ??= Timer(const Duration(seconds: 30), () async {
      _saveDebounceTimer = null;
      await save();
    });
  }

  Future<void> save() async {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _lastSaveTime = DateTime.now();
    try {
      final file = await _getFile();
      final data = {
        'daily': _dailySummaries.map((k, v) => MapEntry(k, v.toJson())),
        'sites': _targetSiteUsages.map((k, v) => MapEntry(k, v.toJson())),
      };
      await file.writeAsString(json.encode(data), flush: true);
    } catch (e) {
      commonPrint.log('TrafficStatsStore save error: $e');
    }
  }

  void _scheduleNotify() {
    if (!hasListeners) return;
    if (_uiThrottleTimer?.isActive ?? false) {
      _needsNotify = true;
      return;
    }
    notifyListeners();
    _needsNotify = false;
    _uiThrottleTimer = Timer(const Duration(milliseconds: 800), () {
      if (_needsNotify && hasListeners) {
        _needsNotify = false;
        notifyListeners();
      }
    });
  }

  void _accumulate({required int uploadDelta, required int downloadDelta}) {
    if (uploadDelta <= 0 && downloadDelta <= 0) return;

    final now = DateTime.now();
    final todayKey = _dateKey(now);
    final hour = now.hour;

    final daily = _dailySummaries.putIfAbsent(
      todayKey,
      () => DailyTrafficData(date: todayKey),
    );
    daily.upload += uploadDelta;
    daily.download += downloadDelta;

    final hourly = daily.hourly.putIfAbsent(
      hour,
      () => HourlyTrafficData(hour: hour),
    );
    hourly.upload += uploadDelta;
    hourly.download += downloadDelta;
  }

  void _reconcileTodayData() {
    final todayKey = _dateKey(DateTime.now());
    final todayDaily = _dailySummaries[todayKey];
    var sitesUp = 0;
    var sitesDown = 0;
    for (final s in _targetSiteUsages.values) {
      sitesUp += s.upload;
      sitesDown += s.download;
    }
    if (todayDaily == null) {
      if (sitesUp > 0 || sitesDown > 0) {
        final d = DailyTrafficData(
          date: todayKey,
          upload: sitesUp,
          download: sitesDown,
        );
        final hour = DateTime.now().hour;
        d.hourly[hour] = HourlyTrafficData(
          hour: hour,
          upload: sitesUp,
          download: sitesDown,
        );
        _dailySummaries[todayKey] = d;
      }
    } else if (todayDaily.total < (sitesUp + sitesDown)) {
      final missingUp = (sitesUp - todayDaily.upload).clamp(0, sitesUp);
      final missingDown = (sitesDown - todayDaily.download).clamp(0, sitesDown);
      todayDaily.upload += missingUp;
      todayDaily.download += missingDown;
      final hour = DateTime.now().hour;
      final h = todayDaily.hourly.putIfAbsent(
        hour,
        () => HourlyTrafficData(hour: hour),
      );
      h.upload += missingUp;
      h.download += missingDown;
    }
  }

  void recordTraffic({required int uploadDelta, required int downloadDelta}) {
    if (uploadDelta <= 0 && downloadDelta <= 0) return;
    _accumulate(uploadDelta: uploadDelta, downloadDelta: downloadDelta);
    scheduleSave();
    _scheduleNotify();
  }

  void recordRequest(TrackerInfo info) {
    var host = info.title.trim();
    if (host.isEmpty) return;

    if (host.contains(':')) {
      final parts = host.split(':');
      if (parts.length == 2 && int.tryParse(parts[1]) != null) {
        host = parts[0];
      }
    }

    _requestIdToHost[info.id] = host;
    if (info.upload > 0 || info.download > 0) {
      _requestIdToTraffic[info.id] = (
        upload: info.upload,
        download: info.download,
      );
    }
    if (_requestIdToHost.length > 2000) {
      final toRemove = _requestIdToHost.keys.take(500).toList();
      for (final k in toRemove) {
        _requestIdToHost.remove(k);
        _requestIdToTraffic.remove(k);
      }
    }

    final process = info.metadata.process.trim();

    final site = _targetSiteUsages.putIfAbsent(
      host,
      () => TargetSiteData(
        host: host,
        upload: 0,
        download: 0,
        count: 0,
        process: process.isNotEmpty ? process : null,
      ),
    );
    site.upload += info.upload;
    site.download += info.download;
    site.count++;
    site.lastSeen = DateTime.now().millisecondsSinceEpoch;
    if ((site.process == null || site.process!.isEmpty) && process.isNotEmpty) {
      site.process = process;
    }

    if (info.upload > 0 || info.download > 0) {
      _accumulate(
        uploadDelta: info.upload > 0 ? info.upload : 0,
        downloadDelta: info.download > 0 ? info.download : 0,
      );
    }

    scheduleSave();
    _scheduleNotify();
  }

  void recordRequestTraffic(Map<String, RequestTraffic> trafficMap) {
    if (trafficMap.isEmpty) return;
    var hasUpdates = false;

    trafficMap.forEach((id, traffic) {
      final host = _requestIdToHost[id];

      final last = _requestIdToTraffic[id];
      final lastUp = last?.upload ?? 0;
      final lastDown = last?.download ?? 0;

      final deltaUp = traffic.upload - lastUp;
      final deltaDown = traffic.download - lastDown;

      _requestIdToTraffic[id] = (
        upload: traffic.upload,
        download: traffic.download,
      );

      if (deltaUp > 0 || deltaDown > 0) {
        if (host != null && host.isNotEmpty) {
          final site = _targetSiteUsages[host];
          if (site != null) {
            if (deltaUp > 0) site.upload += deltaUp;
            if (deltaDown > 0) site.download += deltaDown;
            site.lastSeen = DateTime.now().millisecondsSinceEpoch;
          }
        }

        _accumulate(
          uploadDelta: deltaUp > 0 ? deltaUp : 0,
          downloadDelta: deltaDown > 0 ? deltaDown : 0,
        );
        hasUpdates = true;
      }
    });

    if (hasUpdates) {
      scheduleSave();
      _scheduleNotify();
    }
  }

  @override
  void dispose() {
    _saveDebounceTimer?.cancel();
    _uiThrottleTimer?.cancel();
    super.dispose();
  }

  DailyTrafficData? get todayData => _dailySummaries[_dateKey(DateTime.now())];

  int get todayUpload => todayData?.upload ?? 0;
  int get todayDownload => todayData?.download ?? 0;
  int get todayTotal => todayUpload + todayDownload;

  DailyTrafficData? get yesterdayData {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    return _dailySummaries[_dateKey(yesterday)];
  }

  int get yesterdayTotal =>
      (yesterdayData?.upload ?? 0) + (yesterdayData?.download ?? 0);

  int get differenceFromYesterday => todayTotal - yesterdayTotal;

  int get weekTotal {
    final now = DateTime.now();
    var sum = 0;
    for (var i = 0; i < 7; i++) {
      final date = now.subtract(Duration(days: i));
      final data = _dailySummaries[_dateKey(date)];
      if (data != null) {
        sum += data.total;
      }
    }
    return sum;
  }

  int get monthTotal {
    final now = DateTime.now();
    var sum = 0;
    for (var i = 0; i < 30; i++) {
      final date = now.subtract(Duration(days: i));
      final data = _dailySummaries[_dateKey(date)];
      if (data != null) {
        sum += data.total;
      }
    }
    return sum;
  }

  List<ChartBarPoint> getChartPoints(TrafficStatsRange range) {
    final now = DateTime.now();
    switch (range) {
      case TrafficStatsRange.today:
        final today = todayData;
        final currentHour = now.hour;
        return List.generate(24, (h) {
          final hourly = today?.hourly[h];
          final hourStr = h.toString().padLeft(2, '0');
          return ChartBarPoint(
            label: h % 4 == 0 ? '$hourStr:00' : '',
            fullLabel: '$hourStr:00 - $hourStr:59',
            upload: hourly?.upload ?? 0,
            download: hourly?.download ?? 0,
            isCurrent: h == currentHour,
          );
        });

      case TrafficStatsRange.week:
        // Last 7 days, left-to-right (oldest to newest)
        return List.generate(7, (i) {
          final d = now.subtract(Duration(days: 6 - i));
          final key = _dateKey(d);
          final data = _dailySummaries[key];
          final dayStr = '${d.month}/${d.day}';
          return ChartBarPoint(
            label: dayStr,
            fullLabel: key,
            upload: data?.upload ?? 0,
            download: data?.download ?? 0,
            isCurrent: i == 6,
          );
        });

      case TrafficStatsRange.month:
        // Last 30 days
        return List.generate(30, (i) {
          final d = now.subtract(Duration(days: 29 - i));
          final key = _dateKey(d);
          final data = _dailySummaries[key];
          final dayStr = '${d.month}/${d.day}';
          return ChartBarPoint(
            label: (29 - i) % 5 == 0 ? dayStr : '',
            fullLabel: key,
            upload: data?.upload ?? 0,
            download: data?.download ?? 0,
            isCurrent: i == 29,
          );
        });

      case TrafficStatsRange.all:
        if (_dailySummaries.isEmpty) {
          return [
            ChartBarPoint(
              label: '${now.month}/${now.day}',
              fullLabel: _dateKey(now),
              upload: 0,
              download: 0,
              isCurrent: true,
            ),
          ];
        }
        final sortedKeys = _dailySummaries.keys.toList()..sort();
        final takeCount = math.min(sortedKeys.length, 60);
        final recentKeys = sortedKeys.sublist(sortedKeys.length - takeCount);
        return recentKeys.map((key) {
          final data = _dailySummaries[key]!;
          final parts = key.split('-');
          final label = parts.length == 3 ? '${parts[1]}/${parts[2]}' : key;
          return ChartBarPoint(
            label: label,
            fullLabel: key,
            upload: data.upload,
            download: data.download,
            isCurrent: key == _dateKey(now),
          );
        }).toList();
    }
  }

  List<TargetSiteData> getTopSites({int limit = 50}) {
    final list = _targetSiteUsages.values.toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return list.take(limit).toList();
  }

  Future<void> clearAll() async {
    _dailySummaries.clear();
    _targetSiteUsages.clear();
    _requestIdToHost.clear();
    _requestIdToTraffic.clear();
    try {
      final file = await _getFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
    notifyListeners();
  }
}
