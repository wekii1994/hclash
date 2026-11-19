import 'dart:async';
import 'dart:io' show InternetAddress;
import 'dart:math' as math;

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/api/connection_book.dart' show CounterDemand;
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:fl_clash/views/dashboard/widgets/card.dart';
import 'package:fl_clash/widgets/widgets.dart';

enum _Period { day, week, month }

enum _Rank { hosts, processes, nodes, profiles, rules }

typedef _Range = ({DateTime start, DateTime end});

String _two(int value) => value.toString().padLeft(2, '0');

String _dayKey(DateTime date) =>
    '${date.year}-${_two(date.month)}-${_two(date.day)}';

_Range _rangeOf(_Period period, int offset) {
  final now = DateTime.now();
  switch (period) {
    case _Period.day:
      final day = DateTime(now.year, now.month, now.day - offset);
      return (start: day, end: day);
    case _Period.week:
      final start = DateTime(
        now.year,
        now.month,
        now.day - (now.weekday - 1) - offset * 7,
      );
      return (
        start: start,
        end: DateTime(start.year, start.month, start.day + 6),
      );
    case _Period.month:
      final start = DateTime(now.year, now.month - offset, 1);
      return (start: start, end: DateTime(start.year, start.month + 1, 0));
  }
}

String _rangeLabel(_Period period, _Range range, bool isZh) {
  switch (period) {
    case _Period.day:
      return _dayKey(range.start);
    case _Period.week:
      return '${_dayKey(range.start).substring(5)} ~ ${_dayKey(range.end).substring(5)}';
    case _Period.month:
      return _dayKey(range.start).substring(0, 7);
  }
}

String _bytes(num value) => value.traffic.show;

class TrafficStatisticsView extends ConsumerStatefulWidget {
  const TrafficStatisticsView({super.key});

  @override
  ConsumerState<TrafficStatisticsView> createState() =>
      _TrafficStatisticsViewState();
}

class _TrafficStatisticsViewState extends ConsumerState<TrafficStatisticsView>
    with WidgetsBindingObserver {
  _Period _period = _Period.day;
  int _offset = 0;
  _Rank _rank = _Rank.hosts;
  TrafficStatsResult? _result;
  bool _isLoading = false;
  Timer? _timer;
  int _serial = 0;
  CounterDemand? _demand;
  TrafficStatsOptions _options = const TrafficStatsOptions(
    enable: true,
    detail: true,
    retentionDays: 7,
  );

  _Range get _range => _rangeOf(_period, _offset);
  bool get _isLive => _period == _Period.day && _offset == 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _demand = ref.read(connectionBookProvider).demand..acquire();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _load();
      }
    });
    _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_demand == null) {
        _demand = ref.read(connectionBookProvider).demand..acquire();
      }
      if (_isLive) {
        _load();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _demand?.release();
      _demand = null;
    }
    _syncTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _demand?.release();
    _demand = null;
    super.dispose();
  }

  void _syncTimer() {
    _timer?.cancel();
    _timer = null;
    if (_isLive) {
      _timer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted && _isLive) {
          _load(background: true);
        }
      });
    }
  }

  Future<void> _load({bool background = false}) async {
    final serial = ++_serial;
    if (!background) {
      setState(() => _isLoading = true);
    }
    final range = _range;
    TrafficStatsResult? result;
    try {
      result = await ref.read(coreHandlerProvider).getTrafficStats(
            start: _dayKey(range.start),
            end: _dayKey(range.end),
          );
    } catch (_) {
      result = const TrafficStatsResult();
    }
    if (!mounted || serial != _serial) return;
    setState(() {
      _result = result ?? const TrafficStatsResult();
      _isLoading = false;
    });
  }

  void _selectPeriod(_Period period) {
    setState(() {
      _period = period;
      _offset = 0;
    });
    _load();
    _syncTimer();
  }

  void _changeOffset(int delta) {
    final next = _offset + delta;
    if (next < 0) return;
    setState(() => _offset = next);
    _load();
    _syncTimer();
  }

  Future<void> _clearData() async {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final cleanTitle = isZh ? '清空流量统计' : 'Clear Traffic Statistics';
    final cleanTip = isZh
        ? '确定要清空所有流量统计历史和明细记录吗？此操作无法撤销。'
        : 'Are you sure you want to clear all traffic statistics and history? This action cannot be undone.';

    final confirmed = await dialogs.showMessage(
      context: context,
      title: cleanTitle,
      message: TextSpan(text: cleanTip),
      destructive: true,
    );
    if (confirmed == true && mounted) {
      await ref.read(coreHandlerProvider).clearTrafficStats();
      await siteIconCache.clear();
      await _load();
    }
  }

  void _openSettings() {
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    dialogs.showCommonDialog(
      context: context,
      child: _TrafficStatsSettingsDialog(
        initialOptions: _options,
        isZh: isZh,
        onOptionsChanged: (opts) {
          setState(() => _options = opts);
          ref.read(coreHandlerProvider).configureTrafficStats(opts);
        },
        onCleared: () {
          _load();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final range = _range;
    final result = _result ?? const TrafficStatsResult();
    final since = result.since;
    final canBack = since.isEmpty || _dayKey(range.start).compareTo(since) > 0;

    return Scaffold(
      title: l.trafficUsage,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: isZh ? '刷新' : 'Refresh',
          onPressed: _isLoading ? null : () => _load(),
        ),
        IconButtonData(
          glyph: AppGlyphs.clearAll,
          tooltip: isZh ? '清空' : 'Clear',
          onPressed: _clearData,
        ),
        IconButtonData(
          glyph: AppGlyphs.settings,
          tooltip: isZh ? '设置' : 'Settings',
          onPressed: _openSettings,
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
          // Period Segmented Control
          SegmentedControl<_Period>(
            segments: [
              (_Period.day, isZh ? '按日' : 'Day'),
              (_Period.week, isZh ? '按周' : 'Week'),
              (_Period.month, isZh ? '按月' : 'Month'),
            ],
            value: _period,
            onChanged: _selectPeriod,
          ),
          const SizedBox(height: 12),

          // Date Navigator Row
          Row(
            children: [
              IconButton(
                onPressed: canBack ? () => _changeOffset(1) : null,
                icon: const GlyphIcon(AppGlyphs.chevronBack),
              ),
              Expanded(
                child: Text(
                  _rangeLabel(_period, range, isZh),
                  textAlign: TextAlign.center,
                  style: AppTextStyle.callout
                      .of(context, emphasized: true)
                      .copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: context.colorScheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                onPressed: _offset > 0 ? () => _changeOffset(-1) : null,
                icon: const GlyphIcon(AppGlyphs.chevronForward),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 1. Overview Card
          _OverviewCard(result: result, isZh: isZh),
          const SizedBox(height: 16),

          // 2. Trend Chart Card
          _TrendChartCard(
            series: result.series,
            hourly: _period == _Period.day,
            isZh: isZh,
          ),
          const SizedBox(height: 16),

          // 3. Rule Hits Card (if any rules present)
          if (result.rules.isNotEmpty) ...[
            _RuleHitsCard(
              rules: result.rules,
              totalHits: result.ruleHits,
              isZh: isZh,
            ),
            const SizedBox(height: 16),
          ],

          // 4. Five-dimension Traffic Ranking Card
          _RankingCard(
            rank: _rank,
            result: result,
            range: range,
            hourly: _period == _Period.day,
            isZh: isZh,
            siteIcon: _options.siteIcon,
            onRankChanged: (newRank) => setState(() => _rank = newRank),
          ),
        ],
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  final TrafficStatsResult result;
  final bool isZh;

  const _OverviewCard({required this.result, required this.isZh});

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final upColor = DashboardColors.of(context).series2;
    final downColor = colorScheme.primary;
    final totalTraffic = result.total.traffic;

    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                totalTraffic.value,
                style: AppTextStyle.custom(
                  context,
                  size: 32,
                  leading: 36,
                  weight: FontWeight.w800,
                ).copyWith(
                  color: colorScheme.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 4),
              Text(
                totalTraffic.unit,
                style:
                    AppTextStyle.callout.of(context, emphasized: true).copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: ShapeDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.1),
                  shape: AppShape.full,
                ),
                child: Text(
                  isZh ? '总流量' : 'Total Traffic',
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(
                        color: colorScheme.primary,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _MetricItem(
                  color: upColor,
                  label: isZh ? '上传流量' : 'Upload',
                  value: _bytes(result.up),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MetricItem(
                  color: downColor,
                  label: isZh ? '下载流量' : 'Download',
                  value: _bytes(result.down),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: ShapeDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              shape: AppShape.all(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${isZh ? '代理' : 'Proxies'}: ${_bytes(result.proxyTotal)}',
                    style: AppTextStyle.caption1
                        .of(context, emphasized: true)
                        .copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Text(
                  '·',
                  style: AppTextStyle.subheadline
                      .of(context, emphasized: true)
                      .copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
                Expanded(
                  child: Text(
                    '${isZh ? '直连' : 'Direct'}: ${_bytes(result.directTotal)}',
                    textAlign: TextAlign.end,
                    style: AppTextStyle.caption1
                        .of(context, emphasized: true)
                        .copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricItem extends StatelessWidget {
  final Color color;
  final String label;
  final String value;

  const _MetricItem({
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: ShapeDecoration(
            color: color,
            shape: AppShape.full,
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: AppTextStyle.caption2.of(context).copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
            ),
            Text(
              value,
              style: AppTextStyle.subheadline
                  .of(context, emphasized: true)
                  .copyWith(
                color: context.colorScheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TrendChartCard extends StatefulWidget {
  final List<TrafficStatsPoint> series;
  final bool hourly;
  final bool isZh;

  const _TrendChartCard({
    required this.series,
    required this.hourly,
    required this.isZh,
  });

  @override
  State<_TrendChartCard> createState() => _TrendChartCardState();
}

class _TrendChartCardState extends State<_TrendChartCard> {
  int? _selected;

  @override
  void didUpdateWidget(_TrendChartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.series.length != widget.series.length) {
      _selected = null;
    }
  }

  void _pick(Offset position, double width) {
    final length = widget.series.length;
    if (length == 0 || width <= 0) return;
    final index = (position.dx / width * length).floor().clamp(0, length - 1);
    setState(() => _selected = index);
  }

  String _title(TrafficStatsPoint point) {
    if (widget.hourly) {
      final hour = int.tryParse(point.label) ?? 0;
      return '${_two(hour)}:00';
    }
    return point.label.length > 5 ? point.label.substring(5) : point.label;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final series = widget.series;
    final selected = _selected;
    final point =
        selected != null && selected < series.length ? series[selected] : null;

    final upColor = DashboardColors.of(context).series2;
    final downColor = colorScheme.primary;

    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                widget.isZh ? '流量趋势' : 'Traffic Trend',
                style: AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .copyWith(
                      color: colorScheme.onSurface,
                    ),
              ),
              if (point != null)
                Text(
                  '${_title(point)}   ↑ ${_bytes(point.up)}   ↓ ${_bytes(point.down)}',
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (series.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  widget.isZh ? '暂无流量走势数据' : 'No trend data',
                  style: AppTextStyle.footnote.of(context).copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            )
          else
            LayoutBuilder(
              builder: (_, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) =>
                    _pick(details.localPosition, constraints.maxWidth),
                onHorizontalDragUpdate: (details) =>
                    _pick(details.localPosition, constraints.maxWidth),
                child: SizedBox(
                  height: 130,
                  width: constraints.maxWidth,
                  child: CustomPaint(
                    painter: _TrendPainter(
                      series: series,
                      selected: selected,
                      upColor: upColor,
                      downColor: downColor,
                      trackColor: colorScheme.onSurface.withValues(alpha: 0.05),
                      labelStyle: AppTextStyle.caption2.of(context).copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                      labels: [
                        for (final (index, p) in series.indexed)
                          _showLabel(index, series.length, widget.hourly)
                              ? (widget.hourly
                                  ? p.label
                                  : (int.tryParse(p.label.split('-').last)
                                          ?.toString() ??
                                      p.label))
                              : '',
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool _showLabel(int index, int length, bool hourly) {
    if (length <= 7) return true;
    if (hourly) return index % 6 == 0 || index == length - 1;
    return index == 0 || (index + 1) % 5 == 0 || index == length - 1;
  }
}

class _TrendPainter extends CustomPainter {
  final List<TrafficStatsPoint> series;
  final int? selected;
  final Color upColor;
  final Color downColor;
  final Color trackColor;
  final TextStyle labelStyle;
  final List<String> labels;

  const _TrendPainter({
    required this.series,
    required this.selected,
    required this.upColor,
    required this.downColor,
    required this.trackColor,
    required this.labelStyle,
    required this.labels,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (series.isEmpty) return;
    const labelHeight = 18.0;
    final chartHeight = size.height - labelHeight;
    final slot = size.width / series.length;
    final barWidth = math.min(math.max(slot * 0.56, 2.0), 18.0);
    final peak = series.fold<int>(
      0,
      (value, point) => math.max(value, point.up + point.down),
    );
    final corner = Radius.circular(math.min(barWidth / 2, 4));

    for (final (index, point) in series.indexed) {
      final left = slot * index + (slot - barWidth) / 2;
      final dim = selected != null && selected != index;
      final trackRect = Rect.fromLTRB(left, 0, left + barWidth, chartHeight);
      canvas.drawRSuperellipse(
        RSuperellipse.fromRectAndRadius(trackRect, corner),
        Paint()..color = trackColor,
      );

      final total = point.up + point.down;
      if (peak > 0 && total > 0) {
        final height = math.max(chartHeight * total / peak, 2.0);
        final downHeight = height * point.down / total;
        final top = chartHeight - height;
        final barRect = Rect.fromLTRB(left, top, left + barWidth, chartHeight);
        final barPath = Path()
          ..addRSuperellipse(
            RSuperellipse.fromRectAndRadius(barRect, corner),
          );
        canvas.save();
        canvas.clipPath(barPath);
        canvas.drawRect(
          Rect.fromLTRB(left, top, left + barWidth, chartHeight - downHeight),
          Paint()..color = upColor.withValues(alpha: dim ? 0.35 : 1.0),
        );
        canvas.drawRect(
          Rect.fromLTRB(
            left,
            chartHeight - downHeight,
            left + barWidth,
            chartHeight,
          ),
          Paint()..color = downColor.withValues(alpha: dim ? 0.35 : 1.0),
        );
        canvas.restore();
      }

      final label = index < labels.length ? labels[index] : '';
      if (label.isNotEmpty) {
        final painter = TextPainter(
          text: TextSpan(text: label, style: labelStyle),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final x = (slot * index + slot / 2 - painter.width / 2)
            .clamp(0.0, math.max(size.width - painter.width, 0.0))
            .toDouble();
        painter.paint(canvas, Offset(x, chartHeight + 4));
      }
    }
  }

  @override
  bool shouldRepaint(_TrendPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.selected != selected ||
      oldDelegate.upColor != upColor ||
      oldDelegate.downColor != downColor ||
      oldDelegate.trackColor != trackColor;
}

class _RuleHitsCard extends StatelessWidget {
  final List<TrafficStatsItem> rules;
  final int totalHits;
  final bool isZh;

  const _RuleHitsCard({
    required this.rules,
    required this.totalHits,
    required this.isZh,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isZh ? '分流规则命中' : 'Rule Hits',
                style: AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .copyWith(
                      color: colorScheme.onSurface,
                    ),
              ),
              Text(
                '${isZh ? '总命中' : 'Total Hits'}: $totalHits',
                style: AppTextStyle.caption1.of(context).copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 104,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: Row(
                children: [
                  for (var i = 0; i < math.min(rules.length, 20); i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    _buildRuleItem(context, rules[i], colorScheme),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleItem(
    BuildContext context,
    TrafficStatsItem r,
    ColorScheme colorScheme,
  ) {
    final separator = r.name.indexOf(',');
    final type = separator < 0 ? r.name : r.name.substring(0, separator);
    final payload = separator < 0 ? '' : r.name.substring(separator + 1);
    return Container(
      width: 140,
      padding: const EdgeInsets.all(10),
      decoration: ShapeDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: AppShape.all(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            payload.isEmpty ? type : payload,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyle.footnote.of(context, emphasized: true).copyWith(
                  color: colorScheme.onSurface,
                ),
          ),
          const SizedBox(height: 2),
          Text(
            payload.isEmpty ? 'RULE' : type,
            maxLines: 1,
            style: AppTextStyle.caption2.of(context, emphasized: true).copyWith(
                  color: colorScheme.primary,
                ),
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${r.hits} ${isZh ? '次' : 'hits'}',
                style: AppTextStyle.caption2
                    .of(context, emphasized: true)
                    .copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                _bytes(r.total),
                style: AppTextStyle.caption2
                    .of(context, emphasized: true)
                    .copyWith(
                  color: colorScheme.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RankingCard extends StatelessWidget {
  final _Rank rank;
  final TrafficStatsResult result;
  final _Range range;
  final bool hourly;
  final bool isZh;
  final bool siteIcon;
  final ValueChanged<_Rank> onRankChanged;

  const _RankingCard({
    required this.rank,
    required this.result,
    required this.range,
    required this.hourly,
    required this.isZh,
    required this.onRankChanged,
    this.siteIcon = true,
  });

  List<TrafficStatsItem> get _currentItems => switch (rank) {
        _Rank.hosts => result.hosts,
        _Rank.processes => result.processes,
        _Rank.nodes => result.nodes,
        _Rank.profiles => result.profiles,
        _Rank.rules => result.rules,
      };

  Glyph _glyphFor(_Rank r) => switch (r) {
        _Rank.hosts => AppGlyphs.language,
        _Rank.processes => AppGlyphs.connections,
        _Rank.nodes => AppGlyphs.proxies,
        _Rank.profiles => AppGlyphs.profiles,
        _Rank.rules => AppGlyphs.rules,
      };

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final items = _currentItems;
    final maxTotal = items.isEmpty ? 1 : math.max(items.first.total, 1);

    return DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                isZh ? '流量排行' : 'Traffic Ranking',
                style: AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .copyWith(
                      color: colorScheme.onSurface,
                    ),
              ),
              Text(
                '${isZh ? '共' : 'Total'} ${items.length} ${isZh ? '项' : 'items'}',
                style: AppTextStyle.caption1.of(context).copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedControl<_Rank>(
            segments: [
              (_Rank.hosts, isZh ? '域名' : 'Hosts'),
              (_Rank.processes, isZh ? '应用' : 'Apps'),
              (_Rank.nodes, isZh ? '节点' : 'Nodes'),
              (_Rank.profiles, isZh ? '订阅' : 'Profiles'),
              (_Rank.rules, isZh ? '规则' : 'Rules'),
            ],
            value: rank,
            onChanged: onRankChanged,
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: Text(
                  isZh ? '当前维度暂无流量记录' : 'No records for this dimension',
                  style: AppTextStyle.footnote.of(context).copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            )
          else
            Column(
              children: [
                for (final (index, item) in items.take(20).indexed)
                  _RankTile(
                    index: index + 1,
                    glyph: _glyphFor(rank),
                    item: item,
                    ratio: item.total / maxTotal,
                    isZh: isZh,
                    isHost: rank == _Rank.hosts,
                    siteIcon: siteIcon,
                    onTap: rank == _Rank.hosts
                        ? () => _showHostDetailSheet(
                              context,
                              host: item.name,
                              item: item,
                              range: range,
                              hourly: hourly,
                              isZh: isZh,
                              siteIcon: siteIcon,
                            )
                        : null,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  void _showHostDetailSheet(
    BuildContext context, {
    required String host,
    required TrafficStatsItem item,
    required _Range range,
    required bool hourly,
    required bool isZh,
    required bool siteIcon,
  }) {
    showNestedSheet<void>(
      context,
      builder: (_) => _HostDetailSheet(
        host: host,
        item: item,
        range: range,
        hourly: hourly,
        isZh: isZh,
        siteIcon: siteIcon,
      ),
    );
  }
}

class _RankTile extends StatelessWidget {
  final int index;
  final Glyph glyph;
  final TrafficStatsItem item;
  final double ratio;
  final bool isZh;
  final bool isHost;
  final bool siteIcon;
  final VoidCallback? onTap;

  const _RankTile({
    required this.index,
    required this.glyph,
    required this.item,
    required this.ratio,
    required this.isZh,
    this.isHost = false,
    this.siteIcon = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final primary = colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '$index',
                  textAlign: TextAlign.center,
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(
                        color:
                            index <= 3 ? primary : colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              const SizedBox(width: 8),
              if (isHost)
                SiteIcon(
                  domain: item.name,
                  size: 32,
                  enabled: siteIcon,
                )
              else
                Container(
                  width: 32,
                  height: 32,
                  decoration: ShapeDecoration(
                    color: primary.withValues(alpha: 0.1),
                    shape: AppShape.all(8),
                  ),
                  child: Center(
                    child: GlyphIcon(
                      glyph,
                      color: primary,
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyle.footnote
                                .of(context, emphasized: true)
                                .copyWith(
                                  color: colorScheme.onSurface,
                                ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _bytes(item.total),
                          style: AppTextStyle.footnote
                              .of(context, emphasized: true)
                              .copyWith(
                            color: colorScheme.onSurface,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: LinearProgressIndicator(
                            value: ratio.clamp(0.0, 1.0),
                            minHeight: 4,
                            backgroundColor: primary.withValues(alpha: 0.12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '↑ ${_bytes(item.up)} · ↓ ${_bytes(item.down)}',
                          style: AppTextStyle.caption2.of(context).copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 6),
                GlyphIcon(
                  AppGlyphs.chevronForward,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HostDetailSheet extends StatelessWidget {
  final String host;
  final TrafficStatsItem item;
  final _Range range;
  final bool hourly;
  final bool isZh;
  final bool siteIcon;

  const _HostDetailSheet({
    required this.host,
    required this.item,
    required this.range,
    required this.hourly,
    required this.isZh,
    this.siteIcon = true,
  });

  bool get _isAddress => InternetAddress.tryParse(host) != null;

  @override
  Widget build(BuildContext context) {
    final isAddress = _isAddress;
    final subs = item.subs;

    return Scaffold(
      title: isZh ? '域名详情' : 'Host Details',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: isZh ? '基本信息' : 'Basic Info',
            items: [
              DetailRow(
                title: isZh ? '目标地址' : 'Target Host',
                copyText: host,
                value: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SiteIcon(
                      domain: host,
                      size: 20,
                      enabled: siteIcon,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              DetailRow.text(
                title: isZh ? '地址类型' : 'Address Type',
                value: isAddress
                    ? (isZh ? 'IP 直连目标' : 'Direct IP')
                    : (isZh ? '域名解析目标' : 'Resolved Domain'),
              ),
              DetailRow.text(
                title: isZh ? '总流量' : 'Total Traffic',
                value: _bytes(item.total),
              ),
              DetailRow.text(
                title: isZh ? '上行流量' : 'Upload Traffic',
                value: '↑ ${_bytes(item.up)}',
              ),
              DetailRow.text(
                title: isZh ? '下行流量' : 'Download Traffic',
                value: '↓ ${_bytes(item.down)}',
              ),
              if (item.hits > 0)
                DetailRow.text(
                  title: isZh ? '请求命中' : 'Request Hits',
                  value: '${item.hits} ${isZh ? '次' : 'hits'}',
                ),
            ],
          ),
          if (subs.isNotEmpty)
            generateSection(
              title: '${isZh ? '子域名统计明细' : 'Subdomains Breakdown'} (${subs.length})',
              items: [
                for (final sub in subs)
                  DecorationListItem(
                    leading: SiteIcon(
                      domain: sub.name,
                      size: 24,
                      enabled: siteIcon,
                    ),
                    title: Text(
                      sub.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      _bytes(sub.total),
                      style: AppTextStyle.subheadline.of(context, emphasized: true),
                    ),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: sub.name));
                      if (context.mounted) {
                        dialogs.showBanner(context.appLocalizations.copySuccess);
                      }
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _TrafficStatsSettingsDialog extends ConsumerStatefulWidget {
  final TrafficStatsOptions initialOptions;
  final bool isZh;
  final ValueChanged<TrafficStatsOptions> onOptionsChanged;
  final VoidCallback onCleared;

  const _TrafficStatsSettingsDialog({
    required this.initialOptions,
    required this.isZh,
    required this.onOptionsChanged,
    required this.onCleared,
  });

  @override
  ConsumerState<_TrafficStatsSettingsDialog> createState() =>
      _TrafficStatsSettingsDialogState();
}

class _TrafficStatsSettingsDialogState
    extends ConsumerState<_TrafficStatsSettingsDialog> {
  late TrafficStatsOptions _options;

  @override
  void initState() {
    super.initState();
    _options = widget.initialOptions;
  }

  void _update(
    TrafficStatsOptions Function(TrafficStatsOptions state) builder,
  ) {
    setState(() {
      _options = builder(_options);
    });
    widget.onOptionsChanged(_options);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final isZh = widget.isZh;

    return LiquidGlassScope(
      enabled: false,
      child: AlertDialog(
        title: isZh ? '流量统计设置' : 'Traffic Statistics Settings',
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(isZh ? '完成' : 'Done'),
          ),
        ],
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListItem.toggle(
                title: Text(isZh ? '启用流量统计' : 'Enable Traffic Statistics'),
                subtitle: Text(
                  isZh ? '在内核底层进行流量与连接统计' : 'Track traffic at core engine level',
                ),
                value: _options.enable,
                onChanged: (val) => _update((o) => o.copyWith(enable: val)),
              ),
              ListItem.toggle(
                title: Text(isZh ? '记录明细数据' : 'Record Detailed Dimensions'),
                subtitle: Text(
                  isZh
                      ? '记录域名、应用、节点与规则维度'
                      : 'Record hosts, processes, nodes and rules',
                ),
                value: _options.detail,
                onChanged: (val) => _update((o) => o.copyWith(detail: val)),
              ),
              ListItem.toggle(
                title: Text(isZh ? '显示网站图标' : 'Show Website Icons'),
                subtitle: Text(
                  isZh
                      ? '优先从对应网站获取，无图标时通过公共服务获取'
                      : 'Fetch icons from sites or public favicon services',
                ),
                value: _options.siteIcon,
                onChanged: (val) => _update((o) => o.copyWith(siteIcon: val)),
              ),
              ListItem<int>.options(
                title: Text(isZh ? '数据保留时长' : 'Retention Period'),
                subtitle: Text(
                  _options.retentionDays == 0
                      ? (isZh ? '不保留' : 'Do not keep')
                      : '${_options.retentionDays} ${isZh ? '天' : 'days'}',
                ),
                options: const [0, 1, 3, 7, 14, 30, 90],
                value: _options.retentionDays,
                textBuilder: (days) => days == 0
                    ? (isZh ? '不保留' : 'None')
                    : '$days ${isZh ? '天' : 'days'}',
                onChanged: (days) =>
                    _update((o) => o.copyWith(retentionDays: days)),
              ),
              const SizedBox(height: 8),
              ListItem(
                title: Text(
                  isZh ? '清空所有统计数据' : 'Clear All Traffic Statistics',
                  style: AppTextStyle.body.of(context).copyWith(
                        color: colorScheme.error,
                      ),
                ),
                trailing: GlyphIcon(
                  AppGlyphs.delete,
                  color: colorScheme.error,
                ),
                onTap: () async {
                  Navigator.of(context).pop();
                  final cleanTitle =
                      isZh ? '清空流量统计' : 'Clear Traffic Statistics';
                  final cleanTip = isZh
                      ? '确定要清空所有流量统计历史、明细记录与图标缓存吗？此操作无法撤销。'
                      : 'Are you sure you want to clear all traffic statistics, history and icon caches? This action cannot be undone.';
                  final confirmed = await dialogs.showMessage(
                    context: context,
                    title: cleanTitle,
                    message: TextSpan(text: cleanTip),
                    destructive: true,
                  );
                  if (confirmed == true) {
                    await ref.read(coreHandlerProvider).clearTrafficStats();
                    await siteIconCache.clear();
                    widget.onCleared();
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
