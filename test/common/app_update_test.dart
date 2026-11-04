import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/app_update.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/package.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('selfUpdateAssetSuffix', () {
    test('names the APK built for the running ABI', () {
      expect(
        selfUpdateAssetSuffix(Abi.androidArm64, windowsInstalled: false),
        'android-arm64-v8a.apk',
      );
      expect(
        selfUpdateAssetSuffix(Abi.androidArm, windowsInstalled: false),
        isNull,
      );
      expect(
        selfUpdateAssetSuffix(Abi.androidX64, windowsInstalled: false),
        isNull,
      );
    });

    test('does not offer installers the fork does not publish', () {
      expect(
        selfUpdateAssetSuffix(Abi.windowsX64, windowsInstalled: true),
        isNull,
      );
      expect(
        selfUpdateAssetSuffix(Abi.windowsArm64, windowsInstalled: true),
        isNull,
      );
      expect(
        selfUpdateAssetSuffix(Abi.windowsX64, windowsInstalled: false),
        isNull,
      );
    });

    test('leaves macOS and Linux to the release page', () {
      for (final abi in [
        Abi.macosArm64,
        Abi.macosX64,
        Abi.linuxX64,
        Abi.linuxArm64,
      ]) {
        expect(selfUpdateAssetSuffix(abi, windowsInstalled: true), isNull);
      }
    });
  });

  test('releaseAssetName drops the tag prefix', () {
    expect(
      releaseAssetName('v0.9.3', 'android-arm64-v8a.apk'),
      '$appName-0.9.3-android-arm64-v8a.apk',
    );
  });

  test('fork prereleases compare numerically and stay below stable', () {
    expect(compareVersions('v0.9.3-pre10', 'v0.9.3-pre9'), greaterThan(0));
    expect(compareVersions('v0.9.3-pre22', '0.9.3-pre22'), 0);
    expect(compareVersions('0.9.3', '0.9.3-pre22'), greaterThan(0));
    expect(compareVersions('0.9.3-pre1', '0.9.2-pre22'), greaterThan(0));
    expect(compareVersions('0.9.3-pre1', '0.9.3'), lessThan(0));
  });

  test('fork assets and checksums use the published release paths', () {
    final name = releaseAssetName('v0.9.3-pre1', 'android-arm64-v8a.apk');
    expect(
      releaseAssetUri('v0.9.3-pre1', name).toString(),
      'https://github.com/wekii1994/hclash/releases/download/v0.9.3-pre1/hclash-0.9.3-pre1-android-arm64-v8a.apk',
    );
    expect(releaseChecksumsName, 'sha256sum.txt');
  });

  group('releaseChecksum', () {
    const digest =
        'ff6a953c0f5c12e6bdc97b49428b565b64c4a62d85e50081823ba297407529b1';

    test('reads the entry sha256sum wrote for a file', () {
      final sums =
          '$digest  ./FlClash-0.9.2-android-arm64-v8a.apk\n'
          '${'0' * 64}  ./FlClash-0.9.2-windows-amd64-setup.exe\n';

      expect(
        releaseChecksum(sums, 'FlClash-0.9.2-android-arm64-v8a.apk'),
        digest,
      );
    });

    test('accepts the binary marker, upper case and CRLF', () {
      final sums = '${digest.toUpperCase()} *FlClash.apk\r\n';

      expect(releaseChecksum(sums, 'FlClash.apk'), digest);
    });

    test('answers null for a file the listing does not name', () {
      expect(releaseChecksum('$digest  ./other.apk\n', 'FlClash.apk'), isNull);
      expect(releaseChecksum('not a listing', 'FlClash.apk'), isNull);
    });
  });

  test('fileSha256 hashes the file on disk', () async {
    final directory = await Directory.systemTemp.createTemp('app_update');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/package');
    await file.writeAsString('package');

    expect(
      await fileSha256(file.path),
      sha256.convert(utf8.encode('package')).toString(),
    );
  });

  test('windowsUpdateArguments installs silently on behalf of a pid', () {
    final arguments = windowsUpdateArguments(4242).split(' ');

    expect(arguments, containsAll(['/SILENT', '/SUPPRESSMSGBOXES']));
    expect(arguments, contains('/updatefrom=4242'));
  });
}
