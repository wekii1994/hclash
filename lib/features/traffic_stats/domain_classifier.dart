import 'package:flutter/material.dart';
import 'traffic_stats_models.dart';

class ServiceCategory {
  final String name;
  final String iconText;
  final Color? brandColor;

  const ServiceCategory({
    required this.name,
    required this.iconText,
    this.brandColor,
  });
}

class AggregatedSiteGroup {
  final String key;
  final String displayName;
  final String iconText;
  final Color? brandColor;
  final List<TargetSiteData> subSites;

  int get upload => subSites.fold(0, (sum, s) => sum + s.upload);
  int get download => subSites.fold(0, (sum, s) => sum + s.download);
  int get total => upload + download;
  int get count => subSites.fold(0, (sum, s) => sum + s.count);

  AggregatedSiteGroup({
    required this.key,
    required this.displayName,
    required this.iconText,
    this.brandColor,
    required this.subSites,
  });
}

class DomainClassifier {
  static const Map<String, ServiceCategory> _knownRules = {
    // YouTube / Google Video
    'googlevideo.com': ServiceCategory(name: 'YouTube', iconText: 'YT', brandColor: Color(0xFFFF0000)),
    'youtube.com': ServiceCategory(name: 'YouTube', iconText: 'YT', brandColor: Color(0xFFFF0000)),
    'ytimg.com': ServiceCategory(name: 'YouTube', iconText: 'YT', brandColor: Color(0xFFFF0000)),
    'youtu.be': ServiceCategory(name: 'YouTube', iconText: 'YT', brandColor: Color(0xFFFF0000)),

    // Bilibili
    'bilivideo.com': ServiceCategory(name: '哔哩哔哩', iconText: 'Bili', brandColor: Color(0xFF00AEEC)),
    'bilibili.com': ServiceCategory(name: '哔哩哔哩', iconText: 'Bili', brandColor: Color(0xFF00AEEC)),
    'hdslb.com': ServiceCategory(name: '哔哩哔哩', iconText: 'Bili', brandColor: Color(0xFF00AEEC)),
    'biliapi.net': ServiceCategory(name: '哔哩哔哩', iconText: 'Bili', brandColor: Color(0xFF00AEEC)),

    // Netflix
    'nflxvideo.net': ServiceCategory(name: 'Netflix', iconText: 'NF', brandColor: Color(0xFFE50914)),
    'nflxso.net': ServiceCategory(name: 'Netflix', iconText: 'NF', brandColor: Color(0xFFE50914)),
    'nflxext.com': ServiceCategory(name: 'Netflix', iconText: 'NF', brandColor: Color(0xFFE50914)),
    'netflix.com': ServiceCategory(name: 'Netflix', iconText: 'NF', brandColor: Color(0xFFE50914)),

    // TikTok / 抖音
    'byteoversea.com': ServiceCategory(name: 'TikTok', iconText: 'TT', brandColor: Color(0xFF000000)),
    'ibytedtos.com': ServiceCategory(name: 'TikTok', iconText: 'TT', brandColor: Color(0xFF000000)),
    'tiktokv.com': ServiceCategory(name: 'TikTok', iconText: 'TT', brandColor: Color(0xFF000000)),
    'tiktok.com': ServiceCategory(name: 'TikTok', iconText: 'TT', brandColor: Color(0xFF000000)),
    'tiktokcdn.com': ServiceCategory(name: 'TikTok', iconText: 'TT', brandColor: Color(0xFF000000)),

    // X / Twitter
    'twimg.com': ServiceCategory(name: 'X (Twitter)', iconText: 'X', brandColor: Color(0xFF1DA1F2)),
    'twitter.com': ServiceCategory(name: 'X (Twitter)', iconText: 'X', brandColor: Color(0xFF1DA1F2)),
    'x.com': ServiceCategory(name: 'X (Twitter)', iconText: 'X', brandColor: Color(0xFF1DA1F2)),
    't.co': ServiceCategory(name: 'X (Twitter)', iconText: 'X', brandColor: Color(0xFF1DA1F2)),

    // GitHub
    'github.com': ServiceCategory(name: 'GitHub', iconText: 'GH', brandColor: Color(0xFF24292E)),
    'githubusercontent.com': ServiceCategory(name: 'GitHub', iconText: 'GH', brandColor: Color(0xFF24292E)),
    'githubassets.com': ServiceCategory(name: 'GitHub', iconText: 'GH', brandColor: Color(0xFF24292E)),

    // Telegram
    'telegram.org': ServiceCategory(name: 'Telegram', iconText: 'TG', brandColor: Color(0xFF2AABEE)),
    't.me': ServiceCategory(name: 'Telegram', iconText: 'TG', brandColor: Color(0xFF2AABEE)),
    'telesco.pe': ServiceCategory(name: 'Telegram', iconText: 'TG', brandColor: Color(0xFF2AABEE)),

    // Apple
    'apple.com': ServiceCategory(name: 'Apple', iconText: 'AP', brandColor: Color(0xFF888888)),
    'aaplimg.com': ServiceCategory(name: 'Apple', iconText: 'AP', brandColor: Color(0xFF888888)),
    'mzstatic.com': ServiceCategory(name: 'Apple', iconText: 'AP', brandColor: Color(0xFF888888)),
    'icloud.com': ServiceCategory(name: 'Apple', iconText: 'AP', brandColor: Color(0xFF888888)),

    // Microsoft
    'microsoft.com': ServiceCategory(name: 'Microsoft', iconText: 'MS', brandColor: Color(0xFF00A4EF)),
    'azureedge.net': ServiceCategory(name: 'Microsoft', iconText: 'MS', brandColor: Color(0xFF00A4EF)),
    'live.com': ServiceCategory(name: 'Microsoft', iconText: 'MS', brandColor: Color(0xFF00A4EF)),
    'msftconnecttest.com': ServiceCategory(name: 'Microsoft', iconText: 'MS', brandColor: Color(0xFF00A4EF)),
    'windowsupdate.com': ServiceCategory(name: 'Microsoft', iconText: 'MS', brandColor: Color(0xFF00A4EF)),
    'office.com': ServiceCategory(name: 'Microsoft', iconText: 'MS', brandColor: Color(0xFF00A4EF)),

    // Google
    'google.com': ServiceCategory(name: 'Google', iconText: 'G', brandColor: Color(0xFF4285F4)),
    'gstatic.com': ServiceCategory(name: 'Google', iconText: 'G', brandColor: Color(0xFF4285F4)),
    'googleusercontent.com': ServiceCategory(name: 'Google', iconText: 'G', brandColor: Color(0xFF4285F4)),
    'googleapis.com': ServiceCategory(name: 'Google', iconText: 'G', brandColor: Color(0xFF4285F4)),
    '1e100.net': ServiceCategory(name: 'Google', iconText: 'G', brandColor: Color(0xFF4285F4)),

    // OpenAI
    'openai.com': ServiceCategory(name: 'OpenAI', iconText: 'AI', brandColor: Color(0xFF10A37F)),
    'oaistatic.com': ServiceCategory(name: 'OpenAI', iconText: 'AI', brandColor: Color(0xFF10A37F)),
    'oaiusercontent.com': ServiceCategory(name: 'OpenAI', iconText: 'AI', brandColor: Color(0xFF10A37F)),

    // Steam
    'steampowered.com': ServiceCategory(name: 'Steam', iconText: 'ST', brandColor: Color(0xFF171A21)),
    'steamstatic.com': ServiceCategory(name: 'Steam', iconText: 'ST', brandColor: Color(0xFF171A21)),
    'steamcommunity.com': ServiceCategory(name: 'Steam', iconText: 'ST', brandColor: Color(0xFF171A21)),

    // Cloudflare
    'cloudflare.com': ServiceCategory(name: 'Cloudflare', iconText: 'CF', brandColor: Color(0xFFF38020)),
    'cloudflarestream.com': ServiceCategory(name: 'Cloudflare', iconText: 'CF', brandColor: Color(0xFFF38020)),
    'workers.dev': ServiceCategory(name: 'Cloudflare', iconText: 'CF', brandColor: Color(0xFFF38020)),

    // 百度
    'baidu.com': ServiceCategory(name: '百度', iconText: 'BD', brandColor: Color(0xFF2932E1)),
    'bdstatic.com': ServiceCategory(name: '百度', iconText: 'BD', brandColor: Color(0xFF2932E1)),

    // 腾讯
    'tencent.com': ServiceCategory(name: '腾讯服务', iconText: 'TX', brandColor: Color(0xFF12B7F5)),
    'qq.com': ServiceCategory(name: '腾讯服务', iconText: 'TX', brandColor: Color(0xFF12B7F5)),
    'qpic.cn': ServiceCategory(name: '腾讯服务', iconText: 'TX', brandColor: Color(0xFF12B7F5)),
    'gtimg.com': ServiceCategory(name: '腾讯服务', iconText: 'TX', brandColor: Color(0xFF12B7F5)),

    // 阿里
    'alipay.com': ServiceCategory(name: '阿里服务', iconText: 'AL', brandColor: Color(0xFFFF5000)),
    'taobao.com': ServiceCategory(name: '阿里服务', iconText: 'AL', brandColor: Color(0xFFFF5000)),
    'tmall.com': ServiceCategory(name: '阿里服务', iconText: 'AL', brandColor: Color(0xFFFF5000)),
    'alicdn.com': ServiceCategory(name: '阿里服务', iconText: 'AL', brandColor: Color(0xFFFF5000)),
    'aliyun.com': ServiceCategory(name: '阿里服务', iconText: 'AL', brandColor: Color(0xFFFF5000)),
  };

  static const List<String> _twoPartTlds = [
    '.com.cn',
    '.net.cn',
    '.org.cn',
    '.edu.cn',
    '.gov.cn',
    '.co.uk',
    '.org.uk',
    '.com.hk',
    '.com.tw',
    '.co.jp',
    '.co.kr',
  ];

  static ServiceCategory classify(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    if (host.contains(':')) {
      final parts = host.split(':');
      if (parts.length == 2 && int.tryParse(parts[1]) != null) {
        host = parts[0];
      }
    }

    if (host.isEmpty) {
      return const ServiceCategory(name: '未知服务', iconText: '?');
    }

    // Check known service domains
    for (final entry in _knownRules.entries) {
      final rule = entry.key;
      if (host == rule || host.endsWith('.$rule')) {
        return entry.value;
      }
    }

    // Extract root domain
    final root = extractRootDomain(host);
    final initial = root.isNotEmpty ? root[0].toUpperCase() : '?';
    return ServiceCategory(name: root, iconText: initial);
  }

  static String extractRootDomain(String host) {
    // Check if IP address
    final ipv4 = RegExp(r'^\d+\.\d+\.\d+\.\d+$');
    if (ipv4.hasMatch(host) || host.contains(':')) {
      return host;
    }

    for (final tld in _twoPartTlds) {
      if (host.endsWith(tld)) {
        final prefix = host.substring(0, host.length - tld.length);
        final parts = prefix.split('.');
        final last = parts.isNotEmpty ? parts.last : '';
        return '$last$tld';
      }
    }

    final parts = host.split('.');
    if (parts.length >= 2) {
      return '${parts[parts.length - 2]}.${parts.last}';
    }
    return host;
  }

  static List<AggregatedSiteGroup> aggregateSites(List<TargetSiteData> sites) {
    final Map<String, List<TargetSiteData>> groups = {};
    final Map<String, ServiceCategory> categories = {};

    for (final site in sites) {
      final cat = classify(site.host);
      groups.putIfAbsent(cat.name, () => []).add(site);
      categories[cat.name] = cat;
    }

    final list = groups.entries.map((e) {
      final cat = categories[e.key]!;
      final subSites = e.value..sort((a, b) => b.total.compareTo(a.total));
      return AggregatedSiteGroup(
        key: e.key,
        displayName: cat.name,
        iconText: cat.iconText,
        brandColor: cat.brandColor,
        subSites: subSites,
      );
    }).toList();

    list.sort((a, b) => b.total.compareTo(a.total));
    return list;
  }
}
