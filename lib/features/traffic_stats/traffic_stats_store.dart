import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';

import 'domain_classifier.dart';
import 'traffic_stats_engine.dart';
import 'traffic_stats_models.dart';
import 'traffic_stats_persistence.dart';

/// Flutter/Core adapter. Accounting and storage coordination live in the engine.
class TrafficStatsStore extends ChangeNotifier {
  static TrafficStatsStore? _instance;
  static TrafficStatsStore get instance => _instance ??= TrafficStatsStore(
    persistence: JsonTrafficStatsPersistence(
      () async =>
          File(join(await appPath.homeDirPath, 'traffic_statistics.json')),
    ),
  );

  TrafficStatsStore({
    required TrafficStatsPersistence persistence,
    DateTime Function()? now,
  }) : _engine = TrafficStatsEngine(
         persistence: persistence,
         now: now,
         log: (message) => commonPrint.log(message),
       ) {
    _engine.onChanged = () {
      if (hasListeners) notifyListeners();
    };
  }

  final TrafficStatsEngine _engine;
  static const maxDaysToKeep = TrafficStatsEngine.maxDaysToKeep;
  static const maxSitesToKeep = TrafficStatsEngine.maxSitesToKeep;
  Object? get lastPersistenceError => _engine.lastPersistenceError;
  int get trackedConnections => _engine.trackedConnections;
  Map<String, DailyTrafficData> get dailySummaries => _engine.dailySummaries;
  Map<String, TargetSiteData> get targetSiteUsages => _engine.targetSiteUsages;
  DailyTrafficData? get todayData => _engine.todayData;
  DailyTrafficData? get yesterdayData => _engine.yesterdayData;
  int get todayUpload => _engine.todayUpload;
  int get todayDownload => _engine.todayDownload;
  int get todayTotal => _engine.todayTotal;
  int get yesterdayTotal => _engine.yesterdayTotal;
  int get differenceFromYesterday => _engine.differenceFromYesterday;
  int get weekUpload => _engine.weekUpload;
  int get weekDownload => _engine.weekDownload;
  int get weekTotal => _engine.weekTotal;
  int get monthTotal => _engine.monthTotal;
  Future<void> init() => _engine.init();
  Future<void> retryLoad() => _engine.retryLoad();
  Future<void> save() => _engine.save();
  void scheduleSave() => _engine.scheduleSave();
  Future<void> clearAll() => _engine.clearAll();
  List<ChartBarPoint> getChartPoints(TrafficStatsRange range) =>
      _engine.getChartPoints(range);
  List<TargetSiteData> getTopSites({int limit = 50}) =>
      _engine.getTopSites(limit: limit);
  List<AggregatedSiteGroup> getAggregatedSites({int limit = 50}) =>
      _engine.getAggregatedSites(limit: limit);
  void beginCoreEpoch(Object epoch) => _engine.beginCoreEpoch(epoch);
  void recordClosedConnection(String id) => _engine.recordClosedConnection(id);
  void reconcileCompleteSnapshot(Set<String> activeIds) =>
      _engine.reconcileCompleteSnapshot(activeIds);

  void recordRequest(TrackerInfo info) => _engine.recordRequestSample(
    id: info.id,
    upload: info.upload,
    download: info.download,
    host: DomainClassifier.stripPort(info.title),
    process: info.metadata.process.trim(),
  );

  void recordRequestTraffic(Map<String, RequestTraffic> trafficMap) {
    for (final entry in trafficMap.entries) {
      _engine.recordTrafficSample(
        id: entry.key,
        upload: entry.value.upload,
        download: entry.value.download,
      );
    }
  }

  void recordRequestTrafficSamples(List<RequestTrafficSample> samples) {
    for (final sample in samples) {
      _engine.recordTrafficSample(
        id: sample.id,
        upload: sample.upload,
        download: sample.download,
        host: sample.host,
        process: sample.process,
        isClosed: sample.closed,
      );
      if (sample.closed) _engine.recordClosedConnection(sample.id);
    }
  }

  void recordTraffic({required int uploadDelta, required int downloadDelta}) {}

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }
}
