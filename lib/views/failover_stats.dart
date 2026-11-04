import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class FailoverStatsView extends ConsumerWidget {
  const FailoverStatsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final colorScheme = context.colorScheme;
    final dashboardColors = DashboardColors.of(context);
    final statsAsync = ref.watch(failoverStatsProvider);
    final stats = statsAsync.value ?? const FailoverStats();
    final isLoading = statsAsync.isLoading;
    final hasError = statsAsync.hasError;

    final records = stats.records;

    return CommonScaffold(
      title: isZh ? '故障转移统计' : 'Failover Statistics',
      isLoading: isLoading,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: isZh ? '刷新' : 'Refresh',
          onPressed: () {
            ref.read(failoverStatsProvider.notifier).refresh();
          },
        ),
        IconButtonData(
          glyph: AppGlyphs.clearAll,
          tooltip: isZh ? '清空统计' : 'Clear Statistics',
          onPressed: () async {
            final confirmed = await dialogs.showMessage(
              context: context,
              title: isZh ? '清空故障转移统计' : 'Clear Failover Statistics',
              message: TextSpan(
                text: isZh
                    ? '确定要清空今日与总计触发计数及所有转移历史吗？此操作无法撤销。'
                    : 'Are you sure you want to clear all failover counts and history records? This action cannot be undone.',
              ),
              destructive: true,
            );
            if (confirmed == true) {
              await ref.read(failoverStatsProvider.notifier).reset();
            }
          },
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: context.contentTopPadding,
          bottom: 24 + context.bottomInset,
        ),
        children: [
          if (hasError)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                isZh
                    ? '加载统计数据失败，请点击右上角刷新重试。'
                    : 'Failed to load failover statistics. Tap refresh to retry.',
                style: TextStyle(color: colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              isZh
                  ? '记录节点被动故障感知（Passive Failure Detection）与秒级无感故障转移（Fast Failover）的实际切换触发数据。'
                  : 'Tracks actual failover triggers from Passive Failure Detection & Fast Failover.',
              style: context.listCaptionStyle,
            ),
          ),
          // 1. Metric Summary Cards
          Row(
            children: [
              // Today card
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: ShapeDecoration(
                    color: dashboardColors.card,
                    shape: AppShape.all(16),
                    shadows: DashboardShadows.e1(context),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isZh ? '今日触发' : 'Today',
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '${stats.today}',
                            style: AppTextStyle.title1
                                .of(context, emphasized: true)
                                .copyWith(
                                  color: stats.today > 0
                                      ? colorScheme.primary
                                      : null,
                                ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isZh ? '次' : 'times',
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
              const SizedBox(width: 12),
              // Total card
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: ShapeDecoration(
                    color: dashboardColors.card,
                    shape: AppShape.all(16),
                    shadows: DashboardShadows.e1(context),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isZh ? '总计触发' : 'Total',
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '${stats.total}',
                            style: AppTextStyle.title1
                                .of(context, emphasized: true),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isZh ? '次' : 'times',
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
          // 2. Failover History Section
          generateSection(
            title: isZh ? '最近触发记录' : 'Recent Failovers',
            items: records.isEmpty
                ? [
                    ListItem(
                      title: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            isZh ? '暂无故障转移记录' : 'No failover records yet',
                            style:
                                TextStyle(color: colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ),
                    ),
                  ]
                : records
                    .map((record) => _FailoverRecordItem(record: record))
                    .toList(),
          ),
        ],
      ),
    );
  }
}

class _FailoverRecordItem extends StatelessWidget {
  final FailoverRecord record;

  const _FailoverRecordItem({required this.record});

  String _formatDateTime(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final timeStr = _formatDateTime(record.dateTime);
    final relativeTime = record.dateTime.getLastUpdateTimeDesc(context);

    return ListItem(
      leading: const GlyphIcon(AppGlyphs.swap),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: ShapeDecoration(
              color: colorScheme.primaryContainer,
              shape: AppShape.xs,
            ),
            child: Text(
              record.group,
              style:
                  AppTextStyle.caption2.of(context, emphasized: true).copyWith(
                        color: colorScheme.onPrimaryContainer,
                      ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$timeStr ($relativeTime)',
              style: AppTextStyle.caption2.of(context).copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                record.before.isEmpty ? '—' : record.before,
                style: AppTextStyle.subheadline.of(context).copyWith(
                  color: colorScheme.error,
                  decoration: TextDecoration.lineThrough,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: GlyphIcon(
                AppGlyphs.chevronForward,
                size: 14,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: Text(
                record.after.isEmpty ? '—' : record.after,
                style: AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .copyWith(
                      color: colorScheme.primary,
                    ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
