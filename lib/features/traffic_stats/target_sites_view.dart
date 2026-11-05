import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

import 'domain_classifier.dart';
import 'traffic_stats_models.dart';

class TargetSitesView extends StatefulWidget {
  final List<TargetSiteData> sites;
  final List<AggregatedSiteGroup>? aggregatedGroups;
  final ValueChanged<int>? onCountChanged;
  final bool? isAggregated;
  final ValueChanged<bool>? onModeChanged;

  const TargetSitesView({
    super.key,
    required this.sites,
    this.aggregatedGroups,
    this.onCountChanged,
    this.isAggregated,
    this.onModeChanged,
  });

  @override
  State<TargetSitesView> createState() => _TargetSitesViewState();
}

class _TargetSitesViewState extends State<TargetSitesView> {
  bool _internalIsAggregated = true;
  bool get _isAggregated => widget.isAggregated ?? _internalIsAggregated;
  final Set<String> _expandedKeys = <String>{};
  List<AggregatedSiteGroup>? _cachedGroups;
  int? _lastNotifiedCount;

  @override
  void initState() {
    super.initState();
    _updateAggregatedGroups();
    _notifyCount();
  }

  @override
  void didUpdateWidget(covariant TargetSitesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isAggregated) {
      _updateAggregatedGroups();
    } else {
      _cachedGroups = null;
    }
    _notifyCount();
  }

  void _notifyCount() {
    if (widget.onCountChanged == null) return;
    final count = _isAggregated
        ? min(50, _cachedGroups?.length ?? 0)
        : min(50, widget.sites.length);
    if (_lastNotifiedCount == count) return;
    _lastNotifiedCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onCountChanged!(count);
    });
  }

  void _updateAggregatedGroups() {
    if (widget.aggregatedGroups != null) {
      _cachedGroups = widget.aggregatedGroups;
    } else if (widget.sites.isNotEmpty) {
      _cachedGroups = DomainClassifier.aggregateSites(widget.sites);
    } else {
      _cachedGroups = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasData = _isAggregated
        ? (_cachedGroups != null && _cachedGroups!.isNotEmpty)
        : widget.sites.isNotEmpty;
    if (!hasData) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            context.appLocalizations.noData,
            style: AppTextStyle.subheadline
                .of(context)
                .copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    if (_isAggregated && _cachedGroups == null) {
      _updateAggregatedGroups();
    }
    final aggregatedGroups = _isAggregated ? _cachedGroups : null;
    final displayGroups = aggregatedGroups?.take(50).toList();
    final displaySites = widget.sites.take(50).toList();

    final maxTotal = _isAggregated
        ? ((displayGroups?.isNotEmpty ?? false) &&
                  displayGroups!.first.total > 0
              ? displayGroups.first.total
              : 1)
        : (displaySites.isNotEmpty && displaySites.first.total > 0
              ? displaySites.first.total
              : 1);

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
                    if (widget.onModeChanged != null) {
                      widget.onModeChanged!(true);
                    } else {
                      setState(() {
                        _internalIsAggregated = true;
                        if (_cachedGroups == null) {
                          _updateAggregatedGroups();
                        }
                      });
                      _notifyCount();
                    }
                  }
                },
              ),
              const SizedBox(width: 6),
              _TogglePill(
                label: '原始域名',
                isSelected: !_isAggregated,
                onTap: () {
                  if (_isAggregated) {
                    if (widget.onModeChanged != null) {
                      widget.onModeChanged!(false);
                    } else {
                      setState(() => _internalIsAggregated = false);
                      _notifyCount();
                    }
                  }
                },
              ),
            ],
          ),
        ),

        // Items list
        if (_isAggregated && displayGroups != null)
          for (var index = 0; index < displayGroups.length; index++) ...[
            if (index > 0) const SizedBox(height: 8),
            _AggregatedGroupTile(
              group: displayGroups[index],
              rank: index + 1,
              maxTotal: maxTotal,
              isExpanded: _expandedKeys.contains(displayGroups[index].key),
              onToggleExpand: () {
                setState(() {
                  final key = displayGroups[index].key;
                  if (_expandedKeys.contains(key)) {
                    _expandedKeys.remove(key);
                  } else {
                    _expandedKeys.add(key);
                  }
                });
              },
            ),
          ]
        else
          for (var index = 0; index < displaySites.length; index++) ...[
            if (index > 0) const SizedBox(height: 8),
            _SiteTile(
              site: displaySites[index],
              rank: index + 1,
              maxTotal: maxTotal,
            ),
          ],
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
        decoration: ShapeDecoration(
          color: isSelected
              ? colorScheme.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          shape: AppShape.sm.copyWith(
            side: BorderSide(
              color: isSelected
                  ? colorScheme.primary
                  : colorScheme.outlineVariant.withValues(alpha: 0.4),
              width: 1,
            ),
          ),
        ),
        child: Text(
          label,
          style: AppTextStyle.caption1
              .of(context, emphasized: isSelected)
              .copyWith(
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

class _TrafficProgressBar extends StatelessWidget {
  final double value;
  final Color color;
  final Color backgroundColor;

  const _TrafficProgressBar({
    required this.value,
    required this.color,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRSuperellipse(
      borderRadius: AppRadius.full,
      child: Container(
        height: 4,
        color: backgroundColor,
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: value.clamp(0.0, 1.0),
          child: Container(color: color),
        ),
      ),
    );
  }
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
    final brandColor = group.brandColor != null
        ? Color(group.brandColor!)
        : colorScheme.primary;

    final tile = Padding(
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
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(color: _rankColor(context, rank)),
                ),
              ),
              const SizedBox(width: 8),
              // Brand / Monogram icon
              Container(
                width: 32,
                height: 32,
                decoration: ShapeDecoration(
                  color: brandColor.withValues(alpha: 0.12),
                  shape: AppShape.sm,
                ),
                alignment: Alignment.center,
                child: Text(
                  group.iconText,
                  style: AppTextStyle.custom(
                    context,
                    size: group.iconText.length > 2 ? 11 : 13,
                    leading: group.iconText.length > 2 ? 11 : 13,
                    weight: FontWeight.w600,
                  ).copyWith(color: brandColor),
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
                      style: AppTextStyle.body.of(
                        context,
                        emphasized: true,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasMultiple
                          ? '↑ ${group.upload.traffic.show}   ↓ ${group.download.traffic.show}   (${group.subSites.length} 个域名)'
                          : '↑ ${group.upload.traffic.show}   ↓ ${group.download.traffic.show}   (${group.count})',
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Total traffic
              Text(
                group.total.traffic.show,
                style: AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .toTabular,
              ),
              if (hasMultiple) ...[
                const SizedBox(width: 4),
                GlyphIcon(
                  isExpanded ? AppGlyphs.chevronUp : AppGlyphs.chevronDown,
                  size: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // Percentage bar
          _TrafficProgressBar(
            value: fraction,
            backgroundColor: colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.5,
            ),
            color: rank <= 3 ? _rankColor(context, rank) : colorScheme.primary,
          ),
          // Sub-domains expansion
          if (hasMultiple && isExpanded) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final sub in group.subSites) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const SizedBox(width: 32),
                        Expanded(
                          child: Text(
                            sub.host,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.caption1.of(context).copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Text(
                          sub.total.traffic.show,
                          style: AppTextStyle.caption1
                              .of(context, emphasized: true)
                              .copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );

    return Container(
      decoration: ShapeDecoration(
        color: DashboardColors.of(context).tone,
        shape: AppShape.md,
      ),
      clipBehavior: Clip.antiAlias,
      child: hasMultiple
          ? PressRegion(
              shape: AppShape.md,
              overlay: PressRegion.hoverOverlay,
              onTap: onToggleExpand,
              child: tile,
            )
          : tile,
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
      decoration: ShapeDecoration(
        color: DashboardColors.of(context).tone,
        shape: AppShape.md,
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
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(color: _rankColor(context, rank)),
                ),
              ),
              const SizedBox(width: 8),
              // Site Monogram
              Container(
                width: 32,
                height: 32,
                decoration: ShapeDecoration(
                  color: isIp
                      ? const Color(0xFF607D8B).withValues(alpha: 0.15)
                      : colorScheme.surfaceContainerHighest,
                  shape: AppShape.sm,
                ),
                alignment: Alignment.center,
                child: Text(
                  initial,
                  style: AppTextStyle.custom(
                    context,
                    size: initial.length > 1 ? 11 : 13,
                    leading: initial.length > 1 ? 11 : 13,
                    weight: FontWeight.w600,
                  ).copyWith(
                    color: isIp
                        ? const Color(0xFF607D8B)
                        : colorScheme.primary,
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
                      style: AppTextStyle.caption2
                          .of(context)
                          .copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Total traffic
              Text(
                site.total.traffic.show,
                style: AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .toTabular,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Percentage bar
          _TrafficProgressBar(
            value: fraction,
            backgroundColor: colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.5,
            ),
            color: rank <= 3 ? _rankColor(context, rank) : colorScheme.primary,
          ),
        ],
      ),
    );
  }
}
