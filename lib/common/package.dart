import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'common.dart';

extension PackageInfoExtension on PackageInfo {
  String get ua => [
    '$appName/v$version',
    'clash-verge',
    'Platform/${Platform.operatingSystem}',
  ].join(' ');
}

int compareVersions(String version1, String version2) {
  version1 = version1.replaceFirst(RegExp(r'^v'), '');
  version2 = version2.replaceFirst(RegExp(r'^v'), '');
  final release1 = version1.split('+')[0].split('-');
  final release2 = version2.split('+')[0].split('-');
  final List<String> v1 = release1.first.split('.');
  final List<String> v2 = release2.first.split('.');
  final int major1 = int.parse(v1[0]);
  final int major2 = int.parse(v2[0]);
  if (major1 != major2) {
    return major1.compareTo(major2);
  }
  final int minor1 = v1.length > 1 ? int.parse(v1[1]) : 0;
  final int minor2 = v2.length > 1 ? int.parse(v2[1]) : 0;
  if (minor1 != minor2) {
    return minor1.compareTo(minor2);
  }
  final int patch1 = v1.length > 2 ? int.parse(v1[2]) : 0;
  final int patch2 = v2.length > 2 ? int.parse(v2[2]) : 0;
  if (patch1 != patch2) {
    return patch1.compareTo(patch2);
  }
  if (release1.length != release2.length &&
      (release1.length == 1 || release2.length == 1)) {
    return release1.length == 1 ? 1 : -1;
  }
  if (release1.length > 1 && release2.length > 1) {
    List<String> parts(List<String> release) => release
        .skip(1)
        .join('-')
        .replaceFirstMapped(RegExp(r'^pre(\d+)$'), (m) => 'pre.${m[1]}')
        .split('.');
    final pre1 = parts(release1);
    final pre2 = parts(release2);
    for (var i = 0; i < pre1.length && i < pre2.length; i++) {
      final n1 = int.tryParse(pre1[i]);
      final n2 = int.tryParse(pre2[i]);
      final compared = n1 != null && n2 != null
          ? n1.compareTo(n2)
          : n1 != null
          ? -1
          : n2 != null
          ? 1
          : pre1[i].compareTo(pre2[i]);
      if (compared != 0) return compared;
    }
    if (pre1.length != pre2.length) return pre1.length.compareTo(pre2.length);
  }
  final int build1 = version1.contains('+')
      ? int.parse(version1.split('+')[1])
      : 0;
  final int build2 = version2.contains('+')
      ? int.parse(version2.split('+')[1])
      : 0;
  return build1.compareTo(build2);
}

const releaseNotesBeginMarker = '<!-- flclash:changelog:begin -->';
const releaseNotesEndMarker = '<!-- flclash:changelog:end -->';

List<String> parseReleaseBody(String? body) {
  if (body == null) return [];
  final regex = RegExp(r'^[ \t]*-[ \t]+(.*)$', multiLine: true);
  return regex
      .allMatches(scopeReleaseNotes(body))
      .map((match) => match.group(1)?.trim() ?? '')
      .where((item) => item.isNotEmpty)
      .toList();
}

String scopeReleaseNotes(String body) {
  final begin = body.indexOf(releaseNotesBeginMarker);
  if (begin < 0) return body;
  final start = begin + releaseNotesBeginMarker.length;
  final end = body.indexOf(releaseNotesEndMarker, start);
  return end < 0 ? body.substring(start) : body.substring(start, end);
}
