part of '../state.dart';

@riverpod
ConfigPatch updateParams(Ref ref) {
  final authentication = ref.watch(
    networkSettingProvider.select((state) => state.authentication),
  );
  final options = ref.watch(coreOptionsProvider);
  final hostCredential = ref.watch(hostCredentialProvider);
  final tunDisabled = ref.watch(tunDisabledThisRunProvider);
  return ref.watch(
    patchClashConfigProvider.select(
      (state) => configPatchOf(
        tunDisabled ? state.copyWith.tun(enable: false) : state,
        authentication: authentication.credentials,
        hostCredential: hostCredential,
        options: options,
      ),
    ),
  );
}

@riverpod
CoreOptions coreOptions(Ref ref) {
  final (:testUrl, :mitmCapture) = ref.watch(
    patchClashConfigProvider.select(
      (state) => (testUrl: state.testUrl, mitmCapture: state.mitm.capture),
    ),
  );
  final (:checkCertificate, :delayTestTimeout) = ref.watch(
    appSettingProvider.select(
      (state) => (
        checkCertificate: state.checkCertificate,
        delayTestTimeout: state.delayTestTimeout,
      ),
    ),
  );
  return CoreOptions(
    testUrl: testUrl,
    skipCertVerify: !checkCertificate,
    delayTestTimeout: delayTestTimeout,
    mitmCapture: mitmCapture,
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

Group? _findPrimaryGroup(
  List<Group> groups,
  Mode mode, {
  String? currentGroupName,
}) {
  if (groups.isEmpty) return null;
  if (mode == Mode.global) {
    return groups.getGroup('GLOBAL') ?? groups.first;
  }

  final nonGlobalGroups =
      groups.where((g) => g.name.toUpperCase() != 'GLOBAL').toList();
  if (nonGlobalGroups.isEmpty) return groups.first;

  final selectorGroups = nonGlobalGroups
      .where(
        (g) => g.type == GroupType.Selector || g.type == GroupType.Smart,
      )
      .toList();
  final searchPool =
      selectorGroups.isNotEmpty ? selectorGroups : nonGlobalGroups;

  final groupNames = nonGlobalGroups.map((g) => g.name).toSet();
  final referencedGroupNames = <String>{};
  for (final g in nonGlobalGroups) {
    for (final proxy in g.all) {
      if (groupNames.contains(proxy.name)) {
        referencedGroupNames.add(proxy.name);
      }
    }
  }
  final rootGroups =
      searchPool.where((g) => !referencedGroupNames.contains(g.name)).toList();

  final candidatePool = rootGroups.isNotEmpty ? rootGroups : searchPool;

  const strongPrimaryKeywords = [
    '节点选择',
    '选择节点',
    '默认代理',
    '代理模式',
    '科学上网',
    'proxy',
    'proxies',
    'default',
    'select',
    '🚀',
    '🔰',
  ];

  const broadPrimaryKeywords = ['全球', '代理', '节点', '主'];

  const excludeKeywords = [
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
    '直连',
    '拒绝',
    '香港',
    '台湾',
    '日本',
    '新加坡',
    '美国',
    '韩国',
    '英国',
    '德国',
    '狮城',
    'hk',
    'tw',
    'jp',
    'sg',
    'us',
    'kr',
  ];

  bool isExcluded(String lowerName) =>
      excludeKeywords.any((k) => lowerName.contains(k));

  for (final keyword in strongPrimaryKeywords) {
    for (final group in candidatePool) {
      final lowerName = group.name.toLowerCase();
      if (!isExcluded(lowerName) && lowerName.contains(keyword)) {
        return group;
      }
    }
  }

  final rootWithSub = rootGroups
      .where((g) => g.all.any((p) => groupNames.contains(p.name)))
      .toList();
  if (rootWithSub.isNotEmpty) {
    rootWithSub.sort((a, b) => b.all.length.compareTo(a.all.length));
    return rootWithSub.first;
  }

  for (final keyword in broadPrimaryKeywords) {
    for (final group in candidatePool) {
      final lowerName = group.name.toLowerCase();
      if (!isExcluded(lowerName) && lowerName.contains(keyword)) {
        return group;
      }
    }
  }

  if (currentGroupName != null && currentGroupName.isNotEmpty) {
    final currentGroup = groups.getGroup(currentGroupName);
    if (currentGroup != null && currentGroup.name.toUpperCase() != 'GLOBAL') {
      return currentGroup;
    }
  }

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
  final groups = ref.watch(groupsProvider);
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
  final currentProfileName = _resolveNotificationTitle(
    groups: groups,
    selectedMap: currentProfile.selectedMap,
    mode: mode,
    currentGroupName: currentGroupName,
    fallbackLabel: currentProfile.label,
    directLabel: currentAppLocalizations.direct,
  );
  final selectedMap = currentProfile.selectedMap;
  final hostCredential = ref.watch(hostCredentialProvider);
  final safeMode = ref.watch(safeModeProvider);
  final onlyStatisticsProxy = appSetting.onlyStatisticsProxy;
  return SharedState(
    currentProfileName: currentProfileName,
    onlyStatisticsProxy: onlyStatisticsProxy,
    showStopAction: appSetting.showStopAction,
    stopText: currentAppLocalizations.stop,
    stopTip: currentAppLocalizations.stopVpn,
    startTip: currentAppLocalizations.startVpn,
    setupParams: SetupParams(
      selectedMap: selectedMap,
      options: ref.watch(coreOptionsProvider),
      host: ref.watch(
        patchClashConfigProvider.select(
          (config) => hostSettingsOf(
            config,
            credential: hostCredential,
            safeMode: safeMode,
          ),
        ),
      ),
    ),
    vpnOptions: ref.watch(vpnOptionsProvider).value,
    mitm: ref.watch(
      patchClashConfigProvider.select((config) => config.mitm.enable),
    ),
  );
}

@Riverpod(keepAlive: true)
Future<List<String>> vpnRouteAddress(Ref ref) async {
  final modules = ref.watch(mitmModuleNetworkProvider.future);
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
  final network = await modules;
  return routes
      .copyWith(
        routeAddress: routes.routeAddress.isEmpty
            ? const []
            : {...routes.routeAddress, ...network.routeAddress}.toList(),
        routeExcludeAddress: {
          ...routes.routeExcludeAddress,
          ...?network.routeExcludeAddress?.values,
        }.toList(),
      )
      .vpnRouteAddress(bypassPrivateRoute: bypassPrivateRoute);
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
  final modules = ref.watch(mitmModuleNetworkProvider.future);
  final tun = clashConfig.tun;
  return VpnOptions(
    enable: vpnSetting.enable && !safeMode,
    // VpnService.setHttpProxy cannot carry credentials, so an authenticated
    // mixed port is left to TUN instead of declared as the system proxy.
    systemProxy:
        vpnSetting.systemProxy && !networkSetting.authenticated && !safeMode,
    port: clashConfig.mixedPort,
    ipv6: vpnSetting.ipv6,
    dnsHijacking: vpnSetting.dnsHijacking,
    accessControlProps: vpnSetting.accessControlProps,
    allowBypass: vpnSetting.allowBypass,
    bypassDomain:
        (await modules).bypassDomain?.applyTo(networkSetting.bypassDomain) ??
        networkSetting.bypassDomain,
    routeAddress: await routeAddress,
    mtu: tun.mtu,
    congestionController: tun.congestionController,
  );
}

@riverpod
class AccessControlState extends _$AccessControlState
    with AutoDisposeNotifierMixin {
  /// A draft of the saved props, which the access page edits until it saves.
  @override
  AccessControlProps build() =>
      ref.read(vpnSettingProvider.select((state) => state.accessControlProps));
}

@riverpod
bool suspend(Ref ref) {
  final currentSSID = ref.watch(currentSSIDProvider);
  final excludeSSIDs = ref.watch(excludeSSIDsProvider);
  return excludeSSIDs.contains(currentSSID);
}

/// Keeps a start on screen for [minimumStart] so a fast restart does not flash.
@riverpod
class HeldCoreStatus extends _$HeldCoreStatus {
  static const minimumStart = Duration(milliseconds: 1500);

  Timer? _hold;

  @override
  CoreStatus build() {
    ref.onDispose(() => _hold?.cancel());
    ref.listen(coreStatusProvider, (_, next) {
      switch (next) {
        case CoreStatus.connecting:
          _hold ??= Timer(minimumStart, () {
            _hold = null;
            state = ref.read(coreStatusProvider);
          });
          state = next;
        case CoreStatus.disconnected:
          _hold?.cancel();
          _hold = null;
          state = next;
        case CoreStatus.connected:
          if (_hold == null) state = next;
      }
    });
    return ref.read(coreStatusProvider);
  }
}
