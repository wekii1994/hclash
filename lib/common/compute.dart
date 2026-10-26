import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

List<Group> computeSort({
  required List<Group> groups,
  required ProxiesSortType sortType,
  required DelayMap delayMap,
  required Map<String, String> selectedMap,
  required String defaultTestUrl,
}) {
  List<Proxy> sortOfDelay({
    required List<Group> groups,
    required List<Proxy> proxies,
    required DelayMap delayMap,
    required Map<String, String> selectedMap,
    required String testUrl,
  }) {
    final delayStates = {
      for (final proxy in proxies)
        proxy.name: computeProxyDelayState(
          proxyName: proxy.name,
          testUrl: testUrl,
          groups: groups,
          selectedMap: selectedMap,
          delayMap: delayMap,
        ),
    };
    return List.of(proxies)
      ..sort((a, b) => delayStates[a.name]!.compareTo(delayStates[b.name]!));
  }

  List<Proxy> sortOfName(List<Proxy> proxies) {
    return List.of(proxies)..sort((a, b) => a.name.compareTo(b.name));
  }

  return groups.map((group) {
    final proxies = group.all;
    final newProxies = switch (sortType) {
      ProxiesSortType.none => proxies,
      ProxiesSortType.delay => sortOfDelay(
        groups: groups,
        proxies: proxies,
        delayMap: delayMap,
        selectedMap: selectedMap,
        testUrl: group.testUrl.takeFirstValid([defaultTestUrl]),
      ),
      ProxiesSortType.name => sortOfName(proxies),
    };
    return group.copyWith(all: newProxies);
  }).toList();
}

/// Built-in adapters whose delay probe always fails, so a timeout says nothing.
const _unprobeableProxyTypes = {
  'Reject',
  'RejectDrop',
  'Pass',
  'PassRule',
  'Rematch',
  'Compatible',
  'Dns',
};

List<Group> computeHideTimeout({
  required List<Group> groups,
  required List<Group> allGroups,
  required DelayMap delayMap,
  required Map<String, String> selectedMap,
  required String defaultTestUrl,
}) {
  final realStates = <String, SelectedProxyState>{};
  final proxyTypes = {
    for (final group in allGroups)
      for (final proxy in group.all) proxy.name: proxy.type,
  };
  return groups.map((group) {
    final groupTestUrl = group.testUrl.takeFirstValid([defaultTestUrl]);
    final groupWithNow = allGroups.getGroup(group.name) ?? group;
    final selectedName = groupWithNow.getCurrentSelectedName(
      selectedMap[group.name] ?? '',
    );
    final visible = group.all.where((proxy) {
      // A group's delay is its pick's, and hiding it would take away the only
      // way to choose the group where the mode does not show it on its own.
      if (proxy.name == selectedName ||
          allGroups.getGroup(proxy.name) != null) {
        return true;
      }
      final state = realStates.putIfAbsent(
        proxy.name,
        () => computeRealSelectedProxyState(
          proxy.name,
          groups: allGroups,
          selectedMap: selectedMap,
        ),
      );
      if (_unprobeableProxyTypes.contains(proxyTypes[state.proxyName])) {
        return true;
      }
      final testUrl = state.testUrl.takeFirstValid([groupTestUrl]);
      final delay = delayMap[testUrl]?[state.proxyName];
      return delay == null || delay > 0;
    }).toList();
    return group.copyWith(all: visible.isEmpty ? group.all : visible);
  }).toList();
}

SelectedProxyState getRealSelectedProxyState(
  SelectedProxyState state, {
  required List<Group> groups,
  required Map<String, String> selectedMap,
  Set<String>? visited,
}) {
  final seen = visited ?? <String>{};
  final proxyName = state.proxyName;
  if (proxyName.isEmpty || !seen.add(proxyName)) {
    return state;
  }
  final group = groups.getGroup(proxyName);
  if (group == null) {
    final now = groups.getRematchProxy(proxyName)?.now;
    if (now != null && now.isNotEmpty && now != proxyName) {
      return getRealSelectedProxyState(
        state.copyWith(proxyName: now, group: true),
        groups: groups,
        selectedMap: selectedMap,
        visited: seen,
      );
    }
    return state;
  }
  final currentSelectedName = group.getCurrentSelectedName(
    selectedMap[proxyName] ?? '',
  );
  if (currentSelectedName.isEmpty) {
    return state.copyWith(group: true);
  }
  return getRealSelectedProxyState(
    state.copyWith(
      proxyName: currentSelectedName,
      group: true,
      testUrl: (group.testUrl != null && group.testUrl!.isNotEmpty)
          ? group.testUrl
          : state.testUrl,
    ),
    groups: groups,
    selectedMap: selectedMap,
    visited: seen,
  );
}

SelectedProxyState computeRealSelectedProxyState(
  String proxyName, {
  required List<Group> groups,
  required Map<String, String> selectedMap,
}) {
  return getRealSelectedProxyState(
    SelectedProxyState(proxyName: proxyName),
    groups: groups,
    selectedMap: selectedMap,
  );
}

String delayTestKey(String testUrl, String proxyName) {
  return '$testUrl\u0000$proxyName';
}

DelayState computeProxyDelayState({
  required String proxyName,
  required String testUrl,
  required List<Group> groups,
  required Map<String, String> selectedMap,
  required DelayMap delayMap,
}) {
  final state = computeRealSelectedProxyState(
    proxyName,
    groups: groups,
    selectedMap: selectedMap,
  );
  final currentDelayMap =
      delayMap[state.testUrl.takeFirstValid([testUrl])] ?? {};
  final delay = currentDelayMap[state.proxyName];
  return DelayState(delay: delay ?? 0, group: state.group);
}
