import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/traffic_stats/traffic_stats.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/icons/app_glyphs.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:fl_clash/views/dashboard/widgets/card.dart';
import 'package:fl_clash/widgets/widgets.dart';

class TrafficStatisticsView extends StatefulWidget {
  const TrafficStatisticsView({super.key});

  @override
  State<TrafficStatisticsView> createState() => _TrafficStatisticsViewState();
}

class _TrafficStatisticsViewState extends State<TrafficStatisticsView> {
  TrafficStatsRange _selectedRange = TrafficStatsRange.today;
  int _selectedBarIndex = -1;
  int? _siteCount;
  bool _isAggregated = true;

  // Throttled presentation states to avoid expensive recalculations on every 800ms tick
  Timer? _metricsTimer;
  Timer? _sitesTimer;
  DateTime _lastMetricsUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSitesUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  List<ChartBarPoint>? _cachedChartPoints;
  List<AggregatedSiteGroup>? _cachedAggregatedGroups;
  List<TargetSiteData>? _cachedTopSites;
  int? _todayTotal;
  int? _weekTotal;
  TrafficDiff? _diff;

  @override
  void initState() {
    super.initState();
    TrafficStatsStore.instance.addListener(_onStoreChanged);
    TrafficStatsStore.instance.init();
    _refreshMetricsImmediately();
    _refreshSitesImmediately();
  }

  @override
  void dispose() {
    _metricsTimer?.cancel();
    _sitesTimer?.cancel();
    TrafficStatsStore.instance.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _refreshMetricsImmediately() {
    if (!mounted) return;
    _lastMetricsUpdate = DateTime.now();
    final store = TrafficStatsStore.instance;
    setState(() {
      _todayTotal = store.todayTotal;
      _weekTotal = store.weekTotal;
      _diff = store.differenceFromYesterday;
      _cachedChartPoints = store.getChartPoints(_selectedRange);
    });
  }

  void _refreshSitesImmediately() {
    if (!mounted) return;
    _lastSitesUpdate = DateTime.now();
    final store = TrafficStatsStore.instance;
    setState(() {
      if (_isAggregated) {
        _cachedAggregatedGroups = store.getAggregatedSites(limit: 50);
        _cachedTopSites = null;
      } else {
        _cachedTopSites = store.getTopSites(limit: 50);
        _cachedAggregatedGroups = null;
      }
    });
  }

  void _onStoreChanged() {
    if (!mounted) return;
    final now = DateTime.now();

    // 1. Metrics & Chart throttled to ~1 second
    final metricsElapsed = now.difference(_lastMetricsUpdate);
    if (metricsElapsed >= const Duration(milliseconds: 1000)) {
      _metricsTimer?.cancel();
      _metricsTimer = null;
      _refreshMetricsImmediately();
    } else if (_metricsTimer == null || !_metricsTimer!.isActive) {
      final remaining = const Duration(milliseconds: 1000) - metricsElapsed;
      _metricsTimer = Timer(remaining, () {
        if (mounted) _refreshMetricsImmediately();
      });
    }

    // 2. Sites ranking throttled to ~3 seconds
    final sitesElapsed = now.difference(_lastSitesUpdate);
    if (sitesElapsed >= const Duration(milliseconds: 3000)) {
      _sitesTimer?.cancel();
      _sitesTimer = null;
      _refreshSitesImmediately();
    } else if (_sitesTimer == null || !_sitesTimer!.isActive) {
      final remaining = const Duration(milliseconds: 3000) - sitesElapsed;
      _sitesTimer = Timer(remaining, () {
        if (mounted) _refreshSitesImmediately();
      });
    }
  }

  void _onRangeChanged(TrafficStatsRange range) {
    setState(() {
      _selectedRange = range;
      _selectedBarIndex = -1;
      _cachedChartPoints = TrafficStatsStore.instance.getChartPoints(_selectedRange);
    });
  }

  String _rangeLabel(TrafficStatsRange range, BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    return switch (range) {
      TrafficStatsRange.today => isZh ? '今日' : 'Today',
      TrafficStatsRange.week => isZh ? '近7天' : '7 days',
      TrafficStatsRange.month => isZh ? '近30天' : '30 days',
      TrafficStatsRange.all => isZh ? '近90天' : '90 days',
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final store = TrafficStatsStore.instance;

    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final todayText = isZh ? '今日' : 'Today';
    final weekText = isZh ? '近7天' : 'Last 7 days';
    final cleanText = isZh ? '清空' : 'Clear';
    final cleanTitle = isZh ? '清空流量统计' : 'Clear Traffic Statistics';
    final cleanTip = isZh
        ? '确定要清空所有流量统计历史和站点记录吗？此操作无法撤销。'
        : 'Are you sure you want to clear all traffic statistics and site records? This action cannot be undone.';

    final todayTotal = _todayTotal ?? store.todayTotal;
    final weekTotal = _weekTotal ?? store.weekTotal;
    final diff = _diff ?? store.differenceFromYesterday;
    final chartPoints = _cachedChartPoints ?? store.getChartPoints(_selectedRange);
    final allTopSites = _cachedTopSites ?? const <TargetSiteData>[];
    final aggregatedGroups = _cachedAggregatedGroups;
    final totalInitialCount = (aggregatedGroups?.isNotEmpty ?? false)
        ? min(50, aggregatedGroups!.length)
        : min(50, allTopSites.length);

    final uploadColor = DashboardColors.of(context).series2;
    final downloadColor = colorScheme.primary;

    return Scaffold(
      title: l.trafficUsage,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.clearAll,
          tooltip: cleanText,
          onPressed: () async {
            final confirmed = await dialogs.showMessage(
              context: context,
              title: cleanTitle,
              message: TextSpan(text: cleanTip),
              destructive: true,
            );
            if (confirmed == true) {
              if (!mounted) return;
              setState(() => _siteCount = null);
              try {
                await store.clearAll();
                if (!mounted) return;
                _refreshMetricsImmediately();
                _refreshSitesImmediately();
              } catch (_) {
                if (!context.mounted) return;
                await dialogs.showMessage(
                  context: context,
                  title: isZh ? '清空未保存' : 'Clear was not saved',
                  message: TextSpan(
                    text: isZh ? '内存统计已清空，但写入失败，磁盘上可能仍有旧数据。请检查存储权限后重试。' : 'Memory was cleared, but saving failed. Old data may remain on disk. Check storage access and retry.',
                  ),
                );
              }
            }
          },
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: context.appBarInset + 8,
          bottom: 24 + context.bottomInset,
        ),
        children: [
          if (store.lastPersistenceError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                isZh ? '统计文件读取或保存失败；当前数据可能不完整，旧文件不会被自动覆盖。' : 'Statistics could not be loaded or saved. Current data may be incomplete.',
                style: TextStyle(color: colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              isZh ? '基于客户端收到的连接事件统计；未连接内核期间可能缺少数据。' : 'Based on received connection events; data may be incomplete while disconnected from the core.',
            ),
          ),
          // 1. Metric Summary Cards
          Row(
            spacing: 12,
            children: [
              // Today card
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: ShapeDecoration(
                    color: DashboardColors.of(context).card,
                    shape: AppShape.all(16),
                    shadows: DashboardShadows.e1(context),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        todayText,
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        todayTotal.traffic.show,
                        style: AppTextStyle.title1
                            .of(context, emphasized: true)
                            .toTabular,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        diff == 0
                            ? '0 B'
                            : '${diff > 0 ? '+' : '-'}${diff.abs().traffic.show}',
                        style: AppTextStyle.caption2
                            .of(context)
                            .copyWith(
                              color: diff > 0
                                  ? colorScheme.error
                                  : (diff < 0
                                        ? colorScheme.primary
                                        : colorScheme.onSurfaceVariant),
                            ),
                      ),
                    ],
                  ),
                ),
              ),
              // Week card
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: ShapeDecoration(
                    color: DashboardColors.of(context).card,
                    shape: AppShape.all(16),
                    shadows: DashboardShadows.e1(context),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        weekText,
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        weekTotal.traffic.show,
                        style: AppTextStyle.title1
                            .of(context, emphasized: true)
                            .toTabular,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        spacing: 8,
                        children: [
                          Text(
                            '↑ ${store.weekUpload.traffic.show}',
                            style: AppTextStyle.caption2
                                .of(context)
                                .copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                          Text(
                            '↓ ${store.weekDownload.traffic.show}',
                            style: AppTextStyle.caption2
                                .of(context)
                                .copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // 2. Bar Chart Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: ShapeDecoration(
              color: DashboardColors.of(context).card,
              shape: AppShape.all(16),
              shadows: DashboardShadows.e1(context),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header with range pills
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    DashboardCardHeader(
                      glyph: AppGlyphs.dataUsage,
                      title: l.traffic,
                    ),
                    // Legend
                    Row(
                      spacing: 8,
                      children: [
                        _LegendDot(color: uploadColor, label: l.upload),
                        _LegendDot(color: downloadColor, label: l.download),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Range selector chips
                Row(
                  spacing: 6,
                  children: [
                    for (final range in TrafficStatsRange.values)
                      Expanded(
                        child: _RangeChip(
                          label: _rangeLabel(range, context),
                          selected: _selectedRange == range,
                          onTap: () => _onRangeChanged(range),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                // The Chart
                Builder(
                  builder: (context) {
                    final defaultIndex = chartPoints.indexWhere(
                      (p) => p.isCurrent,
                    );
                    final effectiveIndex =
                        _selectedBarIndex >= 0 &&
                            _selectedBarIndex < chartPoints.length
                        ? _selectedBarIndex
                        : (defaultIndex != -1
                              ? defaultIndex
                              : (chartPoints.isNotEmpty
                                    ? chartPoints.length - 1
                                    : -1));
                    return TrafficBarChart(
                      points: chartPoints,
                      selectedIndex: effectiveIndex,
                      onSelectIndex: (index) {
                        setState(() {
                          _selectedBarIndex = index;
                        });
                      },
                    );
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 3. Target Sites Ranking Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: ShapeDecoration(
              color: DashboardColors.of(context).card,
              shape: AppShape.all(16),
              shadows: DashboardShadows.e1(context),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    DashboardCardHeader(
                      glyph: AppGlyphs.target,
                      title: l.target,
                    ),
                    if (allTopSites.isNotEmpty || aggregatedGroups.isNotEmpty)
                      DashboardChip(
                        label: '${_siteCount ?? totalInitialCount}',
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    isZh ? '站点累计不随图表范围筛选；非活跃站点保留90天。' : 'Site totals are independent of the chart range. Inactive sites are retained for 90 days.',
                  ),
                ),
                TargetSitesView(
                  isAggregated: _isAggregated,
                  onModeChanged: (val) {
                    setState(() {
                      _isAggregated = val;
                      _refreshSitesImmediately();
                    });
                  },
                  sites: allTopSites,
                  aggregatedGroups: aggregatedGroups,
                  onCountChanged: (count) {
                    if (_siteCount != count) {
                      setState(() => _siteCount = count);
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      spacing: 4,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        Text(
          label,
          style: AppTextStyle.caption2
              .of(context)
              .copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _RangeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RangeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 6),
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: selected
              ? colorScheme.primary
              : DashboardColors.of(context).tone,
          shape: AppShape.sm,
        ),
        child: Text(
          label,
          style: AppTextStyle.caption1
              .of(context, emphasized: selected)
              .copyWith(
                color: selected
                    ? colorScheme.onPrimary
                    : colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}
