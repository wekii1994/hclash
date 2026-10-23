import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/traffic_stats/traffic_stats.dart';
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
    final l = context.appLocalizations;
    return switch (range) {
      TrafficStatsRange.today => l.today,
      TrafficStatsRange.week => l.week,
      TrafficStatsRange.month => l.month,
      TrafficStatsRange.all => l.all,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final colorScheme = context.colorScheme;
    final store = TrafficStatsStore.instance;

    final todayTotal = store.todayTotal;
    final weekTotal = store.weekTotal;
    final diff = store.differenceFromYesterday;
    final topSites = store.getTopSites();
    final chartPoints = store.getChartPoints(_selectedRange);

    final uploadColor = DashboardColors.of(context).series2;
    final downloadColor = colorScheme.primary;

    return CommonScaffold(
      title: l.trafficUsage,
      actions: [
        IconButtonData(
          glyph: AppGlyphs.clearAll,
          tooltip: l.clean,
          onPressed: () async {
            final confirmed = await dialogs.showMessage(
              context: context,
              title: l.clean,
              message: TextSpan(text: l.cleanTip),
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
                        l.today,
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        todayTotal.traffic.show,
                        style: AppTextStyle.title1.of(context, emphasized: true).toTabular,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        diff >= 0
                            ? '+${diff.traffic.show}'
                            : '-${(-diff).traffic.show}',
                        style: AppTextStyle.caption2.of(context).copyWith(
                              color: diff >= 0
                                  ? colorScheme.error
                                  : colorScheme.primary,
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
                        l.week,
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        weekTotal.traffic.show,
                        style: AppTextStyle.title1.of(context, emphasized: true).toTabular,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        spacing: 8,
                        children: [
                          Text(
                            '↑ ${store.todayUpload.traffic.show}',
                            style: AppTextStyle.caption2
                                .of(context)
                                .copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                          Text(
                            '↓ ${store.todayDownload.traffic.show}',
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
                TrafficBarChart(
                  points: chartPoints,
                  selectedIndex: _selectedBarIndex,
                  onSelectIndex: (index) {
                    setState(() {
                      _selectedBarIndex = index;
                    });
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
                    if (topSites.isNotEmpty)
                      DashboardChip(label: '${topSites.length}'),
                  ],
                ),
                const SizedBox(height: 12),
                TargetSitesView(sites: topSites),
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
          style: AppTextStyle.caption1.of(context, emphasized: selected).copyWith(
                color: selected
                    ? colorScheme.onPrimary
                    : colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}
