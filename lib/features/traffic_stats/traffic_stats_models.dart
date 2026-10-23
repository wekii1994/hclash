import 'package:fl_clash/common/common.dart';

enum TrafficStatsRange {
  today,
  week,
  month,
  all;

  String getLabel(String todayText, String weekText, String monthText, String allText) {
    return switch (this) {
      TrafficStatsRange.today => todayText,
      TrafficStatsRange.week => weekText,
      TrafficStatsRange.month => monthText,
      TrafficStatsRange.all => allText,
    };
  }
}

class HourlyTrafficData {
  final int hour;
  int upload;
  int download;

  HourlyTrafficData({
    required this.hour,
    this.upload = 0,
    this.download = 0,
  });

  int get total => upload + download;

  Map<String, dynamic> toJson() => {
        'hour': hour,
        'upload': upload,
        'download': download,
      };

  factory HourlyTrafficData.fromJson(Map<String, dynamic> json) =>
      HourlyTrafficData(
        hour: json['hour'] as int? ?? 0,
        upload: json['upload'] as int? ?? 0,
        download: json['download'] as int? ?? 0,
      );
}

class DailyTrafficData {
  final String date; // YYYY-MM-DD
  int upload;
  int download;
  final Map<int, HourlyTrafficData> hourly;

  DailyTrafficData({
    required this.date,
    this.upload = 0,
    this.download = 0,
    Map<int, HourlyTrafficData>? hourly,
  }) : hourly = hourly ?? {};

  int get total => upload + download;

  Map<String, dynamic> toJson() => {
        'date': date,
        'upload': upload,
        'download': download,
        'hourly': hourly.map((k, v) => MapEntry(k.toString(), v.toJson())),
      };

  factory DailyTrafficData.fromJson(Map<String, dynamic> json) {
    final hourlyMap = <int, HourlyTrafficData>{};
    if (json['hourly'] is Map) {
      (json['hourly'] as Map).forEach((k, v) {
        final hour = int.tryParse(k.toString()) ?? 0;
        if (v is Map<String, dynamic>) {
          hourlyMap[hour] = HourlyTrafficData.fromJson(v);
        } else if (v is Map) {
          hourlyMap[hour] =
              HourlyTrafficData.fromJson(Map<String, dynamic>.from(v));
        }
      });
    }
    return DailyTrafficData(
      date: json['date'] as String? ?? '',
      upload: json['upload'] as int? ?? 0,
      download: json['download'] as int? ?? 0,
      hourly: hourlyMap,
    );
  }
}

class TargetSiteData {
  final String host;
  int upload;
  int download;
  int count;
  int lastSeen; // timestamp ms
  String? process;

  TargetSiteData({
    required this.host,
    this.upload = 0,
    this.download = 0,
    this.count = 1,
    int? lastSeen,
    this.process,
  }) : lastSeen = lastSeen ?? DateTime.now().millisecondsSinceEpoch;

  int get total => upload + download;

  Map<String, dynamic> toJson() => {
        'host': host,
        'upload': upload,
        'download': download,
        'count': count,
        'lastSeen': lastSeen,
        if (process != null && process!.isNotEmpty) 'process': process,
      };

  factory TargetSiteData.fromJson(Map<String, dynamic> json) => TargetSiteData(
        host: json['host'] as String? ?? '',
        upload: json['upload'] as int? ?? 0,
        download: json['download'] as int? ?? 0,
        count: json['count'] as int? ?? 1,
        lastSeen: json['lastSeen'] as int? ?? 0,
        process: json['process'] as String?,
      );
}

class ChartBarPoint {
  final String label;
  final String fullLabel;
  final int upload;
  final int download;
  final bool isCurrent;

  const ChartBarPoint({
    required this.label,
    required this.fullLabel,
    required this.upload,
    required this.download,
    this.isCurrent = false,
  });

  int get total => upload + download;
}
