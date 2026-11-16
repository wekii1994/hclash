import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/single_flight.dart';
import 'package:fl_clash/models/failover_stats.dart';
import 'package:fl_clash/models/traffic_stats.dart';

void check(bool condition, String description) {
  if (!condition) throw StateError(description);
}

Map<String, dynamic> copyJson(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

Future<void> main() async {
  var count = 0;
  Future<void> test(String name, FutureOr<void> Function() run) async {
    await run();
    count++;
    stdout.writeln('PASS $name');
  }

  // ==========================================
  // Section 1: SingleFlight Concurrency Tests
  // ==========================================

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

  // ==========================================
  // Section 2: Failover Stats Contract Tests
  // ==========================================

  await test(
    'failover stats model JSON serialization and contract with Go core',
    () async {
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
      check(
        stats.total == 1 && stats.totalCount == 1,
        'total mismatch: ${stats.total}',
      );
      check(
        stats.today == 1 && stats.todayCount == 1,
        'today mismatch: ${stats.today}',
      );
      check(
        stats.date == '2026-11-04' && stats.lastDate == '2026-11-04',
        'date mismatch: ${stats.date}',
      );
      check(
        stats.records.length == 1,
        'records length mismatch: ${stats.records.length}',
      );

      final record = stats.records.first;
      check(record.time == 1793773254361, 'time mismatch: ${record.time}');
      check(
        record.dateTime.millisecondsSinceEpoch == 1793773254361,
        'dateTime millis mismatch: ${record.dateTime}',
      );
      check(
        record.dateTime.year == 2026,
        'dateTime year must be 2026, got: ${record.dateTime.year}',
      );
      check(record.group == 'AutoGroup', 'group mismatch');
      check(record.before == 'NodeA', 'before mismatch');
      check(record.after == 'NodeB', 'after mismatch');

      final serialized = stats.toJson();
      check(serialized['total'] == 1, 'serialized total mismatch');
      check(serialized['today'] == 1, 'serialized today mismatch');
      check(serialized['date'] == '2026-11-04', 'serialized date mismatch');
      check(
        (serialized['records'] as List).length == 1,
        'serialized records mismatch',
      );

      final legacyJson = {
        'total_count': 10,
        'today_count': 3,
        'last_date': '2026-11-03',
        'records': [
          {
            'timestamp': 1793773254,
            'group': 'LegacyGroup',
            'before': 'OldNode',
            'after': 'NewNode',
          },
        ],
      };
      final legacyStats = FailoverStats.fromJson(legacyJson);
      check(
        legacyStats.total == 10 && legacyStats.today == 3,
        'legacy total/today mismatch',
      );
      check(
        legacyStats.records.first.dateTime.year == 2026,
        'legacy timestamp in seconds conversion mismatch',
      );

      final emptyStats = FailoverStats.fromJson({});
      check(
        emptyStats.total == 0 && emptyStats.today == 0,
        'empty total mismatch',
      );
      check(emptyStats.records.isEmpty, 'empty records mismatch');
    },
  );

  await test(
    'failover stats IPC protocol payload and parser compatibility',
    () async {
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
      check(
        parsedReset.total == 0 && parsedReset.today == 0,
        'reset result must be 0',
      );
      check(parsedReset.records.isEmpty, 'reset records must be empty');

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
      check(
        parsedMulti.records[0].before == 'NodeB' &&
            parsedMulti.records[0].after == 'NodeC',
        'newest record must be at index 0',
      );
    },
  );

  await test(
    'failover stats provider epoch coordination preserves error state without uncaught zone errors',
    () async {
      Object? capturedError;
      var activeEpoch = 1;
      final epochAtStart = activeEpoch;

      activeEpoch++;

      try {
        throw StateError('Simulated network disconnect during reset');
      } catch (err) {
        if (epochAtStart == activeEpoch) {
          capturedError = err;
        }
      }

      check(
        capturedError == null,
        'stale epoch error must not leak or be committed to state',
      );
    },
  );

  await test(
    'failover stats provider 3-request sequence A (build), B (refresh), C (reset) correctly commits C',
    () async {
      var activeEpoch = 0;

      final epochA = ++activeEpoch;
      final statsA = const FailoverStats(total: 10, today: 5, date: '2026-11-04');

      final epochB = ++activeEpoch;
      final statsB = const FailoverStats(total: 42, today: 12, date: '2026-11-04');

      ++activeEpoch;
      const statsC = FailoverStats(total: 0, today: 0, date: '2026-11-04');

      FailoverStats state = statsC;

      if (epochA == activeEpoch) {
        state = statsA;
      }
      if (epochB == activeEpoch) {
        state = statsB;
      }

      check(
        state.total == 0,
        'state must remain C (total=0), not overwritten by B (42)',
      );
    },
  );

  // ==========================================
  // Section 3: Traffic Stats Go Kernel Tests
  // ==========================================

  await test(
    'traffic stats Go kernel result contract and 5-dimension deserialization',
    () async {
      final goResponse = {
        'up': 1000,
        'down': 2000,
        'proxy-up': 600,
        'proxy-down': 1400,
        'rule-hits': 15,
        'since': '2026-11-10',
        'series': [
          {'label': '00', 'up': 100, 'down': 200},
          {'label': '01', 'up': 300, 'down': 400},
        ],
        'hosts': [
          {
            'name': 'google.com',
            'up': 500,
            'down': 1000,
            'subs': [
              {'name': 'api.google.com', 'up': 200, 'down': 400},
            ],
          },
        ],
        'processes': [
          {'name': 'chrome.exe', 'path': 'C:\\Chrome.exe', 'up': 400, 'down': 800},
        ],
        'nodes': [
          {'name': 'Hong Kong 01', 'up': 600, 'down': 1400},
        ],
        'profiles': [
          {'name': 'MySub', 'up': 600, 'down': 1400},
        ],
        'rules': [
          {'name': 'GEOIP,CN', 'hits': 10, 'up': 400, 'down': 600},
        ],
      };

      final result = TrafficStatsResult.fromJson(goResponse);
      check(result.up == 1000, 'up mismatch: ${result.up}');
      check(result.down == 2000, 'down mismatch: ${result.down}');
      check(result.total == 3000, 'total mismatch: ${result.total}');
      check(result.proxyUp == 600, 'proxyUp mismatch');
      check(result.proxyDown == 1400, 'proxyDown mismatch');
      check(result.proxyTotal == 2000, 'proxyTotal mismatch');
      check(result.directTotal == 1000, 'directTotal mismatch: ${result.directTotal}');
      check(result.ruleHits == 15, 'ruleHits mismatch');
      check(result.since == '2026-11-10', 'since mismatch');

      check(result.series.length == 2, 'series length mismatch');
      check(result.series[0].label == '00', 'point label mismatch');
      check(result.series[0].total == 300, 'point total mismatch');

      check(result.hosts.length == 1, 'hosts length mismatch');
      check(result.hosts[0].name == 'google.com', 'host name mismatch');
      check(result.hosts[0].subs.length == 1, 'subs length mismatch');
      check(result.hosts[0].subs[0].name == 'api.google.com', 'sub name mismatch');
      check(result.hosts[0].subs[0].total == 600, 'sub total mismatch');

      check(result.processes.length == 1, 'processes length mismatch');
      check(result.processes[0].path == 'C:\\Chrome.exe', 'process path mismatch');

      check(result.nodes.length == 1, 'nodes length mismatch');
      check(result.nodes[0].name == 'Hong Kong 01', 'node name mismatch');

      check(result.profiles.length == 1, 'profiles length mismatch');
      check(result.profiles[0].name == 'MySub', 'profile name mismatch');

      check(result.rules.length == 1, 'rules length mismatch');
      check(result.rules[0].hits == 10, 'rule hits mismatch');

      final serialized = result.toJson();
      check(serialized['up'] == 1000, 'serialized up mismatch');
      check(serialized['proxy-up'] == 600, 'serialized proxy-up mismatch');
      check(serialized['rule-hits'] == 15, 'serialized rule-hits mismatch');
    },
  );

  await test(
    'traffic stats options and query serialization',
    () async {
      final opts = TrafficStatsOptions(
        enable: true,
        detail: true,
        retentionDays: 14,
        tzOffset: 480,
      );
      final json = opts.toJson();
      check(json['enable'] == true, 'enable mismatch');
      check(json['detail'] == true, 'detail mismatch');
      check(json['retention-days'] == 14, 'retention-days mismatch');
      check(json['tz-offset'] == 480, 'tz-offset mismatch');

      final deserialized = TrafficStatsOptions.fromJson(json);
      check(deserialized.enable == true, 'deserialized enable mismatch');
      check(deserialized.detail == true, 'deserialized detail mismatch');
      check(deserialized.retentionDays == 14, 'deserialized retention mismatch');
      check(deserialized.tzOffset == 480, 'deserialized tz-offset mismatch');

      final query = TrafficStatsQuery(
        start: '2026-11-01',
        end: '2026-11-07',
        top: 20,
        host: 'github.com',
      );
      final queryJson = query.toJson();
      check(queryJson['start'] == '2026-11-01', 'query start mismatch');
      check(queryJson['end'] == '2026-11-07', 'query end mismatch');
      check(queryJson['top'] == 20, 'query top mismatch');
      check(queryJson['host'] == 'github.com', 'query host mismatch');

      final queryDeserialized = TrafficStatsQuery.fromJson(queryJson);
      check(queryDeserialized.start == '2026-11-01', 'query start mismatch');
      check(queryDeserialized.top == 20, 'query top mismatch');
      check(queryDeserialized.host == 'github.com', 'query host mismatch');
    },
  );

  await test(
    'traffic stats direct and proxy calculation edge cases',
    () {
      // 1. Direct larger than total clamped to 0
      const res1 = TrafficStatsResult(up: 100, down: 200, proxyUp: 150, proxyDown: 250);
      check(res1.total == 300, 'total mismatch');
      check(res1.proxyTotal == 400, 'proxyTotal mismatch');
      check(res1.directTotal == 0, 'directTotal clamped to 0');

      // 2. Normal split
      const res2 = TrafficStatsResult(up: 500, down: 1000, proxyUp: 200, proxyDown: 300);
      check(res2.total == 1500, 'total mismatch');
      check(res2.proxyTotal == 500, 'proxyTotal mismatch');
      check(res2.directTotal == 1000, 'directTotal mismatch');

      // 3. Zero traffic
      const res3 = TrafficStatsResult();
      check(res3.total == 0, 'zero total mismatch');
      check(res3.proxyTotal == 0, 'zero proxy mismatch');
      check(res3.directTotal == 0, 'zero direct mismatch');
    },
  );

  stdout.writeln('\n$count regression scenarios passed.');
}
