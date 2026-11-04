import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart';

List<CoreEvent> coreEventsFromData(Object? data) {
  final items = data is List ? data : [data];
  final events = <CoreEvent>[];
  for (final item in items.whereType<Map>()) {
    try {
      events.add(CoreEvent.fromJson(Map<String, Object?>.from(item)));
    } catch (error) {
      commonPrint.log(
        'Unable to parse Core event: $error',
        logLevel: LogLevel.error,
      );
    }
  }
  return events;
}

abstract mixin class CoreEventListener {
  void onLog(Log log) {}

  void onDelay(Delay delay) {}

  void onRequest(TrackerInfo connection) {}

  void onRequestTraffic(Map<String, RequestTraffic> traffic) {}

  /// Delivered after final cumulative counters in the same FIFO message.
  void onRequestsClosed(Set<String> ids) {}

  void onDns(DnsQuery dnsQuery) {}

  void onLoaded(String providerName) {}

  void onCrash(String message) {}

  void onGeoUpdate(
    String geoType,
    bool updating,
    bool skipped,
    String? error,
  ) {}

  void onRouteChanged(RouteSnapshot snapshot) {}

  void onDialerLoop(String proxyName) {}
}

class CoreEventManager {
  final _controller = StreamController<CoreEvent>();

  CoreEventManager._() {
    _controller.stream.listen((event) {
      for (final CoreEventListener listener in List.of(_listeners)) {
        try {
          switch (event.type) {
            case CoreEventType.log:
              listener.onLog(Log.fromJson(event.data));
              break;
            case CoreEventType.delay:
              final delay = Delay.fromJson(event.data);
              final epoch = (event.data['epoch'] as num?)?.toInt();
              if (epoch != null) {
                delay.epoch = epoch;
              }
              listener.onDelay(delay);
              break;
            case CoreEventType.request:
              listener.onRequest(TrackerInfo.fromJson(event.data));
              break;
            case CoreEventType.requestTraffic:
              listener.onRequestTraffic({
                for (final Map item in event.data)
                  item['id'] as String: (
                    upload: (item['upload'] as num).toInt(),
                    download: (item['download'] as num).toInt(),
                    host: item['host'] as String?,
                    process: item['process'] as String?,
                    closed: item['closed'] as bool?,
                  ),
              });
              final closedIds = <String>{
                for (final Map item in event.data)
                  if (item['closed'] == true) item['id'] as String,
              };
              if (closedIds.isNotEmpty) listener.onRequestsClosed(closedIds);
              break;
            case CoreEventType.dns:
              listener.onDns(DnsQuery.fromJson(event.data));
              break;
            case CoreEventType.loaded:
              listener.onLoaded(event.data);
              break;
            case CoreEventType.crash:
              listener.onCrash(event.data);
              break;
            case CoreEventType.geoUpdate:
              final data = event.data as Map<String, dynamic>;
              listener.onGeoUpdate(
                data['type'] as String,
                data['updating'] as bool,
                data['skipped'] as bool? ?? false,
                data['error'] as String?,
              );
              break;
            case CoreEventType.routeChanged:
              listener.onRouteChanged(
                RouteSnapshot.fromJson(Map<String, Object?>.from(event.data)),
              );
              break;
            case CoreEventType.dialerLoop:
              listener.onDialerLoop(event.data as String);
              break;
          }
        } catch (error) {
          commonPrint.log(
            'Unable to dispatch Core event ${event.type.name}: $error',
            logLevel: LogLevel.error,
          );
        }
      }
    });
  }

  static final CoreEventManager instance = CoreEventManager._();

  final ObserverList<CoreEventListener> _listeners =
      ObserverList<CoreEventListener>();

  bool get hasListeners {
    return _listeners.isNotEmpty;
  }

  void sendEvent(CoreEvent event) {
    _controller.add(event);
  }

  void addListener(CoreEventListener listener) {
    _listeners.add(listener);
  }

  void removeListener(CoreEventListener listener) {
    _listeners.remove(listener);
  }
}

final coreEventManager = CoreEventManager.instance;
