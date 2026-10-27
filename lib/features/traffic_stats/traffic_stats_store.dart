import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';

import 'domain_classifier.dart';
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
  Future<void>? _initFuture;
  Future<void>? _activeSaveFuture;
  bool _isSaving = false;
  bool _hasPendingSave = false;
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

  Future<void> init() {
    if (_isLoaded) return Future.value();
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
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
                    if (existing.lastSeen > loaded.lastSeen) {
                      loaded.lastSeen = existing.lastSeen;
                    }
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

    // 当站点数量显著超出阈值时再裁剪，兼顾活跃度与总流量
    if (_targetSiteUsages.length > maxSitesToKeep) {
      final sortedEntries = _targetSiteUsages.entries.toList()
        ..sort((a, b) => b.value.total.compareTo(a.value.total));
      _targetSiteUsages
        ..clear()
        ..addEntries(sortedEntries.take(maxSitesToKeep));
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
    _pruneOldData();

    if (_isSaving) {
      _hasPendingSave = true;
      return _activeSaveFuture ?? Future.value();
    }

    _isSaving = true;
    _activeSaveFuture = _doSaveLoop();
    return _activeSaveFuture!;
  }

  Future<void> _doSaveLoop() async {
    try {
      do {
        _hasPendingSave = false;
        final file = await _getFile();
        final tmpFile = File('${file.path}.tmp');
        final data = {
          'daily': _dailySummaries.map((k, v) => MapEntry(k, v.toJson())),
          'sites': _targetSiteUsages.map((k, v) => MapEntry(k, v.toJson())),
        };
        await tmpFile.writeAsString(json.encode(data), flush: true);
        if (await tmpFile.exists()) {
          await tmpFile.rename(file.path);
        }
      } while (_hasPendingSave);
    } catch (e) {
      commonPrint.log('TrafficStatsStore save error: $e');
    } finally {
      _isSaving = false;
      _activeSaveFuture = null;
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

  /// [recordTraffic] 保持空实现，确保 [_dailySummaries]
  /// 仅由连接级事件 ([recordRequest] 与 [recordRequestTraffic]) 唯一驱动，杜绝双重累计
  void recordTraffic({required int uploadDelta, required int downloadDelta}) {
    // Intentionally no-op to prevent dual-accumulation
  }

  void recordRequest(TrackerInfo info) {
    final host = DomainClassifier.stripPort(info.title);
    if (host.isEmpty) return;

    final prev = _requestIdToTraffic[info.id];
    final isNewConnection = prev == null;
    final int deltaUp;
    final int deltaDown;

    if (prev != null) {
      deltaUp = math.max(0, info.upload - prev.upload);
      deltaDown = math.max(0, info.download - prev.download);
      _requestIdToTraffic[info.id] = (
        upload: math.max(prev.upload, info.upload),
        download: math.max(prev.download, info.download),
      );
    } else {
      deltaUp = math.max(0, info.upload);
      deltaDown = math.max(0, info.download);
      _requestIdToTraffic[info.id] = (
        upload: deltaUp,
        download: deltaDown,
      );
    }

    _requestIdToHost.remove(info.id);
    _requestIdToHost[info.id] = host;

    if (_requestIdToHost.length > 3000) {
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
    if (deltaUp > 0) site.upload += deltaUp;
    if (deltaDown > 0) site.download += deltaDown;
    if (isNewConnection) {
      site.count++;
    }
    site.lastSeen = DateTime.now().millisecondsSinceEpoch;
    if ((site.process == null || site.process!.isEmpty) && process.isNotEmpty) {
      site.process = process;
    }

    if (deltaUp > 0 || deltaDown > 0) {
      _accumulate(
        uploadDelta: deltaUp,
        downloadDelta: deltaDown,
      );
    }

    scheduleSave();
    _scheduleNotify();
  }

  void recordRequestTraffic(Map<String, RequestTraffic> trafficMap) {
    if (trafficMap.isEmpty) return;
    var hasUpdates = false;

    trafficMap.forEach((id, traffic) {
      // LRU 保活：如果已有该连接的 host 映射，重新插入至 LinkedHashMap 尾部
      final host = _requestIdToHost.remove(id);
      if (host != null) {
        _requestIdToHost[id] = host;
      }

      final last = _requestIdToTraffic[id];
      // 若之前未见过该连接（例如启动前已存在的连接），仅记录当前基准值，避免把历史累计当成增量
      if (last == null) {
        _requestIdToTraffic[id] = (
          upload: traffic.upload,
          download: traffic.download,
        );
        return;
      }

      final deltaUp = traffic.upload - last.upload;
      final deltaDown = traffic.download - last.download;

      _requestIdToTraffic[id] = (
        upload: traffic.upload,
        download: traffic.download,
      );

      if (deltaUp > 0 || deltaDown > 0) {
        final currentHost = host ?? _requestIdToHost[id];
        if (currentHost != null && currentHost.isNotEmpty) {
          final site = _targetSiteUsages[currentHost];
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

    // 优化长连接 Host 映射与流量缓存淘汰：当数量超出阈值时，优先淘汰非活跃连接
    if (_requestIdToHost.length > 3000) {
      _requestIdToHost.removeWhere(
        (id, _) => !trafficMap.containsKey(id),
      );
      if (_requestIdToHost.length > 3000) {
        final toRemove = _requestIdToHost.keys.take(_requestIdToHost.length - 2500).toList();
        for (final k in toRemove) {
          _requestIdToHost.remove(k);
        }
      }
    }

    if (_requestIdToTraffic.length > 3000) {
      _requestIdToTraffic.removeWhere(
        (id, _) => !trafficMap.containsKey(id) && !_requestIdToHost.containsKey(id),
      );
      if (_requestIdToTraffic.length > 3000) {
        final toRemove = _requestIdToTraffic.keys.take(_requestIdToTraffic.length - 2500).toList();
        for (final k in toRemove) {
          _requestIdToTraffic.remove(k);
        }
      }
    }

    if (hasUpdates) {
      scheduleSave();
      _scheduleNotify();
    }
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

  int get weekUpload {
    final now = DateTime.now();
    var sum = 0;
    for (var i = 0; i < 7; i++) {
      final data = _dailySummaries[_dateKey(now.subtract(Duration(days: i)))];
      if (data != null) sum += data.upload;
    }
    return sum;
  }

  int get weekDownload {
    final now = DateTime.now();
    var sum = 0;
    for (var i = 0; i < 7; i++) {
      final data = _dailySummaries[_dateKey(now.subtract(Duration(days: i)))];
      if (data != null) sum += data.download;
    }
    return sum;
  }

  int get weekTotal => weekUpload + weekDownload;

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
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _uiThrottleTimer?.cancel();
    _uiThrottleTimer = null;
    _needsNotify = false;
    _lastSaveTime = null;

    if (_activeSaveFuture != null) {
      try {
        await _activeSaveFuture;
      } catch (_) {}
    }

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

