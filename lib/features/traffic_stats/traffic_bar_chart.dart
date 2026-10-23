import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart';

import 'traffic_stats_models.dart';

class TrafficBarChart extends StatelessWidget {
  final List<ChartBarPoint> points;
  final int selectedIndex;
  final ValueChanged<int> onSelectIndex;
  final double height;

  const TrafficBarChart({
    super.key,
    required this.points,
    required this.selectedIndex,
    required this.onSelectIndex,
    this.height = 180,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return SizedBox(
        height: height,
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

    final colorScheme = context.colorScheme;
    final downloadColor = colorScheme.primary;
    final uploadColor = DashboardColors.of(context).series2;

    // Find max value
    var maxVal = 0;
    for (final p in points) {
      if (p.total > maxVal) maxVal = p.total;
    }
    if (maxVal == 0) maxVal = 1024; // Default scale if empty

    final selectedPoint = (selectedIndex >= 0 && selectedIndex < points.length)
        ? points[selectedIndex]
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Detail row for selected bar
        if (selectedPoint != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: DashboardColors.of(context).tone,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  selectedPoint.fullLabel,
                  style: AppTextStyle.caption1.of(context, emphasized: true),
                ),
                Row(
                  spacing: 12,
                  children: [
                    Row(
                      spacing: 4,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: uploadColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Text(
                          selectedPoint.upload.traffic.show,
                          style: AppTextStyle.caption2
                              .of(context)
                              .toTabular
                              .copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                    Row(
                      spacing: 4,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: downloadColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Text(
                          selectedPoint.download.traffic.show,
                          style: AppTextStyle.caption2
                              .of(context)
                              .toTabular
                              .copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          )
        else
          const SizedBox(height: 12),

        // The canvas chart
        SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  final x = details.localPosition.dx;
                  final index = _indexOfPosition(x, constraints.maxWidth, points.length);
                  if (index >= 0 && index < points.length) {
                    onSelectIndex(index);
                  }
                },
                onHorizontalDragUpdate: (details) {
                  final x = details.localPosition.dx;
                  final index = _indexOfPosition(x, constraints.maxWidth, points.length);
                  if (index >= 0 && index < points.length) {
                    onSelectIndex(index);
                  }
                },
                child: CustomPaint(
                  size: Size(constraints.maxWidth, height),
                  painter: _BarChartPainter(
                    points: points,
                    selectedIndex: selectedIndex,
                    maxValue: maxVal,
                    downloadColor: downloadColor,
                    uploadColor: uploadColor,
                    trackColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                    selectedHighlightColor: colorScheme.primary.withValues(alpha: 0.15),
                    labelStyle: AppTextStyle.caption2
                        .of(context)
                        .copyWith(color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7)),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  int _indexOfPosition(double x, double totalWidth, int count) {
    if (count <= 0 || totalWidth <= 0) return -1;
    final slotWidth = totalWidth / count;
    final index = (x / slotWidth).floor();
    return index.clamp(0, count - 1);
  }
}

class _BarChartPainter extends CustomPainter {
  final List<ChartBarPoint> points;
  final int selectedIndex;
  final int maxValue;
  final Color downloadColor;
  final Color uploadColor;
  final Color trackColor;
  final Color selectedHighlightColor;
  final TextStyle labelStyle;

  _BarChartPainter({
    required this.points,
    required this.selectedIndex,
    required this.maxValue,
    required this.downloadColor,
    required this.uploadColor,
    required this.trackColor,
    required this.selectedHighlightColor,
    required this.labelStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    const labelAreaHeight = 20.0;
    final chartHeight = size.height - labelAreaHeight;
    final count = points.length;
    final slotWidth = size.width / count;
    final barWidth = math.max(3.0, slotWidth * 0.55);

    // Draw grid lines
    final gridPaint = Paint()
      ..color = trackColor
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, 0), Offset(size.width, 0), gridPaint);
    canvas.drawLine(Offset(0, chartHeight / 2), Offset(size.width, chartHeight / 2), gridPaint);
    canvas.drawLine(Offset(0, chartHeight), Offset(size.width, chartHeight), gridPaint);

    final trackPaint = Paint()..color = trackColor;
    final downloadPaint = Paint()..color = downloadColor;
    final uploadPaint = Paint()..color = uploadColor;
    final highlightPaint = Paint()..color = selectedHighlightColor;

    for (var i = 0; i < count; i++) {
      final p = points[i];
      final centerX = i * slotWidth + slotWidth / 2;
      final left = centerX - barWidth / 2;
      final right = centerX + barWidth / 2;

      // Draw selection background pillar
      if (i == selectedIndex) {
        final highlightRRect = RRect.fromRectAndRadius(
          Rect.fromLTRB(centerX - slotWidth / 2 + 1, 0, centerX + slotWidth / 2 - 1, chartHeight),
          const Radius.circular(6),
        );
        canvas.drawRRect(highlightRRect, highlightPaint);
      }

      // Track background bar
      final trackRRect = RRect.fromRectAndRadius(
        Rect.fromLTRB(left, 0, right, chartHeight),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(trackRRect, trackPaint);

      if (p.total > 0 && maxValue > 0) {
        final totalFraction = (p.total / maxValue).clamp(0.0, 1.0);
        final barHeight = chartHeight * totalFraction;
        final uploadFraction = p.total > 0 ? (p.upload / p.total) : 0.0;
        final uploadHeight = barHeight * uploadFraction;
        final downloadHeight = barHeight - uploadHeight;

        final barTop = chartHeight - barHeight;

        // Draw download part (bottom)
        if (downloadHeight > 0) {
          final downloadRRect = RRect.fromRectAndCorners(
            Rect.fromLTRB(left, chartHeight - downloadHeight, right, chartHeight),
            bottomLeft: Radius.circular(barWidth / 2),
            bottomRight: Radius.circular(barWidth / 2),
            topLeft: uploadHeight <= 0 ? Radius.circular(barWidth / 2) : Radius.zero,
            topRight: uploadHeight <= 0 ? Radius.circular(barWidth / 2) : Radius.zero,
          );
          canvas.drawRRect(downloadRRect, downloadPaint);
        }

        // Draw upload part (top)
        if (uploadHeight > 0) {
          final uploadRRect = RRect.fromRectAndCorners(
            Rect.fromLTRB(left, barTop, right, barTop + uploadHeight),
            topLeft: Radius.circular(barWidth / 2),
            topRight: Radius.circular(barWidth / 2),
            bottomLeft: downloadHeight <= 0 ? Radius.circular(barWidth / 2) : Radius.zero,
            bottomRight: downloadHeight <= 0 ? Radius.circular(barWidth / 2) : Radius.zero,
          );
          canvas.drawRRect(uploadRRect, uploadPaint);
        }
      }

      // Draw X-axis label if present
      if (p.label.isNotEmpty) {
        final textSpan = TextSpan(text: p.label, style: labelStyle);
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        )..layout();
        final textX = centerX - textPainter.width / 2;
        final textY = chartHeight + 4;
        textPainter.paint(canvas, Offset(textX, textY));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.selectedIndex != selectedIndex ||
        oldDelegate.maxValue != maxValue ||
        oldDelegate.downloadColor != downloadColor ||
        oldDelegate.uploadColor != uploadColor;
  }
}
