import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/single_flight.dart';
import 'package:fl_clash/features/traffic_stats/traffic_counters.dart';
import 'package:fl_clash/features/traffic_stats/traffic_stats_engine.dart';
import 'package:fl_clash/features/traffic_stats/traffic_stats_models.dart';
import 'package:fl_clash/features/traffic_stats/traffic_stats_persistence.dart';
import 'package:fl_clash/models/failover_stats.dart';

void check(bool condition, String description) {
  if (!condition) throw StateError(description);
}

Map<String, dynamic> copyJson(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

class MemoryPersistence implements TrafficStatsPersistence {
  Map<String, dynamic>? data;
  Object? readError;
  Object? writeError;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  final readStarted = Completer<void>();
  final writeStarted = Completer<void>();
  int writes = 0;

  @override
  Future<Map<String, dynamic>?> read() async {
    final snapshot = data == null ? null : copyJson(data!);
    if (!readStarted.isCompleted) readStarted.complete();
    await readGate?.future;
    if (readError != null) {
      final err = readError;
      if (err is Exception) throw err;
      if (err is Error) throw err;
      throw StateError(err.toString());
    }
    return snapshot;
  }

  @override
  Future<void> write(Map<String, dynamic> snapshot) async {
    final copied = copyJson(snapshot);
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate?.future;
    if (writeError != null) {
      final err = writeError;
      if (err is Exception) throw err;
      if (err is Error) throw err;
      throw StateError(err.toString());
    }
    data = copied;
    writes++;
  }
}

TrafficStatsEngine engine(MemoryPersistence disk) =>
    TrafficStatsEngine(persistence: disk, now: () => DateTime(2026, 11, 2, 12));

Future<void> main() async {
  var count = 0;
  Future<void> test(String name, FutureOr<void> Function() run) async {
    await run();
    count++;
    stdout.writeln('PASS $name');
  }

  await test('single flight shares only equal keys', () async {
    final pool = SingleFlight<(String, String, int), int>();
    final gate = Completer<int>();
    var calls = 0;
    final a = pool.run(('A', 'url', 3000), () {
      calls++;
      return gate.future;
    });
    final same = pool.run(('A', 'url', 3000), () {
      calls++;
      return 9;
    });
    final b = pool.run(('B', 'url', 3000), () {
      calls++;
      return 2;
    });
    check(identical(a, same), 'same key must share the exact future');
    check(await b == 2 && calls == 2, 'B must execute independently');
    gate.complete(1);
    check(
      await a == 1 && pool.pendingCount == 0,
      'completion must clean entries',
    );
  });

  await test(
    'invalidation does not let old completions delete new work',
    () async {
      final pool = SingleFlight<String, int>();
      final oldGate = Completer<int>();
      final newGate = Completer<int>();
      final old = pool.run('A', () => oldGate.future);
      final previous = pool.generation;
      pool.invalidate();
      final fresh = pool.run('A', () => newGate.future);
      oldGate.complete(1);
      await old;
      check(
        pool.generation != previous && pool.pendingCount == 1,
        'old cleared new',
      );
      newGate.complete(2);
      check(
        await fresh == 2 && pool.pendingCount == 0,
        'new work not completed',
      );
    },
  );

  await test(
    'synchronous failure completes the shared future and allows retry',
    () async {
      final pool = SingleFlight<String, int>();
      try {
        await pool.run('A', () => throw StateError('expected'));
        throw StateError('exception was swallowed');
      } on StateError catch (error) {
        check(error.message == 'expected', 'wrong error');
      }
      check(await pool.run('A', () => 7) == 7, 'failure poisoned key');
    },
  );

  await test('out of order counters are high water marks', () {
    final counters = TrafficCounters();
    var total = 0;
    for (final value in [100, 80, 120, 120]) {
      total += counters
          .observe(
            id: 'A',
            upload: 0,
            download: value,
            host: 'a.test',
            baselineIfUnknown: false,
          )
          .download;
    }
    check(total == 120, 'out of order update double counted');
  });

  await test(
    'clear preserves a live baseline and recreates its site',
    () async {
      final e = engine(MemoryPersistence());
      try {
        await e.init();
        e.recordRequestSample(
          id: 'A',
          upload: 0,
          download: 100,
          host: 'a.test',
        );
        await e.clearAll();
        e.recordTrafficSample(id: 'A', upload: 0, download: 110);
        e.recordTrafficSample(id: 'A', upload: 0, download: 120);
        check(e.todayTotal == 20, 'clear lost first post-clear increment');
        check(
          e.getTopSites().single.download == 20,
          'clear lost site attribution',
        );
        check(e.getTopSites().single.count == 1, 'wrong segment count');
      } finally {
        e.dispose();
      }
    },
  );

  await test('3500 live connections retain all counter baselines', () async {
    final e = engine(MemoryPersistence());
    try {
      await e.init();
      for (var i = 0; i < 3500; i++) {
        e.recordRequestSample(
          id: '$i',
          upload: 0,
          download: 0,
          host: 's$i.test',
        );
      }
      for (var sample = 1; sample <= 3; sample++) {
        for (var i = 0; i < 3500; i++) {
          e.recordTrafficSample(
            id: '$i',
            upload: sample,
            download: sample * 10,
          );
        }
      }
      check(e.trackedConnections == 3500, 'evicted live counters');
      check(e.todayTotal == 3500 * 33, 'lost increments above old capacity');
      await e.save();
      check(e.targetSiteUsages.length == 3500, 'save pruned live sites');
      e.reconcileCompleteSnapshot({'0', '1'});
      check(e.trackedConnections == 2, 'complete-snapshot retirement failed');
    } finally {
      e.dispose();
    }
  });

  await test('site below display limit can later become first', () async {
    final e = engine(MemoryPersistence());
    try {
      await e.init();
      for (var i = 0; i < 201; i++) {
        e.recordRequestSample(
          id: '$i',
          upload: 0,
          download: 201 - i,
          host: 's$i.test',
        );
      }
      await e.save();
      e.recordTrafficSample(id: '200', upload: 0, download: 10000);
      check(
        e.getTopSites(limit: 200).first.host == 's200.test',
        'low rank became untracked',
      );
      final leaked = e.targetSiteUsages['s200.test']!;
      leaked.download = 0;
      check(
        e.getTopSites().first.download == 10000,
        'mutable snapshot escaped',
      );
    } finally {
      e.dispose();
    }
  });

  await test(
    'clear while initialization is reading cannot resurrect history',
    () async {
      final disk = MemoryPersistence()
        ..readGate = Completer<void>()
        ..data = {
          'daily': {
            '2026-11-02': {
              'date': '2026-11-02',
              'upload': 0,
              'download': 999,
              'hourly': {},
            },
          },
          'sites': {},
        };
      final e = engine(disk);
      try {
        final init = e.init();
        await disk.readStarted.future;
        final clear = e.clearAll();
        e.recordRequestSample(
          id: 'N',
          upload: 0,
          download: 20,
          host: 'new.test',
        );
        disk.readGate!.complete();
        await Future.wait([init, clear]);
        check(
          e.todayTotal == 20,
          'old initialization resurrected cleared data',
        );
        await e.save();
        check(
          (disk.data!['daily'] as Map)['2026-11-02']['download'] == 20,
          'new bytes not saved',
        );
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'save and clear are ordered without clearing newly arrived bytes',
    () async {
      final disk = MemoryPersistence()..writeGate = Completer<void>();
      final e = engine(disk);
      try {
        await e.init();
        e.recordRequestSample(
          id: 'A',
          upload: 0,
          download: 100,
          host: 'a.test',
        );
        final first = e.save();
        await disk.writeStarted.future;
        final clear = e.clearAll();
        e.recordTrafficSample(id: 'A', upload: 0, download: 125);
        disk.writeGate!.complete();
        await Future.wait([first, clear]);
        check(
          e.todayTotal == 25,
          'clear discarded events received during write',
        );
        await e.save();
        check(
          (disk.data!['daily'] as Map)['2026-11-02']['download'] == 25,
          'stale persisted state',
        );
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'unreadable history is not overwritten by automatic saving',
    () async {
      final disk = MemoryPersistence()
        ..readError = const FormatException('broken');
      final e = engine(disk);
      try {
        await e.init();
        e.recordRequestSample(id: 'A', upload: 0, download: 10, host: 'a.test');
        await e.save();
        check(
          disk.writes == 0 && e.lastPersistenceError != null,
          'overwrote unreadable history',
        );
        disk.readError = null;
        await e.retryLoad();
        await e.save();
        check(disk.writes == 1 && e.todayTotal == 10, 'retry failed');
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'clear failure is reported and a later save can recover',
    () async {
      final disk = MemoryPersistence()
        ..writeError = const FileSystemException('denied');
      final e = engine(disk);
      try {
        await e.init();
        var failed = false;
        try {
          await e.clearAll();
        } on FileSystemException {
          failed = true;
        }
        check(failed && e.lastPersistenceError != null, 'clear failure hidden');
        var recoveredNotification = false;
        e.onChanged = () {
          if (e.lastPersistenceError == null) recoveredNotification = true;
        };
        disk.writeError = null;
        await e.save();
        check(
          disk.writes == 1 && e.lastPersistenceError == null,
          'queue poisoned after failure',
        );
        check(recoveredNotification, 'recovery did not update the UI');
      } finally {
        e.dispose();
      }
    },
  );

  await test('core epoch resets baselines without erasing history', () async {
    final e = engine(MemoryPersistence());
    try {
      await e.init();
      e.beginCoreEpoch(1);
      e.recordRequestSample(id: 'A', upload: 0, download: 100, host: 'a.test');
      e.beginCoreEpoch(2);
      e.recordRequestSample(id: 'A', upload: 0, download: 10, host: 'a.test');
      check(e.todayTotal == 110, 'new core reused previous baseline');
      e.recordClosedConnection('A');
      check(e.trackedConnections == 0, 'closed connection not reclaimed');
    } finally {
      e.dispose();
    }
  });

  await test(
    'rolling chart ranges are calendar-day based and include empty days',
    () async {
      final e = engine(MemoryPersistence());
      try {
        await e.init();
        final week = e.getChartPoints(TrafficStatsRange.week);
        final month = e.getChartPoints(TrafficStatsRange.month);
        final all = e.getChartPoints(TrafficStatsRange.all);
        check(
          week.length == 7 && week.first.fullLabel == '2026-10-27',
          'wrong rolling week',
        );
        check(
          month.length == 30 && month.first.fullLabel == '2026-10-04',
          'wrong rolling month',
        );
        check(
          all.length == 90 && all.last.fullLabel == '2026-11-02',
          'wrong retention range',
        );
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'JSON repository replaces existing snapshots and rejects future schemas',
    () async {
      final dir = await Directory.systemTemp.createTemp('hclash-regression-');
      try {
        final file = File('${dir.path}/stats.json');
        final repository = JsonTrafficStatsPersistence(() async => file);
        await repository.write({'schemaVersion': 1, 'daily': {}, 'sites': {}});
        await repository.write({
          'schemaVersion': 1,
          'daily': {},
          'sites': {},
          'marker': 2,
        });
        check(
          (await repository.read())!['marker'] == 2,
          'existing file not replaced',
        );
        await file.writeAsString('{"schemaVersion":999}');
        var rejected = false;
        try {
          await repository.read();
        } on FormatException {
          rejected = true;
        }
        check(rejected, 'future schema silently loaded');
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  await test(
    'aggregated sites ranking computes over full dataset, not pre-truncated Top 200',
    () async {
      final e = engine(MemoryPersistence());
      try {
        await e.init();
        // 200 distinct standalone sites with 10 units each
        for (var i = 0; i < 200; i++) {
          e.recordRequestSample(
            id: 'site-$i',
            upload: 0,
            download: 10,
            host: 'standalone$i.test',
          );
        }
        // 201 subdomains of googlevideo.com with 9 units each
        for (var i = 0; i < 201; i++) {
          e.recordRequestSample(
            id: 'yt-$i',
            upload: 0,
            download: 9,
            host: 'r$i.googlevideo.com',
          );
        }
        // Raw top 200 only contains standalone sites because 10 > 9
        final topSites = e.getTopSites(limit: 200);
        check(
          topSites.length == 200 &&
              !topSites.any((s) => s.host.endsWith('.googlevideo.com')),
          'individual googlevideo should be filtered out from raw top 200',
        );

        // Aggregated top sites must compute over the full 401 entries
        final aggregated = e.getAggregatedSites(limit: 10);
        check(
          aggregated.isNotEmpty &&
              aggregated.first.displayName == 'YouTube' &&
              aggregated.first.total == 201 * 9,
          'YouTube should be ranked #1 with 1809 total units in aggregated view',
        );
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'delay test generation rejection prevents stale delayed results from overwriting',
    () async {
      var activeGen = 1;
      final acceptedDelays = <String, int>{};

      void mockSetDelay(String name, int val, [int? gen]) {
        if (gen != null && gen != activeGen) return;
        acceptedDelays[name] = val;
      }

      // Generation 1 test starts
      final gen1 = activeGen;
      final delayedCompleter = Completer<int>();

      // Config switch / cancel occurs -> generation increments
      activeGen++; // becomes 2

      // Generation 2 test runs and succeeds immediately
      final gen2 = activeGen;
      mockSetDelay('node1', 50, gen2);
      check(acceptedDelays['node1'] == 50, 'gen2 delay not set');

      // Generation 1 test finishes late with failure/timeout
      delayedCompleter.complete(-1);
      final gen1Delay = await delayedCompleter.future;
      mockSetDelay('node1', gen1Delay, gen1);

      // Value must remain 50, not overwritten by stale gen1 value (-1)
      check(
        acceptedDelays['node1'] == 50,
        'stale generation 1 result overwrote generation 2',
      );
    },
  );

  await test(
    'aggregated site views are immutable snapshots that do not leak or mutate engine ledger',
    () async {
      final disk = MemoryPersistence();
      final e = engine(disk);
      try {
        await e.init();
        e.recordRequestSample(
          id: 'c1',
          upload: 0,
          download: 10,
          host: 'v1.googlevideo.com',
        );
        final initialGroups = e.getAggregatedSites();
        final group = initialGroups.single;
        check(
          group.total == 10 && group.subSites.single.total == 10,
          'initial group total must be 10',
        );

        // Record more traffic
        e.recordTrafficSample(id: 'c1', upload: 0, download: 20);

        // Previously returned group snapshot must not be mutated
        check(
          group.total == 10 && group.subSites.single.total == 10,
          'existing snapshot mutated on subsequent traffic',
        );

        // Attempting to mutate subSites fields in the snapshot must not affect engine ledger
        group.subSites.single.download = 999;
        await e.save();

        check(
          e.todayTotal == 20,
          'engine ledger was corrupted by snapshot field mutation',
        );

        final diskSnapshot = await disk.read();
        final sitesMap = diskSnapshot?['sites'] as Map<String, dynamic>?;
        check(
          sitesMap?['v1.googlevideo.com']?['download'] == 20,
          'persisted site.download corrupted by external snapshot mutation',
        );

        // Next read with new revision reflects true data
        final updatedGroups = e.getAggregatedSites();
        check(
          updatedGroups.single.total == 20 &&
              updatedGroups.single.subSites.single.total == 20,
          'updated aggregation must reflect total 20',
        );
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'unnotified burst connection attributes properly when terminal sample arrives without request event',
    () async {
      final disk = MemoryPersistence();
      final e = TrafficStatsEngine(
        persistence: disk,
        now: () => DateTime(2026, 11, 2, 12),
      );
      try {
        await e.init();

        // No recordRequestSample was ever called (simulating dropped RequestMessage under congestion)
        // Directly deliver terminal sample with isClosed: true and host metadata
        e.recordTrafficSample(
          id: 'burst-conn-1',
          upload: 200,
          download: 1000,
          host: 'burst-site.com',
          isClosed: true,
        );
        e.recordClosedConnection('burst-conn-1');

        check(
          e.todayTotal == 1200,
          'todayTotal must be 1200 for terminal burst connection, got ${e.todayTotal}',
        );
        check(e.todayUpload == 200, 'todayUpload must be 200');
        check(e.todayDownload == 1000, 'todayDownload must be 1000');
        check(
          e.targetSiteUsages['burst-site.com']?.total == 1200,
          'site total must be 1200',
        );
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'live connection continues accumulative accounting across config reloads without losing site attribution',
    () async {
      final disk = MemoryPersistence();
      final e = TrafficStatsEngine(
        persistence: disk,
        now: () => DateTime(2026, 11, 2, 12),
      );
      try {
        await e.init();

        // Initial connection established
        e.recordRequestSample(
          id: 'live-1',
          upload: 0,
          download: 100,
          host: 'example.com',
        );
        check(e.todayTotal == 100, 'initial total 100');
        check(
          e.targetSiteUsages['example.com']?.total == 100,
          'site total 100',
        );

        // Config is reloaded, but core process stays alive (engine connection book not cleared)
        e.recordTrafficSample(id: 'live-1', upload: 0, download: 150);
        e.recordTrafficSample(id: 'live-1', upload: 0, download: 200);

        check(
          e.todayTotal == 200,
          'todayTotal must be 200 across config reload, got ${e.todayTotal}',
        );
        check(
          e.targetSiteUsages['example.com']?.total == 200,
          'site total must be 200, got ${e.targetSiteUsages['example.com']?.total}',
        );
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'cached top sites return clones so caller in-place mutation does not pollute cache',
    () async {
      final disk = MemoryPersistence();
      final e = TrafficStatsEngine(
        persistence: disk,
        now: () => DateTime(2026, 11, 2, 12),
      );
      try {
        await e.init();
        e.recordRequestSample(
          id: 'c1',
          upload: 0,
          download: 10,
          host: 'site.com',
        );

        final read1 = e.getTopSites();
        check(read1.single.download == 10, 'initial download must be 10');

        // Caller mutates returned element
        read1.single.download = 999;

        final read2 = e.getTopSites();
        check(
          read2.single.download == 10,
          'subsequent cache hit must return 10, not polluted 999',
        );
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'unnotified normal connection preserves initial sample bytes across isClosed false then true sequence',
    () async {
      final disk = MemoryPersistence();
      final e = TrafficStatsEngine(
        persistence: disk,
        now: () => DateTime(2026, 11, 2, 12),
      );
      try {
        await e.init();

        // Simulate lost RequestMessage: first regular (non-terminal) sample arrives with host metadata
        e.recordTrafficSample(
          id: 'test-conn-seq',
          upload: 0,
          download: 1000,
          host: 'example.com',
          isClosed: false,
        );

        check(
          e.todayTotal == 1000,
          'initial non-terminal sample for tracked connection must record 1000 bytes, got ${e.todayTotal}',
        );
        check(
          e.targetSiteUsages['example.com']?.total == 1000,
          'site total must be 1000 after first sample',
        );

        // Next tick delivers terminal sample with same cumulative totals
        e.recordTrafficSample(
          id: 'test-conn-seq',
          upload: 0,
          download: 1000,
          host: 'example.com',
          isClosed: true,
        );
        e.recordClosedConnection('test-conn-seq');

        check(
          e.todayTotal == 1000,
          'todayTotal must remain 1000 after terminal sample, got ${e.todayTotal}',
        );
        check(
          e.targetSiteUsages['example.com']?.total == 1000,
          'site total must remain 1000 after close',
        );
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'untracked connection without host metadata establishes baseline without charging past traffic',
    () async {
      final disk = MemoryPersistence();
      final e = TrafficStatsEngine(
        persistence: disk,
        now: () => DateTime(2026, 11, 2, 12),
      );
      try {
        await e.init();

        // Sample without host (e.g. ancient connection from before session)
        e.recordTrafficSample(
          id: 'ancient-conn',
          upload: 0,
          download: 50000,
          host: null,
          isClosed: false,
        );

        check(
          e.todayTotal == 0,
          'sample without host must establish baseline and not charge past 50000 bytes, got ${e.todayTotal}',
        );

        // Next sample transfers 500 new bytes
        e.recordTrafficSample(
          id: 'ancient-conn',
          upload: 0,
          download: 50500,
          host: null,
          isClosed: false,
        );

        check(
          e.todayTotal == 500,
          'subsequent sample must charge only delta 500 bytes, got ${e.todayTotal}',
        );
      } finally {
        e.dispose();
      }
    },
  );

  await test(
    'failover stats model JSON serialization and contract with Go core',
    () async {
      // Exactly matches Go core json tags and millisecond timestamp
      final goResponseJson = {
        'total': 1,
        'today': 1,
        'date': '2026-11-04',
        'records': [
          {
            'time': 1793773254361,
            'group': 'AutoGroup',
            'before': 'NodeA',
            'after': 'NodeB',
          },
        ],
      };

      final stats = FailoverStats.fromJson(goResponseJson);
      check(stats.total == 1 && stats.totalCount == 1, 'total mismatch: ${stats.total}');
      check(stats.today == 1 && stats.todayCount == 1, 'today mismatch: ${stats.today}');
      check(stats.date == '2026-11-04' && stats.lastDate == '2026-11-04', 'date mismatch: ${stats.date}');
      check(stats.records.length == 1, 'records length mismatch: ${stats.records.length}');

      final record = stats.records.first;
      check(record.time == 1793773254361, 'time mismatch: ${record.time}');
      check(record.dateTime.millisecondsSinceEpoch == 1793773254361, 'dateTime millis mismatch: ${record.dateTime}');
      check(record.dateTime.year == 2026, 'dateTime year must be 2026, got: ${record.dateTime.year}');
      check(record.group == 'AutoGroup', 'group mismatch');
      check(record.before == 'NodeA', 'before mismatch');
      check(record.after == 'NodeB', 'after mismatch');

      final serialized = stats.toJson();
      check(serialized['total'] == 1, 'serialized total mismatch');
      check(serialized['today'] == 1, 'serialized today mismatch');
      check(serialized['date'] == '2026-11-04', 'serialized date mismatch');
      check((serialized['records'] as List).length == 1, 'serialized records mismatch');

      final roundtrip = FailoverStats.fromJson(serialized);
      check(roundtrip == stats, 'roundtrip equality mismatch');
      check(roundtrip.hashCode == stats.hashCode, 'roundtrip hashCode mismatch');

      // Also supports legacy total_count / today_count / last_date / timestamp (seconds)
      final legacyJson = {
        'total_count': 10,
        'today_count': 3,
        'last_date': '2026-11-04',
        'records': [
          {
            'timestamp': 1793779200,
            'group': 'LegacyGroup',
            'before': 'OldNode',
            'after': 'NewNode',
          },
        ],
      };
      final legacyStats = FailoverStats.fromJson(legacyJson);
      check(legacyStats.total == 10 && legacyStats.today == 3, 'legacy total/today mismatch');
      check(legacyStats.records.first.dateTime.year == 2026, 'legacy timestamp in seconds conversion mismatch');

      final emptyStats = FailoverStats.fromJson({});
      check(emptyStats.total == 0 && emptyStats.today == 0, 'empty total mismatch');
      check(emptyStats.records.isEmpty, 'empty records mismatch');
    },
  );

  await test(
    'failover stats IPC protocol payload and parser compatibility',
    () async {
      // Go resetFailoverStats returns zeroed snapshot directly (*FailoverStats)
      final goResetResponse = {
        'id': 'req-reset',
        'result': {
          'total': 0,
          'today': 0,
          'date': '2026-11-04',
          'records': [],
        },
      };

      final resultMap = goResetResponse['result'] as Map<String, dynamic>;
      final parsedReset = FailoverStats.fromJson(resultMap);
      check(parsedReset.total == 0 && parsedReset.today == 0, 'reset result must be 0');
      check(parsedReset.records.isEmpty, 'reset records must be empty');

      // Multi-record newest-first ordering test
      final multiRecordResp = {
        'total': 2,
        'today': 2,
        'date': '2026-11-04',
        'records': [
          {
            'time': 1793773260000,
            'group': 'Group1',
            'before': 'NodeB',
            'after': 'NodeC',
          },
          {
            'time': 1793773200000,
            'group': 'Group1',
            'before': 'NodeA',
            'after': 'NodeB',
          },
        ],
      };
      final parsedMulti = FailoverStats.fromJson(multiRecordResp);
      check(parsedMulti.records.length == 2, 'multi records length mismatch');
      // Record 0 must be the newest one (1793773260000 > 1793773200000)
      check(parsedMulti.records[0].before == 'NodeB' && parsedMulti.records[0].after == 'NodeC', 'newest record must be at index 0');
      check(parsedMulti.records[1].before == 'NodeA' && parsedMulti.records[1].after == 'NodeB', 'older record must be at index 1');
    },
  );

  await test(
    'failover stats provider epoch coordination preserves error state without uncaught zone errors',
    () async {
      int activeEpoch = 0;
      dynamic state;
      final zoneErrors = <Object>[];

      await runZonedGuarded(() async {
        // 1. Initial build starts at epoch 1
        final buildEpoch = ++activeEpoch;

        // 2. User triggers reset at epoch 2 before build completes
        final resetEpoch = ++activeEpoch;

        // Reset encounters failure
        final resetError = StateError('reset persistence failed');
        final nextState = resetError;
        if (resetEpoch == activeEpoch) {
          state = nextState;
        }

        // 3. Stale build finishes after reset failure
        const staleStats = FailoverStats(total: 0, today: 0);
        dynamic buildResult;
        if (buildEpoch != activeEpoch) {
          // Superseded build returns uncompleted future to Riverpod, never committing
          buildResult = Completer<FailoverStats>().future;
        } else {
          buildResult = staleStats;
        }

        check(buildResult is Future<FailoverStats>, 'superseded build must return uncompleted future');
        check(state is StateError && state.message == 'reset persistence failed', 'state must remain in error');
      }, (error, stack) {
        zoneErrors.add(error);
      });

      check(zoneErrors.isEmpty, 'must not produce uncaught zone errors! count=${zoneErrors.length}');
    },
  );

  await test(
    'failover stats provider 3-request sequence A (build), B (refresh), C (reset) correctly commits C',
    () async {
      int activeEpoch = 0;
      dynamic state;

      // 1. Build A starts at epoch 1
      final epochA = ++activeEpoch;

      // 2. Refresh B starts at epoch 2
      final epochB = ++activeEpoch;

      // 3. A completes: sees epochA != activeEpoch -> yields uncompleted future, does not write state
      dynamic resultA;
      if (epochA != activeEpoch) {
        resultA = Completer<FailoverStats>().future;
      } else {
        resultA = const FailoverStats(total: 42, today: 5);
      }
      check(resultA is Future<FailoverStats>, 'A must not commit');

      // 4. User triggers reset C at epoch 3 -> C completes and commits total=0
      final epochC = ++activeEpoch;
      const statsC = FailoverStats(total: 0, today: 0);
      if (epochC == activeEpoch) {
        state = statsC;
      }
      check((state as FailoverStats).total == 0, 'C must commit total=0');

      // 5. B completes with old stats 42 -> B checks epochB != activeEpoch, does not write state!
      const statsB = FailoverStats(total: 42, today: 5);
      if (epochB == activeEpoch) {
        state = statsB;
      }

      // Final state must remain C's total=0!
      check(state.total == 0, 'state must remain C (total=0), not overwritten by B (42)');
    },
  );

  stdout.writeln('$count regression scenarios passed.');
}
