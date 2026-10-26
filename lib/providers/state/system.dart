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

  // 主入口策略组关键字（注意：排除了子服务分流关键字与手动选择）
  const primaryKeywords = [
    '默认代理',
    '节点选择',
    '选择节点',
    '代理模式',
    '科学上网',
    'proxy',
    'proxies',
    'default',
    'select',
    '节点',
    '代理',
    '全球',
    '主',
    '🚀',
    '🔰',
  ];

  // 典型子分流/媒体策略组关键字（避免类似“🎬 奈飞节点”、“🤖 OpenAI代理”被误判为主入口）
  const subServiceKeywords = [
    '手动',
    'manual',
    '奈飞',
    'netflix',
    'bili',
    '哔哩',
    'openai',
    'chatgpt',
    'telegram',
    '电报',
    'youtube',
    '油管',
    'spotify',
    'disney',
    'steam',
    'game',
    '游戏',
    'apple',
    '微软',
    'microsoft',
    '漏网之鱼',
  ];

  // 1. 优先按订阅中定义的策略组顺序，查找名称匹配主入口关键字且非特定子分流的 Selector 组
  for (final group in searchPool) {
    final lowerName = group.name.toLowerCase();
    if (subServiceKeywords.any((k) => lowerName.contains(k))) {
      continue;
    }
    for (final keyword in primaryKeywords) {
      if (lowerName.contains(keyword.toLowerCase())) {
        return group;
      }
    }
  }

  // 2. 拓扑特征匹配：优先选择未被其他非 GLOBAL 策略组引用（入度为 0）且包含子项最多的 Selector 组
  final groupNames = nonGlobalGroups.map((g) => g.name).toSet();
  final referencedGroupNames = <String>{};
  for (final g in nonGlobalGroups) {
    for (final proxy in g.all) {
      if (groupNames.contains(proxy.name)) {
        referencedGroupNames.add(proxy.name);
      }
    }
  }

  // 2.1 优先查找入度为 0 且包含子策略组的根 Selector 组（按子项数量降序排列）
  final rootGroupsWithSub = searchPool.where((g) {
    final isRoot = !referencedGroupNames.contains(g.name);
    final hasSubGroup = g.all.any((p) => groupNames.contains(p.name));
    return isRoot && hasSubGroup;
  }).toList();

  if (rootGroupsWithSub.isNotEmpty) {
    rootGroupsWithSub.sort((a, b) => b.all.length.compareTo(a.all.length));
    return rootGroupsWithSub.first;
  }

  // 2.2 查找入度为 0 的根 Selector 组（按子项数量降序排列）
  final rootGroups = searchPool
      .where((g) => !referencedGroupNames.contains(g.name))
      .toList();
  if (rootGroups.isNotEmpty) {
    rootGroups.sort((a, b) => b.all.length.compareTo(a.all.length));
    return rootGroups.first;
  }

  // 2.3 兜底查找任意包含子策略组的 Selector 组（按子项数量降序排列）
  final anyGroupsWithSub = searchPool
      .where((g) => g.all.any((p) => groupNames.contains(p.name)))
      .toList();
  if (anyGroupsWithSub.isNotEmpty) {
    anyGroupsWithSub.sort((a, b) => b.all.length.compareTo(a.all.length));
    return anyGroupsWithSub.first;
  }

  // 3. 回退到用户当前聚焦的分组或第一个非 GLOBAL 分组
  if (currentGroupName != null && currentGroupName.isNotEmpty) {
    final currentGroup = groups.getGroup(currentGroupName);
    if (currentGroup != null && currentGroup.name.toUpperCase() != 'GLOBAL') {
      return currentGroup;
    }
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
