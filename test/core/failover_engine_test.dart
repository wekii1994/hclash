import 'package:fl_clash/core/api/dto.dart';
import 'package:fl_clash/core/failover_engine.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FailoverEngine classifyAutoGroups tests', () {
    test('identifies primary auto groups from active selector references', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final engine = container.read(failoverEngineProvider);

      const allGroups = [
        GroupInfo(
          name: 'GLOBAL',
          type: 'select',
          now: 'Proxy',
          testUrl: 'http://cp.cloudflare.com',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
        GroupInfo(
          name: 'Proxy',
          type: 'select',
          now: 'Auto-Primary',
          testUrl: 'http://cp.cloudflare.com',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
        GroupInfo(
          name: 'Auto-Primary',
          type: 'url-test',
          now: 'HK-01',
          all: ['HK-01', 'HK-02', 'JP-01'],
          testUrl: 'http://cp.cloudflare.com',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
        GroupInfo(
          name: 'Standby-Auto',
          type: 'fallback',
          now: 'SG-01',
          all: ['SG-01', 'SG-02'],
          testUrl: 'http://cp.cloudflare.com',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
      ];

      final result = engine.classifyAutoGroups(allGroups);

      expect(result.primary.map((g) => g.name).toList(), contains('Auto-Primary'));
      expect(result.secondary.map((g) => g.name).toList(), contains('Standby-Auto'));
    });

    test('recognizes primary keywords even if not currently selected', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final engine = container.read(failoverEngineProvider);

      const allGroups = [
        GroupInfo(
          name: 'GLOBAL',
          type: 'select',
          now: 'DIRECT',
          testUrl: 'http://cp.cloudflare.com',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
        GroupInfo(
          name: '自动优选节点',
          type: 'url-test',
          now: 'JP-01',
          all: ['JP-01', 'JP-02'],
          testUrl: 'http://cp.cloudflare.com',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
        GroupInfo(
          name: 'OtherGroup',
          type: 'url-test',
          now: 'US-01',
          all: ['US-01'],
          testUrl: 'http://cp.cloudflare.com',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
        GroupInfo(
          name: 'Standby-Auto',
          type: 'fallback',
          now: 'SG-01',
          all: ['SG-01'],
          testUrl: 'http://cp.cloudflare.com',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
      ];

      final result = engine.classifyAutoGroups(allGroups);

      expect(result.primary.map((g) => g.name).toList(), contains('自动优选节点'));
      expect(result.secondary.map((g) => g.name).toList(), contains('OtherGroup'));
      expect(result.secondary.map((g) => g.name).toList(), contains('Standby-Auto'));
    });

    test('gracefully prevents selector reference loops without infinite recursion', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final engine = container.read(failoverEngineProvider);

      const allGroups = [
        GroupInfo(
          name: 'LoopA',
          type: 'select',
          now: 'LoopB',
          testUrl: '',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
        GroupInfo(
          name: 'LoopB',
          type: 'select',
          now: 'LoopA',
          testUrl: '',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
        GroupInfo(
          name: 'Auto-Fallback',
          type: 'fallback',
          now: 'Node1',
          all: ['Node1'],
          testUrl: '',
          hidden: false,
          icon: '',
          emptyFallback: '',
        ),
      ];

      final result = engine.classifyAutoGroups(allGroups);
      expect(result.primary.isNotEmpty || result.secondary.isNotEmpty, isTrue);
    });
  });

  group('Connection eviction criteria test', () {
    test('filters only stale connections matching group, old proxy, and switch time', () {
      final switchTime = DateTime.now();

      final trackerMatching = TrackerInfo(
        id: 101,
        start: switchTime.subtract(const Duration(seconds: 5)),
        metadata: const Metadata(),
        chains: ['Proxy', 'Auto', 'HK-01'],
        rule: 'Match',
        rulePayload: '',
      );

      final trackerNewConnection = TrackerInfo(
        id: 102,
        start: switchTime.add(const Duration(milliseconds: 100)),
        metadata: const Metadata(),
        chains: ['Proxy', 'Auto', 'HK-01'],
        rule: 'Match',
        rulePayload: '',
      );

      final trackerOtherNode = TrackerInfo(
        id: 103,
        start: switchTime.subtract(const Duration(seconds: 10)),
        metadata: const Metadata(),
        chains: ['Proxy', 'Auto', 'JP-01'],
        rule: 'Match',
        rulePayload: '',
      );

      final trackerDirect = TrackerInfo(
        id: 104,
        start: switchTime.subtract(const Duration(seconds: 15)),
        metadata: const Metadata(),
        chains: ['DIRECT'],
        rule: 'GeoIP',
        rulePayload: 'CN',
      );

      final trackers = [
        trackerMatching,
        trackerNewConnection,
        trackerOtherNode,
        trackerDirect,
      ];

      final staleIds = <int>[];
      for (final tracker in trackers) {
        if (tracker.start.isBefore(switchTime) &&
            tracker.chains.contains('Auto') &&
            tracker.chains.contains('HK-01')) {
          staleIds.add(tracker.id);
        }
      }

      expect(staleIds, equals([101]));
    });
  });
}
