import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/traffic_stats/traffic_stats.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/icons/app_glyphs.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:fl_clash/views/dashboard/widgets/card.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart';

class TrafficStatisticsView extends StatefulWidget {
  const TrafficStatisticsView({super.key});

  @override
  State<TrafficStatisticsView> createState() => _TrafficStatisticsViewState();
}

class _TrafficStatisticsViewState extends State<TrafficStatisticsView> {
  TrafficStatsRange _selectedRange = TrafficStatsRange.today;
  int _selectedBarIndex = -1;
  int? _siteCount;

  @override
  void initState() {
    super.initState();
    TrafficStatsStore.instance.addListener(_onStoreChanged);
    TrafficStatsStore.instance.init();
  }

  @override
  void dispose() {
    TrafficStatsStore.instance.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  void _onRangeChanged(TrafficStatsRange range) {
    setState(() {
      _selectedRange = range;
      _selectedBarIndex = -1;
    });
  }

  String _rangeLabel(TrafficStatsRange range, BuildContext context) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    return switch (range) {
      TrafficStatsRange.today => isZh ? '今日' : 'Today',
      TrafficStatsRange.week => isZh ? '本周' : 'This Week',
      TrafficStatsRange.month => isZh ? '本月' : 'This Month',
      TrafficStatsRange.all => isZh ? '全部' : 'All',
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final store = TrafficStatsStore.instance;

    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final todayText = isZh ? '今日' : 'Today';
    final weekText = isZh ? '本周' : 'This Week';
    final cleanText = isZh ? '清空' : 'Clear';
    final cleanTitle = isZh ? '清空流量统计' : 'Clear Traffic Statistics';
    final cleanTip = isZh
        ? '确定要清空所有流量统计历史和站点记录吗？此操作无法撤销。'
        : 'Are you sure you want to clear all traffic statistics and site records? This action cannot be undone.';

    final todayTotal = store.todayTotal;
    final weekTotal = store.weekTotal;
    final diff = store.differenceFromYesterday;
    final allTopSites = store.getTopSites(limit: TrafficStatsStore.maxSitesToKeep);
    final chartPoints = store.getChartPoints(_selectedRange);

    final uploadColor = DashboardColors.of(context).series2;
    final downloadColor = colorScheme.primary;

    return CommonScaffold(
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
              await store.clearAll();
            }
          },
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: context.appBarInset + 8,
          bottom: 24 + BottomInsetScope.of(context),
        ),
        children: [
          // 1. Metric Summary Cards
          Row(
            spacing: 12,
            children: [
              // Today card
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: DashboardColors.of(context).card,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: DashboardShadows.e1(context),
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
                        style: AppTextStyle.caption2.of(context).copyWith(
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
                  decoration: BoxDecoration(
                    color: DashboardColors.of(context).card,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: DashboardShadows.e1(context),
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
            decoration: BoxDecoration(
              color: DashboardColors.of(context).card,
              borderRadius: BorderRadius.circular(16),
              boxShadow: DashboardShadows.e1(context),
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
                    final defaultIndex = chartPoints.indexWhere((p) => p.isCurrent);
                    final effectiveIndex = _selectedBarIndex >= 0 && _selectedBarIndex < chartPoints.length
                        ? _selectedBarIndex
                        : (defaultIndex != -1 ? defaultIndex : (chartPoints.isNotEmpty ? chartPoints.length - 1 : -1));
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
            decoration: BoxDecoration(
              color: DashboardColors.of(context).card,
              borderRadius: BorderRadius.circular(16),
              boxShadow: DashboardShadows.e1(context),
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
                    if (allTopSites.isNotEmpty)
                      DashboardChip(
                        label: '${_siteCount ?? min(50, allTopSites.length)}',
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TargetSitesView(
                  sites: allTopSites,
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
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary
              : DashboardColors.of(context).tone,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style:
              AppTextStyle.caption1.of(context, emphasized: selected).copyWith(
                    color: selected
                        ? colorScheme.onPrimary
                        : colorScheme.onSurfaceVariant,
                  ),
        ),
      ),
    );
  }
}
