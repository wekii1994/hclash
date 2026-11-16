import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PlatformDispatcher;

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

class SiteIconCache {
  static const _version = '1';
  static const _missTtl = Duration(days: 7);
  static const _unusedTtl = Duration(days: 60);
  static const _touchAge = Duration(days: 7);
  static const _timeout = Duration(seconds: 5);
  static const _listSize = 32;
  static const _minSize = 32;
  static const _maxSize = 96;
  static const _maxConcurrent = 4;
  static const _maxEntries = 64;

  final Map<String, File?> _files = {};
  final Map<String, Future<File?>> _pending = {};
  final List<Completer<void>> _waiting = [];
  Future<Directory>? _directory;
  int _running = 0;
  int _generation = 0;

  static int get targetSize {
    final ratio =
        PlatformDispatcher.instance.views.firstOrNull?.devicePixelRatio ?? 2;
    return (_listSize * ratio).ceil().clamp(_minSize, _maxSize);
  }

  bool contains(String domain) => _files.containsKey(domain);

  File? peek(String domain) {
    if (!_files.containsKey(domain)) return null;
    final file = _files.remove(domain);
    _files[domain] = file;
    return file;
  }

  Future<File?> get(String domain) {
    if (_files.containsKey(domain)) return Future.value(peek(domain));
    final pending = _pending[domain];
    if (pending != null) return pending;
    final generation = _generation;
    late final Future<File?> future;
    future = _load(domain)
        .then((file) {
          if (generation == _generation) _remember(domain, file);
          return file;
        })
        .whenComplete(() {
          if (identical(_pending[domain], future)) _pending.remove(domain);
        });
    _pending[domain] = future;
    return future;
  }

  void _remember(String domain, File? file) {
    _files.remove(domain);
    while (_files.length >= _maxEntries) {
      _files.remove(_files.keys.first);
    }
    _files[domain] = file;
  }

  Future<String> get _directoryPath async =>
      p.join(await appPath.homeDirPath, 'site_icons');

  Future<Directory> _openDirectory() {
    return _directory ??= _prepareDirectory().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _directory = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<Directory> _prepareDirectory() async {
    final directory = Directory(await _directoryPath);
    final versionFile = File(p.join(directory.path, '.version'));
    if (await versionFile.exists() &&
        await versionFile.readAsString() == _version) {
      await _prune(directory);
      return directory;
    }
    if (await directory.exists()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
    await versionFile.writeAsString(_version, flush: true);
    return directory;
  }

  Future<void> _prune(Directory directory) async {
    final now = DateTime.now();
    try {
      await for (final entity in directory.list()) {
        if (entity is! File || p.basename(entity.path) == '.version') {
          continue;
        }
        final ttl = entity.path.endsWith('.png') ? _unusedTtl : _missTtl;
        try {
          if (now.difference(await entity.lastModified()) >= ttl) {
            await entity.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> clear() async {
    _generation++;
    _files.clear();
    _directory = null;
    try {
      final directory = Directory(await _directoryPath);
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> _touch(File file) async {
    try {
      final modified = await file.lastModified();
      if (DateTime.now().difference(modified) < _touchAge) return;
      await file.setLastModified(DateTime.now());
    } catch (_) {}
  }

  Future<File?> _load(String domain) async {
    try {
      return await _loadFile(domain);
    } catch (_) {
      return null;
    }
  }

  Future<File?> _loadFile(String domain) async {
    final directory = await _openDirectory();
    final iconFile = File(p.join(directory.path, '$domain.png'));
    if (await iconFile.exists()) {
      await _touch(iconFile);
      return iconFile;
    }
    final missFile = File(p.join(directory.path, '$domain.miss'));
    if (await missFile.exists()) {
      final modified = await missFile.lastModified();
      if (DateTime.now().difference(modified) < _missTtl) return null;
    }

    final icon = await _fetch(domain, targetSize);
    if (icon == null) {
      await missFile.writeAsString('');
      return null;
    }
    final tempFile = File('${iconFile.path}.tmp');
    await tempFile.writeAsBytes(icon, flush: true);
    if (await iconFile.exists()) await iconFile.delete();
    await tempFile.rename(iconFile.path);
    return iconFile;
  }

  static List<String> candidates(String domain, int size) {
    final enc = Uri.encodeComponent(domain);
    return [
      'https://$domain/apple-touch-icon.png',
      'https://www.google.com/s2/favicons?domain=$enc&sz=$size',
      'https://favicon.yandex.net/favicon/$domain',
      'https://api.iowen.cn/favicon/$domain.png',
    ];
  }

  Future<Uint8List?> _fetch(String domain, int size) async {
    await _acquire();
    try {
      for (final url in candidates(domain, size)) {
        final icon = await _download(url);
        if (icon != null && icon.isNotEmpty) {
          return icon;
        }
      }
      return null;
    } finally {
      _release();
    }
  }

  Future<Uint8List?> _download(String url) async {
    try {
      final res = await request
          .getFileResponseForUrl(url)
          .timeout(_timeout);
      final bytes = res.data;
      if (bytes == null || bytes.isEmpty) return null;
      return _extractValidImage(bytes);
    } catch (_) {
      try {
        final cancelToken = CancelToken();
        final timer = Timer(_timeout, cancelToken.cancel);
        try {
          final res = await request.dio.get<Uint8List>(
            url,
            cancelToken: cancelToken,
            options: Options(responseType: ResponseType.bytes),
          );
          final bytes = res.data;
          if (bytes == null || bytes.isEmpty) return null;
          return _extractValidImage(bytes);
        } finally {
          timer.cancel();
        }
      } catch (_) {
        return null;
      }
    }
  }

  static Uint8List? _extractValidImage(Uint8List bytes) {
    if (bytes.length < 8) return null;

    // Standard PNG
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return bytes;
    }

    // Standard JPEG
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return bytes;
    }

    // Standard GIF
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      return bytes;
    }

    // Standard WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes.length >= 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return bytes;
    }

    // Modern ICO embedding PNG stream
    if (bytes[0] == 0x00 &&
        bytes[1] == 0x00 &&
        bytes[2] == 0x01 &&
        bytes[3] == 0x00) {
      for (var i = 0; i <= bytes.length - 8; i++) {
        if (bytes[i] == 0x89 &&
            bytes[i + 1] == 0x50 &&
            bytes[i + 2] == 0x4E &&
            bytes[i + 3] == 0x47) {
          return bytes.sublist(i);
        }
      }
    }

    return null;
  }

  Future<void> _acquire() async {
    if (_running < _maxConcurrent) {
      _running++;
      return;
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    await completer.future;
  }

  void _release() {
    if (_waiting.isEmpty) {
      _running--;
      return;
    }
    _waiting.removeAt(0).complete();
  }
}

final siteIconCache = SiteIconCache();

class SiteIcon extends StatefulWidget {
  final String domain;
  final double size;
  final bool enabled;

  const SiteIcon({
    super.key,
    required this.domain,
    this.size = 32,
    this.enabled = true,
  });

  @override
  State<SiteIcon> createState() => _SiteIconState();
}

class _SiteIconState extends State<SiteIcon> {
  File? _icon;

  bool get _isAddress => InternetAddress.tryParse(widget.domain) != null;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(SiteIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.domain != widget.domain || oldWidget.enabled != widget.enabled) {
      _resolve();
    }
  }

  void _resolve() {
    final domain = widget.domain;
    _icon = siteIconCache.peek(domain);
    if (!widget.enabled || _isAddress || domain.isEmpty) return;
    if (siteIconCache.contains(domain)) return;
    siteIconCache.get(domain).then((icon) {
      if (!mounted || widget.domain != domain) return;
      setState(() => _icon = icon);
    });
  }

  Widget _buildPlaceholder(BuildContext context) {
    final colorScheme = context.colorScheme;
    final size = widget.size;
    final shape = AppShape.all(size * 0.25);

    if (_isAddress || widget.domain.isEmpty) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: colorScheme.primary.withValues(alpha: 0.1),
          shape: shape,
        ),
        child: GlyphIcon(
          AppGlyphs.proxies,
          size: size * 0.58,
          color: colorScheme.primary,
        ),
      );
    }

    final letter = widget.domain.characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: colorScheme.primary.withValues(alpha: 0.1),
        shape: shape,
      ),
      child: Text(
        letter,
        style: AppTextStyle.subheadline
            .of(context, emphasized: true)
            .copyWith(
              color: colorScheme.primary,
              height: 1,
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final shape = AppShape.all(size * 0.25);
    final icon = widget.enabled ? _icon : null;

    if (icon == null) {
      return _buildPlaceholder(context);
    }

    return Container(
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: context.colorScheme.primary.withValues(alpha: 0.06),
        shape: shape,
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.file(
        icon,
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(context),
      ),
    );
  }
}
