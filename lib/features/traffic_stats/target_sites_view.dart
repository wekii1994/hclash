import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';

import 'domain_classifier.dart';
import 'traffic_stats_models.dart';

class TargetSitesView extends StatefulWidget {
  final List<TargetSiteData> sites;

  const TargetSitesView({super.key, required this.sites});

  @override
  State<TargetSitesView> createState() => _TargetSitesViewState();
}

class _TargetSitesViewState extends State<TargetSitesView> {
  bool _isAggregated = true;
  final Set<String> _expandedKeys = <String>{};
  List<AggregatedSiteGroup>? _cachedGroups;

  @override
  void initState() {
    super.initState();
    _updateAggregatedGroups();
  }

  @override
  void didUpdateWidget(covariant TargetSitesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sites != widget.sites) {
      _updateAggregatedGroups();
    }
  }

  void _updateAggregatedGroups() {
    if (widget.sites.isNotEmpty) {
      _cachedGroups = DomainClassifier.aggregateSites(widget.sites);
    } else {
      _cachedGroups = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sites.isEmpty) {
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

    final aggregatedGroups = _isAggregated ? _cachedGroups : null;

    final maxTotal = _isAggregated
        ? ((aggregatedGroups?.isNotEmpty ?? false) && aggregatedGroups!.first.total > 0
            ? aggregatedGroups.first.total
            : 1)
        : (widget.sites.first.total > 0 ? widget.sites.first.total : 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Mode toggle header
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _TogglePill(
                label: '智能聚合',
                isSelected: _isAggregated,
                onTap: () {
                  if (!_isAggregated) {
                    setState(() => _isAggregated = true);
                  }
                },
              ),
              const SizedBox(width: 6),
              _TogglePill(
                label: '原始域名',
                isSelected: !_isAggregated,
                onTap: () {
                  if (_isAggregated) {
                    setState(() => _isAggregated = false);
                  }
                },
              ),
            ],
          ),
        ),

        // List view
        if (_isAggregated && aggregatedGroups != null)
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: aggregatedGroups.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final group = aggregatedGroups[index];
              final rank = index + 1;
              final isExpanded = _expandedKeys.contains(group.key);
              return _AggregatedGroupTile(
                group: group,
                rank: rank,
                maxTotal: maxTotal,
                isExpanded: isExpanded,
                onToggleExpand: () {
                  setState(() {
                    if (isExpanded) {
                      _expandedKeys.remove(group.key);
                    } else {
                      _expandedKeys.add(group.key);
                    }
                  });
                },
              );
            },
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: widget.sites.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final site = widget.sites[index];
              final rank = index + 1;
              return _SiteTile(
                site: site,
                rank: rank,
                maxTotal: maxTotal,
              );
            },
          ),
      ],
    );
  }
}

class _TogglePill extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _TogglePill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected
              ? colorScheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected
                ? colorScheme.primary
                : colorScheme.outlineVariant.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: AppTextStyle.caption1.of(context, emphasized: isSelected).copyWith(
                color: isSelected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}

Color _rankColor(BuildContext context, int rank) {
  return switch (rank) {
    1 => const Color(0xFFFFB300), // Gold
    2 => const Color(0xFF9E9E9E), // Silver
    3 => const Color(0xFFCD7F32), // Bronze
    _ => context.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
  };
}

class _AggregatedGroupTile extends StatelessWidget {
  final AggregatedSiteGroup group;
  final int rank;
  final int maxTotal;
  final bool isExpanded;
  final VoidCallback onToggleExpand;

  const _AggregatedGroupTile({
    required this.group,
    required this.rank,
    required this.maxTotal,
    required this.isExpanded,
    required this.onToggleExpand,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final fraction = (group.total / maxTotal).clamp(0.0, 1.0);
    final hasMultiple = group.subSites.length > 1;
    final brandColor = group.brandColor ?? colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        color: DashboardColors.of(context).tone,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: hasMultiple ? onToggleExpand : null,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
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
                              color: _rankColor(context, rank),
                            ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Brand / Monogram icon
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: brandColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        group.iconText,
                        style: AppTextStyle.subheadline.of(context, emphasized: true).copyWith(
                              color: brandColor,
                              fontSize: group.iconText.length > 2 ? 11 : 13,
                            ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Display name & details
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            group.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.body.of(context, emphasized: true),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hasMultiple
                                ? '↑ ${group.upload.traffic.show}   ↓ ${group.download.traffic.show}   (${group.subSites.length} 个域名)'
                                : '↑ ${group.upload.traffic.show}   ↓ ${group.download.traffic.show}   (${group.count})',
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
                      group.total.traffic.show,
                      style: AppTextStyle.subheadline.of(context, emphasized: true).toTabular,
                    ),
                    if (hasMultiple) ...[
                      const SizedBox(width: 4),
                      Icon(
                        isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                        size: 18,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                // Progress bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 4,
                    backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    valueColor: AlwaysStoppedAnimation(
                      rank <= 3 ? _rankColor(context, rank) : colorScheme.primary,
                    ),
                  ),
                ),
                // Subsites breakdown when expanded
                if (isExpanded && hasMultiple) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        for (int i = 0; i < group.subSites.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 12,
                              thickness: 0.5,
                              color: colorScheme.outlineVariant.withValues(alpha: 0.2),
                            ),
                          Builder(
                            builder: (context) {
                              final sub = group.subSites[i];
                              final app = DomainClassifier.friendlyAppName(sub.process);
                              return Row(
                                children: [
                                  Icon(
                                    Icons.subdirectory_arrow_right,
                                    size: 14,
                                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                          child: Text(
                                            sub.host,
                                            style: AppTextStyle.caption1.of(context).copyWith(
                                                  color: colorScheme.onSurface,
                                                ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        if (app != null && app.isNotEmpty) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: colorScheme.surfaceContainerHighest,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              app,
                                              style: AppTextStyle.caption2.of(context).copyWith(
                                                    color: colorScheme.onSurfaceVariant,
                                                    fontSize: 10,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    sub.total.traffic.show,
                                    style: AppTextStyle.caption1.of(context, emphasized: true).copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final fraction = (site.total / maxTotal).clamp(0.0, 1.0);
    final isIp = DomainClassifier.isIpAddress(site.host);
    final initial = isIp
        ? 'IP'
        : (site.host.isNotEmpty ? site.host[0].toUpperCase() : '?');
    final app = DomainClassifier.friendlyAppName(site.process);
    final detail = [
      '↑ ${site.upload.traffic.show}   ↓ ${site.download.traffic.show}',
      '(${site.count})',
      if (app != null && app.isNotEmpty) '·  $app',
    ].join('   ');

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
                        color: _rankColor(context, rank),
                      ),
                ),
              ),
              const SizedBox(width: 8),
              // Site Monogram
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isIp
                      ? const Color(0xFF607D8B).withValues(alpha: 0.15)
                      : colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  initial,
                  style: AppTextStyle.subheadline.of(context, emphasized: true).copyWith(
                        color: isIp ? const Color(0xFF607D8B) : colorScheme.primary,
                        fontSize: initial.length > 1 ? 11 : 13,
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
                      detail,
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
                rank <= 3 ? _rankColor(context, rank) : colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
