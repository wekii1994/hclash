part of '../state.dart';

@riverpod
UpdateParams updateParams(Ref ref) {
  final authentication = ref.watch(
    networkSettingProvider.select((state) => state.authentication),
  );
  final checkCertificate = ref.watch(
    appSettingProvider.select((state) => state.checkCertificate),
  );
  return ref.watch(
    patchClashConfigProvider.select(
      (state) => state.toUpdateParams(
        authentication: authentication.credentials,
        skipCertVerify: !checkCertificate,
      ),
    ),
  );
}

@riverpod
({PatchClashConfig patchConfig, bool appendSystemDns, bool bypassPrivateRoute})
setupPatch(Ref ref) {
  return (
    patchConfig: ref.watch(
      patchClashConfigProvider.select((state) => state.setupOnly),
    ),
    appendSystemDns: ref.watch(
      networkSettingProvider.select((state) => state.appendSystemDns),
    ),
    // Android's VPN service takes it on its next start instead.
    bypassPrivateRoute:
        system.isDesktop &&
        ref.watch(
          networkSettingProvider.select((state) => state.bypassPrivateRoute),
        ),
  );
}

@riverpod
TrayState trayState(Ref ref) {
  final isStart = ref.watch(runTimeProvider.select((state) => state != null));
  final systemProxy = ref.watch(
    networkSettingProvider.select((state) => state.systemProxy),
  );
  final clashConfig = ref.watch(
    patchClashConfigProvider.select(
      (state) => (
        mode: state.mode,
        mixedPort: state.mixedPort,
        tunEnable: state.tun.enable,
      ),
    ),
  );
  final appSetting = ref.watch(
    appSettingProvider.select(
      (state) => (
        autoLaunch: state.autoLaunch,
        showTrayTitle: state.showTrayTitle,
        monochromeTrayIcon: state.monochromeTrayIcon,
      ),
    ),
  );
  final groups = ref.watch(currentGroupsStateProvider).value;
  final selectedMap = ref.watch(selectedMapProvider);
  final safeMode = ref.watch(safeModeProvider);
  final suspended = ref.watch(suspendProvider);
  final hotKeys = _trayHotKeys(ref);

  return TrayState(
    mode: clashConfig.mode,
    port: clashConfig.mixedPort,
    autoLaunch: appSetting.autoLaunch,
    systemProxy: systemProxy,
    tunEnable: clashConfig.tunEnable,
    isStart: isStart,
    suspended: isStart && suspended,
    groups: groups,
    selectedMap: selectedMap,
    showTrayTitle: appSetting.showTrayTitle,
    monochromeTrayIcon: appSetting.monochromeTrayIcon,
    safeMode: safeMode,
    hotKeys: hotKeys,
  );
}

Map<HotAction, HotKeyAction> _trayHotKeys(Ref ref) {
  final failures = ref.watch(hotKeyFailuresProvider);
  return {
    for (final hotKeyAction in ref.watch(hotKeyActionsProvider))
      if (isValidHotKey(hotKeyAction.modifiers, hotKeyAction.key) &&
          !failures.containsKey(hotKeyAction.action))
        hotKeyAction.action: hotKeyAction,
  };
}

/// Measured delays of the proxies the tray lists, by group and then proxy
/// name. Resolved like a proxy card, so a nested group shows its selection.
@riverpod
Map<String, Map<String, int>> trayDelays(Ref ref) {
  final delayMap = ref.watch(delayDataSourceProvider);
  if (delayMap.isEmpty) {
    return const {};
  }
  final groups = ref.watch(currentGroupsStateProvider).value;
  final allGroups = ref.watch(groupsProvider);
  final selectedMap = ref.watch(selectedMapProvider);
  final defaultTestUrl = ref.watch(
    patchClashConfigProvider.select((state) => state.testUrl),
  );
  final delays = <String, Map<String, int>>{};
  for (final group in groups) {
    final testUrl = group.testUrl.takeFirstValid([defaultTestUrl]);
    final groupDelays = <String, int>{};
    for (final proxy in group.all) {
      final delay = computeProxyDelayState(
        proxyName: proxy.name,
        testUrl: testUrl,
        groups: allGroups,
        selectedMap: selectedMap,
        delayMap: delayMap,
      ).delay;
      if (delay != 0) {
        groupDelays[proxy.name] = delay;
      }
    }
    if (groupDelays.isNotEmpty) {
      delays[group.name] = groupDelays;
    }
  }
  return delays;
}

@riverpod
TrayTitleState trayTitleState(Ref ref) {
  final showTrayTitle = ref.watch(
    appSettingProvider.select((state) => state.showTrayTitle),
  );
  final traffic = ref.watch(
    trafficsProvider.select((state) => state.list.safeLast(const Traffic())),
  );
  return TrayTitleState(showTrayTitle: showTrayTitle, traffic: traffic);
}

@riverpod
HotKeyAction getHotKeyAction(Ref ref, HotAction hotAction) {
  return ref.watch(
    hotKeyActionsProvider.select((state) {
      final index = state.indexWhere((item) => item.action == hotAction);
      return index != -1 ? state[index] : HotKeyAction(action: hotAction);
    }),
  );
}

@riverpod
bool shouldPatchSystemDns(Ref ref) {
  final autoSetSystemDns = ref.watch(
    networkSettingProvider.select((state) => state.autoSetSystemDns),
  );
  if (!autoSetSystemDns || ref.watch(safeModeProvider)) {
    return false;
  }
  final isStart = ref.watch(runTimeProvider.select((state) => state != null));
  final tunEnable = ref.watch(
    patchClashConfigProvider.select((state) => state.tun.enable),
  );
  final authorizationState = ref.watch(authorizedTunEnableProvider);
  return isStart &&
      tunEnable &&
      authorizationState == TunAuthorizationState.authorized;
}

Group? _findPrimaryGroup(
  List<Group> groups,
  Mode mode, {
  String? currentGroupName,
}) {
  if (groups.isEmpty) return null;
  if (mode == Mode.global) {
    return groups.getGroup('GLOBAL') ?? groups.first;
  }

  final nonGlobalGroups = groups
      .where((g) => g.name.toUpperCase() != 'GLOBAL')
      .toList();
  if (nonGlobalGroups.isEmpty) return groups.first;

  final selectorGroups = nonGlobalGroups
      .where((g) => g.type == GroupType.Selector)
      .toList();
  final searchPool = selectorGroups.isNotEmpty ? selectorGroups : nonGlobalGroups;

  // 1. 计算拓扑结构：找出入度为 0（未被其他非 GLOBAL 组引用）的根策略组
  final groupNames = nonGlobalGroups.map((g) => g.name).toSet();
  final referencedGroupNames = <String>{};
  for (final g in nonGlobalGroups) {
    for (final proxy in g.all) {
      if (groupNames.contains(proxy.name)) {
        referencedGroupNames.add(proxy.name);
      }
    }
  }
  final rootGroups = searchPool
      .where((g) => !referencedGroupNames.contains(g.name))
      .toList();

  // 优先在根策略组中搜索；若所有组相互引用导致无根组，再退回全量 searchPool
  final candidatePool = rootGroups.isNotEmpty ? rootGroups : searchPool;

  // 强入口特征词（高优先级）
  const strongPrimaryKeywords = [
    '节点选择', '选择节点', '默认代理', '代理模式', '科学上网',
    'proxy', 'proxies', 'default', 'select', '🚀', '🔰',
  ];

  // 宽泛特征词（低优先级）
  const broadPrimaryKeywords = ['全球', '代理', '节点', '主'];

  // 子分流与地区策略组排除词（防止分流组或地区组被误判为主入口）
  const excludeKeywords = [
    '手动', 'manual', '奈飞', 'netflix', 'bili', '哔哩', 'openai', 'chatgpt',
    'telegram', '电报', 'youtube', '油管', 'spotify', 'disney', 'steam',
    'game', '游戏', 'apple', '微软', 'microsoft', '漏网之鱼', '直连', '拒绝',
    '香港', '台湾', '日本', '新加坡', '美国', '韩国', '英国', '德国', '狮城',
    'hk', 'tw', 'jp', 'sg', 'us', 'kr',
  ];

  bool isExcluded(String lowerName) =>
      excludeKeywords.any((k) => lowerName.contains(k));

  // 2. 外层按关键字优先级、内层按候选组顺序匹配强特征词
  for (final keyword in strongPrimaryKeywords) {
    for (final group in candidatePool) {
      final lowerName = group.name.toLowerCase();
      if (!isExcluded(lowerName) && lowerName.contains(keyword)) {
        return group;
      }
    }
  }

  // 3. 拓扑特征匹配：在根策略组中，优先选包含子策略组且总节点/子项最多的组
  final rootWithSub = rootGroups
      .where((g) => g.all.any((p) => groupNames.contains(p.name)))
      .toList();
  if (rootWithSub.isNotEmpty) {
    rootWithSub.sort((a, b) => b.all.length.compareTo(a.all.length));
    return rootWithSub.first;
  }

  // 4. 宽泛关键字兜底匹配
  for (final keyword in broadPrimaryKeywords) {
    for (final group in candidatePool) {
      final lowerName = group.name.toLowerCase();
      if (!isExcluded(lowerName) && lowerName.contains(keyword)) {
        return group;
      }
    }
  }

  // 5. 回退到用户当前聚焦的分组
  if (currentGroupName != null && currentGroupName.isNotEmpty) {
    final currentGroup = groups.getGroup(currentGroupName);
    if (currentGroup != null && currentGroup.name.toUpperCase() != 'GLOBAL') {
      return currentGroup;
    }
  }

  // 6. 最终回退
  if (rootGroups.isNotEmpty) {
    rootGroups.sort((a, b) => b.all.length.compareTo(a.all.length));
    return rootGroups.first;
  }
  return searchPool.first;
}

String _resolveNotificationTitle({
  required List<Group> groups,
  required Map<String, String> selectedMap,
  required Mode mode,
  required String? currentGroupName,
  required String fallbackLabel,
  required String directLabel,
}) {
  if (mode == Mode.direct) {
    return directLabel;
  }
  final primaryGroup = _findPrimaryGroup(
    groups,
    mode,
    currentGroupName: currentGroupName,
  );
  if (primaryGroup != null) {
    final realState = computeRealSelectedProxyState(
      primaryGroup.name,
      groups: groups,
      selectedMap: selectedMap,
    );
    final resolvedName = realState.proxyName.isNotEmpty
        ? realState.proxyName
        : primaryGroup.getCurrentSelectedName(
            selectedMap[primaryGroup.name] ?? '',
          );
    if (resolvedName.isNotEmpty && groups.getGroup(resolvedName) == null) {
      if (resolvedName.toUpperCase() == 'DIRECT') {
        return directLabel;
      }
      return resolvedName;
    }
  }
  if (fallbackLabel.isNotEmpty) {
    return fallbackLabel;
  }
  return 'hclash';
}

@riverpod
SharedState sharedState(Ref ref) {
  ref.watch(loadedLocaleProvider);
  final currentProfile = ref.watch(
    currentProfileProvider.select(
      (state) => CurrentProfileSelectorState(
        label: state?.label ?? '',
        selectedMap: state?.selectedMap ?? {},
      ),
    ),
  );
  final currentGroupName = ref.watch(
    currentProfileProvider.select((state) => state?.currentGroupName),
  );
  final mode = ref.watch(
    patchClashConfigProvider.select((state) => state.mode),
  );
  final appSetting = ref.watch(
    appSettingProvider.select(
      (state) => (
        onlyStatisticsProxy: state.onlyStatisticsProxy,
        showStopAction: state.showNotificationStopAction,
        checkCertificate: state.checkCertificate,
      ),
    ),
  );
  final selectedMap = currentProfile.selectedMap;
  final fallbackLabel = currentProfile.label;
  final directLabel = currentAppLocalizations.direct;

  // 仅当解析出的最终节点标题字符串发生变化时才触发重建，忽略测速时的 delay 变化
  final currentProfileName = ref.watch(
    groupsProvider.select(
      (groups) => _resolveNotificationTitle(
        groups: groups,
        selectedMap: selectedMap,
        mode: mode,
        currentGroupName: currentGroupName,
        fallbackLabel: fallbackLabel,
        directLabel: directLabel,
      ),
    ),
  );
  final onlyStatisticsProxy = appSetting.onlyStatisticsProxy;
  final testUrl = ref.watch(
    patchClashConfigProvider.select((state) => state.testUrl),
  );
  return SharedState(
    currentProfileName: currentProfileName,
    onlyStatisticsProxy: onlyStatisticsProxy,
    showStopAction: appSetting.showStopAction,
    stopText: currentAppLocalizations.stop,
    stopTip: currentAppLocalizations.stopVpn,
    startTip: currentAppLocalizations.startVpn,
    localNetworkTip: currentAppLocalizations.localNetworkDeniedTip,
    setupParams: SetupParams(
      selectedMap: selectedMap,
      testUrl: testUrl,
      skipCertVerify: !appSetting.checkCertificate,
    ),
    vpnOptions: ref.watch(vpnOptionsProvider).value,
  );
}

@Riverpod(keepAlive: true)
Future<List<String>> vpnRouteAddress(Ref ref) {
  final routes = ref.watch(
    patchClashConfigProvider.select(
      (state) => Tun(
        routeAddress: state.tun.routeAddress,
        routeExcludeAddress: state.tun.routeExcludeAddress,
      ),
    ),
  );
  final bypassPrivateRoute = ref.watch(
    networkSettingProvider.select((state) => state.bypassPrivateRoute),
  );
  return routes.vpnRouteAddress(bypassPrivateRoute: bypassPrivateRoute);
}

@Riverpod(keepAlive: true)
Future<VpnOptions> vpnOptions(Ref ref) async {
  final networkSetting = ref.watch(
    networkSettingProvider.select(
      (state) => (
        bypassDomain: state.bypassDomain,
        authenticated: state.authentication.credentials.isNotEmpty,
      ),
    ),
  );
  final clashConfig = ref.watch(
    patchClashConfigProvider.select(
      (state) => (tun: state.tun, mixedPort: state.mixedPort),
    ),
  );
  final vpnSetting = ref.watch(vpnSettingProvider);
  final safeMode = ref.watch(safeModeProvider);
  final routeAddress = ref.watch(vpnRouteAddressProvider.future);
  final tun = clashConfig.tun;
  return VpnOptions(
    enable: vpnSetting.enable && !safeMode,
    stack: tun.stack.name,
    // VpnService.setHttpProxy cannot carry credentials, so an authenticated
    // mixed port is left to TUN instead of declared as the system proxy.
    systemProxy:
        vpnSetting.systemProxy && !networkSetting.authenticated && !safeMode,
    port: clashConfig.mixedPort,
    ipv6: vpnSetting.ipv6,
    dnsHijacking: vpnSetting.dnsHijacking,
    accessControlProps: vpnSetting.accessControlProps,
    allowBypass: vpnSetting.allowBypass,
    bypassDomain: networkSetting.bypassDomain,
    routeAddress: await routeAddress,
    mtu: tun.mtu,
    congestionController: tun.congestionController,
  );
}

@riverpod
class AccessControlState extends _$AccessControlState
    with AutoDisposeNotifierMixin {
  @override
  AccessControlProps build() => const AccessControlProps();
}

@riverpod
bool suspend(Ref ref) {
  final currentSSID = ref.watch(currentSSIDProvider);
  final excludeSSIDs = ref.watch(excludeSSIDsProvider);
  return excludeSSIDs.contains(currentSSID);
}
