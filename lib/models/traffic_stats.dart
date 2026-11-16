import 'dart:math' as math;

class TrafficStatsItem {
  final String name;
  final int up;
  final int down;
  final int hits;
  final String path;
  final List<TrafficStatsItem> subs;

  const TrafficStatsItem({
    this.name = '',
    this.up = 0,
    this.down = 0,
    this.hits = 0,
    this.path = '',
    this.subs = const [],
  });

  int get total => up + down;

  factory TrafficStatsItem.fromJson(Map<String, dynamic> json) {
    final rawSubs = json['subs'];
    final subsList = <TrafficStatsItem>[];
    if (rawSubs is List) {
      for (final item in rawSubs) {
        if (item is Map) {
          subsList.add(TrafficStatsItem.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return TrafficStatsItem(
      name: json['name'] as String? ?? '',
      up: (json['up'] as num?)?.toInt() ?? 0,
      down: (json['down'] as num?)?.toInt() ?? 0,
      hits: (json['hits'] as num?)?.toInt() ?? 0,
      path: json['path'] as String? ?? '',
      subs: subsList,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'up': up,
        'down': down,
        if (hits > 0) 'hits': hits,
        if (path.isNotEmpty) 'path': path,
        if (subs.isNotEmpty) 'subs': subs.map((e) => e.toJson()).toList(),
      };
}

class TrafficStatsPoint {
  final String label;
  final int up;
  final int down;

  const TrafficStatsPoint({
    this.label = '',
    this.up = 0,
    this.down = 0,
  });

  int get total => up + down;

  factory TrafficStatsPoint.fromJson(Map<String, dynamic> json) {
    return TrafficStatsPoint(
      label: json['label'] as String? ?? '',
      up: (json['up'] as num?)?.toInt() ?? 0,
      down: (json['down'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'up': up,
        'down': down,
      };
}

class TrafficStatsResult {
  final int up;
  final int down;
  final int proxyUp;
  final int proxyDown;
  final List<TrafficStatsPoint> series;
  final List<TrafficStatsItem> hosts;
  final List<TrafficStatsItem> processes;
  final List<TrafficStatsItem> nodes;
  final List<TrafficStatsItem> profiles;
  final List<TrafficStatsItem> rules;
  final int ruleHits;
  final String since;

  const TrafficStatsResult({
    this.up = 0,
    this.down = 0,
    this.proxyUp = 0,
    this.proxyDown = 0,
    this.series = const [],
    this.hosts = const [],
    this.processes = const [],
    this.nodes = const [],
    this.profiles = const [],
    this.rules = const [],
    this.ruleHits = 0,
    this.since = '',
  });

  int get total => up + down;
  int get proxyTotal => proxyUp + proxyDown;
  int get directTotal => math.max(total - proxyTotal, 0);

  factory TrafficStatsResult.fromJson(Map<String, dynamic> json) {
    List<T> parseList<T>(dynamic raw, T Function(Map<String, dynamic>) fromJson) {
      if (raw is! List) return const [];
      final result = <T>[];
      for (final item in raw) {
        if (item is Map) {
          result.add(fromJson(Map<String, dynamic>.from(item)));
        }
      }
      return result;
    }

    return TrafficStatsResult(
      up: (json['up'] as num?)?.toInt() ?? 0,
      down: (json['down'] as num?)?.toInt() ?? 0,
      proxyUp: (json['proxy-up'] as num?)?.toInt() ?? (json['proxyUp'] as num?)?.toInt() ?? 0,
      proxyDown: (json['proxy-down'] as num?)?.toInt() ?? (json['proxyDown'] as num?)?.toInt() ?? 0,
      series: parseList(json['series'], TrafficStatsPoint.fromJson),
      hosts: parseList(json['hosts'], TrafficStatsItem.fromJson),
      processes: parseList(json['processes'], TrafficStatsItem.fromJson),
      nodes: parseList(json['nodes'], TrafficStatsItem.fromJson),
      profiles: parseList(json['profiles'], TrafficStatsItem.fromJson),
      rules: parseList(json['rules'], TrafficStatsItem.fromJson),
      ruleHits: (json['rule-hits'] as num?)?.toInt() ?? (json['ruleHits'] as num?)?.toInt() ?? 0,
      since: json['since'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'up': up,
        'down': down,
        'proxy-up': proxyUp,
        'proxy-down': proxyDown,
        'series': series.map((e) => e.toJson()).toList(),
        'hosts': hosts.map((e) => e.toJson()).toList(),
        'processes': processes.map((e) => e.toJson()).toList(),
        'nodes': nodes.map((e) => e.toJson()).toList(),
        'profiles': profiles.map((e) => e.toJson()).toList(),
        'rules': rules.map((e) => e.toJson()).toList(),
        'rule-hits': ruleHits,
        'since': since,
      };
}

class TrafficStatsOptions {
  final bool enable;
  final bool detail;
  final int retentionDays;
  final int tzOffset;
  final bool siteIcon;

  const TrafficStatsOptions({
    this.enable = false,
    this.detail = true,
    this.retentionDays = 7,
    this.tzOffset = 0,
    this.siteIcon = true,
  });

  factory TrafficStatsOptions.fromJson(Map<String, dynamic> json) {
    return TrafficStatsOptions(
      enable: json['enable'] as bool? ?? false,
      detail: json['detail'] as bool? ?? true,
      retentionDays: (json['retention-days'] as num?)?.toInt() ??
          (json['retentionDays'] as num?)?.toInt() ??
          7,
      tzOffset: (json['tz-offset'] as num?)?.toInt() ??
          (json['tzOffset'] as num?)?.toInt() ??
          0,
      siteIcon: json['site-icon'] as bool? ?? json['siteIcon'] as bool? ?? true,
    );
  }

  TrafficStatsOptions copyWith({
    bool? enable,
    bool? detail,
    int? retentionDays,
    int? tzOffset,
    bool? siteIcon,
  }) {
    return TrafficStatsOptions(
      enable: enable ?? this.enable,
      detail: detail ?? this.detail,
      retentionDays: retentionDays ?? this.retentionDays,
      tzOffset: tzOffset ?? this.tzOffset,
      siteIcon: siteIcon ?? this.siteIcon,
    );
  }

  Map<String, dynamic> toJson() => {
        'enable': enable,
        'detail': detail,
        'retention-days': retentionDays,
        'tz-offset': tzOffset,
        'site-icon': siteIcon,
      };
}

class TrafficStatsQuery {
  final String start;
  final String end;
  final int top;
  final String host;

  const TrafficStatsQuery({
    this.start = '',
    this.end = '',
    this.top = 0,
    this.host = '',
  });

  factory TrafficStatsQuery.fromJson(Map<String, dynamic> json) {
    return TrafficStatsQuery(
      start: json['start'] as String? ?? '',
      end: json['end'] as String? ?? '',
      top: (json['top'] as num?)?.toInt() ?? 0,
      host: json['host'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        if (start.isNotEmpty) 'start': start,
        if (end.isNotEmpty) 'end': end,
        if (top > 0) 'top': top,
        if (host.isNotEmpty) 'host': host,
      };
}
