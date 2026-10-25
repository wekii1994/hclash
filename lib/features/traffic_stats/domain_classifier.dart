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
  final int upload;
  final int download;
  final int count;

  int get total => upload + download;

  AggregatedSiteGroup({
    required this.key,
    required this.displayName,
    required this.iconText,
    this.brandColor,
    required this.subSites,
  })  : upload = subSites.fold(0, (sum, s) => sum + s.upload),
        download = subSites.fold(0, (sum, s) => sum + s.download),
        count = subSites.fold(0, (sum, s) => sum + s.count);
}

class DomainClassifier {
  static final RegExp _ipv4Regex = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

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

  /// 剥离 Host 中的端口号，兼容 IPv4:port 与 [IPv6]:port
  static String stripPort(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    if (host.isEmpty) return '';

    // 处理 [2001:db8::1]:443 格式
    if (host.startsWith('[')) {
      final closeIndex = host.indexOf(']');
      if (closeIndex != -1) {
        return host.substring(1, closeIndex);
      }
    }

    // 处理单冒号 host:port 格式（排除未加括号的多冒号 IPv6）
    final firstColon = host.indexOf(':');
    final lastColon = host.lastIndexOf(':');
    if (firstColon != -1 && firstColon == lastColon) {
      final portPart = host.substring(lastColon + 1);
      if (int.tryParse(portPart) != null) {
        return host.substring(0, lastColon);
      }
    }

    return host;
  }

  static bool isIpAddress(String host) {
    final clean = stripPort(host);
    if (_ipv4Regex.hasMatch(clean)) {
      return true;
    }
    // 包含冒号（已剥离单冒号端口后）即为 IPv6（含 ::ffff:192.168.1.1 等映射地址）
    if (clean.contains(':')) {
      return true;
    }
    return false;
  }

  static bool isPrivateIp(String ip) {
    if (ip == '127.0.0.1' || ip == 'localhost' || ip == '::1') return true;
    if (ip.startsWith('fe80:') || ip.startsWith('fc00:') || ip.startsWith('fd00:')) {
      return true;
    }
    final normalizedIp = ip.startsWith('::ffff:') ? ip.substring(7) : ip;
    final parts = normalizedIp.split('.');
    if (parts.length != 4) return false;
    final o1 = int.tryParse(parts[0]);
    final o2 = int.tryParse(parts[1]);
    if (o1 == null || o2 == null) return false;

    if (o1 == 10) return true;
    if (o1 == 192 && o2 == 168) return true;
    if (o1 == 172 && o2 >= 16 && o2 <= 31) return true;
    if (o1 == 169 && o2 == 254) return true;
    if (o1 == 100 && o2 >= 64 && o2 <= 127) return true; // Carrier-grade NAT / Tailscale 等
    return false;
  }

  static bool isTelegramIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final o1 = int.tryParse(parts[0]);
    final o2 = int.tryParse(parts[1]);
    final o3 = int.tryParse(parts[2]);
    if (o1 == null || o2 == null || o3 == null) return false;

    if (o1 == 149 && o2 == 154 && o3 >= 160 && o3 <= 175) return true;
    if (o1 == 91 && o2 == 108 && o3 >= 4 && o3 <= 23) return true;
    if (o1 == 91 && o2 == 108 && o3 >= 56 && o3 <= 59) return true;

    return false;
  }

  static ServiceCategory? classifyIp(String ip) {
    if (ip == '127.0.0.1' || ip == 'localhost' || ip == '::1') {
      return const ServiceCategory(
        name: '本地回环 (Localhost)',
        iconText: 'LAN',
        brandColor: Color(0xFF607D8B),
      );
    }
    if (isPrivateIp(ip)) {
      return const ServiceCategory(
        name: '局域网设备 (LAN)',
        iconText: 'LAN',
        brandColor: Color(0xFF009688),
      );
    }
    if (isTelegramIp(ip)) {
      return const ServiceCategory(
        name: 'Telegram',
        iconText: 'TG',
        brandColor: Color(0xFF2AABEE),
      );
    }
    if (ip == '1.1.1.1' || ip == '1.0.0.1') {
      return const ServiceCategory(
        name: 'Cloudflare DNS',
        iconText: 'CF',
        brandColor: Color(0xFFF38020),
      );
    }
    if (ip == '8.8.8.8' || ip == '8.8.4.4') {
      return const ServiceCategory(
        name: 'Google DNS',
        iconText: 'G',
        brandColor: Color(0xFF4285F4),
      );
    }
    if (ip == '114.114.114.114' || ip == '114.114.115.115') {
      return const ServiceCategory(
        name: '114 DNS',
        iconText: '114',
        brandColor: Color(0xFF00897B),
      );
    }
    if (ip == '223.5.5.5' || ip == '223.6.6.6') {
      return const ServiceCategory(
        name: '阿里公共 DNS',
        iconText: 'AL',
        brandColor: Color(0xFFFF5000),
      );
    }
    if (ip == '119.29.29.29' || ip == '182.254.116.116') {
      return const ServiceCategory(
        name: '腾讯 DNSPod',
        iconText: 'TX',
        brandColor: Color(0xFF12B7F5),
      );
    }
    if (ip.startsWith('17.')) {
      return const ServiceCategory(
        name: 'Apple',
        iconText: 'AP',
        brandColor: Color(0xFF888888),
      );
    }
    if (ip.startsWith('104.')) {
      final parts = ip.split('.');
      if (parts.length == 4) {
        final o2 = int.tryParse(parts[1]);
        if (o2 != null && o2 >= 16 && o2 <= 31) {
          return const ServiceCategory(
            name: 'Cloudflare',
            iconText: 'CF',
            brandColor: Color(0xFFF38020),
          );
        }
      }
    }
    return null;
  }

  static String? friendlyAppName(String? process) {
    if (process == null || process.trim().isEmpty) return null;
    final p = process.trim().toLowerCase();
    if (p.contains('telegram') || p.contains('challegram')) return 'Telegram';
    if (p.contains('youtube')) return 'YouTube';
    if (p.contains('bilibili') || p.contains('danmaku.bili')) return '哔哩哔哩';
    if (p.contains('tencent.mm')) return '微信';
    if (p.contains('tencent.mobileqq') || p.contains('tencent.tim')) return 'QQ';
    if (p.contains('netease.cloudmusic')) return '网易云音乐';
    if (p.contains('twitter') || p.contains('com.twitter')) return 'X (Twitter)';
    if (p.contains('github')) return 'GitHub';
    if (p.contains('spotify')) return 'Spotify';
    if (p.contains('netflix')) return 'Netflix';
    if (p.contains('tiktok') || p.contains('aweme') || p.contains('byteoversea')) return 'TikTok / 抖音';
    if (p.contains('coolapk')) return '酷安';
    if (p.contains('chrome')) return 'Chrome';
    if (p.contains('firefox')) return 'Firefox';
    if (p.contains('edge')) return 'Edge';
    if (p.contains('clash')) return 'Clash 内核';

    if (process.contains('.')) {
      final parts = process.split('.');
      if (parts.length >= 2) {
        final last = parts.last;
        if (last.length >= 3) {
          return last[0].toUpperCase() + last.substring(1);
        }
      }
    }
    return process;
  }

  static ServiceCategory classify(String rawHost, {String? process}) {
    final host = stripPort(rawHost);

    if (host.isEmpty) {
      return const ServiceCategory(name: '未知服务', iconText: '?');
    }

    // 1. IP Address Classification
    if (isIpAddress(host)) {
      final ipCat = classifyIp(host);
      if (ipCat != null) {
        return ipCat;
      }

      final app = friendlyAppName(process);
      if (app != null && app.isNotEmpty) {
        final initial = app[0].toUpperCase();
        return ServiceCategory(
          name: '$app (IP直连)',
          iconText: initial.length > 2 ? initial.substring(0, 2) : initial,
          brandColor: const Color(0xFF3F51B5),
        );
      }

      return const ServiceCategory(
        name: 'IP 直连访问',
        iconText: 'IP',
        brandColor: Color(0xFF607D8B),
      );
    }

    // 2. Check known service domains
    for (final entry in _knownRules.entries) {
      final rule = entry.key;
      if (host == rule || host.endsWith('.$rule')) {
        return entry.value;
      }
    }

    // 3. Extract root domain
    final root = extractRootDomain(host);
    final initial = root.isNotEmpty ? root[0].toUpperCase() : '?';
    return ServiceCategory(name: root, iconText: initial);
  }

  static String extractRootDomain(String host) {
    if (isIpAddress(host)) {
      return host;
    }

    for (final tld in _twoPartTlds) {
      if (host.endsWith(tld) && host.length > tld.length) {
        final prefix = host.substring(0, host.length - tld.length);
        final parts = prefix.split('.');
        final last = parts.isNotEmpty ? parts.last : '';
        if (last.isNotEmpty) {
          return '$last$tld';
        }
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
      final cat = classify(site.host, process: site.process);
      groups.putIfAbsent(cat.name, () => []).add(site);
      categories[cat.name] = cat;
    }

    final list = groups.entries.map((e) {
      final cat = categories[e.key]!;
      final subSites = List<TargetSiteData>.from(e.value)
        ..sort((a, b) => b.total.compareTo(a.total));
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

