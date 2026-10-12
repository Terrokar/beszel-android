import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:beszel_pro/models/stats.dart';

class ChartSeries {
  final String label;
  final Color color;

  /// (time, value) pairs, sorted by time. `null` values create gaps.
  final List<(DateTime, double?)> points;
  final bool fill;
  final bool dashed;

  const ChartSeries({
    required this.label,
    required this.color,
    required this.points,
    this.fill = true,
    this.dashed = false,
  });
}

/// Line chart over time with gaps, time axis, tooltip and legend.
class TimeSeriesChart extends StatelessWidget {
  final List<ChartSeries> series;
  final ChartRange range;
  final String Function(double value) formatValue;
  final double? maxY;
  final double height;

  const TimeSeriesChart({
    super.key,
    required this.series,
    required this.range,
    required this.formatValue,
    this.maxY,
    this.height = 170,
  });

  List<FlSpot> _spots(ChartSeries s) {
    final gap = range.expectedInterval.inMilliseconds * 1.5;
    final spots = <FlSpot>[];
    DateTime? prev;
    for (final (time, value) in s.points) {
      if (prev != null &&
          time.difference(prev).inMilliseconds > gap &&
          spots.isNotEmpty &&
          !spots.last.isNull()) {
        spots.add(FlSpot.nullSpot);
      }
      if (value == null || value.isNaN) {
        if (spots.isNotEmpty && !spots.last.isNull()) {
          spots.add(FlSpot.nullSpot);
        }
      } else {
        spots.add(FlSpot(time.millisecondsSinceEpoch.toDouble(), value));
      }
      prev = time;
    }
    while (spots.isNotEmpty && spots.last.isNull()) {
      spots.removeLast();
    }
    return spots;
  }

  String _timeLabel(double x) {
    final t = DateTime.fromMillisecondsSinceEpoch(x.toInt());
    switch (range) {
      case ChartRange.week:
      case ChartRange.month:
        return DateFormat('MM/dd').format(t);
      case ChartRange.live:
        return DateFormat('HH:mm:ss').format(t);
      default:
        return DateFormat('HH:mm').format(t);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allSpots = <List<FlSpot>>[for (final s in series) _spots(s)];
    final real = allSpots.expand((s) => s).where((s) => !s.isNull());

    if (real.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            'no_history'.tr(),
            style: TextStyle(color: theme.colorScheme.outline),
          ),
        ),
      );
    }

    final minX = real.map((s) => s.x).reduce(math.min);
    var maxX = real.map((s) => s.x).reduce(math.max);
    if (maxX == minX) maxX = minX + 1;
    var top = maxY;
    if (top == null) {
      final m = real.map((s) => s.y).reduce(math.max);
      top = m <= 0 ? 1 : m * 1.15;
    }
    final gridColor = theme.colorScheme.outlineVariant.withValues(alpha: 0.4);

    final chart = LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX,
        minY: 0,
        maxY: top,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: top / 4,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: gridColor, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 52,
              interval: top / 4,
              getTitlesWidget: (value, meta) {
                if (value == meta.max && value != 0) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    formatValue(value),
                    style: const TextStyle(fontSize: 9),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: (maxX - minX) / 3,
              getTitlesWidget: (value, meta) {
                if (value == meta.min || value == meta.max) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  space: 4,
                  child: Text(
                    _timeLabel(value),
                    style: const TextStyle(fontSize: 9),
                  ),
                );
              },
            ),
          ),
          rightTitles: const AxisTitles(sideTitles: SideTitles()),
          topTitles: const AxisTitles(sideTitles: SideTitles()),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            tooltipBgColor: theme.colorScheme.inverseSurface.withValues(
              alpha: 0.9,
            ),
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            maxContentWidth: 200,
            getTooltipItems: (touched) {
              return touched.asMap().entries.map((entry) {
                final spot = entry.value;
                final s = series[spot.barIndex];
                final header = entry.key == 0
                    ? '${DateFormat('MM/dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(spot.x.toInt()))}\n'
                    : '';
                return LineTooltipItem(
                  header,
                  TextStyle(
                    color: theme.colorScheme.onInverseSurface,
                    fontSize: 11,
                  ),
                  children: [
                    TextSpan(
                      text: '${s.label}: ${formatValue(spot.y)}',
                      style: TextStyle(
                        color: Color.lerp(s.color, Colors.white, 0.35),
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                  ],
                );
              }).toList();
            },
          ),
        ),
        lineBarsData: [
          for (var i = 0; i < series.length; i++)
            LineChartBarData(
              spots: allSpots[i],
              isCurved: true,
              preventCurveOverShooting: true,
              curveSmoothness: 0.2,
              color: series[i].color,
              barWidth: 1.6,
              dashArray: series[i].dashed ? [4, 3] : null,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: series[i].fill,
                color: series[i].color.withValues(alpha: 0.15),
              ),
            ),
        ],
      ),
      duration: Duration.zero,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: height, child: chart),
        if (series.length > 1) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final s in series)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: s.color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(s.label, style: const TextStyle(fontSize: 11)),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Distinct colors for multi-series charts (temperatures, interfaces ...).
const chartPalette = <Color>[
  Color(0xFF3B82F6),
  Color(0xFF10B981),
  Color(0xFFF59E0B),
  Color(0xFFEF4444),
  Color(0xFF8B5CF6),
  Color(0xFF06B6D4),
  Color(0xFFEC4899),
  Color(0xFF84CC16),
  Color(0xFFF97316),
  Color(0xFF6366F1),
];
