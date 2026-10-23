import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart';

import 'traffic_stats_models.dart';

class TargetSitesView extends StatelessWidget {
  final List<TargetSiteData> sites;

  const TargetSitesView({super.key, required this.sites});

  @override
  Widget build(BuildContext context) {
    if (sites.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            context.appLocalizations.noData,
            style: AppTextStyle.subheadline.of(context).copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }

    final maxTotal = sites.first.total > 0 ? sites.first.total : 1;

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: sites.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final site = sites[index];
        final rank = index + 1;
        return _SiteTile(
          site: site,
          rank: rank,
          maxTotal: maxTotal,
        );
      },
    );
  }
}

class _SiteTile extends StatelessWidget {
  final TargetSiteData site;
  final int rank;
  final int maxTotal;

  const _SiteTile({
    required this.site,
    required this.rank,
    required this.maxTotal,
  });

  Color _rankColor(BuildContext context) {
    return switch (rank) {
      1 => const Color(0xFFFFB300), // Gold
      2 => const Color(0xFF9E9E9E), // Silver
      3 => const Color(0xFFCD7F32), // Bronze
      _ => context.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
    };
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final fraction = (site.total / maxTotal).clamp(0.0, 1.0);
    final initial = site.host.isNotEmpty ? site.host[0].toUpperCase() : '?';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DashboardColors.of(context).tone,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Rank badge
              SizedBox(
                width: 24,
                child: Text(
                  '#$rank',
                  style: AppTextStyle.caption1.of(context, emphasized: true).copyWith(
                        color: _rankColor(context),
                      ),
                ),
              ),
              const SizedBox(width: 8),
              // Site Monogram
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  initial,
                  style: AppTextStyle.subheadline.of(context, emphasized: true).copyWith(
                        color: colorScheme.primary,
                      ),
                ),
              ),
              const SizedBox(width: 12),
              // Domain host & request count
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      site.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.body.of(context, emphasized: true),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '↑ ${site.upload.traffic.show}   ↓ ${site.download.traffic.show}   (${site.count})',
                      style: AppTextStyle.caption2.of(context).copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Total traffic
              Text(
                site.total.traffic.show,
                style: AppTextStyle.subheadline.of(context, emphasized: true).toTabular,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Percentage bar
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              valueColor: AlwaysStoppedAnimation(
                rank <= 3 ? _rankColor(context) : colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
