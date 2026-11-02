import 'dart:convert';
import 'dart:io';

/// A failed operation fails its caller, but does not poison later operations.
class SerialOperations {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then<T>((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}

abstract interface class TrafficStatsPersistence {
  Future<Map<String, dynamic>?> read();
  Future<void> write(Map<String, dynamic> snapshot);
}

/// The store serializes operations. Rename never pre-deletes the old file.
class JsonTrafficStatsPersistence implements TrafficStatsPersistence {
  JsonTrafficStatsPersistence(this.fileProvider);
  final Future<File> Function() fileProvider;

  @override
  Future<Map<String, dynamic>?> read() async {
    final file = await fileProvider();
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Traffic statistics must be a JSON object');
    }
    final version = decoded['schemaVersion'] ?? 0;
    if (version is! int || version < 0 || version > 1) {
      throw FormatException('Unsupported traffic statistics version: $version');
    }
    return decoded;
  }

  @override
  Future<void> write(Map<String, dynamic> snapshot) async {
    final file = await fileProvider();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(snapshot), flush: true);
    await temporary.rename(file.path);
  }
}
