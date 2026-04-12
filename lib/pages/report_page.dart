import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/project_storage_service.dart';
import '../services/area_unit_service.dart';
import '../services/layout_storage_service.dart';
import '../utils/area_unit_utils.dart';
import '../utils/web_print.dart';
import 'dart:collection';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math' as math;
import '../widgets/app_scale_metrics.dart';
import '../widgets/header_refresh_button.dart';
import '../utils/web_arrow_key_scroll_binding.dart';

// Top-level number formatter used by report helpers
String _formatTo2Decimals(dynamic value) {
  if (value == null) return '—';
  final raw = value.toString().trim();
  if (raw.isEmpty || raw == '-' || raw == '—') return '—';
  final numValue = double.tryParse(raw);
  if (numValue == null) return '—';
  if (numValue == 0) return '—';
  return numValue.toStringAsFixed(2);
}

// --- Sales Activity Chart helpers (adapted from dashboard) ---
String _getMonthAbbr(int month) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  return months[month - 1];
}

List<int> _buildFixedIntervalLabelIndices(
  int length,
  int dayInterval, {
  bool includeLast = true,
}) {
  if (length <= 1 || dayInterval <= 0) {
    return List<int>.generate(length, (index) => index);
  }

  final indices = <int>[
    for (int i = 0; i < length; i += dayInterval) i,
  ];
  if (includeLast && (indices.isEmpty || indices.last != length - 1)) {
    indices.add(length - 1);
  }

  return indices;
}

Widget _buildMultiDateXAxisRow(
  String timeFilter,
  List<int> salesData,
  List<int>? labelIndices, {
  bool compact = false,
}) {
  final today = DateTime.now();
  int daysToLookBack = timeFilter == '7D' ? 7 : 29;
  List<DateTime> dates = [];

  for (int i = daysToLookBack - 1; i >= 0; i--) {
    dates.add(today.subtract(Duration(days: i)));
  }

  return LayoutBuilder(
    builder: (context, constraints) {
      final chartWidth = constraints.maxWidth;
      final xOffset = timeFilter == '28D' ? 14.0 : 18.0;
      final rightInset = timeFilter == '28D' ? 48.0 : 40.0;
      final availableWidth = chartWidth - xOffset - rightInset;
      final xSpacing = dates.length > 1
          ? availableWidth / (dates.length - 1)
          : availableWidth;
      final resolvedLabelIndices = labelIndices ??
          (timeFilter == '28D'
              ? _buildFixedIntervalLabelIndices(dates.length, 4,
                  includeLast: true)
              : List<int>.generate(dates.length, (index) => index));
      final labelXShift = timeFilter == '28D' ? -11.0 : -29.0;

      return SizedBox(
        width: chartWidth,
        height: compact ? 34 : 64,
        child: Stack(
          children: List.generate(
            resolvedLabelIndices.length,
            (index) {
              final dateIndex = resolvedLabelIndices[index];
              final date = dates[dateIndex];
              final dateStr = '${date.day} ${_getMonthAbbr(date.month)}';
              final xPos = xOffset + (dateIndex * xSpacing);

              return Positioned(
                left: xPos,
                child: Transform.translate(
                  offset: Offset(labelXShift, compact ? -2.0 : 0.0),
                  child: Column(
                    children: [
                      Container(
                        height: 4,
                        width: 2,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: compact ? 42 : 56,
                        child: Text(
                          dateStr,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: compact ? 8 : 14,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

Widget _buildSalesActivityChart(
  int totalPlots,
  int todaysSales,
  String timeFilter,
  List<int> salesData,
  int fixedMaxY, {
  bool compact = false,
}) {
  final int maxY = fixedMaxY;
  int xInterval = maxY ~/ 5;
  if (xInterval <= 0) xInterval = 1;
  final labelIndices = timeFilter == '28D'
      ? _buildFixedIntervalLabelIndices(salesData.length, 4, includeLast: true)
      : List<int>.generate(salesData.length, (index) => index);

  if (compact) {
    final yLabels = <int>[];
    for (int i = maxY; i > 0; i -= xInterval) {
      yLabels.add(i);
    }
    if (yLabels.isEmpty) {
      yLabels.addAll([5, 4, 3, 2, 1]);
    }

    return Container(
      width: 427,
      height: 191,
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black, width: 0.1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.topRight,
            child: Text(
              '* Last 28 days *',
              style: GoogleFonts.inriaSerif(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final h = constraints.maxHeight;
                      final baselineY = h - 2;
                      final plotHeight = math.max(24.0, baselineY - 16);
                      final stepY = plotHeight / 5;
                      const labelVerticalCompression = 0.75;
                      final centerY = baselineY - (3 * stepY);
                      return Stack(
                        children: List.generate(yLabels.length, (index) {
                          // yLabels are [max..1], map to chart grid lines i=5..1.
                          final gridIndex = 5 - index;
                          final y = baselineY - (gridIndex * stepY);
                          final compressedY = centerY +
                              ((y - centerY) * labelVerticalCompression);
                          final isBottomLabel =
                              index == yLabels.length - 1; // keep "1" fixed
                          final isSecondBottomLabel =
                              index == yLabels.length - 2; // keep "2" fixed
                          final isTopLabel = index == 0; // "5"
                          final isSecondTopLabel = index == 1; // "4"
                          final topLabelsExtraUp = isTopLabel
                              ? 8
                              : (isSecondTopLabel ? 6 : (index == 2 ? 4 : 0));
                          return Positioned(
                            right: 0,
                            top: compressedY -
                                10 -
                                (isBottomLabel ? 0 : 4) -
                                topLabelsExtraUp,
                            child: Text(
                              yLabels[index].toString(),
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                fontWeight: FontWeight.normal,
                                color: const Color(0xFF5C5C5C),
                              ),
                            ),
                          );
                        }),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(
                        child: CustomPaint(
                          painter: _ChartPainter(
                            maxY: maxY,
                            xInterval: xInterval,
                            todaysSales: todaysSales,
                            timeFilter: timeFilter,
                            salesData: salesData,
                            labelIndices: labelIndices,
                          ),
                          child: Container(),
                        ),
                      ),
                      SizedBox(
                        height: 24,
                        child: _buildMultiDateXAxisRow(
                          timeFilter,
                          salesData,
                          labelIndices,
                          compact: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  return SizedBox(
    height: 170,
    child: Padding(
      padding: const EdgeInsets.only(right: 16, top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 0),
            child: Row(
              children: [
                Text(
                  'Plots Sold',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF5C5C5C),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Transform.translate(
            offset: const Offset(0, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 130,
                  child: Row(
                    children: [
                      const SizedBox(width: 2),
                      const SizedBox(width: 2),
                      SizedBox(
                        width: 24,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (int i = maxY; i > 0; i -= xInterval)
                              SizedBox(
                                height: 26,
                                child: Align(
                                  alignment: Alignment.topRight,
                                  child: Transform.translate(
                                    offset: const Offset(-4, -3),
                                    child: Text(
                                      i.toString(),
                                      style: GoogleFonts.inter(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w400,
                                        color: const Color(0xFF5C5C5C),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Transform.translate(
                          offset: const Offset(0, 0),
                          child: CustomPaint(
                            painter: _ChartPainter(
                              maxY: maxY,
                              xInterval: xInterval,
                              todaysSales: todaysSales,
                              timeFilter: timeFilter,
                              salesData: salesData,
                              labelIndices: labelIndices,
                            ),
                            child: Container(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      const SizedBox(width: 2),
                      const SizedBox(width: 2),
                      const SizedBox(width: 24),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Transform.translate(
                          offset: const Offset(0, 0),
                          child: _buildMultiDateXAxisRow(
                            timeFilter,
                            salesData,
                            labelIndices,
                            compact: false,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _ChartPainter extends CustomPainter {
  final int maxY;
  final int xInterval;
  final int todaysSales;
  final String timeFilter;
  final List<int> salesData;
  final List<int> labelIndices;

  _ChartPainter({
    required this.maxY,
    required this.xInterval,
    required this.todaysSales,
    required this.timeFilter,
    required this.salesData,
    required this.labelIndices,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..color = const Color(0xFFD1D1D1)
      ..strokeWidth = 1;

    final thickPaint = Paint()
      ..color = const Color(0xFF5C5C5C)
      ..strokeWidth = 2;

    final baselineY = size.height - 2;
    final plotHeight = math.max(24.0, baselineY - 16);
    final stepY = plotHeight / 5;

    for (int i = 0; i <= 5; i++) {
      final y = baselineY - (i * stepY);
      if (i == 0) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), thickPaint);
      } else if (i == 5) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      } else {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }

    // Match waterfall chart behavior: y-axis starts at the top edge with arrow tip at top.
    const yAxisTop = 0.0;
    canvas.drawLine(Offset(0, yAxisTop), Offset(0, baselineY), thickPaint);

    const arrowSize = 7.0;
    canvas.drawLine(
      const Offset(0, yAxisTop),
      const Offset(-arrowSize / 2, yAxisTop + arrowSize),
      thickPaint,
    );
    canvas.drawLine(
      const Offset(0, yAxisTop),
      const Offset(arrowSize / 2, yAxisTop + arrowSize),
      thickPaint,
    );

    if (timeFilter == '1D') {
      if (todaysSales > 0) {
        final valueRatio = todaysSales / maxY;
        final yPosition = baselineY - (valueRatio * plotHeight);
        final dashedPaint = Paint()
          ..color = const Color(0xFF0C8CE9)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;
        const dashWidth = 5.0;
        const dashSpace = 3.0;
        double startX = 0;
        while (startX < size.width) {
          canvas.drawLine(Offset(startX, yPosition),
              Offset(startX + dashWidth, yPosition), dashedPaint);
          startX += dashWidth + dashSpace;
        }
        const xOffset = 40.0;
        final markerX = xOffset;
        final markerPaint = Paint()
          ..color = const Color(0xFF0C8CE9)
          ..style = PaintingStyle.fill;
        final markerSize = 6.0;
        final markerPath = Path()
          ..moveTo(markerX, yPosition - markerSize)
          ..lineTo(markerX + markerSize, yPosition)
          ..lineTo(markerX, yPosition + markerSize)
          ..lineTo(markerX - markerSize, yPosition)
          ..close();
        canvas.drawPath(markerPath, markerPaint);
      }
    } else {
      if (salesData.isNotEmpty) {
        final dashedPaint = Paint()
          ..color = const Color(0xFF0C8CE9)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;

        final markerPaint = Paint()
          ..color = const Color(0xFF0C8CE9)
          ..style = PaintingStyle.fill;

        final xOffset = timeFilter == '28D' ? 14.0 : 18.0;
        final pointShift = timeFilter == '28D' ? 11.0 : 0.0;
        final rightInset = timeFilter == '28D' ? 48.0 : 40.0;
        final availableWidth = size.width - xOffset - rightInset;
        final xSpacing =
            availableWidth / (salesData.length > 1 ? salesData.length - 1 : 1);
        List<Offset> dataPoints = [];

        for (int i = 0; i < salesData.length; i++) {
          final sales = salesData[i];
          final xPos = xOffset + (i * xSpacing) + pointShift;
          final yRatio = (sales / maxY).clamp(0.0, 1.0);
          final yPos = baselineY - (yRatio * plotHeight);
          dataPoints.add(Offset(xPos, yPos));
        }

        const dashWidth = 5.0;
        const dashSpace = 3.0;
        for (int i = 0; i < dataPoints.length - 1; i++) {
          final start = dataPoints[i];
          final end = dataPoints[i + 1];
          double len = (end - start).distance;
          if (len > 0) {
            double segments = len / (dashWidth + dashSpace);
            for (int j = 0; j < segments.ceil(); j++) {
              double t0 = (j * (dashWidth + dashSpace)) / len;
              double t1 = ((j * (dashWidth + dashSpace)) + dashWidth) / len;
              t0 = t0.clamp(0.0, 1.0);
              t1 = t1.clamp(0.0, 1.0);
              final p0 = Offset(start.dx + (end.dx - start.dx) * t0,
                  start.dy + (end.dy - start.dy) * t0);
              final p1 = Offset(start.dx + (end.dx - start.dx) * t1,
                  start.dy + (end.dy - start.dy) * t1);
              canvas.drawLine(p0, p1, dashedPaint);
            }
          }
        }

        for (int i = 0; i < dataPoints.length; i++) {
          final point = dataPoints[i];
          final sales = salesData[i];
          final isLabelIndex = labelIndices.contains(i);
          final shouldShowMarker = sales > 0 ||
              ((timeFilter == '28D' || timeFilter == '7D') && isLabelIndex);
          if (!shouldShowMarker) continue;
          final markerSize = size.height < 100 ? 3.5 : 6.0;
          final markerPath = Path()
            ..moveTo(point.dx, point.dy - markerSize)
            ..lineTo(point.dx + markerSize, point.dy)
            ..lineTo(point.dx, point.dy + markerSize)
            ..lineTo(point.dx - markerSize, point.dy)
            ..close();
          canvas.drawPath(markerPath, markerPaint);
          final textPainter = TextPainter(
            text: TextSpan(
              text: sales.toString(),
              style: const TextStyle(
                color: Color(0xFF5C5C5C),
                fontSize: 9,
                fontWeight: FontWeight.w500,
              ),
            ),
            textDirection: TextDirection.ltr,
          );
          textPainter.layout();
          textPainter.paint(
              canvas,
              Offset(point.dx - textPainter.width / 2,
                  point.dy - textPainter.height - 12));
        }
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter oldDelegate) {
    return oldDelegate.maxY != maxY ||
        oldDelegate.xInterval != xInterval ||
        oldDelegate.todaysSales != todaysSales ||
        oldDelegate.timeFilter != timeFilter ||
        oldDelegate.salesData != salesData ||
        oldDelegate.labelIndices != labelIndices;
  }
}

class ReportPage extends StatefulWidget {
  final Map<String, dynamic>? projectData;
  final String? projectId;
  final Map<String, dynamic>? dashboardData;
  final int dataVersion;
  final bool isActive;

  const ReportPage({
    super.key,
    this.projectData,
    this.projectId,
    this.dashboardData,
    this.dataVersion = 0,
    this.isActive = false,
  });

  @override
  State<ReportPage> createState() => _ReportPageState();
}

// Top-level helpers for report waterfall chart (copied/adapted from dashboard)
class _AxisScaleReport {
  final double axisMin;
  final double axisMax;
  final double step;
  final double unit;
  final String suffix;

  _AxisScaleReport(
      {required this.axisMin,
      required this.axisMax,
      required this.step,
      required this.unit,
      required this.suffix});
}

_AxisScaleReport _buildAxisScaleReport(double minValue, double maxValue) {
  if (minValue >= 0) {
    final axisMax = _roundUpNiceReport(maxValue <= 0 ? 1.0 : maxValue);
    final step = axisMax / 5;
    final unit = _axisUnitReport(axisMax);
    final suffix = _axisSuffixReport(unit);
    return _AxisScaleReport(
        axisMin: 0, axisMax: axisMax, step: step, unit: unit, suffix: suffix);
  }
  final maxAbs = math.max(maxValue.abs(), minValue.abs());
  final rounded = _roundUpNiceReport(maxAbs);
  final axisMax = rounded;
  final axisMin = -rounded;
  final step = (axisMax - axisMin) / 5;
  final unit = _axisUnitReport(axisMax);
  final suffix = _axisSuffixReport(unit);
  return _AxisScaleReport(
      axisMin: axisMin,
      axisMax: axisMax,
      step: step,
      unit: unit,
      suffix: suffix);
}

double _roundUpNiceReport(double value) {
  if (value <= 0) return 1;
  final exponent =
      math.pow(10, (math.log(value) / math.ln10).floor()).toDouble();
  final fraction = value / exponent;
  double nice;
  if (fraction <= 1) {
    nice = 1;
  } else if (fraction <= 2) {
    nice = 2;
  } else if (fraction <= 5) {
    nice = 5;
  } else {
    nice = 10;
  }
  return nice * exponent;
}

double _axisUnitReport(double axisMax) {
  if (axisMax >= 10000000) return 10000000;
  if (axisMax >= 100000) return 100000;
  if (axisMax >= 1000) return 1000;
  return 1;
}

String _axisSuffixReport(double unit) {
  if (unit == 10000000) return 'Cr';
  if (unit == 100000) return 'L';
  if (unit == 1000) return 'K';
  return '';
}

String _formatCurrencyWithSignReport(double value) {
  if (value < 0) return '-₹ ${_formatTo2Decimals(value.abs())}';
  return '₹ ${_formatTo2Decimals(value)}';
}

String _formatAxisLabelValueReport(double value, _AxisScaleReport scale) {
  final scaled = value / scale.unit;
  final needsDecimal = (scale.step / scale.unit) < 1;
  final formatted =
      needsDecimal ? scaled.toStringAsFixed(1) : scaled.toStringAsFixed(0);
  final trimmed = formatted.replaceAll(RegExp(r'\.0$'), '');
  if (scale.suffix.isEmpty) return trimmed;
  return '$trimmed ${scale.suffix}';
}

Widget _buildChartRowReport(
  double width,
  Color color,
  double height, {
  required double rowWidth,
  required double zeroX,
  double? startX,
  double axisGap = 0,
  required bool isNegative,
  required String tooltipText,
}) {
  return SizedBox(
    width: rowWidth,
    height: height,
    child: Stack(
      alignment: Alignment.centerLeft,
      children: [
        Positioned(
          left: startX ??
              (isNegative ? (zeroX - width - axisGap) : (zeroX + axisGap)),
          top: 0,
          bottom: 0,
          child: Container(
            width: width,
            height: height,
            color: color,
          ),
        ),
      ],
    ),
  );
}

Widget _buildChartDividerReport(double width, double gap, double height) {
  return Column(
    children: [
      SizedBox(height: gap),
      Container(
        width: width,
        height: height,
        color: const Color(0xFFD0D0D0),
      ),
      SizedBox(height: gap),
    ],
  );
}

Widget _buildAxisLabelReport(String text) {
  return Text(
    text,
    style: GoogleFonts.inriaSerif(
      fontSize: 10,
      fontWeight: FontWeight.normal,
      color: Colors.black,
    ),
    textAlign: TextAlign.center,
  );
}

class _VerticalGridPainterReport extends CustomPainter {
  final List<double> tickXs;
  final double plotHeight;

  _VerticalGridPainterReport({required this.tickXs, required this.plotHeight});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..color = const Color(0xFFD1D1D1)
      ..strokeWidth = 0.5;
    final yMax = plotHeight.clamp(0.0, size.height).toDouble();
    for (final x in tickXs) {
      final clampedX = x.clamp(0.0, size.width).toDouble();
      canvas.drawLine(Offset(clampedX, 0), Offset(clampedX, yMax), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _VerticalGridPainterReport oldDelegate) {
    if (oldDelegate.plotHeight != plotHeight) return true;
    if (oldDelegate.tickXs.length != tickXs.length) return true;
    for (var i = 0; i < tickXs.length; i++) {
      if (oldDelegate.tickXs[i] != tickXs[i]) return true;
    }
    return false;
  }
}

class _AxisPainterReport extends CustomPainter {
  final double zeroX;
  final bool hasNegative;
  final bool hasPositive;
  final double axisLineHeight;
  final List<double> tickXs;
  final double verticalAxisEndY;

  const _AxisPainterReport({
    required this.zeroX,
    required this.hasNegative,
    required this.hasPositive,
    required this.axisLineHeight,
    required this.tickXs,
    required this.verticalAxisEndY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    const axisLineWidth = 1.2;
    final verticalPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = axisLineWidth;
    final horizontalPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = axisLineWidth;
    final arrowPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.2;

    final axisY = size.height - (axisLineWidth / 2);
    const arrowSize = 7.0;

    final verticalEndY = verticalAxisEndY.clamp(0.0, size.height);
    canvas.drawLine(
        Offset(zeroX, 0), Offset(zeroX, verticalEndY), verticalPaint);
    canvas.drawLine(
        Offset(zeroX, 0), Offset(zeroX - arrowSize / 2, arrowSize), arrowPaint);
    canvas.drawLine(
        Offset(zeroX, 0), Offset(zeroX + arrowSize / 2, arrowSize), arrowPaint);

    final startX = hasNegative ? 0.0 : zeroX;
    final lastTick =
        tickXs.isEmpty ? 0.0 : tickXs.last.clamp(0.0, size.width).toDouble();
    const extraAfterLastTick = 16.0;
    final endX =
        (lastTick + extraAfterLastTick).clamp(0.0, size.width).toDouble();

    canvas.drawLine(
        Offset(startX, axisY), Offset(endX, axisY), horizontalPaint);
    canvas.drawLine(Offset(endX, axisY),
        Offset(endX - arrowSize, axisY - arrowSize / 2), arrowPaint);
    canvas.drawLine(Offset(endX, axisY),
        Offset(endX - arrowSize, axisY + arrowSize / 2), arrowPaint);

    final tickPaint = Paint()..color = const Color(0xFF000000);
    const tickWidth = 1.0;
    const tickHeight = 3.0;
    for (final x in tickXs) {
      final clampedX = x.clamp(0.0, size.width).toDouble();
      canvas.drawRect(
          Rect.fromLTWH(
              clampedX - (tickWidth / 2), axisY, tickWidth, tickHeight),
          tickPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _AxisPainterReport oldDelegate) {
    if (oldDelegate.zeroX != zeroX ||
        oldDelegate.hasNegative != hasNegative ||
        oldDelegate.hasPositive != hasPositive ||
        oldDelegate.axisLineHeight != axisLineHeight ||
        oldDelegate.verticalAxisEndY != verticalAxisEndY) {
      return true;
    }
    if (oldDelegate.tickXs.length != tickXs.length) return true;
    for (var i = 0; i < tickXs.length; i++) {
      if (oldDelegate.tickXs[i] != tickXs[i]) return true;
    }
    return false;
  }
}

class _AxisLabelLayoutDelegateReport extends SingleChildLayoutDelegate {
  final double tickX;

  _AxisLabelLayoutDelegateReport({required this.tickX});

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return Offset(tickX - (childSize.width / 2), 0);
  }

  @override
  bool shouldRelayout(covariant _AxisLabelLayoutDelegateReport oldDelegate) {
    return oldDelegate.tickX != tickX;
  }
}

class _ReportPageState extends State<ReportPage> {
  static const String _reportIdentityLogoBucket = 'account-report-logos';
  static const double _reportPreviewPageExtent = 858.0;
  static const Duration _printCaptureFrameDelay = Duration(milliseconds: 70);

  Future<void> _handlePrintPressed() async {
    if (_isPrintingReport) return;

    final printWindow = preOpenPrintWindow();
    setState(() {
      _isPrintingReport = true;
    });

    try {
      await Future<void>.delayed(const Duration(milliseconds: 32));
      await WidgetsBinding.instance.endOfFrame;

      final reportPageImages = await _captureAllReportPagesForPrint();
      if (reportPageImages.isEmpty) {
        throw StateError('No report pages available for print.');
      }
      final expectedPages = _buildAllReportPagesForPreview().length;
      if (reportPageImages.length != expectedPages) {
        throw StateError(
          'Captured ${reportPageImages.length} of $expectedPages report pages.',
        );
      }
      debugPrint('Report print page count: ${reportPageImages.length}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Text('Preparing print: ${reportPageImages.length} pages'),
          ),
        );
      }

      await printReportImages(
        reportPageImages,
        preOpenedWindow: printWindow,
      );
    } catch (error, stackTrace) {
      debugPrint('Report print failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      closePrintWindow(printWindow);
      if (!mounted) return;
      final errorText = error.toString();
      final showDetail = errorText.isNotEmpty && errorText.length < 140;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(showDetail
              ? 'Unable to print report: $errorText'
              : 'Unable to print report. Please try again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isPrintingReport = false;
        });
      }
    }
  }

  void _ensureReportPagePrintKeys(int pageCount) {
    if (_reportPagePrintKeys.length < pageCount) {
      for (var i = _reportPagePrintKeys.length; i < pageCount; i++) {
        _reportPagePrintKeys.add(GlobalKey(debugLabel: 'report_print_page_$i'));
      }
      return;
    }

    if (_reportPagePrintKeys.length > pageCount) {
      _reportPagePrintKeys.removeRange(pageCount, _reportPagePrintKeys.length);
    }
  }

  double _targetOffsetForPage(int pageNum) {
    if (!_mainPreviewScrollController.hasClients) return 0.0;
    final maxOffset = _mainPreviewScrollController.position.maxScrollExtent;
    final rawOffset = (pageNum - 1) * _reportPreviewPageExtent;
    return rawOffset.clamp(0.0, maxOffset).toDouble();
  }

  Future<Uint8List?> _captureReportPageAsPng(int pageIndex) async {
    if (pageIndex < 0 || pageIndex >= _reportPagePrintKeys.length) {
      return null;
    }
    final boundaryContext = _reportPagePrintKeys[pageIndex].currentContext;
    if (boundaryContext == null) return null;

    final renderObject = boundaryContext.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      return null;
    }

    final mediaQuery = MediaQuery.maybeOf(boundaryContext);
    final pixelRatio =
        (mediaQuery?.devicePixelRatio ?? 1.0).clamp(1.0, 1.2).toDouble();

    if (renderObject.debugNeedsPaint) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      await WidgetsBinding.instance.endOfFrame;
    }

    final image = await renderObject.toImage(pixelRatio: pixelRatio);
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<List<Uint8List>> _captureAllReportPagesForPrint() async {
    final totalPages = _buildAllReportPagesForPreview().length;
    if (totalPages == 0) return const <Uint8List>[];

    _ensureReportPagePrintKeys(totalPages);

    final capturedPages = <Uint8List>[];
    final initialOffset = _mainPreviewScrollController.hasClients
        ? _mainPreviewScrollController.offset
        : 0.0;

    try {
      for (var i = 0; i < totalPages; i++) {
        if (_mainPreviewScrollController.hasClients) {
          _mainPreviewScrollController.jumpTo(_targetOffsetForPage(i + 1));
        }
        await Future<void>.delayed(_printCaptureFrameDelay);
        await WidgetsBinding.instance.endOfFrame;

        var imageBytes = await _captureReportPageAsPng(i);
        if (imageBytes == null) {
          await Future<void>.delayed(const Duration(milliseconds: 160));
          await WidgetsBinding.instance.endOfFrame;
          imageBytes = await _captureReportPageAsPng(i);
        }
        if (imageBytes == null) {
          throw StateError('Unable to capture report page ${i + 1}.');
        }
        capturedPages.add(imageBytes);
      }
    } finally {
      if (_mainPreviewScrollController.hasClients) {
        final maxOffset = _mainPreviewScrollController.position.maxScrollExtent;
        _mainPreviewScrollController.jumpTo(
          initialOffset.clamp(0.0, maxOffset).toDouble(),
        );
      }
      await WidgetsBinding.instance.endOfFrame;
    }

    return capturedPages;
  }

  double _calculateProjectManagerEarningsReport(Map<String, dynamic> manager) {
    final compensationType = (manager['compensation_type'] ?? '').toString();
    final earningType = (manager['earning_type'] ?? '').toString();

    if (compensationType == 'Fixed Fee') {
      return (manager['fixed_fee'] as num?)?.toDouble() ?? 0.0;
    }
    if (compensationType == 'Monthly Fee') {
      final monthlyFee = (manager['monthly_fee'] as num?)?.toDouble() ?? 0.0;
      final months = (manager['months'] as num?)?.toInt() ?? 0;
      return monthlyFee * months;
    }
    if (compensationType == 'Percentage Bonus') {
      final percentage = (manager['percentage'] as num?)?.toDouble() ?? 0.0;

      final lowerEarning = earningType.toLowerCase();
      final isLumpSum = earningType == 'Lump Sum' ||
          earningType == '% of Total Project Profit' ||
          (lowerEarning.contains('total project profit') ||
              lowerEarning.contains('lump'));

      final soldPlots = _collectReportPlotsForOverview()
          .where(
              (plot) => _normalizeSiteStatusForReport(plot['status']) == 'sold')
          .toList(growable: false);
      final allInCost = _computeAllInCostPerSqftForReport();

      if (isLumpSum) {
        final totalGrossProfit = _computeOverviewGrossProfitForReport();
        if (totalGrossProfit <= 0) return 0.0;
        final totalAgentCompensation =
            math.max(0.0, _calculateTotalAgentCompensationReport());
        final remainingAfterAgent = totalGrossProfit - totalAgentCompensation;
        return _calculateTotalProjectProfitBonusReport(
          profitBase: remainingAfterAgent,
          percentage: percentage,
        );
      }

      double totalEarnings = 0.0;
      final isSellingPriceBased = earningType == 'Selling Price Per Plot' ||
          earningType == '% of Selling Price per Plot' ||
          (lowerEarning.contains('selling price') &&
              lowerEarning.contains('plot'));

      for (final plot in soldPlots) {
        final salePrice = _toDouble(
          plot['sale_price'] ?? plot['salePrice'] ?? plot['salePricePerSqft'],
        );
        final area =
            _toDouble(plot['area'] ?? plot['plotArea'] ?? plot['plot_area']);
        final saleValue = salePrice * area;
        final agentCompOnPlot = _calculateAgentCompensationForPlotReport(plot);

        if (isSellingPriceBased) {
          final remainingAfterAgent = saleValue - agentCompOnPlot;
          totalEarnings += (remainingAfterAgent * percentage) / 100;
        } else {
          final plotCost = area * allInCost;
          final plotProfit = saleValue - plotCost;
          final remainingAfterAgent = plotProfit - agentCompOnPlot;
          totalEarnings += (remainingAfterAgent * percentage) / 100;
        }
      }

      return totalEarnings;
    }

    return 0.0;
  }

  double _nonNegativeReportEarning(dynamic value) {
    final parsed = _toDouble(value);
    if (parsed.isNaN || parsed.isInfinite) return 0.0;
    return parsed < 0 ? 0.0 : parsed;
  }

  double _calculateTotalProjectProfitBonusReport({
    required double profitBase,
    required double percentage,
  }) {
    if (!profitBase.isFinite || !percentage.isFinite) return 0.0;
    if (profitBase <= 0 || percentage <= 0) return 0.0;
    return (profitBase * percentage) / 100;
  }

  String _formatProjectManagerEarningTypeReport(
      String earningType, double percentage) {
    String displayEarningType = earningType;
    final lowerEarningType = earningType.toLowerCase();
    if (lowerEarningType == 'profit per plot') {
      displayEarningType = '% of Profit on Each Sold Plot';
    } else if (lowerEarningType == 'selling price per plot' ||
        lowerEarningType == '% of selling price per plot') {
      displayEarningType = '% of Selling Price per Plot';
    } else if (lowerEarningType == 'lump sum' ||
        lowerEarningType == '% of total project profit') {
      displayEarningType = '% of Total Project Profit';
    } else if (lowerEarningType == 'per plot') {
      displayEarningType = '% of Profit on Each Sold Plot';
    }
    if (percentage <= 0) return displayEarningType;
    return '${_formatPercentageForReport(percentage)}% of ${displayEarningType.replaceFirst('% of ', '')}';
  }

  String _buildProjectManagerEarningTypeDisplayReport(
      Map<String, dynamic> manager) {
    final compensationType =
        (manager['compensation_type'] ?? manager['compensationType'] ?? '')
            .toString();
    final earningType =
        (manager['earning_type'] ?? manager['earningType'] ?? '').toString();
    final percentage = _toDouble(manager['percentage']);
    final fixedFee = _toDouble(manager['fixed_fee'] ?? manager['fixedFee']);
    final monthlyFee =
        _toDouble(manager['monthly_fee'] ?? manager['monthlyFee']);
    final months = _toDouble(manager['months']).toInt();
    final perSqftFee =
        _toDouble(manager['per_sqft_fee'] ?? manager['perSqftFee']);

    if (compensationType == 'Percentage Bonus') {
      return _formatProjectManagerEarningTypeReport(earningType, percentage);
    }
    if (compensationType == 'Fixed Fee') {
      return '₹ ${_formatTo2Decimals(fixedFee)}';
    }
    if (compensationType == 'Monthly Fee') {
      return '₹ ${_formatTo2Decimals(monthlyFee)} * $months';
    }
    if (compensationType == 'Per Sqft Fee' ||
        compensationType == 'Per Sqm Fee' ||
        compensationType == 'Per sqft rate') {
      return '₹ ${_formatTo2Decimals(_displayRateFromSqft(perSqftFee))}';
    }
    return 'NA';
  }

  // Project Manager(s) Details (Figma design)
  Widget _buildReportPage8({
    required int pageNumber,
    int managerStartIndex = 0,
    int? managerLimit,
    bool showTotals = true,
    bool isContinuation = false,
  }) {
    final projectName =
        _projectData['projectName'] ?? _projectData['name'] ?? 'Project Name';
    final managersRaw = (_projectData['project_managers'] ??
            _projectData['projectManagers']) as List<dynamic>? ??
        [];
    final managers = managersRaw.map((m) {
      final manager =
          m is Map ? Map<String, dynamic>.from(m as Map) : <String, dynamic>{};
      final earningsValue = _nonNegativeReportEarning(
        _calculateProjectManagerEarningsReport(manager),
      );
      return {
        'name': manager['name'] ?? '-',
        'compensationType': manager['compensation_type'] ?? '-',
        'earningType': _buildProjectManagerEarningTypeDisplayReport(manager),
        'earningsValue': earningsValue,
        'earnings': '₹ ${_formatTo2Decimals(earningsValue)}',
      };
    }).toList();
    final visibleManagers = managerLimit == null
        ? managers
        : managers
            .skip(managerStartIndex)
            .take(managerLimit)
            .toList(growable: false);
    final totalEarnings = managers.fold<double>(
      0.0,
      (sum, m) => sum + _nonNegativeReportEarning(m['earningsValue']),
    );

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header (same as page 5)
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: const Color(0xFF404040),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Section Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              isContinuation
                  ? '3. Project Manager(s) Details (Cont.)'
                  : '3. Project Manager(s) Details',
              style: GoogleFonts.inriaSerif(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: const Color(0xFF0C8CE9),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Table Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '3.1  Project Manager(s) Earnings',
              style: GoogleFonts.inriaSerif(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Table
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF404040), width: 0.5),
              ),
              child: Column(
                children: [
                  // Table Header
                  Container(
                    color: const Color(0xFF404040),
                    padding:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 124,
                          child: Text(
                            'Project Manager(s) Name',
                            style: GoogleFonts.inriaSerif(
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        SizedBox(
                          width: 100,
                          child: Text(
                            'Compensation Type',
                            style: GoogleFonts.inriaSerif(
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        SizedBox(
                          width: 163,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: Text(
                              'Earning Type',
                              style: GoogleFonts.inriaSerif(
                                fontWeight: FontWeight.bold,
                                fontSize: 10,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 88,
                          child: Text(
                            'Earnings (₹)',
                            style: GoogleFonts.inriaSerif(
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Table Rows
                  ...visibleManagers.map((m) => Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 4, horizontal: 6),
                        decoration: const BoxDecoration(
                          border: Border(
                              bottom:
                                  BorderSide(color: Colors.black, width: 0.25)),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 124,
                              child: Text(
                                m['name'] ?? '-',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  color: const Color(0xFF404040),
                                ),
                              ),
                            ),
                            const SizedBox(width: 20),
                            SizedBox(
                              width: 100,
                              child: Text(
                                m['compensationType'] ?? '-',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  color: const Color(0xFF404040),
                                ),
                              ),
                            ),
                            const SizedBox(width: 20),
                            SizedBox(
                              width: 163,
                              child: Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: Text(
                                  m['earningType'] ?? '-',
                                  style: GoogleFonts.inriaSerif(
                                    fontSize: 10,
                                    color: const Color(0xFF404040),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 88,
                              child: Text(
                                m['earnings'] ?? '-',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  color: const Color(0xFF404040),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )),
                  if (showTotals)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 6),
                      color: const Color(0xFFD9D9D9),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 124,
                            child: Text(
                              'Total',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF404040),
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          const SizedBox(width: 100),
                          const SizedBox(width: 20),
                          const SizedBox(width: 163),
                          SizedBox(
                            width: 88,
                            child: Text(
                              '₹ ${_formatTo2Decimals(totalEarnings)}',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                color: const Color(0xFF404040),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const Spacer(),
          // Footer (same as page 5)
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  bool _agentHasSoldPlotReport(String agentName) {
    final normalized = _normalizeAgentNameKeyForReport(agentName);
    if (normalized.isEmpty) return false;

    final plots = _collectReportPlotsForOverview();
    for (final plot in plots) {
      final status = _normalizeSiteStatusForReport(plot['status']);
      final plotAgent = _normalizeAgentNameKeyForReport(
        plot['agent_name'] ?? plot['agent'] ?? plot['agentName'],
      );
      if (status == 'sold' && plotAgent == normalized) return true;
    }

    final amenityRows = _collectAmenityAreasForReport();
    for (final row in amenityRows) {
      if (_amenityStatusForReport(row) != 'sold') continue;
      final amenityAgent = _normalizeAgentNameKeyForReport(
        row['agent_name'] ?? row['agent'] ?? row['agentName'],
      );
      if (amenityAgent == normalized) return true;
    }

    return false;
  }

  double _calculateAmenityAgentEarningsReport(
    Map<String, dynamic> row,
    Map<String, dynamic> agent,
  ) {
    if (_amenityStatusForReport(row) != 'sold') return 0.0;

    final normalizedAgent = _normalizeReportAgentForCalculations(agent);

    final compensationType =
        (normalizedAgent['compensation_type'] ?? '').toString();
    final earningType = (normalizedAgent['earning_type'] ?? '').toString();
    final areaSqft = _amenityAreaSqftForReport(row);
    final saleValue = _amenitySaleValueForReport(row);

    if (compensationType == 'Per Sqft Fee' ||
        compensationType == 'Per sqft rate') {
      final perSqftFee = _toDouble(normalizedAgent['per_sqft_fee']);
      return perSqftFee * areaSqft;
    }

    if (compensationType == 'Per Sqm Fee') {
      final perSqmFee = _toDouble(normalizedAgent['per_sqm_fee']);
      if (perSqmFee > 0) {
        final areaSqm = AreaUnitUtils.areaFromSqftToDisplay(areaSqft, true);
        return perSqmFee * areaSqm;
      }
      final perSqftFee = _toDouble(normalizedAgent['per_sqft_fee']);
      return perSqftFee * areaSqft;
    }

    if (compensationType == 'Percentage Bonus') {
      final percentage = _toDouble(normalizedAgent['percentage']);
      if (percentage <= 0) return 0.0;

      final lowerEarningType = earningType.toLowerCase();
      final isSellingPriceBased = earningType == 'Selling Price Per Plot' ||
          earningType == '% of Selling Price per Plot' ||
          (lowerEarningType.contains('selling price') &&
              lowerEarningType.contains('plot'));
      if (isSellingPriceBased) {
        return (saleValue * percentage) / 100;
      }

      final isProfitPerPlot = earningType == 'Profit Per Plot' ||
          earningType == 'Per Plot' ||
          earningType == '% of Profit on Each Sold Plot' ||
          (lowerEarningType.contains('profit') &&
              lowerEarningType.contains('plot'));
      if (isProfitPerPlot) {
        final amenityAllInCostSqft = _amenityAllInCostSqftForReport(row);
        final allInCostPerSqft = amenityAllInCostSqft > 0
            ? amenityAllInCostSqft
            : _computeAllInCostPerSqftForReport();
        final amenityCost = allInCostPerSqft * areaSqft;
        final profit = saleValue - amenityCost;
        return (profit * percentage) / 100;
      }
    }

    return 0.0;
  }

  double _calculateAmenityEarningsForAgentReport(Map<String, dynamic> agent) {
    final amenityRows = _collectAmenityAreasForReport();
    if (amenityRows.isEmpty) return 0.0;

    final agentName = _normalizeAgentNameKeyForReport(agent['name']);
    if (agentName.isEmpty) return 0.0;

    var total = 0.0;
    for (final row in amenityRows) {
      final amenityAgent = _normalizeAgentNameKeyForReport(
        row['agent_name'] ?? row['agent'] ?? row['agentName'],
      );
      if (amenityAgent != agentName) continue;
      total += _calculateAmenityAgentEarningsReport(row, agent);
    }
    return total;
  }

  String _formatAgentPercentageEarningTypeReport(
      String earningType, double percentage) {
    String displayEarningType = earningType;
    final lowerEarningType = earningType.toLowerCase();
    if (lowerEarningType == 'profit per plot' ||
        lowerEarningType == 'per plot') {
      displayEarningType = '% of Profit on Each Sold Plot';
    } else if (lowerEarningType == 'selling price per plot' ||
        lowerEarningType == '% of selling price per plot') {
      displayEarningType = '% of Selling Price per Plot';
    } else if (lowerEarningType == 'lump sum' ||
        lowerEarningType == '% of total project profit') {
      displayEarningType = '% of Total Project Profit';
    }
    if (percentage <= 0) return displayEarningType;
    return '${_formatPercentageForReport(percentage)}% of ${displayEarningType.replaceFirst('% of ', '')}';
  }

  String _normalizeAgentCompensationTypeForReport(dynamic value) {
    final raw = (value ?? '').toString().trim();
    if (raw.isEmpty) return '';

    final normalized = raw.toLowerCase();
    if (normalized.contains('fixed')) return 'Fixed Fee';
    if (normalized.contains('monthly')) return 'Monthly Fee';
    if (normalized.contains('percentage') || normalized.contains('bonus')) {
      return 'Percentage Bonus';
    }
    if (normalized.contains('sqm') ||
        normalized.contains('sq m') ||
        normalized.contains('square meter') ||
        normalized.contains('square metre')) {
      return 'Per Sqm Fee';
    }
    if (normalized.contains('sqft') ||
        normalized.contains('sq ft') ||
        normalized.contains('square feet') ||
        normalized == 'per sqft rate') {
      return 'Per Sqft Fee';
    }
    return raw;
  }

  int _parseAgentMonthsForReport(dynamic value) {
    if (value is num) return value.toInt();
    final raw = (value ?? '').toString().trim();
    return int.tryParse(raw) ?? 0;
  }

  String _normalizeAgentNameKeyForReport(dynamic value) {
    final raw = (value ?? '').toString().trim().toLowerCase();
    if (raw.isEmpty) return '';
    return raw.replaceAll(RegExp(r'\s+'), ' ');
  }

  Map<String, dynamic> _normalizeReportAgentForCalculations(
    Map<String, dynamic> rawAgent,
  ) {
    return {
      ...rawAgent,
      'id': (rawAgent['id'] ?? '').toString().trim(),
      'name': (rawAgent['name'] ?? '').toString().trim(),
      'compensation_type': _normalizeAgentCompensationTypeForReport(
        rawAgent['compensation_type'] ??
            rawAgent['compensation'] ??
            rawAgent['compensationType'],
      ),
      'earning_type': (rawAgent['earning_type'] ?? rawAgent['earningType'] ?? '')
          .toString()
          .trim(),
      'percentage': _toDouble(rawAgent['percentage']),
      'fixed_fee': _toDouble(rawAgent['fixed_fee'] ?? rawAgent['fixedFee']),
      'monthly_fee':
          _toDouble(rawAgent['monthly_fee'] ?? rawAgent['monthlyFee']),
      'months': _parseAgentMonthsForReport(
        rawAgent['months'] ?? rawAgent['durationMonths'],
      ),
      'per_sqft_fee':
          _toDouble(rawAgent['per_sqft_fee'] ?? rawAgent['perSqftFee']),
      'per_sqm_fee':
          _toDouble(rawAgent['per_sqm_fee'] ?? rawAgent['perSqmFee']),
    };
  }

  String _buildAgentEarningTypeDisplayReport(Map<String, dynamic> agent) {
    final normalizedAgent = _normalizeReportAgentForCalculations(agent);
    final compensationType =
        (normalizedAgent['compensation_type'] ?? '').toString();
    final earningType = (normalizedAgent['earning_type'] ?? '').toString();
    final percentage = _toDouble(normalizedAgent['percentage']);
    final fixedFee = _toDouble(normalizedAgent['fixed_fee']);
    final monthlyFee = _toDouble(normalizedAgent['monthly_fee']);
    final months = _parseAgentMonthsForReport(normalizedAgent['months']);
    final perSqftFee = _toDouble(normalizedAgent['per_sqft_fee']);

    if (compensationType == 'Percentage Bonus') {
      return _formatAgentPercentageEarningTypeReport(earningType, percentage);
    }
    if (compensationType == 'Fixed Fee') {
      return '₹ ${_formatTo2Decimals(fixedFee)}';
    }
    if (compensationType == 'Monthly Fee') {
      return '₹ ${_formatTo2Decimals(monthlyFee)} * $months';
    }
    if (compensationType == 'Per Sqft Fee' ||
        compensationType == 'Per Sqm Fee' ||
        compensationType == 'Per sqft rate') {
      return '₹ ${_formatTo2Decimals(_displayRateFromSqft(perSqftFee))}';
    }
    return 'NA';
  }

  double _calculateAgentEarningsReport(Map<String, dynamic> agent) {
    final normalizedAgent = _normalizeReportAgentForCalculations(agent);
    final compensationType =
        (normalizedAgent['compensation_type'] ?? '').toString();
    final earningType = (normalizedAgent['earning_type'] ?? '').toString();
    final agentName = (normalizedAgent['name'] ?? '').toString().trim();
    final normalizedAgentName = _normalizeAgentNameKeyForReport(agentName);

    if (compensationType == 'Fixed Fee') {
      return _toDouble(normalizedAgent['fixed_fee']);
    }
    if (compensationType == 'Monthly Fee') {
      final monthlyFee = _toDouble(normalizedAgent['monthly_fee']);
      final months = _parseAgentMonthsForReport(normalizedAgent['months']);
      return monthlyFee * months;
    }
    if (compensationType == 'Per Sqft Fee' ||
        compensationType == 'Per Sqm Fee' ||
        compensationType == 'Per sqft rate') {
      final perSqftFee = _toDouble(normalizedAgent['per_sqft_fee']);
      double totalSoldArea = 0.0;
      final plots = _collectReportPlotsForOverview();
      for (final plot in plots) {
        final status = _normalizeSiteStatusForReport(plot['status']);
        final plotAgent = _plotFieldStr(
          plot,
          ['agent_name', 'agent', 'agentName'],
        );
        final normalizedPlotAgent = _normalizeAgentNameKeyForReport(plotAgent);
        if (status == 'sold' && normalizedPlotAgent == normalizedAgentName) {
          totalSoldArea +=
              _toDouble(plot['area'] ?? plot['plotArea'] ?? plot['plot_area']);
        }
      }
      final feeToUse = _isSqm
          ? AreaUnitUtils.rateFromSqftToDisplay(perSqftFee, true)
          : perSqftFee;
      final areaToUse = _isSqm
          ? AreaUnitUtils.areaFromSqftToDisplay(totalSoldArea, true)
          : totalSoldArea;
      final siteEarnings = feeToUse * areaToUse;
      final amenityEarnings = _calculateAmenityEarningsForAgentReport(agent);
      return siteEarnings + amenityEarnings;
    }
    if (compensationType == 'Percentage Bonus') {
      final percentage = _toDouble(normalizedAgent['percentage']);
      final lowerEarningType = earningType.toLowerCase();
      final isSellingPriceBased = earningType == 'Selling Price Per Plot' ||
          earningType == '% of Selling Price per Plot' ||
          (lowerEarningType.contains('selling price') &&
              lowerEarningType.contains('plot'));
      final isLumpSum = earningType == 'Lump Sum' ||
          earningType == '% of Total Project Profit' ||
          (lowerEarningType.contains('total project profit') ||
              lowerEarningType.contains('lump'));
      final plots = _collectReportPlotsForOverview();
      final allInCost = _computeAllInCostPerSqftForReport();
      final amenityEarnings = _calculateAmenityEarningsForAgentReport(agent);

      if (!isLumpSum && !_agentHasSoldPlotReport(agentName)) {
        return 0.0;
      }

      if (isLumpSum) {
        final totalGrossProfit = _computeOverviewGrossProfitForReport();
        return _calculateTotalProjectProfitBonusReport(
          profitBase: totalGrossProfit,
          percentage: percentage,
        );
      }

      double total = 0.0;
      for (final plot in plots) {
        final status = _normalizeSiteStatusForReport(plot['status']);
        final plotAgent = _plotFieldStr(
          plot,
          ['agent_name', 'agent', 'agentName'],
        );
        final normalizedPlotAgent = _normalizeAgentNameKeyForReport(plotAgent);
        if (status == 'sold' && normalizedPlotAgent == normalizedAgentName) {
          final salePrice = _toDouble(
            plot['sale_price'] ?? plot['salePrice'] ?? plot['salePricePerSqft'],
          );
          final area =
              _toDouble(plot['area'] ?? plot['plotArea'] ?? plot['plot_area']);
          final saleValue = salePrice * area;
          if (isSellingPriceBased) {
            total += (saleValue * percentage) / 100;
          } else {
            final plotCost = area * allInCost;
            final plotProfit = saleValue - plotCost;
            total += (plotProfit * percentage) / 100;
          }
        }
      }
      return total + amenityEarnings;
    }
    return 0.0;
  }

  double? _calculateAgentPlotEarningsReport(
      Map<String, dynamic> plot, Map<String, dynamic>? agent) {
    if (agent == null) return null;
    final normalizedAgent = _normalizeReportAgentForCalculations(agent);
    final status = _normalizeSiteStatusForReport(
      _plotFieldStr(plot, ['status', 'plot_status', 'sale_status']),
    );
    if (status != 'sold') return null;
    final compensationType =
        (normalizedAgent['compensation_type'] ?? '').toString();
    final earningType = (normalizedAgent['earning_type'] ?? '').toString();
    final salePrice = _toDouble(
      plot['sale_price'] ?? plot['salePrice'] ?? plot['salePricePerSqft'],
    );
    final area =
        _toDouble(plot['area'] ?? plot['plotArea'] ?? plot['plot_area']);
    final saleValue = salePrice * area;

    if (compensationType == 'Fixed Fee') {
      return _toDouble(normalizedAgent['fixed_fee']);
    }
    if (compensationType == 'Monthly Fee') {
      final monthlyFee = _toDouble(normalizedAgent['monthly_fee']);
      final months = _parseAgentMonthsForReport(normalizedAgent['months']);
      return monthlyFee * months;
    }

    if (compensationType == 'Per Sqft Fee' ||
        compensationType == 'Per Sqm Fee' ||
        compensationType == 'Per sqft rate') {
      if (compensationType == 'Per Sqm Fee') {
        final perSqmFee = _toDouble(normalizedAgent['per_sqm_fee']);
        if (perSqmFee > 0) {
          final areaSqm = AreaUnitUtils.areaFromSqftToDisplay(area, true);
          return perSqmFee * areaSqm;
        }
      }
      final perSqftFee = _toDouble(normalizedAgent['per_sqft_fee']);
      return perSqftFee * area;
    }
    if (compensationType == 'Percentage Bonus') {
      final percentage = _toDouble(normalizedAgent['percentage']);
      final lowerEarningType = earningType.toLowerCase();
      final isSellingPriceBased = earningType == 'Selling Price Per Plot' ||
          earningType == '% of Selling Price per Plot' ||
          (lowerEarningType.contains('selling price') &&
              lowerEarningType.contains('plot'));
      final isProfitPerPlot = earningType == 'Profit Per Plot' ||
          earningType == 'Per Plot' ||
          earningType == '% of Profit on Each Sold Plot' ||
          (lowerEarningType.contains('profit') &&
              lowerEarningType.contains('plot'));
      final isLumpSum = earningType == 'Lump Sum' ||
          earningType == '% of Total Project Profit' ||
          (lowerEarningType.contains('total project profit') ||
              lowerEarningType.contains('lump'));

      if (isSellingPriceBased) return (saleValue * percentage) / 100;
      if (isLumpSum) {
        final totalGrossProfit = _computeOverviewGrossProfitForReport();
        final totalAgentCompensation = _calculateTotalProjectProfitBonusReport(
          profitBase: totalGrossProfit,
          percentage: percentage,
        );

        final normalizedAgentName =
          _normalizeAgentNameKeyForReport(normalizedAgent['name']);
        if (normalizedAgentName.isEmpty) return 0.0;

        var totalAgentSaleValue = 0.0;
        final allPlots = _collectReportPlotsForOverview();
        for (final candidatePlot in allPlots) {
          final candidateStatus = _normalizeSiteStatusForReport(
            _plotFieldStr(candidatePlot, ['status', 'plot_status', 'sale_status']),
          );
          if (candidateStatus != 'sold') continue;
          final candidateAgent = _plotFieldStr(
            candidatePlot,
            ['agent_name', 'agent', 'agentName'],
          );
          final normalizedCandidateAgent =
              _normalizeAgentNameKeyForReport(candidateAgent);
          if (normalizedCandidateAgent != normalizedAgentName) continue;

          final candidateArea = _toDouble(
            candidatePlot['area'] ??
                candidatePlot['plotArea'] ??
                candidatePlot['plot_area'],
          );
          final candidateSalePrice = _toDouble(
            candidatePlot['sale_price'] ??
                candidatePlot['salePrice'] ??
                candidatePlot['salePricePerSqft'],
          );
          totalAgentSaleValue += candidateArea * candidateSalePrice;
        }

        if (totalAgentSaleValue <= 0) return 0.0;
        return (totalAgentCompensation * saleValue) / totalAgentSaleValue;
      }
      if (!isProfitPerPlot) return 0.0;

      final allInCost = _computeAllInCostPerSqftForReport();
      final plotCost = area * allInCost;
      final plotProfit = saleValue - plotCost;
      return (plotProfit * percentage) / 100;
    }
    return null;
  }

  List<Map<String, dynamic>> _reportAgentsForReport() {
    final fromDashboard =
        _dashboardDataLocal?['agents'] ?? _dashboardDataLocal?['agentDetails'];
    final rawList = (fromDashboard is List && fromDashboard.isNotEmpty)
        ? fromDashboard
        : ((_projectData['agents'] ?? _projectData['agentDetails'])
                as List<dynamic>? ??
            const []);

    return rawList
        .whereType<Map>()
        .map((agent) => _normalizeReportAgentForCalculations(
          Map<String, dynamic>.from(agent),
        ))
        .toList(growable: false);
  }

  double _calculateTotalAgentCompensationReport() {
    double total = 0.0;
    for (final agent in _reportAgentsForReport()) {
      total += _calculateAgentEarningsReport(agent);
    }
    return total;
  }

  double _calculateAgentCompensationForPlotReport(Map<String, dynamic> plot) {
    final plotAgentName = _normalizeAgentNameKeyForReport(
      plot['agent_name'] ?? plot['agent'] ?? plot['agentName'],
    );
    if (plotAgentName.isEmpty) return 0.0;

    for (final agent in _reportAgentsForReport()) {
      final agentName = _normalizeAgentNameKeyForReport(agent['name']);
      if (agentName == plotAgentName) {
        return _calculateAgentPlotEarningsReport(plot, agent) ?? 0.0;
      }
    }
    return 0.0;
  }

  Widget _buildReportPage9({
    required int pageNumber,
    List<Map<String, dynamic>>? layoutBlocksOverride,
    bool showAgentEarningsSection = true,
    bool isContinuation = false,
  }) {
    final projectName =
        _projectData['projectName'] ?? _projectData['name'] ?? 'Project Name';
    final agents = _reportAgentsForReport();
    final agentsWithEarnings = agents
        .map((agent) => {
              'name': (agent['name'] ?? '-').toString(),
              'compensationType':
                  (agent['compensation_type'] ?? '-').toString(),
              'earningType': _buildAgentEarningTypeDisplayReport(agent),
              'earningsValue': _nonNegativeReportEarning(
                _calculateAgentEarningsReport(agent),
              ),
            })
        .toList();
    final totalAgentEarnings = agentsWithEarnings.fold<double>(
      0.0,
      (sum, a) => sum + _nonNegativeReportEarning(a['earningsValue']),
    );

    final agentsByName = <String, Map<String, dynamic>>{};
    for (final agent in agents) {
      final key = _normalizeAgentNameKeyForReport(agent['name']);
      if (key.isNotEmpty) agentsByName[key] = agent;
    }
    final layoutBlocks =
        layoutBlocksOverride ?? _buildReportPage9LayoutBlocks();

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: const Color(0xFF404040),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              isContinuation
                  ? '4. Agent(s) Details (Cont.)'
                  : '4. Agent(s) Details',
              style: GoogleFonts.inriaSerif(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: const Color(0xFF0C8CE9),
              ),
            ),
          ),
          if (showAgentEarningsSection) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '4.1  Agent(s) Earnings',
                style: GoogleFonts.inriaSerif(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: const Color(0xFF404040),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                decoration: BoxDecoration(
                  border:
                      Border.all(color: const Color(0xFF404040), width: 0.5),
                ),
                child: Column(
                  children: [
                    Container(
                      color: const Color(0xFF404040),
                      padding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 136,
                            child: Text(
                              'Agent(s) Name',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 153,
                            child: Text(
                              'Compensation Type',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 156,
                            child: Text(
                              'Earning Type',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 74,
                            child: Text(
                              'Earnings (₹)',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ...agentsWithEarnings.map((agent) => Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 4, horizontal: 4),
                          decoration: const BoxDecoration(
                            border: Border(
                                bottom: BorderSide(
                                    color: Colors.black, width: 0.25)),
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 136,
                                child: Text(
                                  (agent['name'] ?? '-').toString(),
                                  style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040)),
                                ),
                              ),
                              SizedBox(
                                width: 153,
                                child: Text(
                                  (agent['compensationType'] ?? '-').toString(),
                                  style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040)),
                                ),
                              ),
                              SizedBox(
                                width: 156,
                                child: Text(
                                  (agent['earningType'] ?? '-').toString(),
                                  style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040)),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              SizedBox(
                                width: 74,
                                child: Text(
                                  '₹ ${_formatTo2Decimals(agent['earningsValue'])}',
                                  style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040)),
                                ),
                              ),
                            ],
                          ),
                        )),
                    Container(
                      color: const Color(0xFFCFCFCF),
                      padding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 136,
                            child: Text(
                              'Total',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF404040),
                              ),
                            ),
                          ),
                          const SizedBox(width: 153),
                          const SizedBox(width: 156),
                          SizedBox(
                            width: 74,
                            child: Text(
                              '₹ ${_formatTo2Decimals(totalAgentEarnings)}',
                              style: GoogleFonts.inriaSerif(
                                  fontSize: 10, color: const Color(0xFF404040)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '4.2 Agent - Plot Distribution & Earnings',
              style: GoogleFonts.inriaSerif(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          const SizedBox(height: 4),
          if (layoutBlocks.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '1.',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF404040),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Layout:',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF404040),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '-',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          color: const Color(0xFF404040),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: const Color(0xFF404040),
                        width: 0.5,
                      ),
                    ),
                    child: Column(
                      children: [
                        Container(
                          color: const Color(0xFF404040),
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 33,
                                child: Text('Sl. No.',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    )),
                              ),
                              SizedBox(
                                width: 68,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 12),
                                  child: Text('Plot Number',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.visible),
                                ),
                              ),
                              SizedBox(
                                width: 110,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 30),
                                  child: Text('Sale Value (₹)',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      )),
                                ),
                              ),
                              SizedBox(
                                width: 143,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 24),
                                  child: Text('Agent',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      )),
                                ),
                              ),
                              SizedBox(
                                width: 110,
                                child: Text('Earnings (₹)',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    )),
                              ),
                              SizedBox(
                                width: 63,
                                child: Text('Sale Date',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    )),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          color: const Color(0xFFCFCFCF),
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 33,
                                child: Text(
                                  'Total',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.inriaSerif(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF404040),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 68),
                              SizedBox(
                                width: 110,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 30),
                                  child: Text(
                                    '₹ 0.00',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 143),
                              SizedBox(
                                width: 110,
                                child: Text(
                                  '₹ 0.00',
                                  style: GoogleFonts.inriaSerif(
                                    fontSize: 10,
                                    color: const Color(0xFF404040),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 63),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ...layoutBlocks.asMap().entries.map((entry) {
            final idx = entry.key;
            final block = entry.value;
            final layoutIndex = (block['layoutIndex'] as int?) ?? idx;
            final layoutName = (block['layoutName'] ?? 'Unknown').toString();
            final continued = block['continued'] == true;
            final plotStartIndex = (block['plotStartIndex'] as int?) ?? 0;
            final rawPlots = block['plots'] as List<dynamic>? ?? const [];
            final plots = rawPlots
                .map((plot) => plot is Map
                    ? Map<String, dynamic>.from(plot)
                    : <String, dynamic>{})
                .toList(growable: false);
            double layoutTotalSaleValue = 0.0;
            double layoutTotalEarnings = 0.0;

            return Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '${layoutIndex + 1}.',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF404040),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Layout:',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF404040),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        continued ? '$layoutName (Cont.)' : layoutName,
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          color: const Color(0xFF404040),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: const Color(0xFF404040), width: 0.5),
                    ),
                    child: Column(
                      children: [
                        Container(
                          color: const Color(0xFF404040),
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 33,
                                child: Text('Sl. No.',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    )),
                              ),
                              SizedBox(
                                width: 68,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 12),
                                  child: Text('Plot Number',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.visible),
                                ),
                              ),
                              SizedBox(
                                width: 110,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 30),
                                  child: Text('Sale Value (₹)',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      )),
                                ),
                              ),
                              SizedBox(
                                width: 143,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 24),
                                  child: Text('Agent',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      )),
                                ),
                              ),
                              SizedBox(
                                width: 110,
                                child: Text('Earnings (₹)',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    )),
                              ),
                              SizedBox(
                                width: 63,
                                child: Text('Sale Date',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    )),
                              ),
                            ],
                          ),
                        ),
                        ...plots.asMap().entries.map((plotEntry) {
                          final rowIndex = plotEntry.key;
                          final plot = plotEntry.value;
                          final status = _normalizeSiteStatusForReport(
                            _plotFieldStr(
                              plot,
                              ['status', 'plot_status', 'sale_status'],
                            ),
                          );
                          final plotNumber = _plotFieldStr(plot, [
                            'plotNumber',
                            'plot_no',
                            'plotNo',
                            'number',
                            'plot_number'
                          ]);
                          final area = _toDouble(
                            plot['area'] ?? plot['plotArea'] ?? plot['plot_area'],
                          );
                          final salePrice = _toDouble(
                            plot['sale_price'] ??
                                plot['salePrice'] ??
                                plot['salePricePerSqft'] ??
                                plot['sale_price_per_sqft'],
                          );
                          final saleValue =
                              status == 'sold' ? area * salePrice : 0.0;
                          final plotAgentName = _plotFieldStr(
                              plot, ['agent_name', 'agent', 'agentName']);
                            final normalizedAgent =
                              _normalizeAgentNameKeyForReport(plotAgentName);
                          final matchedAgent = agentsByName[normalizedAgent];
                          final canonicalAgentName =
                              (matchedAgent?['name'] ?? '').toString().trim();
                          final displayAgentName = status == 'sold'
                              ? (canonicalAgentName.isNotEmpty
                                  ? canonicalAgentName
                                  : (plotAgentName == '-'
                                      ? 'Direct Sale'
                                      : plotAgentName))
                              : '-';
                          final rowEarnings = _calculateAgentPlotEarningsReport(
                              plot, matchedAgent);
                          final saleDate = _saleDateLabelForReport(plot);
                          if (status == 'sold')
                            layoutTotalSaleValue += saleValue;
                          if (rowEarnings != null)
                            layoutTotalEarnings += rowEarnings;

                          return Container(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            decoration: const BoxDecoration(
                              border: Border(
                                  bottom: BorderSide(
                                      color: Colors.black, width: 0.25)),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 33,
                                  child: Text(
                                    '${plotStartIndex + rowIndex + 1}',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        color: const Color(0xFF404040)),
                                  ),
                                ),
                                SizedBox(
                                  width: 68,
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 12),
                                    child: Text(
                                      plotNumber == '-'
                                          ? 'XX - ${rowIndex + 1}'
                                          : plotNumber,
                                      style: GoogleFonts.inriaSerif(
                                          fontSize: 10,
                                          color: const Color(0xFF404040)),
                                      maxLines: 1,
                                      softWrap: false,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 110,
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 30),
                                    child: Text(
                                      status == 'sold'
                                          ? '₹ ${_formatTo2Decimals(saleValue)}'
                                          : '₹ -',
                                      style: GoogleFonts.inriaSerif(
                                          fontSize: 10,
                                          color: const Color(0xFF404040)),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 143,
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 24),
                                    child: Text(
                                      displayAgentName,
                                      style: GoogleFonts.inriaSerif(
                                          fontSize: 10,
                                          color: const Color(0xFF404040)),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 110,
                                  child: Text(
                                    rowEarnings == null
                                        ? '₹ -'
                                        : '₹ ${_formatTo2Decimals(rowEarnings)}',
                                    style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        color: const Color(0xFF404040)),
                                  ),
                                ),
                                SizedBox(
                                  width: 63,
                                  child: Text(
                                    saleDate,
                                    style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        color: const Color(0xFF404040)),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                        Container(
                          color: const Color(0xFFCFCFCF),
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 33,
                                child: Text(
                                  'Total',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.inriaSerif(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFF404040),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 68),
                              SizedBox(
                                width: 110,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 30),
                                  child: Text(
                                    '₹ ${_formatTo2Decimals(layoutTotalSaleValue)}',
                                    style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        color: const Color(0xFF404040)),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 143),
                              SizedBox(
                                width: 110,
                                child: Text(
                                  '₹ ${_formatTo2Decimals(layoutTotalEarnings)}',
                                  style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040)),
                                ),
                              ),
                              const SizedBox(width: 63),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
          const Spacer(),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  List<String> get _expenseCategoryOrderReport => const [
        'Land Purchase Cost',
        'Statutory & Registration',
        'Legal & Professional Fees',
        'Survey, Approvals & Conversion',
        'Construction & Development',
        'Amenities & Infrastructure',
        'Others',
      ];

  String _normalizeExpenseCategoryReport(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll('&', 'and')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _canonicalExpenseCategoryReport(dynamic rawCategory) {
    final raw = (rawCategory ?? '').toString().trim();
    if (raw.isEmpty) return '';
    final normalized = _normalizeExpenseCategoryReport(raw);
    for (final category in _expenseCategoryOrderReport) {
      if (_normalizeExpenseCategoryReport(category) == normalized)
        return category;
    }
    if (normalized.contains('land') && normalized.contains('purchase'))
      return 'Land Purchase Cost';
    if (normalized.contains('statutory') || normalized.contains('registration'))
      return 'Statutory & Registration';
    if (normalized.contains('legal') || normalized.contains('professional'))
      return 'Legal & Professional Fees';
    if (normalized.contains('survey') ||
        normalized.contains('approval') ||
        normalized.contains('conversion')) {
      return 'Survey, Approvals & Conversion';
    }
    if (normalized.contains('construction') ||
        normalized.contains('development')) {
      return 'Construction & Development';
    }
    if (normalized.contains('amenities') ||
        normalized.contains('infrastructure')) {
      return 'Amenities & Infrastructure';
    }
    if (normalized.contains('other')) return 'Others';
    return raw;
  }

  Map<String, List<Map<String, dynamic>>> _groupExpensesByCategoryReport() {
    final rawExpenses = _projectData['expenses'] as List<dynamic>? ?? [];
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final raw in rawExpenses) {
      if (raw is! Map) continue;
      final expense = Map<String, dynamic>.from(raw);
      final category = _canonicalExpenseCategoryReport(expense['category']);
      final item = (expense['item'] ?? '').toString().trim();
      if (category.isEmpty || item.isEmpty) continue;
      final amount =
          double.tryParse((expense['amount'] ?? '0').toString()) ?? 0.0;
      grouped.putIfAbsent(category, () => <Map<String, dynamic>>[]);
      grouped[category]!.add({
        'item': item,
        'amount': amount,
      });
    }

    final ordered = <String, List<Map<String, dynamic>>>{};
    for (final category in _expenseCategoryOrderReport) {
      final items = grouped[category];
      if (items != null && items.isNotEmpty) {
        ordered[category] = items;
      }
    }
    grouped.forEach((category, items) {
      if (!ordered.containsKey(category) && items.isNotEmpty) {
        ordered[category] = items;
      }
    });
    return ordered;
  }

  double _expenseCategoryTotalReport(List<Map<String, dynamic>> items) {
    return items.fold<double>(
      0.0,
      (sum, item) => sum + ((item['amount'] as num?)?.toDouble() ?? 0.0),
    );
  }

  Widget _buildExpenseTwoColumnTableReport({
    required String leftHeader,
    required String rightHeader,
    required List<Map<String, dynamic>> rows,
  }) {
    final total = _expenseCategoryTotalReport(rows);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF404040), width: 0.5),
      ),
      child: Column(
        children: [
          Container(
            color: const Color(0xFF404040),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    leftHeader,
                    style: GoogleFonts.inriaSerif(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: Text(
                    rightHeader,
                    style: GoogleFonts.inriaSerif(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ...rows.map((row) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                decoration: const BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: Colors.black, width: 0.25)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        (row['item'] ?? '-').toString(),
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          color: const Color(0xFF404040),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 160,
                      child: Text(
                        '₹ ${_formatTo2Decimals(row['amount'])}',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          color: const Color(0xFF404040),
                        ),
                      ),
                    ),
                  ],
                ),
              )),
          Container(
            color: const Color(0xFFCFCFCF),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Total',
                    style: GoogleFonts.inriaSerif(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF404040),
                    ),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: Text(
                    '₹ ${_formatTo2Decimals(total)}',
                    style: GoogleFonts.inriaSerif(
                      fontSize: 10,
                      color: const Color(0xFF404040),
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

  Widget _buildReportPage10() {
    final expenseSectionNumber = _expenseSectionNumberForReport();
    final projectName =
        _projectData['projectName'] ?? _projectData['name'] ?? 'Project Name';
    final grouped = _groupExpensesByCategoryReport();
    final summaryEntries = grouped.entries.toList();
    final firstFiveCategories = _expenseCategoryOrderReport.take(5).toList();
    final lastTwoCategories = _expenseCategoryOrderReport.skip(5).toSet();
    final page10BreakdownCategories = <String>[
      for (final c in firstFiveCategories)
        if (grouped.containsKey(c) && grouped[c]!.isNotEmpty) c,
      for (final c in grouped.keys)
        if (!firstFiveCategories.contains(c) && !lastTwoCategories.contains(c))
          c,
    ];
    final hasSummary = summaryEntries.isNotEmpty;
    final hasBreakdown = page10BreakdownCategories.isNotEmpty;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: const Color(0xFF404040), width: 0.5),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '$expenseSectionNumber. Expense Details',
              style: GoogleFonts.inriaSerif(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: const Color(0xFF0C8CE9),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (hasSummary) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '$expenseSectionNumber.1  Expense Categories Summary',
                        style: GoogleFonts.inriaSerif(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: const Color(0xFF404040),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: const Color(0xFF404040), width: 0.5),
                        ),
                        child: Column(
                          children: [
                            Container(
                              color: const Color(0xFF404040),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Expense Category',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 160,
                                    child: Text(
                                      'Value (₹)',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            ...summaryEntries.map((entry) => Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 4),
                                  decoration: const BoxDecoration(
                                    border: Border(
                                        bottom: BorderSide(
                                            color: Colors.black, width: 0.25)),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          entry.key,
                                          style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            color: const Color(0xFF404040),
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 160,
                                        child: Text(
                                          '₹ ${_formatTo2Decimals(_expenseCategoryTotalReport(entry.value))}',
                                          style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            color: const Color(0xFF404040),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                )),
                            Container(
                              color: const Color(0xFFCFCFCF),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Total',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: const Color(0xFF404040),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 160,
                                    child: Text(
                                      '₹ ${_formatTo2Decimals(summaryEntries.fold<double>(0.0, (sum, e) => sum + _expenseCategoryTotalReport(e.value)))}',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        color: const Color(0xFF404040),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (hasBreakdown) ...[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '$expenseSectionNumber.2  Expense Breakdown',
                        style: GoogleFonts.inriaSerif(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: const Color(0xFF404040),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...page10BreakdownCategories.map((category) => Padding(
                          padding: const EdgeInsets.only(
                              left: 16, right: 16, bottom: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '•  $category',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF404040),
                                ),
                              ),
                              const SizedBox(height: 2),
                              _buildExpenseTwoColumnTableReport(
                                leftHeader: 'Expense Item',
                                rightHeader: 'Value (₹)',
                                rows: grouped[category]!,
                              ),
                            ],
                          ),
                        )),
                  ],
                ],
              ),
            ),
          ),
          _buildStandardReportFooter(8),
        ],
      ),
    );
  }

  Widget _buildReportPage11() {
    final projectName =
        _projectData['projectName'] ?? _projectData['name'] ?? 'Project Name';
    final grouped = _groupExpensesByCategoryReport();
    final page11Categories = <String>[
      for (final c in _expenseCategoryOrderReport.skip(5))
        if (grouped.containsKey(c) && grouped[c]!.isNotEmpty) c,
    ];

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: const Color(0xFF404040), width: 0.5),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...page11Categories.map((category) => Padding(
                        padding: const EdgeInsets.only(
                            left: 16, right: 16, bottom: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '•  $category',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF404040),
                              ),
                            ),
                            const SizedBox(height: 2),
                            _buildExpenseTwoColumnTableReport(
                              leftHeader: 'Expense Item',
                              rightHeader: 'Value (₹)',
                              rows: grouped[category]!,
                            ),
                          ],
                        ),
                      )),
                ],
              ),
            ),
          ),
          _buildStandardReportFooter(9),
        ],
      ),
    );
  }

  double _estimateExpenseBreakdownBlockHeightReport(
    int rowCount, {
    required bool showBullet,
  }) {
    // Block = optional bullet label + two-column table + outer bottom gap.
    // Keep this close to rendered sizes so page breaks happen only when needed.
    const baseTableHeight = 42.0; // header + total + borders/chrome
    const rowHeight = 20.0;
    const blockBottomGap = 6.0;
    final bulletHeight = showBullet ? 18.0 : 0.0;
    return bulletHeight +
        baseTableHeight +
        (rowCount * rowHeight) +
        blockBottomGap;
  }

  List<Map<String, dynamic>> _buildExpenseBreakdownBlocksReport(
    Map<String, List<Map<String, dynamic>>> grouped,
  ) {
    final blocks = <Map<String, dynamic>>[];
    for (final category in grouped.keys) {
      final rows = grouped[category] ?? const <Map<String, dynamic>>[];
      if (rows.isEmpty) continue;
      // Keep each category table as one block by default.
      blocks.add({
        'category': category,
        'rows': rows,
        'showBullet': true,
      });
    }
    return blocks;
  }

  Widget _buildExpenseDetailsPageReport({
    required String projectName,
    required int pageNumber,
    required bool showMainTitle,
    required bool showSummary,
    required List<MapEntry<String, List<Map<String, dynamic>>>> summaryEntries,
    required List<Map<String, dynamic>> blocks,
  }) {
    final expenseSectionNumber = _expenseSectionNumberForReport();
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: const Color(0xFF404040), width: 0.5),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (showMainTitle)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '$expenseSectionNumber. Expense Details',
                style: GoogleFonts.inriaSerif(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: const Color(0xFF0C8CE9),
                ),
              ),
            ),
          if (showMainTitle) const SizedBox(height: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showSummary && summaryEntries.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '$expenseSectionNumber.1  Expense Categories Summary',
                      style: GoogleFonts.inriaSerif(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: const Color(0xFF404040),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: const Color(0xFF404040), width: 0.5),
                      ),
                      child: Column(
                        children: [
                          Container(
                            color: const Color(0xFF404040),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Expense Category',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 160,
                                  child: Text(
                                    'Value (₹)',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ...summaryEntries.map((entry) => Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 4),
                                decoration: const BoxDecoration(
                                  border: Border(
                                      bottom: BorderSide(
                                          color: Colors.black, width: 0.25)),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        entry.key,
                                        style: GoogleFonts.inriaSerif(
                                          fontSize: 10,
                                          color: const Color(0xFF404040),
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 160,
                                      child: Text(
                                        '₹ ${_formatTo2Decimals(_expenseCategoryTotalReport(entry.value))}',
                                        style: GoogleFonts.inriaSerif(
                                          fontSize: 10,
                                          color: const Color(0xFF404040),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              )),
                          Container(
                            color: const Color(0xFFCFCFCF),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Total',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 160,
                                  child: Text(
                                    '₹ ${_formatTo2Decimals(summaryEntries.fold<double>(0.0, (sum, e) => sum + _expenseCategoryTotalReport(e.value)))}',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (blocks.isNotEmpty) const SizedBox(height: 10),
                ],
                if (blocks.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      '$expenseSectionNumber.2  Expense Breakdown',
                      style: GoogleFonts.inriaSerif(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: const Color(0xFF404040),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...blocks.map((block) {
                    final category = block['category'] as String;
                    final rows = block['rows'] as List<Map<String, dynamic>>;
                    final showBullet = block['showBullet'] as bool? ?? true;
                    return Padding(
                      padding:
                          const EdgeInsets.only(left: 16, right: 16, bottom: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showBullet)
                            Text(
                              '•  $category',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF404040),
                              ),
                            ),
                          if (showBullet) const SizedBox(height: 2),
                          _buildExpenseTwoColumnTableReport(
                            leftHeader: 'Expense Item',
                            rightHeader: 'Value (₹)',
                            rows: rows,
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  List<Widget> _buildExpenseDetailsPages({required int startPageNumber}) {
    final grouped = _groupExpensesByCategoryReport();
    if (grouped.isEmpty) return const <Widget>[];

    final summaryEntries = grouped.entries.toList();
    final breakdownBlocks = _buildExpenseBreakdownBlocksReport(grouped);

    const firstPageCapacity = 420.0;
    const nextPageCapacity = 640.0;
    final pagesBlocks = <List<Map<String, dynamic>>>[];
    var current = <Map<String, dynamic>>[];
    var remaining = firstPageCapacity;

    for (final block in breakdownBlocks) {
      final category = (block['category'] ?? '').toString();
      final rows = (block['rows'] as List<Map<String, dynamic>>?) ??
          const <Map<String, dynamic>>[];
      if (rows.isEmpty) continue;

      int rowStart = 0;
      bool isFirstChunkForCategory = true;

      while (rowStart < rows.length) {
        final rowsRemaining = rows.length - rowStart;
        final fullChunkCost = _estimateExpenseBreakdownBlockHeightReport(
          rowsRemaining,
          showBullet: isFirstChunkForCategory,
        );

        // Rule: if the whole table chunk can't fit in current page and there
        // is already content, move it to next page instead of splitting here.
        if (current.isNotEmpty && fullChunkCost > remaining) {
          pagesBlocks.add(current);
          current = <Map<String, dynamic>>[];
          remaining = nextPageCapacity;
          continue;
        }

        // Whole remaining chunk fits: place it and move to next category.
        if (fullChunkCost <= remaining) {
          current.add({
            'category': category,
            'rows': rows.sublist(rowStart, rows.length),
            'showBullet': isFirstChunkForCategory,
          });
          remaining -= fullChunkCost;
          rowStart = rows.length;
          break;
        }

        // At this point, page is empty but the full table still cannot fit.
        // Split only as a fallback for very large single-category tables.
        int rowsToTake = rowsRemaining;
        while (rowsToTake > 1 &&
            _estimateExpenseBreakdownBlockHeightReport(
                  rowsToTake,
                  showBullet: isFirstChunkForCategory,
                ) >
                remaining) {
          rowsToTake--;
        }
        rowsToTake = math.max(1, rowsToTake);
        final chunkEnd = rowStart + rowsToTake;

        current.add({
          'category': category,
          'rows': rows.sublist(rowStart, chunkEnd),
          'showBullet': isFirstChunkForCategory,
        });
        remaining -= _estimateExpenseBreakdownBlockHeightReport(
          rowsToTake,
          showBullet: isFirstChunkForCategory,
        );
        rowStart = chunkEnd;
        isFirstChunkForCategory = false;

        if (rowStart < rows.length) {
          pagesBlocks.add(current);
          current = <Map<String, dynamic>>[];
          remaining = nextPageCapacity;
        }
      }
    }
    if (current.isNotEmpty) {
      pagesBlocks.add(current);
    }
    if (pagesBlocks.isEmpty) {
      pagesBlocks.add(<Map<String, dynamic>>[]);
    }

    final projectName =
        _projectData['projectName'] ?? _projectData['name'] ?? 'Project Name';
    final result = <Widget>[];
    for (int i = 0; i < pagesBlocks.length; i++) {
      final pageWidget = _buildExpenseDetailsPageReport(
        projectName: projectName,
        pageNumber: startPageNumber + i,
        showMainTitle: i == 0,
        showSummary: i == 0,
        summaryEntries: i == 0
            ? summaryEntries
            : const <MapEntry<String, List<Map<String, dynamic>>>>[],
        blocks: pagesBlocks[i],
      );
      result.add(pageWidget);
    }
    return result;
  }

  int _expenseSectionNumberForReport() {
    if (_collectAmenityAreasForReport().isNotEmpty) return 9;
    return _hasPendingPlotsForReport() ? 8 : 7;
  }

  int _formulasSectionNumberForReport() {
    return _expenseSectionNumberForReport() + 1;
  }

  Widget _buildFormulaFractionReport(String top, String bottom,
      {double width = 102}) {
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            top,
            style: GoogleFonts.inriaSerif(
              fontSize: 10,
              color: const Color(0xFF404040),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Container(
            height: 0.5,
            color: const Color(0xFF404040),
          ),
          const SizedBox(height: 2),
          Text(
            bottom,
            style: GoogleFonts.inriaSerif(
              fontSize: 10,
              color: const Color(0xFF404040),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildFormulaSectionHeaderReport(String title) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFCFCFCF),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        title,
        style: GoogleFonts.inriaSerif(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: const Color(0xFF404040),
        ),
      ),
    );
  }

  Widget _buildReportPageFormulas({required int pageNumber}) {
    final formulasSectionNumber = _formulasSectionNumberForReport();
    final projectName =
        _projectData['projectName'] ?? _projectData['name'] ?? 'Project Name';
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: const Color(0xFF404040), width: 0.5),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '$formulasSectionNumber. Formulas',
              style: GoogleFonts.inriaSerif(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: const Color(0xFF0C8CE9),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildFormulaSectionHeaderReport('A'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('i)',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    Text('All-in Cost (₹ / $_areaUnitSuffix)',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    Text('=',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    _buildFormulaFractionReport(
                      'Total Expenses',
                      'Saleable Plot area',
                      width: 124,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('ii)',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    Text('Average Sales Price (₹ / $_areaUnitSuffix)',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    Text('=',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    _buildFormulaFractionReport(
                        'Total Sales Price', 'No. of Plot Sold'),
                  ],
                ),
                const SizedBox(height: 14),
                _buildFormulaSectionHeaderReport('G'),
                const SizedBox(height: 10),
                Text(
                  'iii) Gross Profit  =  Total Sales Value  -  Total Expenses',
                  style: GoogleFonts.inriaSerif(
                      fontSize: 10, color: const Color(0xFF404040)),
                ),
                const SizedBox(height: 14),
                _buildFormulaSectionHeaderReport('N'),
                const SizedBox(height: 10),
                Text(
                  'iv) Net Profit  =  Total Sales Value  -  Total Expenses  -  Total Compensation',
                  style: GoogleFonts.inriaSerif(
                      fontSize: 10, color: const Color(0xFF404040)),
                ),
                const SizedBox(height: 14),
                _buildFormulaSectionHeaderReport('P'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('v)',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    Text('Profit Margin (%)',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    Text('=',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    _buildFormulaFractionReport('Net Profit', 'Total Revenue'),
                    const SizedBox(width: 10),
                    Text('X 100',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                  ],
                ),
                const SizedBox(height: 14),
                _buildFormulaSectionHeaderReport('R'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('vi)',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    Text('ROI (%)',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    Text('=',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                    const SizedBox(width: 6),
                    _buildFormulaFractionReport('Net Profit', 'Total Expenses'),
                    const SizedBox(width: 10),
                    Text('X 100',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040))),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  Widget _buildCompensationDiagramOneFigma() {
    const borderSide = BorderSide(color: Color(0xFFCFCFCF), width: 0.25);
    final labelStyle = GoogleFonts.inriaSerif(
      fontSize: 10,
      fontWeight: FontWeight.w300,
      color: const Color(0xFF404040),
      height: 1.1,
    );

    Widget column({
      required Widget child,
      bool hasRightBorder = true,
    }) {
      return Expanded(
        child: Container(
          decoration: BoxDecoration(
            border: hasRightBorder ? const Border(right: borderSide) : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: child,
        ),
      );
    }

    return Container(
      width: 485,
      height: 226,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFCFCFCF), width: 0.25),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7.75),
        child: Stack(
          children: [
            Positioned.fill(
              child: Row(
                children: [
                  column(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 24,
                          height: 176,
                          color: const Color(0xFF0C8CE9),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          height: 24,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Total Sale Value /\nPer Plot Sale Prize',
                              style: labelStyle,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  column(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          width: 24,
                          height: 88,
                          color: const Color(0xFFFB7D7D),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 24,
                          width: double.infinity,
                          child: Align(
                            alignment: Alignment.center,
                            child: Text(
                              'Expenses',
                              style: labelStyle,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  column(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          width: 24,
                          height: 88,
                          color: const Color(0xFF7CD7EC),
                        ),
                        SizedBox(
                          height: 24,
                          width: double.infinity,
                          child: Align(
                            alignment: Alignment.center,
                            child: Text(
                              'Gross Profit',
                              style: labelStyle,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  column(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        SizedBox(
                          height: 88,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: 24,
                              height: 53,
                              color: const Color(0xFFE1A157),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 24,
                          width: double.infinity,
                          child: Align(
                            alignment: Alignment.center,
                            child: Text(
                              'Compensation',
                              style: labelStyle,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  column(
                    hasRightBorder: false,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          width: 24,
                          height: 35,
                          color: const Color(0xFF76CF68),
                        ),
                        SizedBox(
                          height: 24,
                          width: double.infinity,
                          child: Align(
                            alignment: Alignment.center,
                            child: Text(
                              'Net Profit',
                              style: labelStyle,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const barWidth = 24.0;
                  final colWidth = constraints.maxWidth / 5;
                  final lineStart = (colWidth - barWidth) / 2;
                  final lineEndComp = (3 * colWidth) + lineStart + barWidth;
                  final lineEndNet = (4 * colWidth) + lineStart + barWidth;

                  Widget line(double top, double rightEdge) {
                    return Positioned(
                      left: lineStart,
                      top: top,
                      width: rightEdge - lineStart,
                      child: Container(
                        height: 0.5,
                        color: const Color(0xFF404040),
                      ),
                    );
                  }

                  return Stack(
                    children: [
                      line(0.25, lineEndNet),
                      line(35.25, lineEndNet),
                      line(88.25, lineEndComp),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompensationDiagramTwoFigma() {
    const borderSide = BorderSide(color: Color(0xFFCFCFCF), width: 0.25);
    final labelStyle = GoogleFonts.inriaSerif(
      fontSize: 10,
      fontWeight: FontWeight.w300,
      color: const Color(0xFF404040),
      height: 1.1,
    );

    Widget section({
      required int flex,
      required Widget child,
      double horizontalPadding = 4,
      bool hasRightBorder = true,
    }) {
      return Expanded(
        flex: flex,
        child: Container(
          height: 124,
          decoration: BoxDecoration(
            border: hasRightBorder ? const Border(right: borderSide) : null,
          ),
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: child,
        ),
      );
    }

    return Container(
      width: 449,
      height: 140,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFCFCFCF), width: 0.25),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7.75),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  section(
                    flex: 83,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 24,
                          height: 88,
                          color: const Color(0xFF7CD7EC),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            'Gross Profit',
                            style: labelStyle,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                  section(
                    flex: 98,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        const SizedBox(height: 65),
                        Container(
                          width: 24,
                          height: 25,
                          color: const Color(0xFF7D7FFB),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            'Agent’s Commision',
                            style: labelStyle,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                  section(
                    flex: 81,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                          width: 24,
                          height: 65,
                          color: const Color(0xFF7CD7EC),
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            'Remaining\nGross Profit',
                            style: labelStyle,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                  section(
                    flex: 105,
                    horizontalPadding: 2,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        SizedBox(
                          height: 65,
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: 24,
                              height: 36,
                              color: const Color(0xFFCA7CEC),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            'Project Managers\nCompensation',
                            style: labelStyle,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  section(
                    flex: 82,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        const SizedBox(height: 29),
                        Container(
                          width: 24,
                          height: 61,
                          color: const Color(0xFFE1A157),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: Text(
                            'Compensation',
                            style: labelStyle,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 30.75,
            top: 36.75,
            width: 388,
            child: Container(height: 0.5, color: const Color(0xFF404040)),
          ),
          Positioned(
            left: 30.75,
            top: 72.75,
            width: 388,
            child: Container(height: 0.5, color: const Color(0xFF404040)),
          ),
        ],
      ),
    );
  }

  Widget _buildReportPageCompensationBonusCalculations(
      {required int pageNumber}) {
    final rawProjectName =
        _projectData['projectName'] ?? _projectData['name'] ?? '';
    final projectName = rawProjectName.toString().trim().isEmpty
        ? '*Project Name*'
        : rawProjectName.toString();

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: const Color(0xFF404040).withOpacity(0.9),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  projectName,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '8. Calculations of Agent and Project managers compensation in Percentage Bonus',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0C8CE9),
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '8.1  (%) of Profit on Each Sold Plot',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF404040),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '8.2  (%) of Total Project Profit',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF404040),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '* Sections 8.1 and 8.2 use the same profit calculation and compensation structure given in following i) & ii) *',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                    color: const Color(0xFF404040),
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'i) Project Profit Calculation',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF404040),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Net profit is calculated after deducting expenses and compensation.',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                    color: Colors.black,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                _buildCompensationDiagramOneFigma(),
                const SizedBox(height: 14),
                Text(
                  'ii) Profit Distribution & Compensation',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF404040),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Agent commission is deducted first from gross profit.\nProject manager compensation is calculated from the remaining profit.',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                    color: Colors.black,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                _buildCompensationDiagramTwoFigma(),
              ],
            ),
          ),
          const Spacer(),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  Widget _buildSellingPriceBonusDiagramCaseA() {
    final labelStyle = GoogleFonts.inriaSerif(
      fontSize: 10,
      fontWeight: FontWeight.w300,
      color: const Color(0xFF404040),
      height: 1.1,
    );

    return Container(
      width: double.infinity,
      height: 226,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFCFCFCF), width: 0.25),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const barWidth = 24.0;
          final colWidth = constraints.maxWidth / 6;
          final labelTop = constraints.maxHeight - 30;

          double barLeft(int col) =>
              (col * colWidth) + ((colWidth - barWidth) / 2);
          double barEnd(int col) => barLeft(col) + barWidth;

          Widget label(int col, String text) {
            return Positioned(
              left: col * colWidth,
              top: labelTop,
              width: colWidth,
              child: Text(
                text,
                style: labelStyle,
                textAlign: TextAlign.center,
                maxLines: 2,
              ),
            );
          }

          Widget line(double top, double endX) {
            final startX = barLeft(0);
            return Positioned(
              left: startX,
              top: top,
              width: endX - startX,
              child: Container(height: 0.5, color: const Color(0xFF404040)),
            );
          }

          return Stack(
            children: [
              for (int i = 1; i < 6; i++)
                Positioned(
                  left: i * colWidth,
                  top: 8,
                  bottom: 12,
                  child: Container(
                    width: 0.25,
                    color: const Color(0xFFCFCFCF),
                  ),
                ),
              line(43, barEnd(5)),
              line(96, barEnd(2)),
              line(131, barEnd(1)),
              line(166, barEnd(4)),
              Positioned(
                left: barLeft(0),
                top: 8,
                child: Container(
                  width: barWidth,
                  height: 158,
                  color: const Color(0xFF0C8CE9),
                ),
              ),
              Positioned(
                left: barLeft(1),
                top: 131,
                child: Container(
                  width: barWidth,
                  height: 35,
                  color: const Color(0xFFFB7D7D),
                ),
              ),
              Positioned(
                left: barLeft(2),
                top: 43,
                child: Container(
                  width: barWidth,
                  height: 53,
                  color: const Color(0xFF7CD7EC),
                ),
              ),
              Positioned(
                left: barLeft(3),
                top: 131,
                child: Container(
                  width: barWidth,
                  height: 35,
                  color: const Color(0xFFE1A157),
                ),
              ),
              Positioned(
                left: barLeft(4),
                top: 43,
                child: Container(
                  width: barWidth,
                  height: 88,
                  color: const Color(0xFFFB7D7D),
                ),
              ),
              Positioned(
                left: barLeft(4),
                top: 131,
                child: Container(
                  width: barWidth,
                  height: 35,
                  color: const Color(0xFFE1A157),
                ),
              ),
              Positioned(
                left: barLeft(5),
                top: 8,
                child: Container(
                  width: barWidth,
                  height: 35,
                  color: const Color(0xFF76CF68),
                ),
              ),
              label(0, 'Sale Value'),
              label(1, 'Expenses'),
              label(2, 'Gross Profit'),
              label(3, 'Compensation'),
              label(4, 'Expenses +\nCompensation'),
              label(5, 'Net Profit'),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSellingPriceBonusDiagramCaseB() {
    final labelStyle = GoogleFonts.inriaSerif(
      fontSize: 10,
      fontWeight: FontWeight.w300,
      color: const Color(0xFF404040),
      height: 1.1,
    );

    return Container(
      width: 340,
      height: 272,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFCFCFCF), width: 0.25),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const barWidth = 24.0;
          final colWidth = constraints.maxWidth / 4;
          final labelTop = constraints.maxHeight - 34;

          double barLeft(int col) =>
              (col * colWidth) + ((colWidth - barWidth) / 2);
          double barEnd(int col) => barLeft(col) + barWidth;

          Widget label(int col, String text) {
            return Positioned(
              left: col * colWidth,
              top: labelTop,
              width: colWidth,
              child: Text(
                text,
                style: labelStyle,
                textAlign: TextAlign.center,
                maxLines: 2,
              ),
            );
          }

          Widget line(double top, double startX, double endX) {
            return Positioned(
              left: startX,
              top: top,
              width: endX - startX,
              child: Container(height: 0.5, color: const Color(0xFF404040)),
            );
          }

          return Stack(
            children: [
              for (int i = 1; i < 4; i++)
                Positioned(
                  left: i * colWidth,
                  top: 8,
                  bottom: 10,
                  child: Container(
                    width: 0.25,
                    color: const Color(0xFFCFCFCF),
                  ),
                ),
              Positioned(
                left: 12,
                top: 138,
                width: constraints.maxWidth - 24,
                height: 92,
                child: Container(color: const Color(0xFFE8D3D3)),
              ),
              line(43, barLeft(0), barEnd(1)),
              line(86, barLeft(1), barEnd(2)),
              line(138, barLeft(0), barEnd(3)),
              Positioned(
                left: barLeft(0),
                top: 8,
                child: Container(
                  width: barWidth,
                  height: 130,
                  color: const Color(0xFFECC873),
                ),
              ),
              Positioned(
                left: barLeft(1),
                top: 43,
                child: Container(
                  width: barWidth,
                  height: 95,
                  color: const Color(0xFF0C8CE9),
                ),
              ),
              Positioned(
                left: barLeft(2),
                top: 86,
                child: Container(
                  width: barWidth,
                  height: 52,
                  color: const Color(0xFFE1A157),
                ),
              ),
              Positioned(
                left: barLeft(3),
                top: 138,
                child: Container(
                  width: barWidth,
                  height: 87,
                  color: const Color(0xFF7CD7EC),
                ),
              ),
              Positioned(
                left: 12,
                top: 172,
                width: constraints.maxWidth - 24,
                child: Center(
                  child: Text(
                    'Loss',
                    style: GoogleFonts.inriaSerif(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF404040),
                    ),
                  ),
                ),
              ),
              label(0, 'Purchase Prize'),
              label(1, 'Sale Value'),
              label(2, 'Compensation'),
              label(3, 'Gross Profit\n(Loss)'),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSellingPriceBonusDiagramCaseC() {
    final labelStyle = GoogleFonts.inriaSerif(
      fontSize: 10,
      fontWeight: FontWeight.w300,
      color: const Color(0xFF404040),
      height: 1.1,
    );

    const baseWidth = 436.0;
    const baseHeight = 348.0;

    return SizedBox(
      width: baseWidth,
      height: baseHeight,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFCFCFCF), width: 0.25),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scaleX = constraints.maxWidth / baseWidth;
            final scaleY = constraints.maxHeight / baseHeight;

            double sx(double value) => value * scaleX;
            double sy(double value) => value * scaleY;

            Widget verticalLine(double x) {
              return Positioned(
                left: sx(x),
                top: sy(8),
                bottom: sy(8),
                child: Container(
                  width: 0.25,
                  color: const Color(0xFFCFCFCF),
                ),
              );
            }

            Widget horizontalLine(double y, double startX, double endX) {
              return Positioned(
                left: sx(startX),
                top: sy(y),
                width: sx(endX - startX),
                child: Container(
                  height: 0.5,
                  color: const Color(0xFF404040),
                ),
              );
            }

            Widget bar({
              required double left,
              required double top,
              required double width,
              required double height,
              required Color color,
            }) {
              return Positioned(
                left: sx(left),
                top: sy(top),
                width: sx(width),
                height: sy(height),
                child: ColoredBox(color: color),
              );
            }

            Widget label({
              required double left,
              required double width,
              required String text,
            }) {
              return Positioned(
                left: sx(left),
                top: sy(314),
                width: sx(width),
                child: Text(
                  text,
                  style: labelStyle,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                ),
              );
            }

            return Stack(
              children: [
                verticalLine(97),
                verticalLine(177),
                verticalLine(257),
                verticalLine(337),
                Positioned(
                  left: sx(12),
                  top: sy(138),
                  width: sx(376),
                  height: sy(172),
                  child: const ColoredBox(color: Color(0x17FF0000)),
                ),
                horizontalLine(43, 36, 141),
                horizontalLine(57, 116, 204),
                horizontalLine(86, 116, 277),
                horizontalLine(138, 36, 367),
                bar(
                  left: 36,
                  top: 8,
                  width: 24,
                  height: 130,
                  color: const Color(0xFFFBD37D),
                ),
                bar(
                  left: 116,
                  top: 43,
                  width: 24,
                  height: 95,
                  color: const Color(0xFF0C8CE9),
                ),
                bar(
                  left: 180,
                  top: 57,
                  width: 24,
                  height: 81,
                  color: const Color(0xFFFB7D7D),
                ),
                bar(
                  left: 252,
                  top: 86,
                  width: 24,
                  height: 52,
                  color: const Color(0xFFE1A157),
                ),
                bar(
                  left: 343,
                  top: 138,
                  width: 24,
                  height: 168,
                  color: const Color(0xFF7CD7EC),
                ),
                Positioned(
                  left: sx(12),
                  top: sy(172),
                  width: sx(376),
                  child: Center(
                    child: Text(
                      'Loss',
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF404040),
                      ),
                    ),
                  ),
                ),
                label(left: 0, width: 97, text: 'Purchase Prize'),
                label(left: 97, width: 80, text: 'Sale Value'),
                label(left: 177, width: 80, text: 'Expenses'),
                label(left: 257, width: 80, text: 'Compensation'),
                label(left: 337, width: 99, text: 'Gross Profit\n(Loss)'),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildReportPageCompensationSellingPriceCalculations(
      {required int pageNumber}) {
    final rawProjectName =
        _projectData['projectName'] ?? _projectData['name'] ?? '';
    final projectName = rawProjectName.toString().trim().isEmpty
        ? '*Project Name*'
        : rawProjectName.toString();

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: const Color(0xFF404040).withOpacity(0.9),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  projectName,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '8.3  (%) of Selling Price per Plot',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF404040),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'i) Profit Distribution & Compensation',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF404040),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Agent and project manager commissions are calculated based on the sale value of each plot.',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                    color: Colors.black,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'A) Sale Value > Purchase Prize',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 8),
                _buildSellingPriceBonusDiagramCaseA(),
                const SizedBox(height: 16),
                Text(
                  'B) Sale Value < Purchase Prize',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 8),
                _buildSellingPriceBonusDiagramCaseB(),
              ],
            ),
          ),
          const Spacer(),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  Widget _buildReportPageCompensationSellingPriceCaseC(
      {required int pageNumber}) {
    final rawProjectName =
        _projectData['projectName'] ?? _projectData['name'] ?? '';
    final projectName = rawProjectName.toString().trim().isEmpty
        ? '*Project Name*'
        : rawProjectName.toString();

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: const Color(0xFF404040).withOpacity(0.9),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  projectName,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'C) Sale Value = Purchase Prize',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 16),
                _buildSellingPriceBonusDiagramCaseC(),
                const SizedBox(height: 16),
                Text(
                  '* The presented graphs are for demonstration purposes only. Multiple variations and additional cases may occur based on actual project conditions. *',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.w300,
                    color: Colors.black,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  String _areaUnit = AreaUnitService.defaultUnit;
  bool get _isSqm => AreaUnitUtils.isSqm(_areaUnit);
  String get _areaUnitSuffix => AreaUnitUtils.unitSuffix(_isSqm);
  String get _reportHeaderUnitText {
    final projectName = _reportCoverProjectName().trim();
    return projectName.isEmpty ? '*Project Name*' : projectName;
  }

  String get _reportHeaderDateText {
    final now = DateTime.now();
    final dd = now.day.toString().padLeft(2, '0');
    final mm = now.month.toString().padLeft(2, '0');
    final yyyy = now.year.toString();
    return '$dd/$mm/$yyyy';
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    final cleaned = value.toString().replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(cleaned) ?? 0.0;
  }

  double _displayAreaFromSqft(dynamic areaSqft) =>
      AreaUnitUtils.areaFromSqftToDisplay(_toDouble(areaSqft), _isSqm);

  double _displayRateFromSqft(dynamic ratePerSqft) =>
      AreaUnitUtils.rateFromSqftToDisplay(_toDouble(ratePerSqft), _isSqm);

  bool _isMissingValue(dynamic value) {
    if (value == null) return true;
    final raw = value.toString().trim();
    if (raw.isEmpty || raw == '-' || raw == '—') return true;
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.\-]'), '');
    final parsed = double.tryParse(cleaned);
    return parsed != null && parsed == 0;
  }

  String _displayOrDash(dynamic value) =>
      _isMissingValue(value) ? '—' : '$value';

  String _formatCurrencyOrDash(dynamic value) {
    final formatted = _formatTo2Decimals(value);
    return formatted == '—' ? '—' : '₹ $formatted';
  }

  String _formatPercentOrDash(dynamic value) {
    final formatted = _formatTo2Decimals(value);
    return formatted == '—' ? '—' : '$formatted %';
  }

  String _formatPercentageForReport(double percentage) {
    final normalized = percentage
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return normalized.isEmpty ? '0' : normalized;
  }

  String _formatAreaWithUnit(dynamic areaSqft) {
    final formatted = _formatTo2Decimals(_displayAreaFromSqft(areaSqft));
    return formatted == '—' ? '—' : '$formatted $_areaUnitSuffix';
  }

  String _formatAreaLabelWithUnitForReport(String label, dynamic areaSqft) {
    final formattedArea = _formatAreaWithUnit(areaSqft);
    if (formattedArea == '—') return label;
    return '$label ($formattedArea)';
  }

  String _formatRateWithUnit(dynamic ratePerSqft) {
    final formatted = _formatTo2Decimals(_displayRateFromSqft(ratePerSqft));
    return formatted == '—' ? '—' : '₹/$_areaUnitSuffix $formatted';
  }

  bool get _hasLiveDashboardSnapshotForReport =>
      widget.dashboardData != null && widget.dashboardData!.isNotEmpty;

  bool _fullDetailedReport = true;
  String? _selectedReportType;
  int _currentPage = 1;
  Map<String, dynamic> _projectData = {};
  String _reportIdentityFullName = '';
  String _reportIdentityOrganization = '';
  String _reportIdentityRole = '';
  String? _reportIdentityLogoSvg;
  Uint8List? _reportIdentityLogoBytes;
  final Map<String, String> _layoutIdNameMap = {};
  Map<String, dynamic>? _dashboardDataLocal = {};
  String _reportProjectNameFallback = '';
  String _reportProjectLocationFallback = '';
  final List<GlobalKey> _reportPagePrintKeys = <GlobalKey>[];
  final ScrollController _thumbnailScrollController = ScrollController();
  final ScrollController _mainPreviewScrollController = ScrollController();
  late final WebArrowKeyScrollBinding _arrowKeyScrollBinding =
      WebArrowKeyScrollBinding(controller: _mainPreviewScrollController);
  bool _isSyncingPreviewScroll = false;
  bool _isPrintingReport = false;
  bool _isReportLoading = true;
  Timer? _reportLocalStateWatcher;
  bool _reportWatcherLoadInFlight = false;
  int _reportObservedLocalEditMs = -1;
  int _reportObservedRemoteSaveMs = -1;
  int _reportLoadGeneration = 0;
  static const double _minPreviewZoom = 0.5;
  static const double _maxPreviewZoom = 1.2;
  static const double _previewZoomStep = 0.1;
  double _previewZoom = 1.0;
  final Set<String> _previewControlFlashKeys = <String>{};
  final Map<String, Timer> _previewControlFlashTimers = <String, Timer>{};
  final Map<String, bool> _moduleSelections = {
    'Expense Breakdown': false,
    'Sales Report': false,
    'Site Report': false,
    'Partner Profit Report': false,
    'Project Manager Earning Report': false,
    'Agent Earning Report': false,
  };

  @override
  void initState() {
    super.initState();
    _arrowKeyScrollBinding.attach();
    _mainPreviewScrollController.addListener(_syncMainToThumbnails);
    _primeReportHeaderFallbacks();
    _loadProjectData();
    _loadReportIdentitySettings();
    _startReportLocalStateWatcher();
  }

  @override
  void didUpdateWidget(covariant ReportPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final becameActive = widget.isActive && !oldWidget.isActive;
    final projectChanged = widget.projectId != oldWidget.projectId;
    final projectDataChanged = widget.projectData != oldWidget.projectData;
    final dashboardDataChanged =
        widget.dashboardData != oldWidget.dashboardData;
    final dataVersionChanged = widget.dataVersion != oldWidget.dataVersion;
    if (projectChanged ||
        projectDataChanged ||
        dashboardDataChanged ||
        dataVersionChanged ||
        becameActive) {
      if (projectChanged) {
        _reportObservedLocalEditMs = -1;
        _reportObservedRemoteSaveMs = -1;
      }
      _projectData = {};
      _layoutIdNameMap.clear();
      _dashboardDataLocal = {};
      _loadProjectData(
        forceRefresh: projectChanged || dataVersionChanged || becameActive,
      );
    }
  }

  @override
  void dispose() {
    _reportLocalStateWatcher?.cancel();
    for (final timer in _previewControlFlashTimers.values) {
      timer.cancel();
    }
    _previewControlFlashTimers.clear();
    _previewControlFlashKeys.clear();
    _arrowKeyScrollBinding.detach();
    _mainPreviewScrollController.removeListener(_syncMainToThumbnails);
    _mainPreviewScrollController.dispose();
    _thumbnailScrollController.dispose();
    super.dispose();
  }

  void _startReportLocalStateWatcher() {
    _reportLocalStateWatcher?.cancel();
    _reportLocalStateWatcher = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_reloadReportOnLocalStateChange()),
    );
  }

  Future<void> _reloadReportOnLocalStateChange() async {
    if (!mounted || !widget.isActive || _isReportLoading) return;
    if (_reportWatcherLoadInFlight) return;

    final projectId = (widget.projectId ?? '').trim();
    if (projectId.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final localEditMs = prefs.getInt('project_${projectId}_last_local_edit_ms') ?? 0;
      final remoteSaveMs = prefs.getInt('project_${projectId}_last_remote_save_ms') ?? 0;

      if (_reportObservedLocalEditMs == -1 &&
          _reportObservedRemoteSaveMs == -1) {
        _reportObservedLocalEditMs = localEditMs;
        _reportObservedRemoteSaveMs = remoteSaveMs;
        return;
      }

      if (localEditMs == _reportObservedLocalEditMs &&
          remoteSaveMs == _reportObservedRemoteSaveMs) {
        return;
      }

      _reportObservedLocalEditMs = localEditMs;
      _reportObservedRemoteSaveMs = remoteSaveMs;
      _reportWatcherLoadInFlight = true;
      await _loadProjectData(forceRefresh: localEditMs <= remoteSaveMs);
    } catch (_) {
      // Best-effort watcher refresh.
    } finally {
      _reportWatcherLoadInFlight = false;
    }
  }

  Color _previewControlBackground(String key) {
    return _previewControlFlashKeys.contains(key)
        ? const Color(0xFFEDEDED)
        : Colors.white;
  }

  void _flashPreviewControl(String key) {
    if (!mounted) return;
    setState(() {
      _previewControlFlashKeys.add(key);
    });
    _previewControlFlashTimers[key]?.cancel();
    _previewControlFlashTimers[key] = Timer(const Duration(seconds: 0), () {
      if (!mounted) return;
      setState(() {
        _previewControlFlashKeys.remove(key);
      });
      _previewControlFlashTimers.remove(key);
    });
  }

  void _handlePreviewControlTap(String key, VoidCallback action) {
    action();
    _flashPreviewControl(key);
  }

  void _syncMainToThumbnails() {
    if (_isSyncingPreviewScroll) return;
    if (!_mainPreviewScrollController.hasClients ||
        !_thumbnailScrollController.hasClients) return;
    final mainMax = _mainPreviewScrollController.position.maxScrollExtent;
    final thumbMax = _thumbnailScrollController.position.maxScrollExtent;
    if (mainMax <= 0 || thumbMax <= 0) return;
    final progress =
        (_mainPreviewScrollController.offset / mainMax).clamp(0.0, 1.0);
    final target = progress * thumbMax;
    final totalPages = _buildAllReportPagesForPreview().length;
    final pageExtent = _reportPreviewPageExtent * _previewZoom;
    final computedPage =
        ((_mainPreviewScrollController.offset + (pageExtent / 2)) / pageExtent)
                .floor() +
            1;
    final nextPage = computedPage.clamp(1, math.max(1, totalPages)).toInt();
    _isSyncingPreviewScroll = true;
    _thumbnailScrollController.jumpTo(target.clamp(0.0, thumbMax));
    _isSyncingPreviewScroll = false;
    if (_currentPage != nextPage) {
      setState(() {
        _currentPage = nextPage;
      });
    }
  }

  void _scrollMainPreviewToPage(int pageNum) {
    final totalPages = _buildAllReportPagesForPreview().length;
    final safePage = pageNum.clamp(1, math.max(1, totalPages)).toInt();
    if (!_mainPreviewScrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _scrollMainPreviewToPage(safePage);
        }
      });
      return;
    }

    final maxOffset = _mainPreviewScrollController.position.maxScrollExtent;
    final pageExtent = _reportPreviewPageExtent * _previewZoom;
    final targetOffset = ((safePage - 1) * pageExtent).clamp(0.0, maxOffset);

    _mainPreviewScrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
    );

    if (_currentPage != safePage && mounted) {
      setState(() {
        _currentPage = safePage;
      });
    }
  }

  void _changePreviewZoom(double delta) {
    final before = _previewZoom;
    final after = (before + delta).clamp(_minPreviewZoom, _maxPreviewZoom);
    if ((after - before).abs() < 0.0001) return;
    final currentPage = _currentPage;
    setState(() {
      _previewZoom = double.parse(after.toStringAsFixed(2));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollMainPreviewToPage(currentPage);
    });
  }

  // Helper to resolve plot field values from multiple possible key names
  String _plotFieldStr(Map<String, dynamic> plot, List<String> candidates) {
    for (final k in candidates) {
      if (plot.containsKey(k) && plot[k] != null) {
        final v = plot[k];
        if (v is String) {
          final s = v;
          if (s.trim().isNotEmpty) return s;
        }
        if (v is Map) {
          // try common name fields inside nested map
          for (final nk in ['name', 'layoutName', 'title', 'label']) {
            if (v.containsKey(nk) && v[nk] != null) {
              final s2 = v[nk].toString();
              if (s2.trim().isNotEmpty) return s2;
            }
          }
          // fallback to string form (may be id-like)
          final s3 = v.toString();
          if (s3.trim().isNotEmpty) return s3;
        }
        // other types
        final s = v.toString();
        if (s.trim().isNotEmpty) return s;
      }
    }
    return '-';
  }

  double _plotFieldDouble(Map<String, dynamic> plot, List<String> candidates) {
    final s = _plotFieldStr(plot, candidates);
    final cleaned = s.replaceAll(RegExp(r"[^0-9.\-]"), '');
    return double.tryParse(cleaned) ?? 0.0;
  }

  // Try to infer a plot number when common keys are missing
  String _inferPlotNumber(Map<String, dynamic> plot) {
    // Check keys that likely contain plot identifiers
    for (final k in plot.keys) {
      final kl = k.toString().toLowerCase();
      if (kl.contains('plot') ||
          kl.contains('plot_no') ||
          kl.contains('plotno') ||
          kl.contains('number') ||
          kl.contains('no')) {
        final v = plot[k];
        if (v != null) {
          final s = v.toString().trim();
          if (s.isNotEmpty && s.length <= 40) return s;
        }
      }
    }

    // Fallback: return the first short string value found
    for (final k in plot.keys) {
      final v = plot[k];
      if (v is String && v.trim().isNotEmpty && v.length <= 40) return v.trim();
    }

    return '-';
  }

  // Try to infer layout name from plot when explicit layout field is missing
  String _inferLayoutName(Map<String, dynamic> plot) {
    for (final k in plot.keys) {
      final kl = k.toString().toLowerCase();
      if (kl.contains('layout')) {
        final v = plot[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
        if (v is Map && v.containsKey('name')) {
          final name = v['name'];
          if (name is String && name.trim().isNotEmpty) return name.trim();
        }
      }
    }
    return '-';
  }

  // Resolve layout label from a plot entry. Handles string, nested map, or id lookup against project layouts.
  String _resolveLayoutLabel(Map<String, dynamic> plot) {
    // try common fields
    final candidates = [
      'selectedLayout',
      'layout',
      'selected_layout',
      'layoutName',
      'layout_id',
      'layoutId'
    ];
    for (final c in candidates) {
      if (plot.containsKey(c) && plot[c] != null) {
        final val = plot[c];
        if (val is String && val.trim().isNotEmpty) {
          final s = val.trim();
          final uuidRe = RegExp(
              r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
          if (uuidRe.hasMatch(s)) {
            // looks like an id — try lookup first
            final found = _lookupLayoutNameById(s);
            if (found != null) return found;
            // try normalized form
            final norm = s.replaceAll('-', '').toLowerCase();
            final found2 = _lookupLayoutNameById(norm);
            if (found2 != null) return found2;
            // fall through and don't return the raw id yet
          } else {
            return s;
          }
        }
        if (val is Map) {
          for (final nk in ['name', 'layoutName', 'title', 'label']) {
            if (val.containsKey(nk) && val[nk] != null) {
              final s = val[nk].toString().trim();
              if (s.isNotEmpty) return s;
            }
          }
          // try id inside nested map
          for (final idk in ['id', 'layoutId', '_id']) {
            if (val.containsKey(idk) && val[idk] != null) {
              final idVal = val[idk];
              final found = _lookupLayoutNameById(idVal);
              if (found != null) return found;
            }
          }
        }
        // val might be an id (int or string)
        final foundById = _lookupLayoutNameById(val);
        if (foundById != null) return foundById;
        // Avoid returning raw internal ids (UUIDs). If the value looks like a human label, return it,
        // otherwise keep searching and fall back to inference.
        final s = val.toString().trim();
        if (s.isNotEmpty) {
          final uuidRe = RegExp(
              r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
          if (!uuidRe.hasMatch(s))
            return s; // a non-UUID string is likely a friendly name
          // if it's a UUID-like string, skip returning it and try other heuristics below
        }
      }
    }

    // fallback to infer from other keys
    final inferred = _inferLayoutName(plot);
    if (inferred != '-') return inferred;
    // If we reach here, layout id is missing from layouts list
    if (plot.containsKey('layout_id')) {
      final rawId = plot['layout_id'].toString();
      return 'Unknown layout (' + rawId + ')';
    }
    return 'Unknown';
  }

  String? _lookupLayoutNameById(dynamic idVal) {
    if (idVal == null) return null;
    // Fast path: use pre-built map (populated after loading project data)
    try {
      final key = idVal.toString();
      if (_layoutIdNameMap.containsKey(key)) return _layoutIdNameMap[key];
      final norm = key.replaceAll('-', '').toLowerCase();
      if (_layoutIdNameMap.containsKey(norm)) return _layoutIdNameMap[norm];
    } catch (_) {}
    // debug
    // print('DEBUG lookup attempt for id: $idVal');
    // First try common keys
    final candidateKeys = [
      'layouts',
      'layoutList',
      'layouts_list',
      'layoutsData',
      'layoutsDataList',
      'layoutsInfo'
    ];
    for (final key in candidateKeys) {
      if (_projectData.containsKey(key) && _projectData[key] is List) {
        final list = _projectData[key] as List;
        for (final item in list) {
          if (item is Map) {
            for (final idk in ['id', 'layoutId', '_id', 'layout_id']) {
              if (item.containsKey(idk) && item[idk] != null) {
                if (item[idk].toString() == idVal.toString()) {
                  // Prefer explicit human name fields
                  for (final nk in ['name', 'layoutName', 'title', 'label']) {
                    if (item.containsKey(nk) && item[nk] != null)
                      return item[nk].toString();
                  }
                  // Fallbacks: idx, number or other short identifiers that are human-friendly
                  for (final nk in [
                    'idx',
                    'index',
                    'number',
                    'label',
                    'title'
                  ]) {
                    if (item.containsKey(nk) && item[nk] != null) {
                      final v = item[nk].toString().trim();
                      if (v.isNotEmpty && v.length <= 40) return v;
                    }
                  }
                  // As a last resort, check cached map with numeric idx or normalized id
                  final idStr = item['id']?.toString();
                  if (idStr != null) {
                    final normId = idStr.replaceAll('-', '').toLowerCase();
                    if (_layoutIdNameMap.containsKey(normId))
                      return _layoutIdNameMap[normId];
                  }
                  // Nothing human-friendly found here; continue searching other lists
                  break;
                }
              }
            }
          }
        }
      }
    }

    // Fallback: search any list in projectData that looks like a list of layout maps
    for (final entry in _projectData.entries) {
      final val = entry.value;
      if (val is List && val.isNotEmpty && val.first is Map) {
        for (final item in val) {
          if (item is Map) {
            // check for id match
            for (final idk in ['id', 'layoutId', '_id', 'layout_id']) {
              if (item.containsKey(idk) &&
                  item[idk] != null &&
                  item[idk].toString() == idVal.toString()) {
                for (final nk in ['name', 'layoutName', 'title', 'label']) {
                  if (item.containsKey(nk) && item[nk] != null)
                    return item[nk].toString();
                }
                for (final nk in ['idx', 'index', 'number', 'label', 'title']) {
                  if (item.containsKey(nk) && item[nk] != null) {
                    final v = item[nk].toString().trim();
                    if (v.isNotEmpty && v.length <= 40) return v;
                  }
                }
                // no friendly name here — keep searching other lists
                break;
              }
            }
          }
        }
      }
    }

    // Deep scan fallback: check any field value inside maps for a match (normalized)
    try {
      final keyStr = idVal.toString();
      final normKey = keyStr.replaceAll('-', '').toLowerCase();
      for (final entry in _projectData.entries) {
        final val = entry.value;
        if (val is List && val.isNotEmpty && val.first is Map) {
          for (final item in val) {
            if (item is Map) {
              // scan all values
              for (final e in item.entries) {
                final v = e.value;
                if (v == null) continue;
                final s = v.toString();
                if (s == keyStr ||
                    s == normKey ||
                    s.replaceAll('-', '').toLowerCase() == normKey) {
                  for (final nk in ['name', 'layoutName', 'title', 'label']) {
                    if (item.containsKey(nk) && item[nk] != null)
                      return item[nk].toString();
                  }
                  // fallback to idx or other short identifier
                  for (final nk in ['idx', 'index', 'number']) {
                    if (item.containsKey(nk) && item[nk] != null)
                      return item[nk].toString();
                  }
                }
              }
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  String _plotIdStringForReport(Map<String, dynamic> plot) {
    for (final key in ['id', 'plot_id', 'plotId', '_id']) {
      final raw = plot[key];
      if (raw == null) continue;
      final id = raw.toString().trim();
      if (id.isNotEmpty) return id;
    }
    return '';
  }

  String _normalizePlotIdentityForReport(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
  }

  List<String> _extractPartnerNamesFromAnyReport(dynamic raw) {
    final names = <String>[];
    final seen = <String>{};

    void addName(String value) {
      var candidate = value.trim();
      if (candidate.isEmpty || candidate == '-') return;
      if (candidate.startsWith('[') && candidate.endsWith(']')) {
        candidate = candidate.substring(1, candidate.length - 1);
      }
      final parts = candidate.split(RegExp(r'[,\n;]'));
      for (final part in parts) {
        final clean = part.trim();
        if (clean.isEmpty || clean == '-') continue;
        final normalized = clean.toLowerCase();
        if (seen.add(normalized)) {
          names.add(clean);
        }
      }
    }

    void walk(dynamic value) {
      if (value == null) return;
      if (value is List) {
        for (final item in value) {
          walk(item);
        }
        return;
      }
      if (value is Map) {
        final map = Map<String, dynamic>.from(value);
        var foundAny = false;
        for (final key in [
          'name',
          'partner',
          'partner_name',
          'partnerName',
          'label',
          'title'
        ]) {
          if (!map.containsKey(key) || map[key] == null) continue;
          foundAny = true;
          walk(map[key]);
        }
        if (!foundAny) {
          for (final entry in map.values) {
            walk(entry);
          }
        }
        return;
      }
      addName(value.toString());
    }

    walk(raw);
    return names;
  }

  List<String> _partnerNamesFromPlotForReport(Map<String, dynamic> plot) {
    final names = LinkedHashSet<String>();

    for (final key in [
      'partners',
      'partnersName',
      'partners_name',
      'partner_names',
      'partner',
      'partnerName',
      'partner_name',
    ]) {
      if (!plot.containsKey(key) || plot[key] == null) continue;
      names.addAll(_extractPartnerNamesFromAnyReport(plot[key]));
    }

    final fallback = _plotFieldStr(plot, [
      'partner',
      'partnerName',
      'partner_name',
      'partnersName',
      'partners_name',
    ]);
    if (fallback != '-') {
      names.addAll(_extractPartnerNamesFromAnyReport(fallback));
    }

    return names.toList(growable: false);
  }

  String _partnerLabelFromPlotForReport(Map<String, dynamic> plot) {
    final names = _partnerNamesFromPlotForReport(plot);
    return names.isEmpty ? '-' : names.join(', ');
  }

  String? _firstNonEmptyStringReport(Iterable<String?> values) {
    for (final value in values) {
      if (value == null) continue;
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  Map<String, String> _buildPlotIdToPartnerLabelMapForReport() {
    final assignments =
        _projectData['plot_partners'] as List<dynamic>? ?? const [];
    final plotToPartners = <String, LinkedHashSet<String>>{};

    void addPartnerForPlot(String plotIdentity, String partnerName) {
      final cleanIdentity = plotIdentity.trim();
      final cleanPartner = partnerName.trim();
      if (cleanIdentity.isEmpty || cleanPartner.isEmpty) return;
      plotToPartners
          .putIfAbsent(cleanIdentity, () => LinkedHashSet<String>())
          .add(cleanPartner);
      final normalized = _normalizePlotIdentityForReport(cleanIdentity);
      if (normalized.isEmpty) return;
      plotToPartners
          .putIfAbsent(normalized, () => LinkedHashSet<String>())
          .add(cleanPartner);
    }

    for (final raw in assignments) {
      if (raw is! Map) continue;
      final assignment = Map<String, dynamic>.from(raw);
      final plotId = (assignment['plot_id'] ??
              assignment['plotId'] ??
              assignment['id'] ??
              '')
          .toString();
      final plotNumber = (assignment['plot_number'] ??
              assignment['plotNumber'] ??
              assignment['plot_no'] ??
              assignment['number'] ??
              '')
          .toString();
      final partnerNames = _extractPartnerNamesFromAnyReport(
        assignment['partner_name'] ??
            assignment['partnerName'] ??
            assignment['name'] ??
            assignment['partner'] ??
            assignment['partnersName'] ??
            assignment['partners_name'],
      );
      for (final partnerName in partnerNames) {
        addPartnerForPlot(plotId, partnerName);
        addPartnerForPlot(plotNumber, partnerName);
      }
    }

    final plots = _collectReportPlotsForOverview();
    for (final plot in plots) {
      final plotId = _plotIdStringForReport(plot);
      final plotNumber = _plotFieldStr(
        plot,
        ['plotNumber', 'plot_no', 'plotNo', 'number', 'plot_number'],
      );
      final partnerNames = _partnerNamesFromPlotForReport(plot);
      for (final partnerName in partnerNames) {
        addPartnerForPlot(plotId, partnerName);
        addPartnerForPlot(plotNumber, partnerName);
      }
    }

    return plotToPartners.map(
      (key, names) => MapEntry(key, names.join(', ')),
    );
  }

  String _plotStatusPendingAmenitySyncKeyForReport(String projectId) {
    return 'project_plot_status_pending_amenity_sync_v1_${projectId.trim()}';
  }

  String _plotStatusAmenitySnapshotKeyForReport(String projectId) {
    return 'project_plot_status_amenity_snapshot_v1_${projectId.trim()}';
  }

  List<Map<String, dynamic>> _mapListForReport(dynamic raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  String _amenityOverlayRowKeyForReport(Map<String, dynamic> row) {
    final id = (row['id'] ?? row['amenityId'] ?? '').toString().trim();
    if (id.isNotEmpty) return 'id:$id';
    final name = (row['name'] ?? '').toString().trim().toLowerCase();
    if (name.isNotEmpty) return 'name:$name';
    return '';
  }

  bool _hasAmenitySalesSignalForReportOverlay(Map<String, dynamic> row) {
    final salePrice = _toDouble(row['sale_price'] ?? row['salePrice']);
    final saleValue = _toDouble(row['sale_value'] ?? row['saleValue']);
    final paymentAmount =
        _toDouble(row['payment_amount'] ?? row['paymentAmount']);
    final buyerName =
        (row['buyer_name'] ?? row['buyerName'] ?? '').toString().trim();
    final saleDate = _readSaleDateValueForReport(row).toString();
    final payment = (row['payment'] ?? '').toString().trim();
    return salePrice > 0 ||
        saleValue > 0 ||
        paymentAmount > 0 ||
        buyerName.isNotEmpty ||
        saleDate.trim().isNotEmpty ||
        payment.isNotEmpty;
  }

  Map<String, dynamic> _normalizeAmenityOverlayRowForReport(
    Map<String, dynamic> row,
  ) {
    return <String, dynamic>{
      ...row,
      'id': (row['id'] ?? row['amenityId'] ?? '').toString().trim(),
      'name': (row['name'] ?? '').toString().trim(),
      'area': row['area'],
      'all_in_cost':
          row['all_in_cost'] ?? row['allInCost'] ?? row['allInCostPerSqft'],
      'status': row['status'] ??
          row['amenity_status'] ??
          row['amenityStatus'] ??
          row['plot_status'] ??
          row['plotStatus'] ??
          row['sale_status'] ??
          row['saleStatus'],
      'sale_price': row['sale_price'] ?? row['salePrice'],
      'sale_value': row['sale_value'] ?? row['saleValue'],
      'buyer_name': row['buyer_name'] ?? row['buyerName'],
      'buyer_contact_number':
          row['buyer_contact_number'] ?? row['buyerContactNumber'],
      'payment': row['payment'],
      'payment_amount': row['payment_amount'] ?? row['paymentAmount'],
      'agent_name': row['agent_name'] ?? row['agentName'] ?? row['agent'],
      'sale_date': _readSaleDateValueForReport(row),
    };
  }

  Map<String, dynamic> _sanitizeAmenityOverlayForReport(
    Map<String, dynamic> existing,
    Map<String, dynamic> overlay,
  ) {
    final sanitized = Map<String, dynamic>.from(overlay);
    final existingStatus = _amenityStatusForReport(existing);
    final incomingStatus = _amenityStatusForReport(overlay);
    if (existingStatus != 'available' &&
        incomingStatus == 'available' &&
        !_hasAmenitySalesSignalForReportOverlay(overlay)) {
      sanitized.remove('status');
      for (final key in const [
        'sale_price',
        'sale_value',
        'buyer_name',
        'buyer_contact_number',
        'payment',
        'payment_amount',
        'agent_name',
        'sale_date',
      ]) {
        final value = sanitized[key];
        final blankString = value is String && value.trim().isEmpty;
        final zeroNumber = value is num && value.toDouble() == 0;
        if (value == null || blankString || zeroNumber) {
          sanitized.remove(key);
        }
      }
    }
    return sanitized;
  }

  Future<void> _applyPlotStatusAmenityLocalOverlaysForReport(
    String projectId,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty || _projectData.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final baseRows = _mapListForReport(
      _projectData['amenityAreas'] ?? _projectData['amenity_areas'],
    );
    final mergedRows = baseRows
        .map((row) => _normalizeAmenityOverlayRowForReport(row))
        .toList(growable: true);
    final indexByRowKey = <String, int>{};

    void reindex() {
      indexByRowKey.clear();
      for (var i = 0; i < mergedRows.length; i++) {
        final key = _amenityOverlayRowKeyForReport(mergedRows[i]);
        if (key.isNotEmpty) {
          indexByRowKey[key] = i;
        }
      }
    }

    reindex();

    void applyOverlayRow(
      Map<String, dynamic> rawRow, {
      required bool onlySignalRows,
    }) {
      final normalized = _normalizeAmenityOverlayRowForReport(rawRow);
      final status = _amenityStatusForReport(normalized);
      final hasSignal = status != 'available' ||
          _hasAmenitySalesSignalForReportOverlay(normalized);
      final shouldApply = mergedRows.isEmpty || !onlySignalRows || hasSignal;
      if (!shouldApply) return;

      final key = _amenityOverlayRowKeyForReport(normalized);
      final existingIndex = key.isEmpty ? null : indexByRowKey[key];
      if (existingIndex == null) {
        mergedRows.add(normalized);
      } else {
        final safeOverlay = _sanitizeAmenityOverlayForReport(
          mergedRows[existingIndex],
          normalized,
        );
        mergedRows[existingIndex] = <String, dynamic>{
          ...mergedRows[existingIndex],
          ...safeOverlay,
        };
      }
      reindex();
    }

    final snapshotRaw = prefs.getString(
      _plotStatusAmenitySnapshotKeyForReport(normalizedProjectId),
    );
    if (snapshotRaw != null && snapshotRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(snapshotRaw);
        if (decoded is List) {
          for (final row in decoded.whereType<Map>()) {
            applyOverlayRow(
              Map<String, dynamic>.from(row),
              onlySignalRows: true,
            );
          }
        }
      } catch (_) {}
    }

    final queueRaw = prefs.getString(
      _plotStatusPendingAmenitySyncKeyForReport(normalizedProjectId),
    );
    if (queueRaw != null && queueRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(queueRaw);
        if (decoded is List) {
          for (final row in decoded.whereType<Map>()) {
            final queueRow = Map<String, dynamic>.from(row);
            applyOverlayRow(
              <String, dynamic>{
                'id': queueRow['amenityId'] ?? queueRow['id'],
                'name': queueRow['name'],
                'area': queueRow['area'],
                'all_in_cost': queueRow['allInCost'] ?? queueRow['all_in_cost'],
                'status': queueRow['status'],
                'sale_price': queueRow['salePrice'],
                'sale_value': queueRow['saleValue'],
                'buyer_name': queueRow['buyerName'],
                'buyer_contact_number': queueRow['buyerContactNumber'],
                'payment': queueRow['payment'],
                'payment_amount':
                    queueRow['paymentAmount'] ?? queueRow['payment_amount'],
                'agent_name': queueRow['agentName'],
                'sale_date': queueRow['saleDate'] ??
                    queueRow['dateOfSale'] ??
                    queueRow['sale_date'] ??
                    queueRow['date_of_sale'],
              },
              onlySignalRows: false,
            );
          }
        }
      } catch (_) {}
    }

    if (mergedRows.isNotEmpty) {
      _projectData['amenityAreas'] = mergedRows;
      _projectData['amenity_areas'] = mergedRows;
    }
  }

  Future<void> _applyPendingPartnerExpenseDraftForReport(
    String projectId,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(
        'project_${normalizedProjectId}_pending_partner_expense_draft',
      );
      if (raw == null || raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final draft = Map<String, dynamic>.from(decoded.cast<String, dynamic>());

      final partnersRaw = draft['partners'];
      if (partnersRaw is List) {
        final draftPartners = <Map<String, dynamic>>[];
        for (final rawPartner in partnersRaw.whereType<Map>()) {
          final partner = Map<String, dynamic>.from(rawPartner);
          final id = (partner['id'] ?? '').toString().trim();
          final name = (partner['name'] ?? '').toString().trim();
          final amount = _toDouble(partner['amount']);
          if (id.isEmpty && name.isEmpty && amount <= 0) continue;
          draftPartners.add({
            'id': id,
            'name': name,
            'amount': amount,
          });
        }
        if (draftPartners.isNotEmpty) {
          _projectData['partners'] = draftPartners;
        }
      }

      final areaRaw = draft['area'];
      if (areaRaw is Map) {
        final area = Map<String, dynamic>.from(areaRaw);
        final estimatedRaw = area['estimatedDevelopmentCost'] ??
            area['estimated_development_cost'];
        if (estimatedRaw != null) {
          final estimated = _toDouble(estimatedRaw);
          if (estimated > 0) {
            _projectData['estimatedDevelopmentCost'] = estimated;
            _projectData['estimated_development_cost'] = estimated;
          }
        }
      }
    } catch (e) {
      debugPrint(
        'Warning: Could not apply pending partner expense draft for report: $e',
      );
    }
  }

  Future<void> _applyPendingCompensationDraftForReport(
    String projectId,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(
        'project_${normalizedProjectId}_pending_compensation_draft',
      );
      if (raw == null || raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final draft = Map<String, dynamic>.from(decoded.cast<String, dynamic>());

      final managersRaw = draft['managers'];
      if (managersRaw is List) {
        final draftManagers = <Map<String, dynamic>>[];
        for (final rawManager in managersRaw.whereType<Map>()) {
          final manager = Map<String, dynamic>.from(rawManager);
          final id = (manager['id'] ?? '').toString().trim();
          final name = (manager['name'] ?? '').toString().trim();
          if (id.isEmpty && name.isEmpty) continue;
          draftManagers.add({
            'id': id,
            'name': name,
            'compensation_type':
                (manager['compensation'] ?? '').toString().trim(),
            'earning_type': (manager['earningType'] ?? '').toString().trim(),
            'percentage': _toDouble(manager['percentage']),
            'fixed_fee': _toDouble(manager['fixedFee']),
            'monthly_fee': _toDouble(manager['monthlyFee']),
            'months': int.tryParse((manager['months'] ?? '').toString()) ?? 0,
          });
        }
        if (draftManagers.isNotEmpty) {
          _projectData['projectManagers'] = draftManagers;
          _projectData['project_managers'] = draftManagers;
        }
      }

      final agentsRaw = draft['agents'];
      if (agentsRaw is List) {
        final draftAgents = <Map<String, dynamic>>[];
        for (final rawAgent in agentsRaw.whereType<Map>()) {
          final agent = Map<String, dynamic>.from(rawAgent);
          final id = (agent['id'] ?? '').toString().trim();
          final name = (agent['name'] ?? '').toString().trim();
          if (id.isEmpty && name.isEmpty) continue;
          draftAgents.add({
            'id': id,
            'name': name,
            'compensation_type':
                (agent['compensation'] ?? '').toString().trim(),
            'earning_type': (agent['earningType'] ?? '').toString().trim(),
            'percentage': _toDouble(agent['percentage']),
            'fixed_fee': _toDouble(agent['fixedFee']),
            'monthly_fee': _toDouble(agent['monthlyFee']),
            'months': int.tryParse((agent['months'] ?? '').toString()) ?? 0,
            'per_sqft_fee': _toDouble(agent['perSqftFee']),
          });
        }
        if (draftAgents.isNotEmpty) {
          _projectData['agents'] = draftAgents;
          _projectData['agentDetails'] = draftAgents;
        }
      }
    } catch (e) {
      debugPrint(
        'Warning: Could not apply pending compensation draft for report: $e',
      );
    }
  }

  Future<void> _loadProjectData({bool forceRefresh = false}) async {
    final loadGeneration = ++_reportLoadGeneration;
    if (mounted) {
      setState(() {
        _isReportLoading = true;
      });
    }
    try {
      _areaUnit = await AreaUnitService.getAreaUnit(widget.projectId);
      final normalizedProjectId = (widget.projectId ?? '').trim();

      if (normalizedProjectId.isNotEmpty) {
        try {
          final prefs = await SharedPreferences.getInstance();
          _reportObservedLocalEditMs =
              prefs.getInt('project_${normalizedProjectId}_last_local_edit_ms') ??
                  0;
          _reportObservedRemoteSaveMs =
              prefs.getInt('project_${normalizedProjectId}_last_remote_save_ms') ??
                  0;
        } catch (_) {
          // Ignore watcher baseline updates on load failures.
        }
      }

      // Keep report in lockstep with dashboard:
      // 1) Prefer explicit dashboard snapshot from parent when provided.
      // 2) Otherwise always read latest cached dashboard snapshot.
      if (widget.dashboardData != null && widget.dashboardData!.isNotEmpty) {
        if (mounted && loadGeneration == _reportLoadGeneration) {
          setState(() => _dashboardDataLocal = widget.dashboardData);
        } else {
          _dashboardDataLocal = widget.dashboardData;
        }
      } else if (normalizedProjectId.isNotEmpty) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final dashboardJson =
              prefs.getString('dashboard_data_$normalizedProjectId');
          if (dashboardJson != null && dashboardJson.trim().isNotEmpty) {
            final decoded = jsonDecode(dashboardJson);
            if (decoded is Map) {
              final dashboardMap = Map<String, dynamic>.from(
                decoded.cast<String, dynamic>(),
              );
              if (mounted && loadGeneration == _reportLoadGeneration) {
                setState(() => _dashboardDataLocal = dashboardMap);
              } else {
                _dashboardDataLocal = dashboardMap;
              }
            }
          }
        } catch (e) {
          debugPrint('Warning: Could not load dashboard data: $e');
        }
      }

      if (widget.projectData != null) {
        final scopedWidgetData = normalizedProjectId.isEmpty
            ? Map<String, dynamic>.from(widget.projectData!)
            : ProjectStorageService.coerceProjectScopedData(
                normalizedProjectId,
                widget.projectData!,
              );
        if (scopedWidgetData != null) {
          if (mounted && loadGeneration == _reportLoadGeneration) {
            setState(() => _projectData = scopedWidgetData);
          } else {
            _projectData = scopedWidgetData;
          }
          _buildLayoutIdNameMap();
        }
      } else if (normalizedProjectId.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final localEditMs =
            prefs.getInt('project_${normalizedProjectId}_last_local_edit_ms') ??
                0;
        final remoteSaveMs = prefs
                .getInt('project_${normalizedProjectId}_last_remote_save_ms') ??
            0;
        final hasUnsyncedLocalState = localEditMs > remoteSaveMs;

        var loadedFromLocal = false;
        final projectJson =
            prefs.getString('project_data_$normalizedProjectId');
        if (projectJson != null && projectJson.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(projectJson);
            final localMap = ProjectStorageService.coerceProjectScopedData(
              normalizedProjectId,
              decoded,
            );
            if (localMap != null) {
              if (mounted && loadGeneration == _reportLoadGeneration) {
                setState(() => _projectData = localMap);
              } else {
                _projectData = localMap;
              }
              _buildLayoutIdNameMap();
              loadedFromLocal = true;
            }
          } catch (_) {}
        }

        if (!hasUnsyncedLocalState || !loadedFromLocal) {
          final supabaseData = await ProjectStorageService.fetchProjectDataById(
            normalizedProjectId,
            forceRefresh: forceRefresh,
          );
          if (supabaseData != null) {
            if (mounted && loadGeneration == _reportLoadGeneration) {
              setState(() => _projectData = supabaseData);
            } else {
              _projectData = supabaseData;
            }
            _buildLayoutIdNameMap();
          }
        }
      } else {
        if (mounted && loadGeneration == _reportLoadGeneration) {
          setState(() => _projectData = <String, dynamic>{});
        } else {
          _projectData = <String, dynamic>{};
        }
        _buildLayoutIdNameMap();
      }

      if (normalizedProjectId.isNotEmpty &&
          await _hasUnsyncedLocalStateForReport(normalizedProjectId)) {
        await _applyUnsyncedLayoutDraftsForReport(normalizedProjectId);
      }
      if (normalizedProjectId.isNotEmpty) {
        await _overlayLocalLayoutsIfRicherForReport(normalizedProjectId);
      }

      if (normalizedProjectId.isNotEmpty && _projectData.isNotEmpty) {
        await _applyPendingCompensationDraftForReport(normalizedProjectId);
        await _applyPendingPartnerExpenseDraftForReport(normalizedProjectId);
        await _applyPlotStatusAmenityLocalOverlaysForReport(
          normalizedProjectId,
        );
      }
      _buildLayoutIdNameMap();
      await _primeReportHeaderFallbacks();
    } catch (e) {
      debugPrint('Error loading project data: $e');
    } finally {
      if (mounted && loadGeneration == _reportLoadGeneration) {
        setState(() {
          _isReportLoading = false;
        });
      }
    }
  }

  Future<bool> _hasUnsyncedLocalStateForReport(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return false;

    try {
      final prefs = await SharedPreferences.getInstance();
      final localEditMs =
          prefs.getInt('project_${normalizedProjectId}_last_local_edit_ms') ??
              0;
      final remoteSaveMs =
          prefs.getInt('project_${normalizedProjectId}_last_remote_save_ms') ??
              0;
      return localEditMs > remoteSaveMs;
    } catch (_) {
      return false;
    }
  }

  int _countReportPlotsFromData(Map<String, dynamic> data) {
    final layoutsRaw = data['layouts'];
    var layoutPlotsCount = 0;
    if (layoutsRaw is List) {
      for (final rawLayout in layoutsRaw) {
        if (rawLayout is! Map) continue;
        final layout = Map<String, dynamic>.from(rawLayout);
        final layoutPlots = layout['plots'];
        if (layoutPlots is List) {
          layoutPlotsCount += layoutPlots.length;
        }
      }
    }

    if (layoutPlotsCount > 0) return layoutPlotsCount;

    final topLevelPlots = data['plots'];
    if (topLevelPlots is List) return topLevelPlots.length;
    return 0;
  }

  List<Map<String, dynamic>> _flattenReportPlotsFromLayouts(
    List<Map<String, dynamic>> layouts,
  ) {
    final flattened = <Map<String, dynamic>>[];

    for (final layout in layouts) {
      final layoutName =
          (layout['name'] ?? layout['layoutName'] ?? layout['title'] ?? '')
              .toString()
              .trim();
      final layoutId =
          (layout['id'] ??
              layout['layoutId'] ??
              layout['_id'] ??
              layout['layout_id'] ??
              '')
              .toString()
              .trim();
      final rawPlots = layout['plots'];
      if (rawPlots is! List) continue;

      for (final rawPlot in rawPlots.whereType<Map>()) {
        final plot = Map<String, dynamic>.from(rawPlot);
        if (layoutName.isNotEmpty) {
          if ((plot['layout'] ?? '').toString().trim().isEmpty) {
            plot['layout'] = layoutName;
          }
          if ((plot['layoutName'] ?? '').toString().trim().isEmpty) {
            plot['layoutName'] = layoutName;
          }
        }
        if (layoutId.isNotEmpty) {
          if ((plot['layout_id'] ?? '').toString().trim().isEmpty) {
            plot['layout_id'] = layoutId;
          }
          if ((plot['layoutId'] ?? '').toString().trim().isEmpty) {
            plot['layoutId'] = layoutId;
          }
        }
        flattened.add(plot);
      }
    }

    return flattened;
  }

  Future<void> _applyUnsyncedLayoutDraftsForReport(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;

    try {
      final localLayouts = await LayoutStorageService.loadLayoutsData(
        projectKey: normalizedProjectId,
      );
      if (localLayouts.isEmpty) return;

      final flattenedPlots = _flattenReportPlotsFromLayouts(localLayouts);
      _projectData = Map<String, dynamic>.from(_projectData);
      _projectData['layouts'] = localLayouts;
      if (flattenedPlots.isNotEmpty) {
        _projectData['plots'] = flattenedPlots;
      }
      _buildLayoutIdNameMap();
    } catch (e) {
      debugPrint(
        'Warning: Could not apply unsynced local layouts for report: $e',
      );
    }
  }

  Future<void> _overlayLocalLayoutsIfRicherForReport(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;

    try {
      final localLayouts = await LayoutStorageService.loadLayoutsData(
        projectKey: normalizedProjectId,
      );
      if (localLayouts.isEmpty) return;

      final flattenedPlots = _flattenReportPlotsFromLayouts(localLayouts);
      final localPlotCount = flattenedPlots.length;
      final currentPlotCount = _countReportPlotsFromData(_projectData);
      if (localPlotCount <= 0 || localPlotCount <= currentPlotCount) {
        return;
      }

      _projectData = Map<String, dynamic>.from(_projectData);
      _projectData['layouts'] = localLayouts;
      _projectData['plots'] = flattenedPlots;
      _buildLayoutIdNameMap();
    } catch (_) {
      // Best-effort overlay only.
    }
  }

  Future<void> _primeReportHeaderFallbacks() async {
    final projectId = (widget.projectId ?? '').trim();
    var fallbackName = _readStringFromMap(_projectData, const [
      'projectName',
      'project_name',
      'name',
      'project',
      'project_title',
      'title',
    ]);
    var fallbackLocation = _readStringFromMap(_projectData, const [
      'projectAddress',
      'project_address',
      'projectLocation',
      'project_location',
      'location',
      'address',
      'google_maps_link',
      'googleMapsLink',
      'maps_link',
      'mapsLink',
      'location_link',
      'locationLink',
    ]);

    try {
      final prefs = await SharedPreferences.getInstance();
      if (fallbackName.isEmpty) {
        fallbackName = (prefs.getString('nav_project_name') ?? '').trim();
      }
      if (fallbackLocation.isEmpty && projectId.isNotEmpty) {
        final about = await LayoutStorageService.loadProjectAbout(
          projectKey: projectId,
        );
        final address = (about['address'] ?? '').trim();
        final mapsLink = (about['mapsLink'] ?? '').trim();
        fallbackLocation = address.isNotEmpty ? address : mapsLink;
      }
    } catch (_) {}

    if (!mounted) {
      _reportProjectNameFallback = fallbackName;
      _reportProjectLocationFallback = fallbackLocation;
      return;
    }

    setState(() {
      _reportProjectNameFallback = fallbackName;
      _reportProjectLocationFallback = fallbackLocation;
    });
  }

  String _readStringFromMap(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (!map.containsKey(key)) continue;
      final raw = map[key];
      if (raw == null) continue;
      final value = raw.toString().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  bool _isSvgFileNameForReport(String fileName) {
    return fileName.trim().toLowerCase().endsWith('.svg');
  }

  String _reportCoverProjectName() {
    final resolved = _readStringFromMap(_projectData, [
      'projectName',
      'project_name',
      'name',
      'project',
      'project_title',
      'title',
    ]);
    if (resolved.trim().isNotEmpty) return resolved;
    return _reportProjectNameFallback;
  }

  String _reportCoverProjectLocation() {
    final resolved = _readStringFromMap(_projectData, [
      'projectAddress',
      'project_address',
      'projectLocation',
      'project_location',
      'location',
      'address',
      'google_maps_link',
      'googleMapsLink',
      'maps_link',
      'mapsLink',
      'location_link',
      'locationLink',
    ]);
    if (resolved.trim().isNotEmpty) return resolved;
    return _reportProjectLocationFallback;
  }

  String _coverValueOrDash(String value) {
    return value.trim().isEmpty ? '—' : value.trim();
  }

  String _formatCoverDate(DateTime value) {
    final day = value.day.toString().padLeft(2, '0');
    final month = value.month.toString().padLeft(2, '0');
    final year = value.year.toString();
    return '$day/$month/$year';
  }

  dynamic _readSaleDateValueForReport(Map<String, dynamic> row) {
    for (final key in const [
      'saleDate',
      'dateOfSale',
      'sale_date',
      'date_of_sale',
    ]) {
      if (!row.containsKey(key) || row[key] == null) continue;
      final value = row[key];
      if (value is String && value.trim().isEmpty) continue;
      return value;
    }
    return '';
  }

  String _saleDateLabelForReport(Map<String, dynamic> row) {
    return _formatReportDateValue(_readSaleDateValueForReport(row));
  }

  String _formatReportDateValue(dynamic value) {
    if (value == null) return '-';
    final raw = value.toString().trim();
    if (raw.isEmpty || raw == '-' || raw == '—') return '-';

    String asDdMmYyyy(int day, int month, int year) {
      final dd = day.toString().padLeft(2, '0');
      final mm = month.toString().padLeft(2, '0');
      final yyyy = year.toString().padLeft(4, '0');
      return '$dd/$mm/$yyyy';
    }

    final dmyMatch =
        RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$').firstMatch(raw);
    if (dmyMatch != null) {
      final day = int.tryParse(dmyMatch.group(1) ?? '');
      final month = int.tryParse(dmyMatch.group(2) ?? '');
      final yearRaw = dmyMatch.group(3) ?? '';
      final parsedYear = int.tryParse(yearRaw);
      if (day != null && month != null && parsedYear != null) {
        final year = yearRaw.length == 2 ? (2000 + parsedYear) : parsedYear;
        if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
          return asDdMmYyyy(day, month, year);
        }
      }
    }

    final ymdMatch =
        RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T\s].*)?$').firstMatch(raw);
    if (ymdMatch != null) {
      final year = int.tryParse(ymdMatch.group(1) ?? '');
      final month = int.tryParse(ymdMatch.group(2) ?? '');
      final day = int.tryParse(ymdMatch.group(3) ?? '');
      if (year != null &&
          month != null &&
          day != null &&
          month >= 1 &&
          month <= 12 &&
          day >= 1 &&
          day <= 31) {
        return asDdMmYyyy(day, month, year);
      }
    }

    final ymdSlashMatch =
        RegExp(r'^(\d{4})/(\d{1,2})/(\d{1,2})(?:[T\s].*)?$').firstMatch(raw);
    if (ymdSlashMatch != null) {
      final year = int.tryParse(ymdSlashMatch.group(1) ?? '');
      final month = int.tryParse(ymdSlashMatch.group(2) ?? '');
      final day = int.tryParse(ymdSlashMatch.group(3) ?? '');
      if (year != null &&
          month != null &&
          day != null &&
          month >= 1 &&
          month <= 12 &&
          day >= 1 &&
          day <= 31) {
        return asDdMmYyyy(day, month, year);
      }
    }

    final epoch = int.tryParse(raw);
    if (epoch != null) {
      final isSecondsEpoch = raw.length <= 10;
      final millis = isSecondsEpoch ? epoch * 1000 : epoch;
      final dt = DateTime.fromMillisecondsSinceEpoch(millis);
      return asDdMmYyyy(dt.day, dt.month, dt.year);
    }

    final parsed = DateTime.tryParse(raw);
    if (parsed != null) {
      return asDdMmYyyy(parsed.day, parsed.month, parsed.year);
    }

    return raw;
  }

  Widget _buildCoverDotPattern({
    required int rows,
    int columns = 24,
    double rowSpacing = 10,
    double dotSize = 1.4,
  }) {
    return Column(
      children: List.generate(rows, (rowIndex) {
        return Padding(
          padding:
              EdgeInsets.only(bottom: rowIndex == rows - 1 ? 0 : rowSpacing),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(columns, (_) {
              return Container(
                width: dotSize,
                height: dotSize,
                decoration: const BoxDecoration(
                  color: Color(0xFF404040),
                  shape: BoxShape.circle,
                ),
              );
            }),
          ),
        );
      }),
    );
  }

  Widget _buildCoverLogo({
    required double width,
    required double height,
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.centerLeft,
  }) {
    if (_reportIdentityLogoSvg != null &&
        _reportIdentityLogoSvg!.trim().isNotEmpty) {
      return SvgPicture.string(
        _reportIdentityLogoSvg!,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );
    }
    if (_reportIdentityLogoBytes != null &&
        _reportIdentityLogoBytes!.isNotEmpty) {
      return Image.memory(
        _reportIdentityLogoBytes!,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
      );
    }
    return const SizedBox.shrink();
  }

  Future<void> _loadReportIdentitySettings() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    try {
      final row = await Supabase.instance.client
          .from('account_report_identity_settings')
          .select(
              'full_name, organization, role, logo_storage_path, logo_svg, logo_base64, logo_file_name')
          .eq('user_id', userId)
          .maybeSingle();

      if (!mounted || row == null) return;

      final fullName = (row['full_name'] ?? '').toString().trim();
      final organization = (row['organization'] ?? '').toString().trim();
      final role = (row['role'] ?? '').toString().trim();
      final logoStoragePath =
          (row['logo_storage_path'] ?? '').toString().trim();
      final legacyLogoSvg = (row['logo_svg'] ?? '').toString().trim();
      final legacyLogoBase64 = (row['logo_base64'] ?? '').toString().trim();
      final logoFileName = (row['logo_file_name'] ?? '').toString().trim();

      Uint8List? logoBytes;
      String? logoSvg;

      if (logoStoragePath.isNotEmpty) {
        try {
          final downloadedLogoBytes = await Supabase.instance.client.storage
              .from(_reportIdentityLogoBucket)
              .download(logoStoragePath);
          if (_isSvgFileNameForReport(
              logoFileName.isNotEmpty ? logoFileName : logoStoragePath)) {
            final decodedSvg =
                utf8.decode(downloadedLogoBytes, allowMalformed: true).trim();
            if (decodedSvg.isNotEmpty) {
              logoSvg = decodedSvg;
            } else {
              logoBytes = downloadedLogoBytes;
            }
          } else {
            logoBytes = downloadedLogoBytes;
          }
        } catch (error) {
          print(
              'ReportPage: failed to download report logo from storage: $error');
        }
      }

      if (logoSvg == null &&
          (logoBytes == null || logoBytes.isEmpty) &&
          legacyLogoBase64.isNotEmpty) {
        try {
          logoBytes = base64Decode(legacyLogoBase64);
        } catch (_) {
          logoBytes = null;
        }
      }

      if (logoSvg == null &&
          (logoBytes == null || logoBytes.isEmpty) &&
          legacyLogoSvg.isNotEmpty) {
        logoSvg = legacyLogoSvg;
      }

      if (!mounted) return;
      setState(() {
        _reportIdentityFullName = fullName;
        _reportIdentityOrganization = organization;
        _reportIdentityRole = role;
        _reportIdentityLogoSvg = logoSvg;
        _reportIdentityLogoBytes = logoBytes;
      });
    } catch (error) {
      print('ReportPage: failed to load report identity settings: $error');
    }
  }

  void _buildLayoutIdNameMap() {
    _layoutIdNameMap.clear();
    if (_projectData.isEmpty) return;
    // Common keys that may hold layouts as list
    final candidateKeys = [
      'layouts',
      'layoutList',
      'layouts_list',
      'layoutsData',
      'layoutsDataList',
      'layoutsInfo'
    ];
    for (final key in candidateKeys) {
      if (_projectData.containsKey(key) && _projectData[key] is List) {
        final list = _projectData[key] as List;
        for (final item in list) {
          if (item is Map) {
            final id = item['id'] ?? item['layout_id'] ?? item['_id'];
            final idx = item['idx'] ?? item['index'];
            final name = item['name'] ??
                item['layoutName'] ??
                item['title'] ??
                item['label'];
            if (id != null && name != null) {
              _layoutIdNameMap[id.toString()] = name.toString();
              // also index by a normalized id (no dashes, lowercase) and by numeric idx
              _layoutIdNameMap[id
                  .toString()
                  .replaceAll('-', '')
                  .toLowerCase()] = name.toString();
            }
            if ((idx != null) && name != null) {
              _layoutIdNameMap[idx.toString()] = name.toString();
            }
          }
        }
      }
    }
    // Generic scan: any list of maps that contains id+name
    for (final entry in _projectData.entries) {
      final val = entry.value;
      if (val is List && val.isNotEmpty && val.first is Map) {
        for (final item in val) {
          if (item is Map) {
            final id = item['id'] ?? item['layout_id'] ?? item['_id'];
            final idx = item['idx'] ?? item['index'];
            final name = item['name'] ??
                item['layoutName'] ??
                item['title'] ??
                item['label'];
            if (id != null && name != null) {
              _layoutIdNameMap[id.toString()] = name.toString();
              _layoutIdNameMap[id
                  .toString()
                  .replaceAll('-', '')
                  .toLowerCase()] = name.toString();
            }
            if ((idx != null) && name != null) {
              _layoutIdNameMap[idx.toString()] = name.toString();
            }
          }
        }
      }
    }
  }

  Widget _buildReportOption({
    required String label,
    bool checked = false,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: checked ? const Color(0xFFF5FAFE) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 2,
              spreadRadius: 0,
              offset: const Offset(0, 0),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: checked
                        ? const Color(0xFF0C8CE9)
                        : Colors.black.withOpacity(0.25),
                    blurRadius: 2,
                    spreadRadius: 0,
                    offset: const Offset(0, 0),
                  ),
                ],
              ),
              child: checked
                  ? SvgPicture.asset(
                      'assets/images/Selected.svg',
                      width: 14,
                      height: 14,
                      fit: BoxFit.contain,
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black.withOpacity(0.75),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderRefreshButton(VoidCallback onTap) {
    return HeaderRefreshButton(onTap: onTap);
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final scaleMetrics = AppScaleMetrics.of(context);
    final tabLineWidth = (scaleMetrics?.designViewportWidth ?? screenWidth) +
        (scaleMetrics?.rightOverflowWidth ?? 0.0);
    final extraTabLineWidth =
        tabLineWidth > screenWidth ? tabLineWidth - screenWidth : 0.0;

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 24, right: 24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Report',
                                style: GoogleFonts.inter(
                                  fontSize: 32,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black,
                                ),
                              ),
                              const SizedBox(width: 12),
                              _buildHeaderRefreshButton(() {
                                unawaited(_loadProjectData(forceRefresh: true));
                                unawaited(_loadReportIdentitySettings());
                              }),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Generate structured reports for financial, sales, and project performance insights.',
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.normal,
                              color: Colors.black.withOpacity(0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 32,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: -extraTabLineWidth,
                  bottom: 0,
                  child: Container(
                    height: 0.5,
                    color: const Color(0xFF5C5C5C),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Color(0xFF0C8CE9),
                              width: 2,
                            ),
                          ),
                        ),
                        child: Center(
                          child: Text(
                            'Reports',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF0C8CE9),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 36),
                      const SizedBox(
                        height: 32,
                        width: 49,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 40),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _isReportLoading
                  ? _buildReportLoadingSkeleton()
                  : _buildReportContentPanels(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportContentPanels() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 344,
          child: _buildSelectPanel(),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildPreviewPanel(),
        ),
      ],
    );
  }

  Widget _buildSkeletonBlock({
    double width = double.infinity,
    required double height,
    BorderRadius? borderRadius,
  }) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFE7E7E7),
        borderRadius: borderRadius ?? BorderRadius.circular(8),
      ),
    );
  }

  Widget _buildReportLoadingSkeleton() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 344,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 2,
                  spreadRadius: 0,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSkeletonBlock(width: 184, height: 24),
                const SizedBox(height: 8),
                _buildSkeletonBlock(width: 228, height: 14),
                const SizedBox(height: 24),
                _buildSkeletonBlock(height: 40),
                const SizedBox(height: 16),
                _buildSkeletonBlock(height: 40),
                const SizedBox(height: 16),
                _buildSkeletonBlock(height: 40),
                const SizedBox(height: 16),
                _buildSkeletonBlock(height: 40),
                const SizedBox(height: 16),
                _buildSkeletonBlock(height: 40),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 2,
                  spreadRadius: 0,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _buildSkeletonBlock(width: 98, height: 24),
                      const Spacer(),
                      _buildSkeletonBlock(width: 40, height: 40),
                      const SizedBox(width: 8),
                      _buildSkeletonBlock(width: 48, height: 20),
                      const SizedBox(width: 8),
                      _buildSkeletonBlock(width: 40, height: 40),
                      const SizedBox(width: 24),
                      _buildSkeletonBlock(width: 96, height: 44),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 242,
                          decoration: BoxDecoration(
                            color: const Color(0xFFF8F9FA),
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.25),
                                blurRadius: 2,
                                spreadRadius: 0,
                                offset: const Offset(0, 0),
                              ),
                            ],
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: List.generate(
                                5,
                                (index) => Padding(
                                  padding: EdgeInsets.only(
                                      bottom: index == 4 ? 0 : 12),
                                  child: _buildSkeletonBlock(height: 100),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8F9FA),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.25),
                                  blurRadius: 2,
                                  spreadRadius: 0,
                                  offset: const Offset(0, 0),
                                ),
                              ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child:
                                  _buildSkeletonBlock(height: double.infinity),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectPanel() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 2,
                  spreadRadius: 0,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Select Type of Report',
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Select sections or generate full detailed report.',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black.withOpacity(0.8),
                  ),
                ),
                const SizedBox(height: 24),
                _buildReportOption(
                  label: 'Full Detailed Report',
                  checked: true,
                  onTap: null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProjectAreaUnitPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 2,
            spreadRadius: 0,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Select Project Area Unit',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 16),
          _buildAreaUnitOption(
            label: 'Square Feet (sqft)',
            selected: !_isSqm,
            onTap: () async {
              setState(() {
                _areaUnit = 'Square Feet (sqft)';
              });
              await AreaUnitService.setAreaUnit(widget.projectId, _areaUnit);
            },
          ),
          const SizedBox(height: 16),
          _buildAreaUnitOption(
            label: 'Square Meter (sqm)',
            selected: _isSqm,
            onTap: () async {
              setState(() {
                _areaUnit = 'Square Meter (sqm)';
              });
              await AreaUnitService.setAreaUnit(widget.projectId, _areaUnit);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAreaUnitOption({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF5FAFE) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 2,
              spreadRadius: 0,
              offset: const Offset(0, 0),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                boxShadow: [
                  BoxShadow(
                    color: selected
                        ? const Color(0xFF0C8CE9)
                        : Colors.black.withOpacity(0.25),
                    blurRadius: 2,
                    spreadRadius: 0,
                    offset: const Offset(0, 0),
                  ),
                ],
              ),
              child: selected
                  ? SvgPicture.asset(
                      'assets/images/Selected.svg',
                      width: 14,
                      height: 14,
                      fit: BoxFit.contain,
                    )
                  : null,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black.withOpacity(0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewPanel() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 2,
            spreadRadius: 0,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with Preview title, Zoom controls, and Print button
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Title
                Text(
                  'Preview',
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
                // Right side: Zoom controls and Print button
                Row(
                  children: [
                    // Zoom controls
                    Row(
                      children: [
                        Text(
                          'Zoom:',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Zoom out button
                        GestureDetector(
                          onTap: () => _handlePreviewControlTap(
                            'report_zoom_out',
                            () => _changePreviewZoom(-_previewZoomStep),
                          ),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: _previewControlBackground(
                                    'report_zoom_out'),
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.25),
                                    blurRadius: 2,
                                    spreadRadius: 0,
                                    offset: const Offset(0, 0),
                                  ),
                                ],
                              ),
                              child: SvgPicture.asset(
                                'assets/icons/zoom_out.svg',
                                width: 40,
                                height: 40,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Zoom percentage
                        SizedBox(
                          width: 48,
                          child: Center(
                            child: Text(
                              '${(_previewZoom * 100).round()}%',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.normal,
                                color: Colors.black.withOpacity(0.75),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Zoom in button
                        GestureDetector(
                          onTap: () => _handlePreviewControlTap(
                            'report_zoom_in',
                            () => _changePreviewZoom(_previewZoomStep),
                          ),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color:
                                    _previewControlBackground('report_zoom_in'),
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.25),
                                    blurRadius: 2,
                                    spreadRadius: 0,
                                    offset: const Offset(0, 0),
                                  ),
                                ],
                              ),
                              child: SvgPicture.asset(
                                'assets/icons/zoom_in.svg',
                                width: 40,
                                height: 40,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 24),
                    // Print button
                    GestureDetector(
                      onTap: _isPrintingReport ? null : _handlePrintPressed,
                      child: MouseRegion(
                        cursor: _isPrintingReport
                            ? SystemMouseCursors.basic
                            : SystemMouseCursors.click,
                        child: Container(
                          height: 44,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          decoration: BoxDecoration(
                            color: _isPrintingReport
                                ? const Color(0xFFF5F5F5)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.25),
                                blurRadius: 2,
                                spreadRadius: 0,
                                offset: const Offset(0, 0),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Text(
                                _isPrintingReport ? 'Printing...' : 'Print',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.normal,
                                  color: Colors.black,
                                ),
                              ),
                              const SizedBox(width: 20),
                              SvgPicture.asset(
                                'assets/icons/print.svg',
                                width: 16,
                                height: 16,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Content area: Thumbnails on left, main preview on right
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Thumbnails column - fills available height
                    SizedBox(
                      width: 242,
                      height: double.infinity,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8F9FA),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.25),
                              blurRadius: 2,
                              spreadRadius: 0,
                              offset: const Offset(0, 0),
                            ),
                          ],
                        ),
                        child: Builder(
                          builder: (context) {
                            final previewPages =
                                _buildAllReportPagesForPreview();
                            return SingleChildScrollView(
                              controller: _thumbnailScrollController,
                              child: Column(
                                children: previewPages.isEmpty
                                    ? [_buildPageThumbnail(1)]
                                    : List<Widget>.generate(
                                        previewPages.length,
                                        (index) => _buildPageThumbnail(
                                          index + 1,
                                          preview: previewPages[index],
                                          isSelected: _currentPage == index + 1,
                                        ),
                                      ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Main preview area
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8F9FA),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.25),
                              blurRadius: 2,
                              spreadRadius: 0,
                              offset: const Offset(0, 0),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            // A4 Page preview container - scrollable
                            Expanded(
                              child: Container(
                                color: const Color(0xFFF8F9FA),
                                padding: const EdgeInsets.all(8),
                                child: SingleChildScrollView(
                                  controller: _mainPreviewScrollController,
                                  child: Center(
                                    child: _buildPaginatedReportPreview(),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageThumbnail(int pageNum,
      {bool isSelected = false, Widget? preview}) {
    return GestureDetector(
      onTap: () => _scrollMainPreviewToPage(pageNum),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFF1F1F1) : const Color(0xFFF8F9FA),
          border: isSelected
              ? const Border(bottom: BorderSide(color: Color(0xFFE0E0E0)))
              : null,
        ),
        child: Row(
          children: [
            Text(
              '$pageNum',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black.withOpacity(0.75),
              ),
            ),
            const Spacer(),
            Container(
              width: 71,
              height: 100,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFF0C8CE9)
                      : Colors.black.withOpacity(0.25),
                  width: isSelected ? 2 : 0.5,
                ),
              ),
              child: ClipRect(
                child: preview == null
                    ? const SizedBox.shrink()
                    : FittedBox(
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: 595,
                          height: 842,
                          child: preview,
                        ),
                      ),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  // Helper function to format numbers to 2 decimal places
  String _formatTo2Decimals(dynamic value) {
    if (value == null) return '—';
    final raw = value.toString().trim();
    if (raw.isEmpty || raw == '-' || raw == '—') return '—';
    final numValue = double.tryParse(raw);
    if (numValue == null) return '—';
    if (numValue == 0) return '—';
    return numValue.toStringAsFixed(2);
  }

  double _readMetricFromReportSources(
    List<String> keys, {
    double fallback = 0.0,
  }) {
    for (final key in keys) {
      if (_dashboardDataLocal != null &&
          _dashboardDataLocal!.containsKey(key)) {
        return _toDouble(_dashboardDataLocal![key]);
      }
      if (_projectData.containsKey(key)) {
        return _toDouble(_projectData[key]);
      }
    }
    return fallback;
  }

  dynamic _readValueFromDashboardThenProject(
    List<String> keys, {
    dynamic fallback,
  }) {
    for (final key in keys) {
      if (_dashboardDataLocal != null &&
          _dashboardDataLocal!.containsKey(key) &&
          _dashboardDataLocal![key] != null) {
        return _dashboardDataLocal![key];
      }
      if (_projectData.containsKey(key) && _projectData[key] != null) {
        return _projectData[key];
      }
    }
    return fallback;
  }

  String _normalizeSiteStatusForReport(dynamic rawStatus) {
    final statusTokens = (rawStatus ?? '')
        .toString()
        .trim()
        .toLowerCase()
        .split(RegExp(r'[^a-z]+'))
        .where((token) => token.isNotEmpty)
        .toSet();
    if (statusTokens.contains('reserved') ||
        statusTokens.contains('pending') ||
        statusTokens.contains('blocked')) {
      return 'pending';
    }
    if (statusTokens.contains('sold')) return 'sold';
    return 'available';
  }

  double _computeTotalExpensesForReport() {
    return _readMetricFromReportSources(
      ['totalExpenses', 'total_expenses'],
    );
  }

  double _computeAllInCostPerSqftForReport() {
    final totalExpenses = _computeTotalExpensesForReport();
    final sellingArea = _readMetricFromReportSources(
      ['sellingArea', 'selling_area'],
    );
    if (sellingArea > 0) {
      return totalExpenses / sellingArea;
    }
    return _readMetricFromReportSources(
      ['allInCost', 'all_in_cost'],
    );
  }

  double _computeSiteTotalSalesValueForReport() {
    final plots = _collectReportPlotsForOverview();
    if (plots.isEmpty) {
      return _readMetricFromReportSources(
        ['totalSalesValue', 'total_sales_value'],
      );
    }

    var totalSalesValue = 0.0;
    for (final plot in plots) {
      final status = _normalizeSiteStatusForReport(plot['status']);
      if (status != 'sold') continue;
      final area = _plotFieldDouble(plot, ['area', 'plot_area', 'plotArea']);
      final salePrice = _plotFieldDouble(plot, [
        'sale_price',
        'salePrice',
        'sale_price_per_sqft',
        'salePricePerSqft'
      ]);
      totalSalesValue += salePrice * area;
    }
    return totalSalesValue;
  }

  double _computeSiteGrossProfitForReport() {
    final plots = _collectReportPlotsForOverview();
    if (plots.isEmpty) {
      final totalSalesValue = _readMetricFromReportSources(
        ['totalSalesValue', 'total_sales_value'],
      );
      return totalSalesValue - _computeTotalExpensesForReport();
    }

    final allInCost = _computeAllInCostPerSqftForReport();
    var totalSalesValue = 0.0;
    var totalPlotCost = 0.0;

    for (final plot in plots) {
      final area = _plotFieldDouble(plot, ['area', 'plot_area', 'plotArea']);
      totalPlotCost += area * allInCost;

      final status = _normalizeSiteStatusForReport(plot['status']);
      if (status != 'sold' && status != 'pending') continue;

      final salePrice = _plotFieldDouble(plot, [
        'sale_price',
        'salePrice',
        'sale_price_per_sqft',
        'salePricePerSqft'
      ]);
      totalSalesValue += salePrice * area;
    }

    return totalSalesValue - totalPlotCost;
  }

  double _computeSoldAmenitySalesValueForReport() {
    final amenityRows = _collectAmenityAreasForReport();
    if (amenityRows.isEmpty) {
      return _readMetricFromReportSources(
        ['totalSoldAmenitySalesValue', 'total_sold_amenity_sales_value'],
      );
    }
    return amenityRows
        .where((row) => _amenityStatusForReport(row) == 'sold')
        .fold<double>(
          0.0,
          (sum, row) => sum + _amenitySaleValueForReport(row),
        );
  }

  double _computeAmenityGrossProfitForReport() {
    final amenityRows = _collectAmenityAreasForReport();
    if (amenityRows.isEmpty) return 0.0;

    final totalSoldSaleValue = amenityRows.where((row) {
      final status = _amenityStatusForReport(row);
      return status == 'sold' || status == 'pending';
    }).fold<double>(
      0.0,
      (sum, row) => sum + _amenitySaleValueForReport(row),
    );
    final totalPlotCost = amenityRows.fold<double>(
      0.0,
      (sum, row) =>
          sum +
          (_amenityAreaSqftForReport(row) *
              _amenityAllInCostSqftForReport(row)),
    );
    return totalSoldSaleValue - totalPlotCost;
  }

  double _computeOverviewGrossProfitForReport() {
    return _computeSiteGrossProfitForReport() +
        _computeAmenityGrossProfitForReport();
  }

  double _computeDisplayedTotalAgentsCompensationForReport() {
    final agents = _reportAgentsForReport();
    if (agents.isEmpty) {
      return _readMetricFromReportSources(
        ['totalAgentCompensation', 'total_agent_compensation'],
      );
    }

    return agents.fold<double>(0.0, (sum, agent) {
      return sum + math.max(0.0, _calculateAgentEarningsReport(agent));
    });
  }

  double _computeDisplayedTotalProjectManagersCompensationForReport() {
    final managersRaw = (_projectData['project_managers'] ??
            _projectData['projectManagers']) as List<dynamic>? ??
        [];
    if (managersRaw.isEmpty) {
      return _readMetricFromReportSources([
        'totalProjectManagerCompensation',
        'totalPMCompensation',
        'total_project_manager_compensation',
      ]);
    }

    return managersRaw.fold<double>(0.0, (sum, rawManager) {
      if (rawManager is! Map) return sum;
      final manager = Map<String, dynamic>.from(rawManager);
      return sum +
          math.max(0.0, _calculateProjectManagerEarningsReport(manager));
    });
  }

  double _computeOverviewTotalCompensationForReport() {
    return _computeDisplayedTotalAgentsCompensationForReport() +
        _computeDisplayedTotalProjectManagersCompensationForReport();
  }

  double _computeOverviewNetProfitForReport() {
    final grossProfit = _computeOverviewGrossProfitForReport();
    final totalAgentEarnings =
        _computeDisplayedTotalAgentsCompensationForReport();
    final totalProjectManagerEarnings =
        _computeDisplayedTotalProjectManagersCompensationForReport();
    return (grossProfit - totalAgentEarnings) - totalProjectManagerEarnings;
  }

  double _safePercentForReport(double numerator, double denominator) {
    if (denominator == 0 || !denominator.isFinite) return 0.0;
    final value = (numerator / denominator) * 100;
    if (value.isNaN || value.isInfinite) return 0.0;
    return value;
  }

  double _computeTotalRevenueForReport() {
    return _computeSiteTotalSalesValueForReport() +
        _computeSoldAmenitySalesValueForReport();
  }

  double _computeProfitMarginForReport() {
    final totalRevenue = _computeTotalRevenueForReport();
    final totalExpenses = _computeTotalExpensesForReport();
    final netProfit = _computeOverviewNetProfitForReport();
    final denominator = totalRevenue != 0
        ? totalRevenue
        : (totalExpenses != 0 ? totalExpenses : 0.0);
    return _safePercentForReport(netProfit, denominator);
  }

  double _computeRoiForReport() {
    final totalExpenses = _computeTotalExpensesForReport();
    final netProfit = _computeOverviewNetProfitForReport();
    return _safePercentForReport(netProfit, totalExpenses);
  }

  double? _readMetricIfPresentFromDashboard(List<String> keys) {
    if (_dashboardDataLocal == null || _dashboardDataLocal!.isEmpty) {
      return null;
    }
    for (final key in keys) {
      if (!_dashboardDataLocal!.containsKey(key)) continue;
      final raw = _dashboardDataLocal![key];
      if (raw == null) continue;
      return _toDouble(raw);
    }
    return null;
  }

  // Get or calculate dashboard values
  // If dashboard data available, use it directly
  // If not, use pre-calculated values from project data
  String getDashboardValue(String key, [dynamic defaultValue]) {
    final dashboardMetricKeys = <String, List<String>>{
      'profitMargin': ['profitMargin', 'profit_margin'],
      'totalRevenue': ['totalRevenue', 'total_revenue'],
      'grossProfit': ['grossProfit', 'gross_profit'],
      'netProfit': ['netProfit', 'net_profit'],
      'roi': ['roi'],
      'totalSalesValue': ['totalSalesValue', 'total_sales_value'],
      'totalAgentCompensation': [
        'totalAgentCompensation',
        'total_agent_compensation',
      ],
      'totalProjectManagerCompensation': [
        'totalProjectManagerCompensation',
        'totalPMCompensation',
        'total_project_manager_compensation',
      ],
      'totalPMCompensation': [
        'totalProjectManagerCompensation',
        'totalPMCompensation',
        'total_project_manager_compensation',
      ],
      'totalCompensation': ['totalCompensation', 'total_compensation'],
      'avgSalePricePerSqft': [
        'avgSalePricePerSqft',
        'avgSalesPrice',
        'avg_sale_price_per_sqft',
      ],
    };

    final dashboardKeys = dashboardMetricKeys[key];
    if (dashboardKeys != null) {
      final dashboardValue = _readMetricIfPresentFromDashboard(dashboardKeys);
      if (dashboardValue != null) {
        return _formatTo2Decimals(dashboardValue);
      }
    }

    if (key == 'profitMargin') {
      return _formatTo2Decimals(_computeProfitMarginForReport());
    }
    if (key == 'totalRevenue') {
      return _formatTo2Decimals(_computeTotalRevenueForReport());
    }
    if (key == 'grossProfit') {
      return _formatTo2Decimals(_computeOverviewGrossProfitForReport());
    }
    if (key == 'netProfit') {
      return _formatTo2Decimals(_computeOverviewNetProfitForReport());
    }
    if (key == 'roi') {
      return _formatTo2Decimals(_computeRoiForReport());
    }
    if (key == 'totalSalesValue') {
      return _formatTo2Decimals(_computeSiteTotalSalesValueForReport());
    }
    if (key == 'totalAgentCompensation') {
      return _formatTo2Decimals(
          _computeDisplayedTotalAgentsCompensationForReport());
    }
    if (key == 'totalProjectManagerCompensation' ||
        key == 'totalPMCompensation') {
      return _formatTo2Decimals(
        _computeDisplayedTotalProjectManagersCompensationForReport(),
      );
    }
    if (key == 'totalCompensation') {
      return _formatTo2Decimals(_computeOverviewTotalCompensationForReport());
    }

    switch (key) {
      case 'totalPMCompensation':
        final value = _readValueFromDashboardThenProject(
          const [
            'totalProjectManagerCompensation',
            'totalPMCompensation',
            'total_project_manager_compensation',
          ],
          fallback: defaultValue,
        );
        return _formatTo2Decimals(value);

      case 'avgSalePricePerSqft':
        final value = _readValueFromDashboardThenProject(
          const ['avgSalePricePerSqft', 'avgSalesPrice'],
          fallback: defaultValue,
        );
        return _formatTo2Decimals(value);

      default:
        final value = _readValueFromDashboardThenProject(
          [key],
          fallback: defaultValue,
        );
        return _formatTo2Decimals(value);
    }
  }

  List<Widget> _buildReportPage7Pages({required int startPageNumber}) {
    final allPlots = _collectReportPlotsForOverview();
    final partnersRaw = _projectData['partners'] as List<dynamic>? ?? [];
    final partners = partnersRaw
        .map((p) =>
            p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{})
        .toList();

    if (partners.isEmpty) {
      final names = <String>{};
      for (final plot in allPlots) {
        final partnerNames = _partnerNamesFromPlotForReport(plot);
        for (final name in partnerNames) {
          if (name.trim().isEmpty) continue;
          names.add(name.trim());
        }
      }
      for (final name in names) {
        partners.add({'name': name});
      }
    }

    if (partners.isEmpty) {
      return [
        _buildReportPage7(
          pageNumber: startPageNumber,
          startPartnerIndex: 0,
          partnerLimit: 0,
          showTotals: true,
        ),
      ];
    }

    final plotIdToNumber = <String, String>{};
    final plotIdToLayout = <String, String>{};
    for (final plot in allPlots) {
      final id = _plotIdStringForReport(plot);
      final normalizedId = _normalizePlotIdentityForReport(id);
      final number = _plotFieldStr(
          plot, ['plotNumber', 'plot_no', 'plotNo', 'number', 'plot_number']);
      final normalizedNumber = _normalizePlotIdentityForReport(number);
      final layout = _resolveLayoutLabel(plot);
      if (id.isNotEmpty && number.isNotEmpty && number != '-') {
        plotIdToNumber[id] = number;
        if (normalizedId.isNotEmpty) {
          plotIdToNumber[normalizedId] = number;
        }
      }
      if (number.isNotEmpty && number != '-') {
        plotIdToNumber[number] = number;
        if (normalizedNumber.isNotEmpty) {
          plotIdToNumber[normalizedNumber] = number;
        }
      }
      if (id.isNotEmpty) {
        plotIdToLayout[id] = layout;
        if (normalizedId.isNotEmpty) {
          plotIdToLayout[normalizedId] = layout;
        }
      }
      if (number.isNotEmpty && number != '-') {
        plotIdToLayout[number] = layout;
        if (normalizedNumber.isNotEmpty) {
          plotIdToLayout[normalizedNumber] = layout;
        }
      }
    }

    final assignedCountByPartner = <String, int>{};
    final plotPartnersRaw =
        _projectData['plot_partners'] as List<dynamic>? ?? const [];
    for (final raw in plotPartnersRaw) {
      if (raw is! Map) continue;
      final assignment = Map<String, dynamic>.from(raw);
      final partnerNames = _extractPartnerNamesFromAnyReport(
        assignment['partner_name'] ??
            assignment['partnerName'] ??
            assignment['partners_name'] ??
            assignment['partnersName'] ??
            assignment['partner'] ??
            assignment['partners'] ??
            assignment['name'],
      );
      final plotId = (assignment['plot_id'] ??
              assignment['plotId'] ??
              assignment['id'] ??
              assignment['plot_number'] ??
              assignment['plotNumber'] ??
              assignment['plot_no'] ??
              assignment['plotNo'] ??
              assignment['number'] ??
              assignment['plot'] ??
              '')
          .toString()
          .trim();
      final normalizedPlotId = _normalizePlotIdentityForReport(plotId);
      final number = plotIdToNumber[plotId] ?? plotIdToNumber[normalizedPlotId];
      if (number == null || number.isEmpty || partnerNames.isEmpty) continue;
      for (final partnerName in partnerNames) {
        final partner = partnerName.toLowerCase().trim();
        if (partner.isEmpty || partner == '-') continue;
        assignedCountByPartner.update(
          partner,
          (v) => v + 1,
          ifAbsent: () => 1,
        );
      }
    }

    if (assignedCountByPartner.isEmpty) {
      for (final plot in allPlots) {
        final number = _plotFieldStr(
            plot, ['plotNumber', 'plot_no', 'plotNo', 'number', 'plot_number']);
        if (number.isEmpty || number == '-') continue;
        for (final partnerName in _partnerNamesFromPlotForReport(plot)) {
          final partner = partnerName.toLowerCase().trim();
          if (partner.isEmpty || partner == '-') continue;
          assignedCountByPartner.update(
            partner,
            (v) => v + 1,
            ifAbsent: () => 1,
          );
        }
      }
    }

    final partnerLayoutPlotCounts = <String, Map<String, int>>{};
    for (final raw in plotPartnersRaw) {
      if (raw is! Map) continue;
      final assignment = Map<String, dynamic>.from(raw);
      final partnerNames = _extractPartnerNamesFromAnyReport(
        assignment['partner_name'] ??
            assignment['partnerName'] ??
            assignment['partners_name'] ??
            assignment['partnersName'] ??
            assignment['partner'] ??
            assignment['partners'] ??
            assignment['name'],
      );
      final plotId = (assignment['plot_id'] ??
              assignment['plotId'] ??
              assignment['id'] ??
              assignment['plot_number'] ??
              assignment['plotNumber'] ??
              assignment['plot_no'] ??
              assignment['plotNo'] ??
              assignment['number'] ??
              assignment['plot'] ??
              '')
          .toString()
          .trim();
      if (plotId.isEmpty || partnerNames.isEmpty) continue;
      final normalizedPlotId = _normalizePlotIdentityForReport(plotId);
      final layout = (plotIdToLayout[plotId] ??
              plotIdToLayout[normalizedPlotId] ??
              'Unknown')
          .trim();
      for (final partnerName in partnerNames) {
        final partner = partnerName.toLowerCase().trim();
        if (partner.isEmpty || partner == '-') continue;
        partnerLayoutPlotCounts.putIfAbsent(partner, () => <String, int>{});
        partnerLayoutPlotCounts[partner]!
            .update(layout, (v) => v + 1, ifAbsent: () => 1);
      }
    }

    if (partnerLayoutPlotCounts.isEmpty) {
      for (final plot in allPlots) {
        final layout = _resolveLayoutLabel(plot);
        for (final partnerName in _partnerNamesFromPlotForReport(plot)) {
          final partner = partnerName.toLowerCase().trim();
          if (partner.isEmpty || partner == '-') continue;
          partnerLayoutPlotCounts.putIfAbsent(partner, () => <String, int>{});
          partnerLayoutPlotCounts[partner]!
              .update(layout, (v) => v + 1, ifAbsent: () => 1);
        }
      }
    }

    int _estimateWrapLinesForPlotCount(int count) {
      if (count <= 0) return 1;
      // Slightly conservative to avoid RenderFlex overflow in dense rows.
      const chipsPerLine = 9;
      return math.max(1, (count / chipsPerLine).ceil());
    }

    double _estimatePartnerDistributionRowHeightPx(String partnerNameNorm) {
      final assignedCount = assignedCountByPartner[partnerNameNorm] ?? 0;
      final layoutCounts =
          partnerLayoutPlotCounts[partnerNameNorm] ?? const <String, int>{};

      if (layoutCounts.isEmpty) {
        // "-" fallback row shape in Plot(s) Assigned column.
        return 24.0;
      }

      final values = layoutCounts.values.toList(growable: false);
      double groupsHeight = 0.0;
      for (int i = 0; i < values.length; i++) {
        final count = values[i];
        final lines = _estimateWrapLinesForPlotCount(
          count > 0 ? count : assignedCount,
        );
        const lineHeight = 14.0;
        const runSpacing = 4.0;
        final wrapHeight = (lines * lineHeight) + ((lines - 1) * runSpacing);
        // "Layout: X" line + spacing + chips wrap.
        final groupHeight = 14.0 + 4.0 + wrapHeight;
        groupsHeight += groupHeight;
        if (i < values.length - 1) {
          groupsHeight += 8.0;
        }
      }

      // Row vertical padding (4 + 4) + tiny border allowance.
      return groupsHeight + 9.0;
    }

    double _estimatePartnerSummarySectionHeightPx() {
      // 3.1 title + profit pool + table(header + partner rows + total row)
      const titleHeight = 24.0;
      const poolHeight = 18.0;
      const tableHeaderHeight = 24.0;
      const tableRowHeight = 22.0;
      const tableTotalHeight = 22.0;
      const sectionBottomGap = 12.0;
      const borderAllowance = 2.0;
      return titleHeight +
          poolHeight +
          tableHeaderHeight +
          (partners.length * tableRowHeight) +
          tableTotalHeight +
          sectionBottomGap +
          borderAllowance;
    }

    double _availableDistributionHeightPx({required bool firstPage}) {
      // Matches the report page body height used in preview (842 page - 16 top - 16 bottom).
      const pageBodyHeight = 808.0;
      const headerHeight = 36.0;
      const gapAfterHeader = 12.0;
      const sectionTitleHeight = 34.0; // "2. Partner(s) Details"
      const distributionTitleHeight = 24.0; // "2.2 ..."
      const distributionHeaderHeight = 24.0; // table header bar
      const footerBlockHeight = 66.0; // spacer tail + footer
      const safetyBuffer = 20.0; // keep margin to prevent visual overflows

      final summaryHeight =
          firstPage ? _estimatePartnerSummarySectionHeightPx() : 0.0;
      final usable = pageBodyHeight -
          (headerHeight +
              gapAfterHeader +
              sectionTitleHeight +
              summaryHeight +
              distributionTitleHeight +
              distributionHeaderHeight +
              footerBlockHeight +
              safetyBuffer);
      return math.max(24.0, usable);
    }

    final chunks = <Map<String, int>>[];
    const totalsRowHeightPx = 22.0;
    var start = 0;
    var isFirstPage = true;
    var remaining = _availableDistributionHeightPx(firstPage: true);

    while (start < partners.length) {
      var count = 0;
      var localRemaining = remaining;
      for (int i = start; i < partners.length; i++) {
        final partner = partners[i];
        final name = (partner['name'] ??
                partner['partnerName'] ??
                partner['partner_name'] ??
                '')
            .toString()
            .trim()
            .toLowerCase();
        final rowCost = _estimatePartnerDistributionRowHeightPx(name);
        final isLastPartner = i == partners.length - 1;
        final effectiveRowCost =
            rowCost + (isLastPartner ? totalsRowHeightPx : 0.0);
        if (count > 0 && effectiveRowCost > localRemaining) break;
        if (effectiveRowCost > localRemaining && count == 0) {
          // First page can legitimately be summary-only if no 2.2 row fits.
          if (!isFirstPage) {
            // Continuation pages must always make forward progress.
            count = 1;
          }
          break;
        }
        count++;
        localRemaining -= rowCost;
        if (isLastPartner) {
          localRemaining -= totalsRowHeightPx;
        }
      }

      if (count <= 0) {
        count = 1;
      }

      chunks.add({'start': start, 'count': count});
      start += count;
      if (isFirstPage) {
        isFirstPage = false;
        remaining = _availableDistributionHeightPx(firstPage: false);
      }
    }

    final pages = <Widget>[];
    for (int i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      pages.add(
        _buildReportPage7(
          pageNumber: startPageNumber + i,
          startPartnerIndex: chunk['start'] ?? 0,
          partnerLimit: chunk['count'],
          showSummarySection: i == 0,
          showTotals: i == chunks.length - 1,
          isContinuation: i > 0,
        ),
      );
    }
    return pages;
  }

  List<Widget> _buildReportPage8Pages({required int startPageNumber}) {
    final managersRaw = (_projectData['project_managers'] ??
            _projectData['projectManagers']) as List<dynamic>? ??
        const [];
    final managers = managersRaw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    if (managers.isEmpty) {
      return [
        _buildReportPage8(
          pageNumber: startPageNumber,
          managerStartIndex: 0,
          managerLimit: 0,
          showTotals: true,
        ),
      ];
    }

    const firstPageLimit = 12;
    const nextPageLimit = 24;
    final pages = <Widget>[];
    var index = 0;
    var pageIndex = 0;
    while (index < managers.length) {
      final limit = pageIndex == 0 ? firstPageLimit : nextPageLimit;
      final count = math.min(limit, managers.length - index);
      pages.add(
        _buildReportPage8(
          pageNumber: startPageNumber + pageIndex,
          managerStartIndex: index,
          managerLimit: count,
          showTotals: index + count >= managers.length,
          isContinuation: pageIndex > 0,
        ),
      );
      index += count;
      pageIndex++;
    }
    return pages;
  }

  List<Map<String, dynamic>> _buildReportPage9LayoutBlocks() {
    final allPlotsRaw = _collectReportPlotsForOverview();
    final layoutPlots = <String, List<Map<String, dynamic>>>{};
    for (final raw in allPlotsRaw) {
      final plot = Map<String, dynamic>.from(raw);
      final layoutLabel = _resolveLayoutLabel(plot);
      final key = layoutLabel.isEmpty || layoutLabel == 'Unknown'
          ? 'Unknown'
          : layoutLabel;
      layoutPlots.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(plot);
    }
    final layoutEntries = layoutPlots.entries.toList();
    final blocks = <Map<String, dynamic>>[];
    for (int index = 0; index < layoutEntries.length; index++) {
      final entry = layoutEntries[index];
      blocks.add({
        'layoutIndex': index,
        'layoutName': entry.key,
        'plots': entry.value,
      });
    }
    return blocks;
  }

  List<Widget> _buildReportPage9Pages({required int startPageNumber}) {
    final layouts = _buildReportPage9LayoutBlocks();
    if (layouts.isEmpty) {
      return [
        _buildReportPage9(
          pageNumber: startPageNumber,
          layoutBlocksOverride: const [],
          showAgentEarningsSection: true,
          isContinuation: false,
        ),
      ];
    }

    const firstPageCapacity = 18.0;
    const nextPageCapacity = 28.0;
    const baseCost = 4.0;
    int layoutIndex = 0;
    int rowStart = 0;
    bool isFirstPage = true;
    final pages = <Widget>[];

    while (layoutIndex < layouts.length) {
      final pageBlocks = <Map<String, dynamic>>[];
      double localRemaining =
          isFirstPage ? firstPageCapacity : nextPageCapacity;

      while (layoutIndex < layouts.length) {
        final layout = layouts[layoutIndex];
        final allPlots =
            (layout['plots'] as List<Map<String, dynamic>>?) ?? const [];
        final rowsRemaining = math.max(0, allPlots.length - rowStart);

        if (rowsRemaining == 0) {
          if (pageBlocks.isNotEmpty && baseCost > localRemaining) break;
          pageBlocks.add({
            'layoutIndex': layout['layoutIndex'],
            'layoutName': layout['layoutName'],
            'plots': const <Map<String, dynamic>>[],
            'continued': false,
            'plotStartIndex': 0,
          });
          localRemaining -= baseCost;
          layoutIndex++;
          rowStart = 0;
          continue;
        }

        final fullTableCost = baseCost + rowsRemaining;
        if (fullTableCost <= localRemaining) {
          final chunkEnd = rowStart + rowsRemaining;
          pageBlocks.add({
            'layoutIndex': layout['layoutIndex'],
            'layoutName': layout['layoutName'],
            'plots': allPlots.sublist(rowStart, chunkEnd),
            'continued': rowStart > 0,
            'plotStartIndex': rowStart,
          });
          localRemaining -= fullTableCost;
          layoutIndex++;
          rowStart = 0;
          if (localRemaining <= 0) break;
          continue;
        }

        // If this table can't fit with existing tables, move full table to next page.
        if (pageBlocks.isNotEmpty) {
          break;
        }

        // Split rows only when a single table cannot fit on an empty page.
        int rowsFit = (localRemaining - baseCost).floor();
        if (rowsFit <= 0) rowsFit = 1;
        final rowsToTake = math.min(rowsRemaining, rowsFit);
        final chunkEnd = rowStart + rowsToTake;
        pageBlocks.add({
          'layoutIndex': layout['layoutIndex'],
          'layoutName': layout['layoutName'],
          'plots': allPlots.sublist(rowStart, chunkEnd),
          'continued': rowStart > 0,
          'plotStartIndex': rowStart,
        });
        localRemaining -= (baseCost + rowsToTake);

        if (chunkEnd >= allPlots.length) {
          layoutIndex++;
          rowStart = 0;
        } else {
          rowStart = chunkEnd;
          break;
        }

        if (localRemaining <= 0) break;
      }

      if (pageBlocks.isEmpty && layoutIndex < layouts.length) {
        final layout = layouts[layoutIndex];
        final allPlots =
            (layout['plots'] as List<Map<String, dynamic>>?) ?? const [];
        final chunkEnd = math.min(allPlots.length, rowStart + 1);
        pageBlocks.add({
          'layoutIndex': layout['layoutIndex'],
          'layoutName': layout['layoutName'],
          'plots': allPlots.sublist(rowStart, chunkEnd),
          'continued': rowStart > 0,
          'plotStartIndex': rowStart,
        });
        if (chunkEnd >= allPlots.length) {
          layoutIndex++;
          rowStart = 0;
        } else {
          rowStart = chunkEnd;
        }
      }

      pages.add(
        _buildReportPage9(
          pageNumber: startPageNumber + pages.length,
          layoutBlocksOverride: List<Map<String, dynamic>>.from(pageBlocks),
          showAgentEarningsSection: isFirstPage,
          isContinuation: !isFirstPage,
        ),
      );
      isFirstPage = false;
    }

    return pages;
  }

  List<Widget> _buildAllReportPagesForPreview() {
    final projectOverviewPages = _buildProjectOverviewPages(startPageNumber: 1);
    final overviewPageCount = projectOverviewPages.length;
    final partnerStartPage = overviewPageCount + 1;
    final partnerPages =
        _buildReportPage7Pages(startPageNumber: partnerStartPage);
    final managerStartPage = partnerStartPage + partnerPages.length;
    final managerPages =
        _buildReportPage8Pages(startPageNumber: managerStartPage);
    final agentStartPage = managerStartPage + managerPages.length;
    final agentPages = _buildReportPage9Pages(startPageNumber: agentStartPage);
    final layoutWiseStartPage = agentStartPage + agentPages.length;
    final layoutWisePages =
        _buildReportPage5Pages(startPageNumber: layoutWiseStartPage);
    final page6Number = layoutWiseStartPage + layoutWisePages.length;
    final page6Pages = _buildReportPage6Pages(startPageNumber: page6Number);
    final section7StartPage = page6Number + page6Pages.length;
    final section7Pages =
        _buildReportPage7PendingPages(startPageNumber: section7StartPage);
    final section8StartPage = section7StartPage + section7Pages.length;
    final section8Pages =
        _buildReportPage8AmenityPages(startPageNumber: section8StartPage);
    final pages = <Widget>[
      _buildReportPage1(),
      _buildReportPage2(projectOverviewPagesCount: overviewPageCount),
      ...projectOverviewPages,
      ...partnerPages,
      ...managerPages,
      ...agentPages,
      ...layoutWisePages,
      ...page6Pages,
      ...section7Pages,
      ...section8Pages,
    ];
    // Page numbering starts from Project Overview as page 1 (cover + contents are not counted).
    // So compute next page from the last numbered content page, not from total widget count.
    final lastNumberedContentPage = section8Pages.isNotEmpty
        ? section8StartPage + section8Pages.length - 1
        : (section7Pages.isNotEmpty
            ? section7StartPage + section7Pages.length - 1
            : (page6Number + page6Pages.length - 1));
    final expenseStartPage = lastNumberedContentPage + 1;
    final expensePages =
        _buildExpenseDetailsPages(startPageNumber: expenseStartPage);
    pages.addAll(expensePages);
    final formulasPageNumber = expenseStartPage + expensePages.length;
    pages.add(_buildReportPageFormulas(pageNumber: formulasPageNumber));
    return pages;
  }

  Widget _buildPaginatedReportPreview() {
    final pages = _buildAllReportPagesForPreview();
    _ensureReportPagePrintKeys(pages.length);
    final basePreview = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < pages.length; i++) ...[
          if (i > 0) const SizedBox(height: 16),
          RepaintBoundary(
            key: _reportPagePrintKeys[i],
            child: Container(
              width: 595,
              height: 842,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(
                  color: Colors.black.withOpacity(0.2),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: pages[i],
            ),
          ),
        ],
      ],
    );
    if ((_previewZoom - 1.0).abs() < 0.0001) {
      return basePreview;
    }
    return Align(
      alignment: Alignment.topCenter,
      widthFactor: _previewZoom,
      heightFactor: _previewZoom,
      child: Transform.scale(
        scale: _previewZoom,
        alignment: Alignment.topCenter,
        child: basePreview,
      ),
    );
  }

  Widget _buildReportPage1() {
    final projectName = _coverValueOrDash(_reportCoverProjectName());
    final projectLocation = _coverValueOrDash(_reportCoverProjectLocation());
    final reportAuthor = _coverValueOrDash(_reportIdentityFullName);
    final organization = _coverValueOrDash(_reportIdentityOrganization);
    final role = _coverValueOrDash(_reportIdentityRole);
    final generatedOn = _formatCoverDate(DateTime.now());
    final hasLogo = (_reportIdentityLogoSvg?.trim().isNotEmpty ?? false) ||
        (_reportIdentityLogoBytes != null &&
            _reportIdentityLogoBytes!.isNotEmpty);

    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.fill,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 380,
          height: 538,
          child: Container(
            width: 380,
            height: 538,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 2,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
            child: Column(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildCoverDotPattern(rows: 4, columns: 16),
                      const SizedBox(height: 16),
                      Container(
                        height: 1,
                        color: const Color(0xFF404040),
                      ),
                      const SizedBox(height: 12),
                      RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: 'Project Summary\n',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                                color: Colors.black,
                                height: 1.2,
                              ),
                            ),
                            TextSpan(
                              text: 'Report',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                                color: const Color(0xFF0C8CE9),
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Project: $projectName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inriaSerif(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF404040),
                        ),
                      ),
                      const SizedBox(height: 36),
                      Text(
                        'Project Location: $projectLocation',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inriaSerif(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF404040),
                        ),
                      ),
                      if (hasLogo) ...[
                        const Spacer(),
                        Container(
                          width: 63.9,
                          height: 31.95,
                          color: Colors.white,
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: _buildCoverLogo(
                              width: 60,
                              height: 28,
                              fit: BoxFit.contain,
                              alignment: Alignment.centerLeft,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ] else
                        const Spacer(),
                      Text(
                        'By: $reportAuthor',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 9,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFF404040),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Organization: $organization',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 9,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFF404040),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Role: $role',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 9,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFF404040),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Generated On: $generatedOn',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 9,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFF404040),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 98,
                  child: SvgPicture.asset(
                    'assets/images/Footer.svg',
                    fit: BoxFit.fill,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReportPage2({required int projectOverviewPagesCount}) {
    final hasAmenityArea = _hasAmenityAreaForReport();
    final pagePartnerDetails = projectOverviewPagesCount + 1;
    final partnerPagesCount =
        _buildReportPage7Pages(startPageNumber: pagePartnerDetails).length;
    final pageProjectManagers = pagePartnerDetails + partnerPagesCount;
    final managerPagesCount =
        _buildReportPage8Pages(startPageNumber: pageProjectManagers).length;
    final pageAgents = pageProjectManagers + managerPagesCount;
    final agentPagesCount =
        _buildReportPage9Pages(startPageNumber: pageAgents).length;
    final pageLayoutWiseSalesStart = pageAgents + agentPagesCount;
    final layoutWisePagesCount =
        _buildReportPage5Pages(startPageNumber: pageLayoutWiseSalesStart)
            .length;
    final pageLayoutWiseAfterSales =
        pageLayoutWiseSalesStart + layoutWisePagesCount;
    final layoutWiseAfterSalesPagesCount =
        _buildReportPage6Pages(startPageNumber: pageLayoutWiseAfterSales)
            .length;
    final pageSection7Figma =
        pageLayoutWiseAfterSales + layoutWiseAfterSalesPagesCount;
    final section7FigmaPagesCount =
        _buildReportPage7PendingPages(startPageNumber: pageSection7Figma)
            .length;
    final pageSection8Amenity = pageSection7Figma + section7FigmaPagesCount;
    final section8AmenityPagesCount =
        _buildReportPage8AmenityPages(startPageNumber: pageSection8Amenity)
            .length;
    final expenseStartPage = pageSection8Amenity + section8AmenityPagesCount;
    final expensePages =
        _buildExpenseDetailsPages(startPageNumber: expenseStartPage);
    final hasExpenseDetails = expensePages.isNotEmpty;
    final formulasPage = expenseStartPage + expensePages.length;

    String sectionPageRange(int start, int end) {
      if (end <= start) return '$start';
      return '$start-$end';
    }

    final projectOverviewStart = 1;
    final projectOverviewEnd = projectOverviewPagesCount;
    final partnerDetailsStart = pagePartnerDetails;
    final partnerDetailsEnd = pagePartnerDetails + partnerPagesCount - 1;
    final projectManagersStart = pageProjectManagers;
    final projectManagersEnd = pageProjectManagers + managerPagesCount - 1;
    final agentsStart = pageAgents;
    final agentsEnd = pageAgents + agentPagesCount - 1;
    final layoutWiseSalesEnd =
        pageLayoutWiseSalesStart + layoutWisePagesCount - 1;
    final layoutWiseAfterSalesEnd =
        pageLayoutWiseAfterSales + layoutWiseAfterSalesPagesCount - 1;
    final section7FigmaStart = pageSection7Figma;
    final section7FigmaEnd = pageSection7Figma + section7FigmaPagesCount - 1;
    final section8AmenityStart = pageSection8Amenity;
    final section8AmenityEnd =
        pageSection8Amenity + section8AmenityPagesCount - 1;
    final expenseSectionNumber = section8AmenityPagesCount > 0
        ? 9
        : (section7FigmaPagesCount > 0 ? 8 : 7);
    final formulasSectionNumber = expenseSectionNumber + 1;
    final expenseDetailsStart = expenseStartPage;
    final expenseDetailsEnd = expenseStartPage + expensePages.length - 1;
    final projectOverviewSecondPage =
        math.min(projectOverviewEnd, projectOverviewStart + 1);
    final salesHighlightsPage =
        hasAmenityArea ? projectOverviewSecondPage : projectOverviewStart;

    // Table of Contents data structure (page numbers aligned with generated content)
    final tocItems = [
      {
        'number': '1.',
        'title': 'Project Overview',
        'page': sectionPageRange(projectOverviewStart, projectOverviewEnd),
        'subitems': [
          {'number': '1.1', 'title': 'Project Cost & Area', 'page': '1'},
          {'number': '1.2', 'title': 'Site Overview', 'page': '1'},
          {'number': '1.3', 'title': 'Profit and ROI', 'page': '1'},
          {
            'number': '1.4',
            'title': 'Sales Highlights',
            'page': '$salesHighlightsPage'
          },
          {
            'number': '1.5',
            'title': 'Compensation',
            'page': '$projectOverviewSecondPage'
          },
          {
            'number': '1.6',
            'title': 'Partner(s) Profit Distribution',
            'page': '$projectOverviewSecondPage'
          },
          {
            'number': '1.7',
            'title': 'Sales Activity',
            'page': '$projectOverviewSecondPage'
          },
        ],
      },
      {
        'number': '2.',
        'title': 'Partner Details',
        'page': sectionPageRange(partnerDetailsStart, partnerDetailsEnd),
        'subitems': [
          {
            'number': '2.1',
            'title': 'Partners Profit Distribution',
            'page': '$pagePartnerDetails'
          },
          {
            'number': '2.2',
            'title': 'Partner Plot Distribution',
            'page': '$pagePartnerDetails'
          },
        ],
      },
      {
        'number': '3.',
        'title': 'Project Manager(s) Details',
        'page': sectionPageRange(projectManagersStart, projectManagersEnd),
        'subitems': [
          {
            'number': '3.1',
            'title': 'Project Manager(s) Earnings',
            'page': '$pageProjectManagers'
          },
        ],
      },
      {
        'number': '4.',
        'title': 'Agent(s) Details',
        'page': sectionPageRange(agentsStart, agentsEnd),
        'subitems': [
          {
            'number': '4.1',
            'title': 'Agent(s) Earnings',
            'page': '$pageAgents'
          },
          {
            'number': '4.2',
            'title': 'Agent - Plot Distribution & Earnings',
            'page': '$pageAgents'
          },
        ],
      },
      {
        'number': '5.',
        'title': 'Layout Wise Sales Summary',
        'page': sectionPageRange(pageLayoutWiseSalesStart, layoutWiseSalesEnd),
        'subitems': [],
      },
      {
        'number': '6.',
        'title': 'Layout Wise After Sales Summary',
        'page':
            sectionPageRange(pageLayoutWiseAfterSales, layoutWiseAfterSalesEnd),
        'subitems': [],
      },
      if (section7FigmaPagesCount > 0)
        {
          'number': '7.',
          'title': 'Site Pending Payment',
          'page': sectionPageRange(section7FigmaStart, section7FigmaEnd),
          'subitems': [],
        },
      if (section8AmenityPagesCount > 0)
        {
          'number': '8.',
          'title': 'Amenity Area',
          'page': sectionPageRange(section8AmenityStart, section8AmenityEnd),
          'subitems': [
            {
              'number': '8.1',
              'title': 'Amenity Area Wise Sales Summary',
              'page': '$section8AmenityStart'
            },
            {
              'number': '8.2',
              'title': 'Amenity Area Wise After Sales Summary',
              'page': '$section8AmenityStart'
            },
            {
              'number': '8.3',
              'title': 'Amenity Area Pending Payment',
              'page': '$section8AmenityStart'
            },
          ],
        },
      if (hasExpenseDetails)
        {
          'number': '$expenseSectionNumber.',
          'title': 'Expense Details',
          'page': sectionPageRange(expenseDetailsStart, expenseDetailsEnd),
          'subitems': [
            {
              'number': '$expenseSectionNumber.1',
              'title': 'Expense Categories Summary',
              'page': '$expenseStartPage'
            },
            {
              'number': '$expenseSectionNumber.2',
              'title': 'Expense Breakdown',
              'page': '$expenseStartPage'
            },
          ],
        },
      {
        'number': '$formulasSectionNumber.',
        'title': 'Formulas',
        'page': '$formulasPage',
        'subitems': [],
      },
    ];

    final tocTitleStyle = GoogleFonts.inriaSerif(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      color: const Color(0xFF0C8CE9),
    );
    final tocHeaderStyle = GoogleFonts.inriaSerif(
      fontSize: 14,
      fontWeight: FontWeight.bold,
      color: const Color(0xFF404040),
    );
    final tocSectionStyle = GoogleFonts.inriaSerif(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: const Color(0xFF404040),
    );
    final tocSubItemStyle = GoogleFonts.inriaSerif(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: const Color(0xFF404040),
    );

    Widget buildLeaderDots(TextStyle style) {
      return Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final dotCount = (constraints.maxWidth / 3.2).ceil().clamp(1, 500);
            final dots = List.filled(dotCount, '.').join();
            return Text(
              dots,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: style,
            );
          },
        ),
      );
    }

    Widget buildTocRow({
      required String number,
      required String title,
      required String page,
      required TextStyle style,
      bool isSub = false,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (isSub) const SizedBox(width: 6),
            Text(number, style: style),
            const SizedBox(width: 6),
            Text(title, style: style),
            buildLeaderDots(style),
            Text(page, style: style),
          ],
        ),
      );
    }

    Widget buildTocSection(Map<String, dynamic> section) {
      final subitems = ((section['subitems'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          buildTocRow(
            number: (section['number'] ?? '').toString(),
            title: (section['title'] ?? '').toString(),
            page: (section['page'] ?? '').toString(),
            style: tocSectionStyle,
          ),
          if (subitems.isNotEmpty) const SizedBox(height: 2),
          for (var index = 0; index < subitems.length; index++) ...[
            buildTocRow(
              number: (subitems[index]['number'] ?? '').toString(),
              title: (subitems[index]['title'] ?? '').toString(),
              page: (subitems[index]['page'] ?? '').toString(),
              style: tocSubItemStyle,
              isSub: true,
            ),
            if (index != subitems.length - 1) const SizedBox(height: 2),
          ],
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 55,
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Color(0xFF404040),
                      width: 0.5,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _reportHeaderUnitText,
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF404040),
                      ),
                    ),
                    Text(
                      _reportHeaderDateText,
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF404040),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('Table of Contents', style: tocTitleStyle),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Content', style: tocHeaderStyle),
                    Text('Page Number', style: tocHeaderStyle),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final tocContent = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var index = 0;
                            index < tocItems.length;
                            index++) ...[
                          buildTocSection(
                            (tocItems[index] as Map).cast<String, dynamic>(),
                          ),
                          if (index != tocItems.length - 1)
                            const SizedBox(height: 16),
                        ],
                      ],
                    );

                    return ClipRect(
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: constraints.maxWidth,
                            child: tocContent,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        _buildStandardReportFooter(2, showPageNumber: false),
      ],
    );
  }

  Widget _buildStandardReportFooter(
    int pageNumber, {
    bool showPageNumber = true,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        SizedBox(
          height: 55,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Color(0xFF858585),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      height: 38,
                      child: SvgPicture.asset(
                        'assets/images/Common_footer.svg',
                        width: 112,
                        height: 38,
                        fit: BoxFit.contain,
                        alignment: Alignment.centerLeft,
                      ),
                    ),
                  ),
                ),
                if (showPageNumber)
                  SizedBox(
                    height: 38,
                    child: Center(
                      child: Text(
                        '$pageNumber',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF0C8CE9),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static const double _section56LandscapeSideRailWidth = 55.0;

  Widget _buildSection56LandscapeHeaderRail({
    required String sectionTitle,
  }) {
    return SizedBox(
      width: _section56LandscapeSideRailWidth,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: const BoxDecoration(
          border: Border(
            right: BorderSide(
              color: Color(0xFF858585),
              width: 0.5,
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return RotatedBox(
              quarterTurns: 3,
              child: SizedBox(
                width: constraints.maxHeight,
                child: ClipRect(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: constraints.maxHeight,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _reportHeaderUnitText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: GoogleFonts.inriaSerif(
                                    fontSize: 10,
                                    fontWeight: FontWeight.normal,
                                    color: const Color(0xFF404040),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _reportHeaderDateText,
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  fontWeight: FontWeight.normal,
                                  color: const Color(0xFF404040),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            sectionTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inriaSerif(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF0C8CE9),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSection56LandscapeFooterRail(
    int pageNumber, {
    bool showPageNumber = true,
  }) {
    return SizedBox(
      width: _section56LandscapeSideRailWidth,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(
              color: Color(0xFF858585),
              width: 0.5,
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return RotatedBox(
              quarterTurns: 3,
              child: SizedBox(
                width: constraints.maxHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          height: 38,
                          child: SvgPicture.asset(
                            'assets/images/Common_footer.svg',
                            width: 112,
                            height: 38,
                            fit: BoxFit.contain,
                            alignment: Alignment.centerLeft,
                          ),
                        ),
                      ),
                    ),
                    if (showPageNumber)
                      SizedBox(
                        height: 38,
                        child: Center(
                          child: Text(
                            '$pageNumber',
                            style: GoogleFonts.inriaSerif(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF0C8CE9),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSection56LandscapeScaffold({
    required int pageNumber,
    required String sectionTitle,
    required Widget child,
  }) {
    return Container(
      color: Colors.white,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSection56LandscapeHeaderRail(sectionTitle: sectionTitle),
          Expanded(child: child),
          _buildSection56LandscapeFooterRail(pageNumber),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _buildReportPage7PendingLayoutBlocks() {
    final allPlots = _collectReportPlotsForOverview();
    final layoutPlots = <String, List<Map<String, dynamic>>>{};

    bool hasPendingPayment(Map<String, dynamic> plot) {
      final status = _normalizeSiteStatusForReport(
        _plotFieldStr(plot, ['status', 'plot_status', 'sale_status']),
      );
      if (status == 'pending') {
        return true;
      }
      if (status != 'sold') {
        return false;
      }
      final areaSqft =
          _plotFieldDouble(plot, ['area', 'plotArea', 'plot_area']);
      final salePrice = _plotFieldDouble(plot, [
        'salePrice',
        'sale_price',
        'salePricePerSqft',
        'sale_price_per_sqft'
      ]);
      final saleValue = areaSqft * salePrice;
      final received = _sumSitePlotCollectionsForReport(plot);
      final pending = math.max(0.0, saleValue - received);
      return pending > 0;
    }

    for (final plot in allPlots) {
      if (!hasPendingPayment(plot)) continue;
      final layoutLabel = _resolveLayoutLabel(plot);
      final key = layoutLabel.isEmpty || layoutLabel == 'Unknown'
          ? 'Unknown'
          : layoutLabel;
      layoutPlots.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(plot);
    }

    final blocks = <Map<String, dynamic>>[];
    final entries = layoutPlots.entries.toList();
    for (int layoutIndex = 0; layoutIndex < entries.length; layoutIndex++) {
      final entry = entries[layoutIndex];
      blocks.add({
        'layoutIndex': layoutIndex,
        'layoutName': entry.key,
        'plots': entry.value,
      });
    }
    return blocks;
  }

  double _estimateReportPage7PendingBlockHeightPx(
    int rows, {
    required bool isContinuationChunk,
  }) {
    const headingRow = 16.0;
    const headingGap = 6.0;
    const tableHeader = 26.0;
    const tableRow = 22.0;
    const totalRow = 22.0;
    const blockBottomGap = 12.0;
    const continuationGap = 6.0;
    return headingRow +
        (isContinuationChunk ? continuationGap : headingGap) +
        tableHeader +
        (rows * tableRow) +
        totalRow +
        blockBottomGap;
  }

  List<Widget> _buildReportPage7PendingPages({required int startPageNumber}) {
    final layouts = _buildReportPage7PendingLayoutBlocks();
    if (layouts.isEmpty) return const <Widget>[];

    final availableHeightPx = math.max(
      0.0,
      _landscapeSection56TableUsableExtentPx() - 18.0,
    );
    const minRowsPerChunk = 1;
    int layoutIndex = 0;
    int rowStart = 0;
    final pages = <Widget>[];

    while (layoutIndex < layouts.length) {
      var remainingHeight = availableHeightPx;
      final pageBlocks = <Map<String, dynamic>>[];

      while (layoutIndex < layouts.length) {
        final layout = layouts[layoutIndex];
        final allPlots =
            (layout['plots'] as List<Map<String, dynamic>>?) ?? const [];
        final rowsRemaining = math.max(0, allPlots.length - rowStart);
        if (rowsRemaining == 0) {
          layoutIndex++;
          rowStart = 0;
          continue;
        }

        final fullTableHeight = _estimateReportPage7PendingBlockHeightPx(
          rowsRemaining,
          isContinuationChunk: rowStart > 0,
        );
        if (fullTableHeight <= remainingHeight) {
          final chunkEnd = rowStart + rowsRemaining;
          pageBlocks.add({
            'layoutIndex': layout['layoutIndex'],
            'layoutName': layout['layoutName'],
            'allPlots': allPlots,
            'plots': allPlots.sublist(rowStart, chunkEnd),
            'continued': rowStart > 0,
            'plotStartIndex': rowStart,
          });
          remainingHeight -= fullTableHeight;
          layoutIndex++;
          rowStart = 0;
          if (remainingHeight <= 0) break;
          continue;
        }

        if (pageBlocks.isNotEmpty) {
          break;
        }

        int rowsToTake = rowsRemaining;
        while (rowsToTake > minRowsPerChunk &&
            _estimateReportPage7PendingBlockHeightPx(
                  rowsToTake,
                  isContinuationChunk: rowStart > 0,
                ) >
                remainingHeight) {
          rowsToTake--;
        }
        rowsToTake = math.max(minRowsPerChunk, rowsToTake);
        rowsToTake = math.min(rowsToTake, rowsRemaining);
        final chunkEnd = rowStart + rowsToTake;
        pageBlocks.add({
          'layoutIndex': layout['layoutIndex'],
          'layoutName': layout['layoutName'],
          'allPlots': allPlots,
          'plots': allPlots.sublist(rowStart, chunkEnd),
          'continued': rowStart > 0,
          'plotStartIndex': rowStart,
        });
        if (chunkEnd >= allPlots.length) {
          layoutIndex++;
          rowStart = 0;
        } else {
          rowStart = chunkEnd;
        }
        break;
      }

      if (pageBlocks.isEmpty) {
        final layout = layouts[layoutIndex];
        final allPlots =
            (layout['plots'] as List<Map<String, dynamic>>?) ?? const [];
        final chunkEnd = math.min(allPlots.length, rowStart + minRowsPerChunk);
        pageBlocks.add({
          'layoutIndex': layout['layoutIndex'],
          'layoutName': layout['layoutName'],
          'allPlots': allPlots,
          'plots': allPlots.sublist(rowStart, chunkEnd),
          'continued': rowStart > 0,
          'plotStartIndex': rowStart,
        });
        if (chunkEnd >= allPlots.length) {
          layoutIndex++;
          rowStart = 0;
        } else {
          rowStart = chunkEnd;
        }
      }

      pages.add(
        _buildReportPage7PendingLandscape(
          pageNumber: startPageNumber + pages.length,
          layoutBlocksOverride: List<Map<String, dynamic>>.from(pageBlocks),
          isContinuation: pages.isNotEmpty,
        ),
      );
    }

    return pages;
  }

  Widget _buildReportPage7PendingLandscape({
    required int pageNumber,
    List<Map<String, dynamic>>? layoutBlocksOverride,
    bool isContinuation = false,
  }) {
    final layoutBlocks =
        layoutBlocksOverride ?? _buildReportPage7PendingLayoutBlocks();
    final sectionTitle = isContinuation
        ? '7. Site Pending Payment (Cont.)'
        : '7. Site Pending Payment';
    return _buildSection56LandscapeScaffold(
      pageNumber: pageNumber,
      sectionTitle: sectionTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxTableExtent = math.max(
                    0.0,
                    math.min(
                      _landscapeSection56TableUsableExtentPx(),
                      constraints.maxWidth - 24.0,
                    ),
                  );
                  final tableHeight = math.min(
                    maxTableExtent,
                    constraints.maxHeight,
                  );
                  return Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 16),
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SizedBox(
                          height: tableHeight,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ...layoutBlocks.asMap().entries.map((entry) {
                                final block = entry.value;
                                final layoutIndex =
                                    (block['layoutIndex'] as int?) ?? entry.key;
                                final layoutName =
                                    (block['layoutName'] ?? 'Unknown')
                                        .toString();
                                final continued = block['continued'] == true;
                                final plotStartIndex =
                                    (block['plotStartIndex'] as int?) ?? 0;
                                final rawPlots =
                                    block['plots'] as List<dynamic>? ??
                                        const [];
                                final plots = rawPlots
                                    .map((p) => p is Map
                                        ? Map<String, dynamic>.from(p)
                                        : <String, dynamic>{})
                                    .toList(growable: false);
                                final rawSummaryPlots =
                                    block['allPlots'] as List<dynamic>? ??
                                        rawPlots;
                                final summaryPlots = rawSummaryPlots
                                    .map((p) => p is Map
                                        ? Map<String, dynamic>.from(p)
                                        : <String, dynamic>{})
                                    .toList(growable: false);

                                double totalAreaSqft = 0.0;
                                double totalSaleAllInCost = 0.0;
                                double totalSaleValue = 0.0;
                                double totalReceived = 0.0;
                                double totalPending = 0.0;
                                for (final plot in summaryPlots) {
                                  final areaSqft = _plotFieldDouble(
                                      plot, ['area', 'plotArea', 'plot_area']);
                                  final salePriceVal = _plotFieldDouble(plot, [
                                    'salePrice',
                                    'sale_price',
                                    'salePricePerSqft',
                                    'sale_price_per_sqft'
                                  ]);
                                  final saleValue = areaSqft * salePriceVal;
                                  final receivedVal =
                                      _sumSitePlotCollectionsForReport(plot);
                                  final pendingVal =
                                      math.max(0.0, saleValue - receivedVal);
                                  totalAreaSqft += areaSqft;
                                  totalSaleAllInCost += _displayRateFromSqft(
                                    salePriceVal,
                                  );
                                  totalSaleValue += saleValue;
                                  totalReceived += receivedVal;
                                  totalPending += pendingVal;
                                }
                                final totalAreaDisplay =
                                    _displayAreaFromSqft(totalAreaSqft);

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            '${layoutIndex + 1}.',
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: const Color(0xFF404040),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Layout:',
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: const Color(0xFF404040),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            continued
                                                ? '$layoutName (Cont.)'
                                                : layoutName,
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              color: const Color(0xFF404040),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: const Color(0xFF404040),
                                            width: 0.5,
                                          ),
                                        ),
                                        child: Column(
                                          children: [
                                            Container(
                                              color: const Color(0xFF404040),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  _buildTableCell('Sl. No.', 31,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Plot Number', 62,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Area ($_areaUnitSuffix)',
                                                      108,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Sale All-in Cost (₹/$_areaUnitSuffix)',
                                                      95,
                                                      isHeader: true,
                                                      keepOriginalWidth: true,
                                                      singleLine: true),
                                                  _buildTableCell(
                                                      'Sale Value (₹)', 86,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Received Amount (₹)',
                                                      102,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Pending Amount (₹)', 99,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Buyer Name', 99,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Buyer\'s Contact', 72,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Sale Date', 60,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                ],
                                              ),
                                            ),
                                            ...List.generate(plots.length,
                                                (index) {
                                              final plot = plots[index];
                                              var plotNumber = _plotFieldStr(
                                                  plot, [
                                                'plotNumber',
                                                'plot_no',
                                                'plotNo',
                                                'number'
                                              ]);
                                              if (plotNumber == '-') {
                                                plotNumber =
                                                    _inferPlotNumber(plot);
                                              }
                                              final areaSqft = _plotFieldDouble(
                                                  plot, [
                                                'area',
                                                'plotArea',
                                                'plot_area'
                                              ]);
                                              final salePriceVal =
                                                  _plotFieldDouble(plot, [
                                                'salePrice',
                                                'sale_price',
                                                'salePricePerSqft',
                                                'sale_price_per_sqft'
                                              ]);
                                              final saleValueVal =
                                                  areaSqft * salePriceVal;
                                              final receivedVal =
                                                  _sumSitePlotCollectionsForReport(
                                                      plot);
                                              final pendingVal = math.max(0.0,
                                                  saleValueVal - receivedVal);
                                              final buyerName = _plotFieldStr(
                                                  plot, [
                                                'buyer',
                                                'buyerName',
                                                'buyer_name'
                                              ]);
                                              final buyerContact =
                                                  _plotFieldStr(plot, [
                                                'buyerContactNumber',
                                                'buyer_contact_number',
                                                'buyerContact',
                                                'buyer_contact',
                                                'buyerPhone',
                                                'buyer_phone'
                                              ]);
                                              final saleDate =
                                                  _saleDateLabelForReport(
                                                plot,
                                              );
                                              final areaDisplay =
                                                  _displayAreaFromSqft(
                                                      areaSqft);

                                              return Container(
                                                decoration: BoxDecoration(
                                                  border: Border(
                                                    bottom: BorderSide(
                                                      color: Colors.black
                                                          .withOpacity(0.2),
                                                      width: 0.25,
                                                    ),
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    _buildTableCell(
                                                      (plotStartIndex +
                                                              index +
                                                              1)
                                                          .toString(),
                                                      31,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      plotNumber,
                                                      62,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      '${_formatReportMetricNumber(areaDisplay)} $_areaUnitSuffix',
                                                      108,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      _formatReportCurrencyNumber(
                                                        _displayRateFromSqft(
                                                            salePriceVal),
                                                      ),
                                                      95,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      _formatReportCurrencyNumber(
                                                          saleValueVal),
                                                      86,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      _formatReportCurrencyNumber(
                                                          receivedVal),
                                                      102,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      _formatReportCurrencyNumber(
                                                          pendingVal),
                                                      99,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      buyerName,
                                                      99,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      buyerContact,
                                                      72,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      saleDate,
                                                      60,
                                                      keepOriginalWidth: true,
                                                    ),
                                                  ],
                                                ),
                                              );
                                            }),
                                            Container(
                                              color: const Color(0xFFCFCFCF),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  _buildTableCell('Total', 31,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell('', 62,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                    '${_formatReportMetricNumber(totalAreaDisplay)} $_areaUnitSuffix',
                                                    108,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalSaleAllInCost),
                                                    95,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalSaleValue),
                                                    86,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalReceived),
                                                    102,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalPending),
                                                    99,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell('', 99,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell('', 72,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell('', 60,
                                                      keepOriginalWidth: true),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const String _amenitySection8TableSales = 'sales';
  static const String _amenitySection8TableAfterSales = 'after_sales';
  static const String _amenitySection8TablePending = 'pending';

  List<Widget> _buildReportPage8AmenityPages({required int startPageNumber}) {
    final allRows = _collectAmenityAreasForReport();
    if (allRows.isEmpty) return const <Widget>[];

    final pendingRows = allRows.where((row) {
      final status = _amenityStatusForReport(row);
      if (status == 'pending') return true;
      final saleValue = _amenitySaleValueForReport(row);
      final received = _amenityPaymentAmountForReport(row);
      return math.max(0.0, saleValue - received) > 0;
    }).toList(growable: false);

    final tableOrder = <String>[
      _amenitySection8TableSales,
      _amenitySection8TableAfterSales,
      _amenitySection8TablePending,
    ];
    final rowsByTable = <String, List<Map<String, dynamic>>>{
      _amenitySection8TableSales: allRows,
      _amenitySection8TableAfterSales: allRows,
      _amenitySection8TablePending: pendingRows,
    };
    final rowStartByTable = <String, int>{
      _amenitySection8TableSales: 0,
      _amenitySection8TableAfterSales: 0,
      _amenitySection8TablePending: 0,
    };

    final pageBlocksList = <List<Map<String, dynamic>>>[];
    // Keep a small safety buffer so wrapped amenity cells do not overflow
    // when the rendered height ends up slightly larger than the estimate.
    final availableHeightPx = math.max(
      0.0,
      _landscapeSection56TableUsableExtentPx() - 8.0,
    );
    const minRowsPerChunk = 1;
    var tableIndex = 0;

    while (tableIndex < tableOrder.length) {
      var remainingHeight = availableHeightPx;
      final pageBlocks = <Map<String, dynamic>>[];

      while (tableIndex < tableOrder.length) {
        final tableType = tableOrder[tableIndex];
        final rows = rowsByTable[tableType] ?? const <Map<String, dynamic>>[];
        final hasPlaceholderRow =
            tableType == _amenitySection8TablePending && rows.isEmpty;
        final rowStart = rowStartByTable[tableType] ?? 0;
        final effectiveTotalRows = hasPlaceholderRow ? 1 : rows.length;
        final rowsRemaining = math.max(0, effectiveTotalRows - rowStart);
        if (rowsRemaining == 0) {
          tableIndex++;
          rowStartByTable[tableType] = 0;
          continue;
        }

        final isContinuationChunk = rowStart > 0;
        final fullTableHeight = _estimateReportPage8AmenityBlockHeightPx(
          tableType: tableType,
          rowCount: rowsRemaining,
          isContinuationChunk: isContinuationChunk,
          showTotalRow: true,
        );
        if (fullTableHeight <= remainingHeight) {
          final chunkEnd = rowStart + rowsRemaining;
          pageBlocks.add({
            'tableType': tableType,
            'rows': hasPlaceholderRow
                ? const <Map<String, dynamic>>[]
                : rows.sublist(rowStart, chunkEnd),
            'continued': isContinuationChunk,
            'rowStartIndex': rowStart,
            'showTotalRow': true,
            'showPlaceholderRow': hasPlaceholderRow && rowStart == 0,
          });
          remainingHeight -= fullTableHeight;
          tableIndex++;
          rowStartByTable[tableType] = 0;
          if (remainingHeight <= 0) break;
          continue;
        }

        // Move full table to next page whenever possible.
        if (pageBlocks.isNotEmpty) {
          break;
        }

        // Split rows only when a single table cannot fit on an empty page.
        int rowsToTake = rowsRemaining;
        while (rowsToTake > minRowsPerChunk &&
            _estimateReportPage8AmenityBlockHeightPx(
                  tableType: tableType,
                  rowCount: rowsToTake,
                  isContinuationChunk: isContinuationChunk,
                  showTotalRow: rowsToTake >= rowsRemaining,
                ) >
                remainingHeight) {
          rowsToTake--;
        }

        rowsToTake = math.max(minRowsPerChunk, rowsToTake);
        rowsToTake = math.min(rowsToTake, rowsRemaining);
        final chunkEnd = rowStart + rowsToTake;
        final showTotalRow = chunkEnd >= effectiveTotalRows;
        pageBlocks.add({
          'tableType': tableType,
          'rows': hasPlaceholderRow
              ? const <Map<String, dynamic>>[]
              : rows.sublist(rowStart, chunkEnd),
          'continued': isContinuationChunk,
          'rowStartIndex': rowStart,
          'showTotalRow': showTotalRow,
          'showPlaceholderRow': hasPlaceholderRow && rowStart == 0,
        });

        if (showTotalRow) {
          tableIndex++;
          rowStartByTable[tableType] = 0;
        } else {
          rowStartByTable[tableType] = chunkEnd;
        }
        break;
      }

      if (pageBlocks.isEmpty && tableIndex < tableOrder.length) {
        final tableType = tableOrder[tableIndex];
        final rows = rowsByTable[tableType] ?? const <Map<String, dynamic>>[];
        final hasPlaceholderRow =
            tableType == _amenitySection8TablePending && rows.isEmpty;
        final rowStart = rowStartByTable[tableType] ?? 0;
        final effectiveTotalRows = hasPlaceholderRow ? 1 : rows.length;
        final chunkEnd =
            math.min(effectiveTotalRows, rowStart + minRowsPerChunk);
        final showTotalRow = chunkEnd >= effectiveTotalRows;
        pageBlocks.add({
          'tableType': tableType,
          'rows': hasPlaceholderRow
              ? const <Map<String, dynamic>>[]
              : rows.sublist(rowStart, chunkEnd),
          'continued': rowStart > 0,
          'rowStartIndex': rowStart,
          'showTotalRow': showTotalRow,
          'showPlaceholderRow': hasPlaceholderRow && rowStart == 0,
        });
        if (showTotalRow) {
          tableIndex++;
          rowStartByTable[tableType] = 0;
        } else {
          rowStartByTable[tableType] = chunkEnd;
        }
      }

      pageBlocksList.add(pageBlocks);
    }

    if (pageBlocksList.isEmpty) {
      pageBlocksList.add(<Map<String, dynamic>>[]);
    }

    final pages = <Widget>[];
    for (int i = 0; i < pageBlocksList.length; i++) {
      pages.add(
        _buildReportPage8AmenityLandscape(
          pageNumber: startPageNumber + i,
          isContinuation: i > 0,
          tableBlocksOverride: pageBlocksList[i],
        ),
      );
    }
    return pages;
  }

  double _estimateReportPage8AmenityBlockHeightPx({
    required String tableType,
    required int rowCount,
    required bool isContinuationChunk,
    required bool showTotalRow,
  }) {
    // Keep this slightly conservative to prevent occasional overflow.
    const tableHeader = 28.0;
    const tableRow = 27.0;
    const totalRow = 26.0;
    const blockBottomGap = 12.0;

    double headingAndSummary;
    switch (tableType) {
      case _amenitySection8TableSales:
        headingAndSummary = isContinuationChunk ? 24.0 : 54.0;
        break;
      case _amenitySection8TableAfterSales:
        headingAndSummary = isContinuationChunk ? 24.0 : 66.0;
        break;
      case _amenitySection8TablePending:
        headingAndSummary = 24.0;
        break;
      default:
        headingAndSummary = isContinuationChunk ? 20.0 : 44.0;
    }

    return headingAndSummary +
        tableHeader +
        (rowCount * tableRow) +
        (showTotalRow ? totalRow : 0.0) +
        blockBottomGap;
  }

  String _amenityNameForReport(Map<String, dynamic> row) {
    return _plotFieldStr(row, ['name', 'amenityName', 'amenity_name']);
  }

  String _amenityBuyerContactForReport(Map<String, dynamic> row) {
    return _plotFieldStr(row, [
      'buyer_contact_number',
      'buyerContactNumber',
      'buyerContact',
      'buyer_contact',
      'buyerPhone',
      'buyer_phone',
    ]);
  }

  Widget _buildReportPage8AmenityLandscape({
    required int pageNumber,
    bool isContinuation = false,
    List<Map<String, dynamic>>? tableBlocksOverride,
  }) {
    final allRows = _collectAmenityAreasForReport();
    final soldRows = allRows
        .where((row) => _amenityStatusForReport(row) == 'sold')
        .toList(growable: false);
    final afterRows = allRows.where((row) {
      final status = _amenityStatusForReport(row);
      return status == 'sold' || status == 'pending';
    }).toList(growable: false);
    final pendingRows = allRows.where((row) {
      final status = _amenityStatusForReport(row);
      if (status == 'pending') return true;
      final saleValue = _amenitySaleValueForReport(row);
      final received = _amenityPaymentAmountForReport(row);
      return math.max(0.0, saleValue - received) > 0;
    }).toList(growable: false);

    final soldCount = soldRows.length;

    final salesTotalAreaSqft = allRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityAreaSqftForReport(row),
    );
    final salesTotalPlotCost = allRows.fold<double>(
      0.0,
      (sum, row) =>
          sum +
          (_amenityAreaSqftForReport(row) *
              _amenityAllInCostSqftForReport(row)),
    );
    final salesTotalValue = soldRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenitySaleValueForReport(row),
    );
    final soldAreaSqft = soldRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityAreaSqftForReport(row),
    );
    final salesAvgRateSqft =
        soldAreaSqft > 0 ? salesTotalValue / soldAreaSqft : 0.0;

    final afterTotalAreaSqft = allRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityAreaSqftForReport(row),
    );
    final afterTotalPlotCost = afterRows.fold<double>(
      0.0,
      (sum, row) =>
          sum +
          (_amenityAreaSqftForReport(row) *
              _amenityAllInCostSqftForReport(row)),
    );
    final afterTotalValue = afterRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenitySaleValueForReport(row),
    );
    final afterTotalReceived = afterRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityPaymentAmountForReport(row),
    );
    final afterTotalPending = afterRows.fold<double>(
      0.0,
      (sum, row) =>
          sum +
          math.max(
            0.0,
            _amenitySaleValueForReport(row) -
                _amenityPaymentAmountForReport(row),
          ),
    );
    final afterTotalGrossProfit = afterTotalValue - afterTotalPlotCost;

    final pendingTotalAreaSqft = pendingRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityAreaSqftForReport(row),
    );
    final pendingTotalValue = pendingRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenitySaleValueForReport(row),
    );
    final pendingTotalReceived = pendingRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityPaymentAmountForReport(row),
    );
    final pendingTotalPending = pendingRows.fold<double>(
      0.0,
      (sum, row) =>
          sum +
          math.max(
            0.0,
            _amenitySaleValueForReport(row) -
                _amenityPaymentAmountForReport(row),
          ),
    );
    final pendingAvgRateSqft = pendingTotalAreaSqft > 0
        ? pendingTotalValue / pendingTotalAreaSqft
        : 0.0;

    final tableBlocks = tableBlocksOverride ??
        <Map<String, dynamic>>[
          {
            'tableType': _amenitySection8TableSales,
            'rows': allRows,
            'continued': false,
            'rowStartIndex': 0,
            'showTotalRow': true,
            'showPlaceholderRow': false,
          },
          {
            'tableType': _amenitySection8TableAfterSales,
            'rows': allRows,
            'continued': false,
            'rowStartIndex': 0,
            'showTotalRow': true,
            'showPlaceholderRow': false,
          },
          {
            'tableType': _amenitySection8TablePending,
            'rows': pendingRows,
            'continued': false,
            'rowStartIndex': 0,
            'showTotalRow': true,
            'showPlaceholderRow': pendingRows.isEmpty,
          },
        ];

    final sectionTitle =
        isContinuation ? '8. Amenity Area (Cont.)' : '8. Amenity Area';
    return _buildSection56LandscapeScaffold(
      pageNumber: pageNumber,
      sectionTitle: sectionTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxTableExtent = math.max(
                    0.0,
                    math.min(
                      _landscapeSection56TableUsableExtentPx(),
                      constraints.maxWidth - 24.0,
                    ),
                  );
                  final tableHeight = math.min(
                    maxTableExtent,
                    constraints.maxHeight,
                  );
                  return Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 16),
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SizedBox(
                          height: tableHeight,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (tableBlocks.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    '-',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                ),
                              ...tableBlocks.asMap().entries.map((entry) {
                                final block = entry.value;
                                final tableType =
                                    (block['tableType'] ?? '').toString();
                                final rowsRaw =
                                    block['rows'] as List<dynamic>? ?? const [];
                                final rowsChunk = rowsRaw
                                    .map((row) => row is Map
                                        ? Map<String, dynamic>.from(row)
                                        : <String, dynamic>{})
                                    .toList(growable: false);
                                final continued = block['continued'] == true;
                                final rowStartIndex =
                                    (block['rowStartIndex'] as int?) ?? 0;
                                final showTotalRow =
                                    block['showTotalRow'] == true;
                                final showPlaceholderRow =
                                    block['showPlaceholderRow'] == true;
                                final isLastBlock =
                                    entry.key == tableBlocks.length - 1;

                                Widget blockWidget;
                                switch (tableType) {
                                  case _amenitySection8TableSales:
                                    blockWidget =
                                        _buildReportPage8AmenitySalesBlock(
                                      rowsChunk: rowsChunk,
                                      rowStartIndex: rowStartIndex,
                                      continued: continued,
                                      showTotalRow: showTotalRow,
                                      soldCount: soldCount,
                                      totalRowsCount: allRows.length,
                                      salesTotalAreaSqft: salesTotalAreaSqft,
                                      salesTotalPlotCost: salesTotalPlotCost,
                                      salesTotalValue: salesTotalValue,
                                      salesAvgRateSqft: salesAvgRateSqft,
                                    );
                                    break;
                                  case _amenitySection8TableAfterSales:
                                    blockWidget =
                                        _buildReportPage8AmenityAfterSalesBlock(
                                      rowsChunk: rowsChunk,
                                      rowStartIndex: rowStartIndex,
                                      continued: continued,
                                      showTotalRow: showTotalRow,
                                      soldCount: soldCount,
                                      totalRowsCount: allRows.length,
                                      afterTotalAreaSqft: afterTotalAreaSqft,
                                      afterTotalPlotCost: afterTotalPlotCost,
                                      afterTotalValue: afterTotalValue,
                                      afterTotalReceived: afterTotalReceived,
                                      afterTotalPending: afterTotalPending,
                                      afterTotalGrossProfit:
                                          afterTotalGrossProfit,
                                    );
                                    break;
                                  case _amenitySection8TablePending:
                                    blockWidget =
                                        _buildReportPage8AmenityPendingBlock(
                                      rowsChunk: rowsChunk,
                                      rowStartIndex: rowStartIndex,
                                      continued: continued,
                                      showTotalRow: showTotalRow,
                                      showPlaceholderRow: showPlaceholderRow,
                                      pendingTotalAreaSqft:
                                          pendingTotalAreaSqft,
                                      pendingAvgRateSqft: pendingAvgRateSqft,
                                      pendingTotalValue: pendingTotalValue,
                                      pendingTotalReceived:
                                          pendingTotalReceived,
                                      pendingTotalPending: pendingTotalPending,
                                    );
                                    break;
                                  default:
                                    blockWidget = const SizedBox.shrink();
                                }

                                return Padding(
                                  padding: EdgeInsets.only(
                                      bottom: isLastBlock ? 0 : 12),
                                  child: blockWidget,
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportPage8AmenitySalesBlock({
    required List<Map<String, dynamic>> rowsChunk,
    required int rowStartIndex,
    required bool continued,
    required bool showTotalRow,
    required int soldCount,
    required int totalRowsCount,
    required double salesTotalAreaSqft,
    required double salesTotalPlotCost,
    required double salesTotalValue,
    required double salesAvgRateSqft,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          continued
              ? '8.1  Amenity Area Wise Sales Summary (Cont.)'
              : '8.1  Amenity Area Wise Sales Summary',
          style: GoogleFonts.inriaSerif(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Amenity Area',
          style: GoogleFonts.inriaSerif(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        if (!continued) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '$soldCount / $totalRowsCount Amenity Area sold',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                '•',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Area: ${_formatTo2Decimals(_displayAreaFromSqft(salesTotalAreaSqft))} $_areaUnitSuffix',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                '•',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Total Plot Cost: ₹ ${_formatTo2Decimals(salesTotalPlotCost)}',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                '•',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Total Sales Value: ₹ ${_formatTo2Decimals(salesTotalValue)}',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ] else ...[
          const SizedBox(height: 6),
        ],
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFF404040),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              Container(
                color: const Color(0xFF404040),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTableCell('Sl. No.', 31,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Amenity Area', 94,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Area ($_areaUnitSuffix)', 108,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Plot Cost (₹)', 86,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell(
                      'Sale All-in Cost (₹/$_areaUnitSuffix)',
                      92,
                      isHeader: true,
                      keepOriginalWidth: true,
                    ),
                    _buildTableCell('Sale Value (₹)', 86,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Buyer Name', 88,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Buyer\'s Contact', 72,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Agent', 88,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Sale Date', 60,
                        isHeader: true, keepOriginalWidth: true),
                  ],
                ),
              ),
              ...List.generate(rowsChunk.length, (index) {
                final row = rowsChunk[index];
                final status = _amenityStatusForReport(row);
                final isSold = status == 'sold';
                final areaSqft = _amenityAreaSqftForReport(row);
                final plotCost = areaSqft * _amenityAllInCostSqftForReport(row);
                final saleRate = _amenitySalePriceSqftForReport(row);
                final saleValue = _amenitySaleValueForReport(row);
                return Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.black.withOpacity(0.2),
                        width: 0.25,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTableCell('${rowStartIndex + index + 1}', 31,
                          keepOriginalWidth: true),
                      _buildTableCell(_amenityNameForReport(row), 94,
                          keepOriginalWidth: true),
                      _buildTableCell(
                        '${_formatTo2Decimals(_displayAreaFromSqft(areaSqft))} $_areaUnitSuffix',
                        108,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        isSold ? '₹ ${_formatTo2Decimals(plotCost)}' : '₹ -',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        isSold
                            ? '₹ ${_formatTo2Decimals(_displayRateFromSqft(saleRate))}'
                            : '₹ -',
                        92,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        isSold ? '₹ ${_formatTo2Decimals(saleValue)}' : '₹ -',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        isSold ? _amenityBuyerLabelForReport(row) : '-',
                        88,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        isSold ? _amenityBuyerContactForReport(row) : '-',
                        72,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        _amenityAgentLabelForReport(row),
                        88,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        isSold ? _amenitySaleDateLabelForReport(row) : '-',
                        60,
                        keepOriginalWidth: true,
                      ),
                    ],
                  ),
                );
              }),
              if (showTotalRow)
                Container(
                  color: const Color(0xFFCFCFCF),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTableCell('Total', 31, keepOriginalWidth: true),
                      _buildTableCell('', 94, keepOriginalWidth: true),
                      _buildTableCell(
                        '${_formatTo2Decimals(_displayAreaFromSqft(salesTotalAreaSqft))} $_areaUnitSuffix',
                        108,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(salesTotalPlotCost)}',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(_displayRateFromSqft(salesAvgRateSqft))}',
                        92,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(salesTotalValue)}',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell('', 88, keepOriginalWidth: true),
                      _buildTableCell('', 72, keepOriginalWidth: true),
                      _buildTableCell('', 88, keepOriginalWidth: true),
                      _buildTableCell('', 60, keepOriginalWidth: true),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReportPage8AmenityAfterSalesBlock({
    required List<Map<String, dynamic>> rowsChunk,
    required int rowStartIndex,
    required bool continued,
    required bool showTotalRow,
    required int soldCount,
    required int totalRowsCount,
    required double afterTotalAreaSqft,
    required double afterTotalPlotCost,
    required double afterTotalValue,
    required double afterTotalReceived,
    required double afterTotalPending,
    required double afterTotalGrossProfit,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          continued
              ? '8.2  Amenity Area Wise After Sales Summary (Cont.)'
              : '8.2  Amenity Area Wise After Sales Summary',
          style: GoogleFonts.inriaSerif(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Amenity Area',
          style: GoogleFonts.inriaSerif(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        if (!continued) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '$soldCount / $totalRowsCount plots sold',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                '•',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Area: ${_formatTo2Decimals(_displayAreaFromSqft(afterTotalAreaSqft))} $_areaUnitSuffix',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                '•',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Total Plot Cost: ₹ ${_formatTo2Decimals(afterTotalPlotCost)}',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                '•',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Total Sales Value: ₹ ${_formatTo2Decimals(afterTotalValue)}',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(
            spacing: 8,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Received Amount: ₹ ${_formatTo2Decimals(afterTotalReceived)}',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                '•',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Pending Amount: ₹ ${_formatTo2Decimals(afterTotalPending)}',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                '•',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Gross Profit: ₹ ${_formatTo2Decimals(afterTotalGrossProfit)}',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ] else ...[
          const SizedBox(height: 6),
        ],
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFF404040),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              Container(
                color: const Color(0xFF404040),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTableCell('Sl. No.', 31,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Plot Number', 62,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Area ($_areaUnitSuffix)', 108,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Plot Cost (₹)', 86,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Sale Value (₹)', 86,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Gross Profit (₹)', 86,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Received Amount (₹)', 102,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Pending Amount (₹)', 99,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Sale Date', 60,
                        isHeader: true, keepOriginalWidth: true),
                  ],
                ),
              ),
              ...List.generate(rowsChunk.length, (index) {
                final row = rowsChunk[index];
                final status = _amenityStatusForReport(row);
                final includeFinancial =
                    status == 'sold' || status == 'pending';
                final areaSqft = _amenityAreaSqftForReport(row);
                final plotCost = areaSqft * _amenityAllInCostSqftForReport(row);
                final saleValue = _amenitySaleValueForReport(row);
                final received = _amenityPaymentAmountForReport(row);
                final pending = math.max(0.0, saleValue - received);
                final grossProfit = saleValue - plotCost;
                return Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.black.withOpacity(0.2),
                        width: 0.25,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTableCell('${rowStartIndex + index + 1}', 31,
                          keepOriginalWidth: true),
                      _buildTableCell(_amenityNameForReport(row), 62,
                          keepOriginalWidth: true),
                      _buildTableCell(
                        '${_formatTo2Decimals(_displayAreaFromSqft(areaSqft))} $_areaUnitSuffix',
                        108,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        includeFinancial
                            ? '₹ ${_formatTo2Decimals(plotCost)}'
                            : '₹ -',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        includeFinancial
                            ? '₹ ${_formatTo2Decimals(saleValue)}'
                            : '₹ -',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        includeFinancial
                            ? '₹ ${_formatTo2Decimals(grossProfit)}'
                            : '₹ -',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        includeFinancial
                            ? '₹ ${_formatTo2Decimals(received)}'
                            : '₹ -',
                        102,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        includeFinancial
                            ? '₹ ${_formatTo2Decimals(pending)}'
                            : '₹ -',
                        99,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        includeFinancial
                            ? _amenitySaleDateLabelForReport(row)
                            : '-',
                        60,
                        keepOriginalWidth: true,
                      ),
                    ],
                  ),
                );
              }),
              if (showTotalRow)
                Container(
                  color: const Color(0xFFCFCFCF),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTableCell('Total', 31, keepOriginalWidth: true),
                      _buildTableCell('', 62, keepOriginalWidth: true),
                      _buildTableCell(
                        '${_formatTo2Decimals(_displayAreaFromSqft(afterTotalAreaSqft))} $_areaUnitSuffix',
                        108,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(afterTotalPlotCost)}',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(afterTotalValue)}',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(afterTotalGrossProfit)}',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(afterTotalReceived)}',
                        102,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(afterTotalPending)}',
                        99,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell('', 60, keepOriginalWidth: true),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReportPage8AmenityPendingBlock({
    required List<Map<String, dynamic>> rowsChunk,
    required int rowStartIndex,
    required bool continued,
    required bool showTotalRow,
    required bool showPlaceholderRow,
    required double pendingTotalAreaSqft,
    required double pendingAvgRateSqft,
    required double pendingTotalValue,
    required double pendingTotalReceived,
    required double pendingTotalPending,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          continued
              ? '8.3  Amenity Area Pending Payment (Cont.)'
              : '8.3  Amenity Area Pending Payment',
          style: GoogleFonts.inriaSerif(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFF404040),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              Container(
                color: const Color(0xFF404040),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTableCell('Sl. No.', 31,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Plot Number', 62,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Area ($_areaUnitSuffix)', 108,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Sale Value (₹/$_areaUnitSuffix)', 78,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Sale Value (₹)', 86,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Received Amount (₹)', 102,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Pending Amount (₹)', 99,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Buyer Name', 99,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Buyer\'s Contact', 72,
                        isHeader: true, keepOriginalWidth: true),
                    _buildTableCell('Sale Date', 60,
                        isHeader: true, keepOriginalWidth: true),
                  ],
                ),
              ),
              if (showPlaceholderRow)
                Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.black.withOpacity(0.2),
                        width: 0.25,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTableCell('-', 31, keepOriginalWidth: true),
                      _buildTableCell('-', 62, keepOriginalWidth: true),
                      _buildTableCell('-', 108, keepOriginalWidth: true),
                      _buildTableCell('-', 78, keepOriginalWidth: true),
                      _buildTableCell('-', 86, keepOriginalWidth: true),
                      _buildTableCell('-', 102, keepOriginalWidth: true),
                      _buildTableCell('-', 99, keepOriginalWidth: true),
                      _buildTableCell('-', 99, keepOriginalWidth: true),
                      _buildTableCell('-', 72, keepOriginalWidth: true),
                      _buildTableCell('-', 60, keepOriginalWidth: true),
                    ],
                  ),
                ),
              ...List.generate(rowsChunk.length, (index) {
                final row = rowsChunk[index];
                final areaSqft = _amenityAreaSqftForReport(row);
                final saleRate = _amenitySalePriceSqftForReport(row);
                final saleValue = _amenitySaleValueForReport(row);
                final received = _amenityPaymentAmountForReport(row);
                final pending = math.max(0.0, saleValue - received);
                return Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.black.withOpacity(0.2),
                        width: 0.25,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTableCell('${rowStartIndex + index + 1}', 31,
                          keepOriginalWidth: true),
                      _buildTableCell(_amenityNameForReport(row), 62,
                          keepOriginalWidth: true),
                      _buildTableCell(
                        '${_formatTo2Decimals(_displayAreaFromSqft(areaSqft))} $_areaUnitSuffix',
                        108,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(_displayRateFromSqft(saleRate))}',
                        78,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(saleValue)}',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(received)}',
                        102,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(pending)}',
                        99,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        _amenityBuyerLabelForReport(row),
                        99,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        _amenityBuyerContactForReport(row),
                        72,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        _amenitySaleDateLabelForReport(row),
                        60,
                        keepOriginalWidth: true,
                      ),
                    ],
                  ),
                );
              }),
              if (showTotalRow)
                Container(
                  color: const Color(0xFFCFCFCF),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTableCell('Total', 31, keepOriginalWidth: true),
                      _buildTableCell('', 62, keepOriginalWidth: true),
                      _buildTableCell(
                        '${_formatTo2Decimals(_displayAreaFromSqft(pendingTotalAreaSqft))} $_areaUnitSuffix',
                        108,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(_displayRateFromSqft(pendingAvgRateSqft))}',
                        78,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(pendingTotalValue)}',
                        86,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(pendingTotalReceived)}',
                        102,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell(
                        '₹ ${_formatTo2Decimals(pendingTotalPending)}',
                        99,
                        keepOriginalWidth: true,
                      ),
                      _buildTableCell('', 99, keepOriginalWidth: true),
                      _buildTableCell('', 72, keepOriginalWidth: true),
                      _buildTableCell('', 60, keepOriginalWidth: true),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatCurrencyCompactReport(double value) {
    final absValue = value.abs();
    final hasFraction = absValue % 1 != 0;
    final formatted = absValue.toStringAsFixed(hasFraction ? 2 : 0);
    return value < 0 ? '-₹ $formatted' : '₹ $formatted';
  }

  Map<String, double> _buildCompensationTotalsForReport() {
    final totalAgentCompensation =
        double.tryParse(getDashboardValue('totalAgentCompensation')) ?? 0.0;
    final totalProjectManagerCompensation =
        double.tryParse(getDashboardValue('totalProjectManagerCompensation')) ??
            0.0;
    final totalCompensation =
        double.tryParse(getDashboardValue('totalCompensation')) ?? 0.0;

    return {
      'totalAgentCompensation': totalAgentCompensation,
      'totalProjectManagerCompensation': totalProjectManagerCompensation,
      'totalCompensation': totalCompensation,
    };
  }

  Widget _buildPendingCompensationReportPage({required int pageNumber}) {
    final compensation = _buildCompensationTotalsForReport();
    final totalAgentCompensation = compensation['totalAgentCompensation'] ?? 0;
    final totalProjectManagerCompensation =
        compensation['totalProjectManagerCompensation'] ?? 0;
    final totalCompensation = compensation['totalCompensation'] ?? 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 55,
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Color(0xFF404040),
                      width: 0.5,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _reportHeaderUnitText,
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF404040),
                      ),
                    ),
                    Text(
                      _reportHeaderDateText,
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF404040),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '1.5  Compensation',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF404040),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFF404040),
                      width: 0.5,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        color: const Color(0xFF404040),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Field',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 158,
                              child: Text(
                                'Value',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.black.withOpacity(0.25),
                              width: 0.25,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Total Agent Compensation',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  fontWeight: FontWeight.normal,
                                  color: const Color(0xFF404040),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 158,
                              child: Text(
                                _formatCurrencyCompactReport(
                                  totalAgentCompensation,
                                ),
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  fontWeight: FontWeight.normal,
                                  color: const Color(0xFF404040),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.black.withOpacity(0.25),
                              width: 0.25,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Total Project Manager Compensation',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  fontWeight: FontWeight.normal,
                                  color: const Color(0xFF404040),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 158,
                              child: Text(
                                _formatCurrencyCompactReport(
                                  totalProjectManagerCompensation,
                                ),
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  fontWeight: FontWeight.normal,
                                  color: const Color(0xFF404040),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        color: const Color(0x40404040),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Total Compensation',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black,
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 158,
                              child: Text(
                                _formatCurrencyCompactReport(totalCompensation),
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 10,
                                  fontWeight: FontWeight.normal,
                                  color: const Color(0xFF404040),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        _buildStandardReportFooter(pageNumber),
      ],
    );
  }

  List<Widget> _buildProjectOverviewPages({required int startPageNumber}) {
    final hasAmenityArea = _hasAmenityAreaForReport();
    final sections = _hasPendingPlotsForReport()
        ? _buildProjectOverviewSectionsWithPending()
        : _buildProjectOverviewSectionsWithoutPending();
    final firstPageSectionCount = hasAmenityArea ? 3 : 4;
    final firstPageSections = sections.take(firstPageSectionCount).toList();
    final secondPageSections = sections.skip(firstPageSectionCount).toList();

    if (firstPageSections.isEmpty && secondPageSections.isEmpty) {
      return [
        _buildProjectOverviewPage(
          sections: const <Map<String, dynamic>>[],
          pageNumber: startPageNumber,
          isContinuation: false,
          showChapterTitle: true,
        ),
      ];
    }
    if (secondPageSections.isEmpty) {
      return [
        _buildProjectOverviewPage(
          sections: firstPageSections,
          pageNumber: startPageNumber,
          isContinuation: false,
          showChapterTitle: true,
        ),
      ];
    }
    return [
      _buildProjectOverviewPage(
        sections: firstPageSections,
        pageNumber: startPageNumber,
        isContinuation: false,
        showChapterTitle: true,
      ),
      _buildProjectOverviewPage(
        sections: secondPageSections,
        pageNumber: startPageNumber + 1,
        isContinuation: true,
        showChapterTitle: false,
      ),
    ];
  }

  List<Map<String, dynamic>> _buildProjectOverviewSectionsWithoutPending() {
    String getValue(String key, [dynamic defaultValue]) {
      final value =
          _readValueFromDashboardThenProject([key], fallback: defaultValue);
      return _displayOrDash(value);
    }

    final nonSellableAreas = _collectNonSellableAreasForReport();
    final amenityAreas = _collectAmenityAreasForReport();
    final hasAmenityArea = amenityAreas.isNotEmpty;
    final amenitySoldCount = amenityAreas
        .where((row) => _amenityStatusForReport(row) == 'sold')
        .length;
    final amenityAvailableCount = amenityAreas
        .where((row) => _amenityStatusForReport(row) == 'available')
        .length;
    final totalAmenityAreaSqft = amenityAreas.fold<double>(
      0.0,
      (sum, area) => sum + _amenityAreaSqftForReport(area),
    );
    final sellingAreaLabel =
        hasAmenityArea ? 'Approved Selling Area' : 'Saleable Plot Area';
    final projectCostRows = <List<String>>[
      ['Total Project Area', _formatAreaWithUnit(getValue('totalArea'))],
      [sellingAreaLabel, _formatAreaWithUnit(getValue('sellingArea'))],
      ['Non-Sellable Area', _formatAreaWithUnit(getValue('nonSellableArea'))],
      ...nonSellableAreas.map((row) {
        final label = _plotFieldStr(row, ['name']);
        final resolvedLabel = label == '-' ? 'Non-Sellable Area' : label;
        return <String>[
          '. ${_formatAreaLabelWithUnitForReport(resolvedLabel, _toDouble(row['area']))}',
          '',
        ];
      }),
      if (hasAmenityArea)
        ['Amenity Area', _formatAreaWithUnit(totalAmenityAreaSqft)],
      ...amenityAreas.map((row) {
        final label =
            _plotFieldStr(row, ['name', 'amenityName', 'amenity_name']);
        final resolvedLabel = label == '-' ? 'Amenity Area' : label;
        return <String>[
          '. ${_formatAreaLabelWithUnitForReport(resolvedLabel, _amenityAreaSqftForReport(row))}',
          '',
        ];
      }),
      ['All-in Cost', _formatRateWithUnit(getValue('allInCost'))],
      [
        'Estimated Project Cost',
        _formatCurrencyOrDash(_projectData['estimatedDevelopmentCost'])
      ],
      ['Total Expenses', _formatCurrencyOrDash(_projectData['totalExpenses'])],
    ];
    final siteOverviewRows = <List<String>>[
      ['Total Number of Layouts', getValue('totalLayouts')],
      ['Total Number of Plots', getValue('totalPlots')],
      ['Total Number of Plot Sold', getValue('soldPlots')],
      ['Total Number of Plot Available', getValue('availablePlots')],
      if (hasAmenityArea)
        ['Total Number of Amenity Plot', '${amenityAreas.length}'],
      if (hasAmenityArea)
        ['Total Number of Amenity Plot Sold', '$amenitySoldCount'],
      if (hasAmenityArea)
        ['Total Number of Amenity Plot Available', '$amenityAvailableCount'],
    ];
    final grossProfit =
        double.tryParse(getDashboardValue('grossProfit')) ?? 0.0;
    final netProfit = double.tryParse(getDashboardValue('netProfit')) ?? 0.0;
    final roi = double.tryParse(getDashboardValue('roi')) ?? 0.0;
    final profitMargin =
        double.tryParse(getDashboardValue('profitMargin')) ?? 0.0;
    final salesMetrics = _buildSalesHighlightsMetricsForReport();

    return [
      {
        'type': 'table',
        'title': '1.1  Project Cost & Area',
        'rows': projectCostRows,
        'allowSplit': true,
        'gapAfter': 8.0,
      },
      {
        'type': 'table',
        'title': '1.2  Site Overview',
        'rows': siteOverviewRows,
        'allowSplit': false,
        'gapAfter': 8.0,
      },
      {
        'type': 'custom',
        'builder': () => _buildProjectOverviewProfitAndRoiTableReport(
              amountReceivedGrossProfit: grossProfit,
              expectedGrossProfit: grossProfit,
              amountReceivedNetProfit: netProfit,
              expectedNetProfit: netProfit,
              amountReceivedRoi: roi,
              expectedRoi: roi,
              amountReceivedProfitMargin: profitMargin,
              expectedProfitMargin: profitMargin,
            ),
        'estimatedHeight': 132.0,
        'gapAfter': 8.0,
      },
      {
        'type': 'custom',
        'builder': () => _buildProjectOverviewSalesHighlightsTableReport(
              overallTotalSalesValue:
                  salesMetrics['overallTotalSalesValue'] ?? 0,
              overallAmountReceived: salesMetrics['overallAmountReceived'] ?? 0,
              overallPendingAmount: salesMetrics['overallPendingAmount'] ?? 0,
              siteTotalSalesValue: salesMetrics['siteTotalSalesValue'] ?? 0,
              siteAmountReceived: salesMetrics['siteAmountReceived'] ?? 0,
              sitePendingAmount: salesMetrics['sitePendingAmount'] ?? 0,
              amenityTotalSalesValue:
                  salesMetrics['amenityTotalSalesValue'] ?? 0,
              amenityAmountReceived: salesMetrics['amenityAmountReceived'] ?? 0,
              amenityPendingAmount: salesMetrics['amenityPendingAmount'] ?? 0,
            ),
        'estimatedHeight': 108.0,
        'gapAfter': 8.0,
      },
      {
        'type': 'custom',
        'builder': _buildProjectOverviewCompensationTableReport,
        'estimatedHeight': 96.0,
        'gapAfter': 8.0,
      },
      {
        'type': 'custom',
        'builder': _buildProjectOverviewPartnerDistributionSectionReport,
        'estimatedHeight': 180.0,
        'gapAfter': 8.0,
      },
      {
        'type': 'custom',
        'builder': _buildProjectOverviewSalesActivitySectionReport,
        'estimatedHeight': 250.0,
        'gapAfter': 0.0,
      },
    ];
  }

  List<Map<String, dynamic>> _collectReportPlotsForOverview() {
    final plots = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    final seenLayoutPlotKeys = <String>{};

    void addPlot(dynamic rawPlot, {String? layoutName, String? layoutId}) {
      if (rawPlot is! Map) return;
      final plot = Map<String, dynamic>.from(rawPlot);
      if (layoutName != null && layoutName.trim().isNotEmpty) {
        final normalizedLayoutName = layoutName.trim();
        if ((plot['layout'] ?? '').toString().trim().isEmpty) {
          plot['layout'] = normalizedLayoutName;
        }
        if ((plot['layoutName'] ?? '').toString().trim().isEmpty) {
          plot['layoutName'] = normalizedLayoutName;
        }
      }
      if (layoutId != null && layoutId.trim().isNotEmpty) {
        final normalizedLayoutId = layoutId.trim();
        if ((plot['layout_id'] ?? '').toString().trim().isEmpty) {
          plot['layout_id'] = normalizedLayoutId;
        }
        if ((plot['layoutId'] ?? '').toString().trim().isEmpty) {
          plot['layoutId'] = normalizedLayoutId;
        }
      }

      final id = (plot['id'] ?? plot['_id'] ?? '').toString().trim();
      if (id.isNotEmpty && !seenIds.add(id)) {
        return;
      }

      if (id.isEmpty) {
        final layoutLabel = _resolveLayoutLabel(plot).trim().toLowerCase();
        final plotNumber = _plotFieldStr(
          plot,
          ['plotNumber', 'plot_no', 'plotNo', 'number', 'plot_number'],
        ).trim().toLowerCase();
        final hasLayout = layoutLabel.isNotEmpty && layoutLabel != 'unknown';
        final hasPlotNumber = plotNumber.isNotEmpty && plotNumber != '-';
        if (hasLayout && hasPlotNumber) {
          final key = '$layoutLabel::$plotNumber';
          if (!seenLayoutPlotKeys.add(key)) {
            return;
          }
        }
      }

      plots.add(plot);
    }

    if (_projectData['layouts'] is List) {
      for (final rawLayout in (_projectData['layouts'] as List)) {
        if (rawLayout is! Map) continue;
        final layout = Map<String, dynamic>.from(rawLayout);
        final layoutName =
            (layout['name'] ?? layout['layoutName'] ?? '').toString();
        final layoutId =
          (layout['id'] ??
              layout['layoutId'] ??
              layout['_id'] ??
              layout['layout_id'] ??
              '')
                .toString();
        final layoutPlots = layout['plots'];
        if (layoutPlots is List && layoutPlots.isNotEmpty) {
          for (final rawPlot in layoutPlots) {
            addPlot(rawPlot, layoutName: layoutName, layoutId: layoutId);
          }
        }
      }
    }

    // Merge top-level plots as well. Some intermediate local payloads can
    // temporarily under-populate `layouts[].plots` before reconciliation.
    if (_projectData['plots'] is List) {
      for (final rawPlot in (_projectData['plots'] as List)) {
        addPlot(rawPlot);
      }
    }

    return plots;
  }

  double _sumPlotPaymentAmountReport(Map<String, dynamic> plot) {
    final rawPayments = plot['payments'];
    if (rawPayments == null) return 0.0;

    List<dynamic> payments;
    if (rawPayments is List) {
      payments = rawPayments;
    } else if (rawPayments is String && rawPayments.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPayments);
        payments = decoded is List ? decoded : const [];
      } catch (_) {
        payments = const [];
      }
    } else {
      payments = const [];
    }

    var total = 0.0;
    for (final rawPayment in payments) {
      if (rawPayment is! Map) continue;
      final payment = Map<String, dynamic>.from(rawPayment);
      final amount = payment['paymentAmount'] ??
          payment['payment_amount'] ??
          payment['amount'];
      total += _toDouble(amount);
    }

    return total;
  }

  double _sumSitePlotCollectionsForReport(Map<String, dynamic> plot) {
    final fromPayments = _sumPlotPaymentAmountReport(plot);
    if (fromPayments > 0) return fromPayments;
    return _toDouble(
      plot['payment_amount'] ?? plot['paymentAmount'] ?? plot['payment'],
    );
  }

  double _computePendingSiteCollectionsForReport() {
    final plots = _collectReportPlotsForOverview();
    if (plots.isEmpty) return 0.0;

    var totalPendingCollections = 0.0;
    for (final plot in plots) {
      final status = _normalizeSiteStatusForReport(plot['status']);
      if (status != 'pending') continue;
      totalPendingCollections += _sumSitePlotCollectionsForReport(plot);
    }
    return totalPendingCollections;
  }

  Map<String, dynamic> _buildPendingOverviewMetricsReport() {
    final plots = _collectReportPlotsForOverview();

    var soldPlotsRevenue = 0.0;
    var collectionsReceived = 0.0;
    var expectedRevenue = 0.0;
    var soldPlotsCount = 0;
    var pendingPlotsCount = 0;
    var availablePlotsCount = 0;

    for (final plot in plots) {
      final status = _normalizeSiteStatusForReport(
        _plotFieldStr(plot, ['status', 'plot_status', 'sale_status']),
      );
      final isSold = status == 'sold';
      final isPending = status == 'pending';
      final isAvailable = status == 'available';

      if (isAvailable) {
        availablePlotsCount++;
      }
      if (!isSold && !isPending) {
        continue;
      }

      final area = _plotFieldDouble(plot, ['area', 'plot_area', 'plotArea']);
      final salePrice = _plotFieldDouble(plot, [
        'salePrice',
        'sale_price',
        'salePricePerSqft',
        'sale_price_per_sqft'
      ]);
      final saleValue = (area > 0 && salePrice > 0) ? area * salePrice : 0.0;

      if (isSold) {
        soldPlotsCount++;
        soldPlotsRevenue += saleValue;
      }
      if (isPending) {
        pendingPlotsCount++;
      }

      expectedRevenue += saleValue;
      collectionsReceived += _sumPlotPaymentAmountReport(plot);
    }

    return {
      'plots': plots,
      'soldPlotsRevenue': soldPlotsRevenue,
      'collectionsReceived': collectionsReceived,
      'expectedRevenue': expectedRevenue,
      'soldPlotsCount': soldPlotsCount,
      'pendingPlotsCount': pendingPlotsCount,
      'availablePlotsCount': availablePlotsCount,
    };
  }

  bool _hasPendingPlotsForReport() {
    final plots = _collectReportPlotsForOverview();
    if (plots.isNotEmpty) {
      for (final plot in plots) {
        final status = _normalizeSiteStatusForReport(
          _plotFieldStr(plot, ['status', 'plot_status', 'sale_status']),
        );
        if (status == 'pending') {
          return true;
        }
      }
      return false;
    }

    final dashboardPending = _toDouble(
      _dashboardDataLocal?['pendingPlots'] ??
          _dashboardDataLocal?['pending_plots'],
    );
    if (dashboardPending > 0) return true;

    final projectPending = _toDouble(
      _projectData['pendingPlots'] ?? _projectData['pending_plots'],
    );
    if (projectPending > 0) return true;

    return false;
  }

  List<Map<String, dynamic>> _collectNonSellableAreasForReport() {
    final rawNonSellableAreas = (_projectData['nonSellableAreas'] is List)
        ? (_projectData['nonSellableAreas'] as List)
        : (_projectData['non_sellable_areas'] is List)
            ? (_projectData['non_sellable_areas'] as List)
            : const <dynamic>[];

    final rows = <Map<String, dynamic>>[];
    for (final raw in rawNonSellableAreas) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final name = _plotFieldStr(row, ['name']);
      final areaSqft = _toDouble(row['area']);
      final hasContent = name != '-' || areaSqft > 0;
      if (hasContent) {
        rows.add(row);
      }
    }
    return rows;
  }

  List<Map<String, dynamic>> _collectAmenityAreasForReport() {
    final rawAmenityAreas = (_projectData['amenityAreas'] is List)
        ? (_projectData['amenityAreas'] as List)
        : (_projectData['amenity_areas'] is List)
            ? (_projectData['amenity_areas'] as List)
            : const <dynamic>[];

    final rows = <Map<String, dynamic>>[];
    for (final raw in rawAmenityAreas) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final name = _plotFieldStr(row, ['name', 'amenityName', 'amenity_name']);
      final areaSqft = _toDouble(row['area']);
      final allInCostSqft = _toDouble(row['all_in_cost'] ??
          row['allInCost'] ??
          row['all_in_cost_per_sqft']);
      final salePriceSqft = _toDouble(
          row['sale_price'] ?? row['salePrice'] ?? row['sale_price_per_sqft']);
      final saleValue = _toDouble(row['sale_value'] ?? row['saleValue']);
      final buyerName =
          _plotFieldStr(row, ['buyer_name', 'buyerName', 'buyer_name_text']);
      final normalizedStatus = _amenityStatusForReport(row);
      final hasContent = name != '-' ||
          areaSqft > 0 ||
          allInCostSqft > 0 ||
          salePriceSqft > 0 ||
          saleValue > 0 ||
          buyerName != '-' ||
          normalizedStatus != 'available';
      if (hasContent) {
        rows.add(row);
      }
    }
    return rows;
  }

  bool _hasAmenityAreaForReport() {
    return _collectAmenityAreasForReport().isNotEmpty;
  }

  String _normalizeAmenityStatusForReport(dynamic rawStatus) {
    final statusTokens = (rawStatus ?? '')
        .toString()
        .trim()
        .toLowerCase()
        .split(RegExp(r'[^a-z]+'))
        .where((token) => token.isNotEmpty)
        .toSet();
    if (statusTokens.contains('reserved') ||
        statusTokens.contains('pending') ||
        statusTokens.contains('blocked')) {
      return 'pending';
    }
    if (statusTokens.contains('sold')) return 'sold';
    return 'available';
  }

  String _amenityStatusForReport(Map<String, dynamic> row) {
    final rawStatus = row['status'] ??
        row['amenity_status'] ??
        row['amenityStatus'] ??
        row['plot_status'] ??
        row['plotStatus'] ??
        row['sale_status'] ??
        row['saleStatus'];
    final normalized = _normalizeAmenityStatusForReport(rawStatus);
    if (normalized != 'available') return normalized;

    // Backward-compatibility: older saves could persist pending rows as
    // available even when sale-stage fields are present.
    final buyerName =
        _plotFieldStr(row, ['buyer_name', 'buyerName', 'buyer_name_text'])
            .trim();
    final saleDate = _readSaleDateValueForReport(row).toString().trim();
    final salePrice = _toDouble(
      row['sale_price'] ?? row['salePrice'] ?? row['sale_price_per_sqft'],
    );
    final saleValue = _amenitySaleValueForReport(row);
    final paymentAmount = _amenityPaymentAmountForReport(row);
    final hasBuyer = buyerName.isNotEmpty && buyerName != '-';
    final hasSaleDate = saleDate.isNotEmpty && saleDate != '-';
    final hasSalesSignal = salePrice > 0 || saleValue > 0;

    if (saleValue > 0 &&
        paymentAmount > 0 &&
        paymentAmount + 0.0001 >= saleValue) {
      return 'sold';
    }
    if (hasBuyer || hasSaleDate || paymentAmount > 0 || hasSalesSignal) {
      return 'pending';
    }
    return normalized;
  }

  double _amenityAreaSqftForReport(Map<String, dynamic> row) {
    return _toDouble(row['area']);
  }

  double _amenityAllInCostSqftForReport(Map<String, dynamic> row) {
    return _toDouble(
      row['all_in_cost'] ?? row['allInCost'] ?? row['all_in_cost_per_sqft'],
    );
  }

  double _amenitySalePriceSqftForReport(Map<String, dynamic> row) {
    return _toDouble(
      row['sale_price'] ?? row['salePrice'] ?? row['sale_price_per_sqft'],
    );
  }

  double _amenitySaleValueForReport(Map<String, dynamic> row) {
    final explicitValue = _toDouble(row['sale_value'] ?? row['saleValue']);
    if (explicitValue > 0) return explicitValue;
    final areaSqft = _amenityAreaSqftForReport(row);
    final salePriceSqft = _amenitySalePriceSqftForReport(row);
    return areaSqft * salePriceSqft;
  }

  double _amenityPaymentAmountForReport(Map<String, dynamic> row) {
    final raw = row['payment'] ?? row['payment_amount'] ?? row['paymentAmount'];
    if (raw is num) return raw.toDouble();
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return 0.0;
      final cleaned = trimmed.replaceAll(RegExp(r'[^0-9.\-]'), '');
      return double.tryParse(cleaned) ?? 0.0;
    }
    return _toDouble(raw);
  }

  String _amenityPartnerLabelForReport(Map<String, dynamic> row) {
    return _plotFieldStr(row, [
      'partner',
      'partner_name',
      'partnerName',
      'partnersName',
      'partners_name',
    ]);
  }

  String _formatCurrencyAlwaysReport(double value) {
    final absValue = value.abs().toStringAsFixed(2);
    return value < 0 ? '-₹ $absValue' : '₹ $absValue';
  }

  String _formatPercentAlwaysReport(double value) {
    return '${value.toStringAsFixed(2)} %';
  }

  Widget _buildPendingProfitAndRoiRowReport({
    required String field,
    required String actual,
    required String booked,
    required String expected,
    bool isLast = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: isLast
              ? BorderSide.none
              : BorderSide(
                  color: Colors.black.withOpacity(0.25),
                  width: 0.25,
                ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(
              field,
              style: GoogleFonts.inriaSerif(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          Expanded(
            child: Text(
              actual,
              style: GoogleFonts.inriaSerif(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          Expanded(
            child: Text(
              booked,
              style: GoogleFonts.inriaSerif(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          Expanded(
            child: Text(
              expected,
              style: GoogleFonts.inriaSerif(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingProfitAndRoiTableReport({
    required double actualGrossProfit,
    required double bookedGrossProfit,
    required double expectedGrossProfit,
    required double actualNetProfit,
    required double bookedNetProfit,
    required double expectedNetProfit,
    required double actualRoi,
    required double bookedRoi,
    required double expectedRoi,
    required double actualProfitMargin,
    required double bookedProfitMargin,
    required double expectedProfitMargin,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '1.3  Profit and ROI',
          style: GoogleFonts.inriaSerif(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFF404040),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              Container(
                color: const Color(0xFF404040),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 74,
                      child: Text(
                        'Field',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Actual (Payments Received)',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Booked (Only Sold Plots)',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Expected (Pipeline)',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _buildPendingProfitAndRoiRowReport(
                field: 'Gross Profit',
                actual: _formatCurrencyAlwaysReport(actualGrossProfit),
                booked: _formatCurrencyAlwaysReport(bookedGrossProfit),
                expected: _formatCurrencyAlwaysReport(expectedGrossProfit),
              ),
              _buildPendingProfitAndRoiRowReport(
                field: 'Net Profit',
                actual: _formatCurrencyAlwaysReport(actualNetProfit),
                booked: _formatCurrencyAlwaysReport(bookedNetProfit),
                expected: _formatCurrencyAlwaysReport(expectedNetProfit),
              ),
              _buildPendingProfitAndRoiRowReport(
                field: 'ROI',
                actual: _formatPercentAlwaysReport(actualRoi),
                booked: _formatPercentAlwaysReport(bookedRoi),
                expected: _formatPercentAlwaysReport(expectedRoi),
              ),
              _buildPendingProfitAndRoiRowReport(
                field: 'Profit Margin',
                actual: _formatPercentAlwaysReport(actualProfitMargin),
                booked: _formatPercentAlwaysReport(bookedProfitMargin),
                expected: _formatPercentAlwaysReport(expectedProfitMargin),
                isLast: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Map<String, dynamic>> _buildProjectOverviewSectionsWithPending() {
    String getValue(String key, [dynamic defaultValue]) {
      final value =
          _readValueFromDashboardThenProject([key], fallback: defaultValue);
      return _displayOrDash(value);
    }

    final metrics = _buildPendingOverviewMetricsReport();
    final plots = (metrics['plots'] as List<Map<String, dynamic>>?) ?? const [];
    final collectionsReceived =
        (metrics['collectionsReceived'] as double?) ?? 0.0;
    final expectedRevenue = (metrics['expectedRevenue'] as double?) ?? 0.0;
    final soldPlotsCount = (metrics['soldPlotsCount'] as int?) ?? 0;
    final availableByStatus = (metrics['availablePlotsCount'] as int?) ?? 0;

    final totalExpenses = _toDouble(
      _dashboardDataLocal?['totalExpenses'] ??
          _dashboardDataLocal?['total_expenses'] ??
          _projectData['totalExpenses'] ??
          _projectData['total_expenses'],
    );
    final totalCompensation =
        double.tryParse(getDashboardValue('totalCompensation')) ?? 0.0;

    final actualGrossProfit = collectionsReceived - totalExpenses;

    final actualNetProfit = actualGrossProfit - totalCompensation;

    final actualRoi =
        totalExpenses > 0 ? (actualNetProfit / totalExpenses) * 100 : 0.0;

    final actualProfitMargin = collectionsReceived > 0
        ? (actualNetProfit / collectionsReceived) * 100
        : 0.0;

    // Keep report "Expected (Pipeline)" aligned with Dashboard Overview values.
    final expectedGrossProfit =
      double.tryParse(getDashboardValue('grossProfit')) ??
        _computeOverviewGrossProfitForReport();
    final expectedNetProfit = double.tryParse(getDashboardValue('netProfit')) ??
      _computeOverviewNetProfitForReport();
    final expectedRoi = double.tryParse(getDashboardValue('roi')) ??
      _computeRoiForReport();
    final expectedProfitMargin =
      double.tryParse(getDashboardValue('profitMargin')) ??
        _computeProfitMarginForReport();

    final totalLayouts = _toDouble(
      _dashboardDataLocal?['totalLayouts'] ??
          _projectData['totalLayouts'] ??
          _projectData['total_layouts'],
    ).round();

    final totalPlots = plots.isNotEmpty
        ? plots.length
        : _toDouble(
            _dashboardDataLocal?['totalPlots'] ??
                _projectData['totalPlots'] ??
                _projectData['total_plots'],
          ).round();

    final soldPlots = plots.isNotEmpty
        ? soldPlotsCount
        : _toDouble(
            _dashboardDataLocal?['soldPlots'] ??
                _projectData['soldPlots'] ??
                _projectData['sold_plots'],
          ).round();
    final pendingPlotsFallback = _toDouble(
      _dashboardDataLocal?['pendingPlots'] ??
          _dashboardDataLocal?['pending_plots'] ??
          _projectData['pendingPlots'] ??
          _projectData['pending_plots'],
    ).round();

    final availablePlots = plots.isNotEmpty
        ? availableByStatus
        : math.max(0, totalPlots - soldPlots - pendingPlotsFallback);
    final nonSellableAreas = _collectNonSellableAreasForReport();
    final amenityAreas = _collectAmenityAreasForReport();
    final hasAmenityArea = amenityAreas.isNotEmpty;
    final amenitySoldCount = amenityAreas
        .where((row) => _amenityStatusForReport(row) == 'sold')
        .length;
    final amenityAvailableCount = amenityAreas
        .where((row) => _amenityStatusForReport(row) == 'available')
        .length;
    final totalAmenityAreaSqft = amenityAreas.fold<double>(
      0.0,
      (sum, area) => sum + _amenityAreaSqftForReport(area),
    );
    final sellingAreaLabel =
        hasAmenityArea ? 'Approved Selling Area' : 'Saleable Plot Area';
    final projectCostRows = <List<String>>[
      ['Total Project Area', _formatAreaWithUnit(getValue('totalArea'))],
      [sellingAreaLabel, _formatAreaWithUnit(getValue('sellingArea'))],
      ['Non-Sellable Area', _formatAreaWithUnit(getValue('nonSellableArea'))],
      ...nonSellableAreas.map((row) {
        final label = _plotFieldStr(row, ['name']);
        final resolvedLabel = label == '-' ? 'Non-Sellable Area' : label;
        return <String>[
          '. ${_formatAreaLabelWithUnitForReport(resolvedLabel, _toDouble(row['area']))}',
          '',
        ];
      }),
      if (hasAmenityArea)
        ['Amenity Area', _formatAreaWithUnit(totalAmenityAreaSqft)],
      ...amenityAreas.map((row) {
        final label =
            _plotFieldStr(row, ['name', 'amenityName', 'amenity_name']);
        final resolvedLabel = label == '-' ? 'Amenity Area' : label;
        return <String>[
          '. ${_formatAreaLabelWithUnitForReport(resolvedLabel, _amenityAreaSqftForReport(row))}',
          '',
        ];
      }),
      ['All-in Cost', _formatRateWithUnit(getValue('allInCost'))],
      [
        'Estimated Project Cost',
        _formatCurrencyOrDash(_projectData['estimatedDevelopmentCost'])
      ],
      [
        'Total Expenses',
        _formatCurrencyOrDash(_dashboardDataLocal?['totalExpenses'] ??
            _projectData['totalExpenses'])
      ],
    ];
    final siteOverviewRows = <List<String>>[
      ['Total Number of Layouts', '$totalLayouts'],
      ['Total Number of Plots', '$totalPlots'],
      ['Total Number of Plot Sold', '$soldPlots'],
      ['Total Number of Plot Available', '$availablePlots'],
      if (hasAmenityArea)
        ['Total Number of Amenity Plot', '${amenityAreas.length}'],
      if (hasAmenityArea)
        ['Total Number of Amenity Plot Sold', '$amenitySoldCount'],
      if (hasAmenityArea)
        ['Total Number of Amenity Plot Available', '$amenityAvailableCount'],
    ];
    final salesMetrics = _buildSalesHighlightsMetricsForReport();

    return [
      {
        'type': 'table',
        'title': '1.1  Project Cost & Area',
        'rows': projectCostRows,
        'allowSplit': true,
        'gapAfter': 8.0,
      },
      {
        'type': 'table',
        'title': '1.2  Site Overview',
        'rows': siteOverviewRows,
        'allowSplit': false,
        'gapAfter': 8.0,
      },
      {
        'type': 'custom',
        'builder': () => _buildProjectOverviewProfitAndRoiTableReport(
              amountReceivedGrossProfit: actualGrossProfit,
              expectedGrossProfit: expectedGrossProfit,
              amountReceivedNetProfit: actualNetProfit,
              expectedNetProfit: expectedNetProfit,
              amountReceivedRoi: actualRoi,
              expectedRoi: expectedRoi,
              amountReceivedProfitMargin: actualProfitMargin,
              expectedProfitMargin: expectedProfitMargin,
            ),
        'estimatedHeight': 132.0,
        'gapAfter': 8.0,
      },
      {
        'type': 'custom',
        'builder': () => _buildProjectOverviewSalesHighlightsTableReport(
              overallTotalSalesValue:
                  salesMetrics['overallTotalSalesValue'] ?? 0,
              overallAmountReceived: salesMetrics['overallAmountReceived'] ?? 0,
              overallPendingAmount: salesMetrics['overallPendingAmount'] ?? 0,
              siteTotalSalesValue: salesMetrics['siteTotalSalesValue'] ?? 0,
              siteAmountReceived: salesMetrics['siteAmountReceived'] ?? 0,
              sitePendingAmount: salesMetrics['sitePendingAmount'] ?? 0,
              amenityTotalSalesValue:
                  salesMetrics['amenityTotalSalesValue'] ?? 0,
              amenityAmountReceived: salesMetrics['amenityAmountReceived'] ?? 0,
              amenityPendingAmount: salesMetrics['amenityPendingAmount'] ?? 0,
            ),
        'estimatedHeight': 108.0,
        'gapAfter': 8.0,
      },
      {
        'type': 'custom',
        'builder': _buildProjectOverviewCompensationTableReport,
        'estimatedHeight': 96.0,
        'gapAfter': 8.0,
      },
      {
        'type': 'custom',
        'builder': _buildProjectOverviewPartnerDistributionSectionReport,
        'estimatedHeight': 180.0,
        'gapAfter': 8.0,
      },
      {
        'type': 'custom',
        'builder': _buildProjectOverviewSalesActivitySectionReport,
        'estimatedHeight': 250.0,
        'gapAfter': 0.0,
      },
    ];
  }

  String _formatPercentCompactReport(double value) {
    final absValue = value.abs();
    final hasFraction = absValue % 1 != 0;
    final formatted = absValue.toStringAsFixed(hasFraction ? 2 : 0);
    return value < 0 ? '-$formatted %' : '$formatted %';
  }

  Map<String, double> _buildAmenitySalesMetricsForReport() {
    final amenityAreas = _collectAmenityAreasForReport();
    var totalSalesValue = 0.0;
    var amountReceived = 0.0;

    for (final row in amenityAreas) {
      final status = _amenityStatusForReport(row);
      if (status != 'sold' && status != 'pending') continue;
      totalSalesValue += _amenitySaleValueForReport(row);
      amountReceived += _amenityPaymentAmountForReport(row);
    }

    final pendingAmount = math.max(0.0, totalSalesValue - amountReceived);
    return {
      'totalSalesValue': totalSalesValue,
      'amountReceived': amountReceived,
      'pendingAmount': pendingAmount,
    };
  }

  Map<String, double> _buildSalesHighlightsMetricsForReport() {
    final siteMetrics = _buildPendingOverviewMetricsReport();
    var siteTotalSalesValue =
        (siteMetrics['expectedRevenue'] as double?) ?? 0.0;
    var siteAmountReceived =
        (siteMetrics['collectionsReceived'] as double?) ?? 0.0;

    if (siteTotalSalesValue <= 0 && siteAmountReceived <= 0) {
      siteTotalSalesValue = _readMetricFromReportSources(
        ['totalSalesValue', 'total_sales_value'],
      );
      // In the absence of explicit collection metrics, align with total sales.
      siteAmountReceived = siteTotalSalesValue;
    }

    final sitePendingAmount =
        math.max(0.0, siteTotalSalesValue - siteAmountReceived);
    final amenityMetrics = _buildAmenitySalesMetricsForReport();
    final amenityTotalSalesValue = amenityMetrics['totalSalesValue'] ?? 0.0;
    final amenityAmountReceived = amenityMetrics['amountReceived'] ?? 0.0;
    final amenityPendingAmount = amenityMetrics['pendingAmount'] ?? 0.0;

    return {
      'overallTotalSalesValue': siteTotalSalesValue + amenityTotalSalesValue,
      'overallAmountReceived': siteAmountReceived + amenityAmountReceived,
      'overallPendingAmount': sitePendingAmount + amenityPendingAmount,
      'siteTotalSalesValue': siteTotalSalesValue,
      'siteAmountReceived': siteAmountReceived,
      'sitePendingAmount': sitePendingAmount,
      'amenityTotalSalesValue': amenityTotalSalesValue,
      'amenityAmountReceived': amenityAmountReceived,
      'amenityPendingAmount': amenityPendingAmount,
    };
  }

  Widget _buildProjectOverviewProfitAndRoiRowReport({
    required String field,
    required String amountReceived,
    required String expected,
    bool isLast = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: isLast
              ? BorderSide.none
              : BorderSide(
                  color: Colors.black.withOpacity(0.25),
                  width: 0.25,
                ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 78,
            child: Text(
              field,
              style: GoogleFonts.inriaSerif(
                fontSize: 10,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          Expanded(
            child: Text(
              amountReceived,
              style: GoogleFonts.inriaSerif(
                fontSize: 10,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          Expanded(
            child: Text(
              expected,
              style: GoogleFonts.inriaSerif(
                fontSize: 10,
                color: const Color(0xFF404040),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProjectOverviewProfitAndRoiTableReport({
    required double amountReceivedGrossProfit,
    required double expectedGrossProfit,
    required double amountReceivedNetProfit,
    required double expectedNetProfit,
    required double amountReceivedRoi,
    required double expectedRoi,
    required double amountReceivedProfitMargin,
    required double expectedProfitMargin,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '1.3  Profit and ROI',
          style: GoogleFonts.inriaSerif(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFF404040),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              Container(
                color: const Color(0xFF404040),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 78,
                      child: Text(
                        'Field',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Amount Received',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Expected (Pipeline)',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _buildProjectOverviewProfitAndRoiRowReport(
                field: 'Gross Profit',
                amountReceived:
                    _formatCurrencyCompactReport(amountReceivedGrossProfit),
                expected: _formatCurrencyCompactReport(expectedGrossProfit),
              ),
              _buildProjectOverviewProfitAndRoiRowReport(
                field: 'Net Profit',
                amountReceived:
                    _formatCurrencyCompactReport(amountReceivedNetProfit),
                expected: _formatCurrencyCompactReport(expectedNetProfit),
              ),
              _buildProjectOverviewProfitAndRoiRowReport(
                field: 'ROI',
                amountReceived: _formatPercentCompactReport(amountReceivedRoi),
                expected: _formatPercentCompactReport(expectedRoi),
              ),
              _buildProjectOverviewProfitAndRoiRowReport(
                field: 'Profit Margin',
                amountReceived:
                    _formatPercentCompactReport(amountReceivedProfitMargin),
                expected: _formatPercentCompactReport(expectedProfitMargin),
                isLast: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProjectOverviewSalesHighlightsTableReport({
    required double overallTotalSalesValue,
    required double overallAmountReceived,
    required double overallPendingAmount,
    required double siteTotalSalesValue,
    required double siteAmountReceived,
    required double sitePendingAmount,
    required double amenityTotalSalesValue,
    required double amenityAmountReceived,
    required double amenityPendingAmount,
  }) {
    Widget buildRow({
      required String label,
      required double totalSalesValue,
      required double amountReceived,
      required double pendingAmount,
      bool isLast = false,
    }) {
      return Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: isLast
                ? BorderSide.none
                : BorderSide(
                    color: Colors.black.withOpacity(0.25),
                    width: 0.25,
                  ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                label,
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
            ),
            Expanded(
              child: Text(
                _formatCurrencyCompactReport(totalSalesValue),
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
            ),
            Expanded(
              child: Text(
                _formatCurrencyCompactReport(amountReceived),
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
            ),
            Expanded(
              child: Text(
                _formatCurrencyCompactReport(pendingAmount),
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '1.4  Sales Highlights',
          style: GoogleFonts.inriaSerif(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFF404040),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              Container(
                color: const Color(0xFF404040),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(
                        'Field',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Total Sales Value',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Amount Received',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Total Pending Amount',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              buildRow(
                label: 'Overall Sales',
                totalSalesValue: overallTotalSalesValue,
                amountReceived: overallAmountReceived,
                pendingAmount: overallPendingAmount,
              ),
              buildRow(
                label: 'Site Sales',
                totalSalesValue: siteTotalSalesValue,
                amountReceived: siteAmountReceived,
                pendingAmount: sitePendingAmount,
              ),
              buildRow(
                label: 'Amenity Area Sales',
                totalSalesValue: amenityTotalSalesValue,
                amountReceived: amenityAmountReceived,
                pendingAmount: amenityPendingAmount,
                isLast: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProjectOverviewCompensationTableReport() {
    final compensation = _buildCompensationTotalsForReport();
    final totalAgentCompensation =
        compensation['totalAgentCompensation'] ?? 0.0;
    final totalProjectManagerCompensation =
        compensation['totalProjectManagerCompensation'] ?? 0.0;
    final totalCompensation = compensation['totalCompensation'] ?? 0.0;

    Widget buildRow({
      required String label,
      required String value,
      bool isLast = false,
    }) {
      return Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: isLast
                ? BorderSide.none
                : BorderSide(
                    color: Colors.black.withOpacity(0.25),
                    width: 0.25,
                  ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
            ),
            SizedBox(
              width: 160,
              child: Text(
                value,
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '1.5  Compensation',
          style: GoogleFonts.inriaSerif(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFF404040),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              Container(
                color: const Color(0xFF404040),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Field',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 160,
                      child: Text(
                        'Value',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              buildRow(
                label: 'Total Agent Compensation',
                value: _formatCurrencyCompactReport(totalAgentCompensation),
              ),
              buildRow(
                label: 'Total Project Manager Compensation',
                value: _formatCurrencyCompactReport(
                  totalProjectManagerCompensation,
                ),
                isLast: true,
              ),
              Container(
                color: Colors.grey.withOpacity(0.25),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Total Compensation',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 160,
                      child: Text(
                        _formatCurrencyCompactReport(totalCompensation),
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          color: const Color(0xFF404040),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  double _computePartnersProfitPoolForReport() {
    // Keep partner pool locked to the exact Net Profit shown in reports.
    if (_hasLiveDashboardSnapshotForReport) {
      final dashboardNetProfit = _readMetricIfPresentFromDashboard(
        ['netProfit', 'net_profit'],
      );
      if (dashboardNetProfit != null) {
        return dashboardNetProfit;
      }
    }
    return _computeOverviewNetProfitForReport();
  }

  double _readEstimatedDevelopmentCostForPartnerReport() {
    if (_hasLiveDashboardSnapshotForReport) {
      final dashboardEstimatedCost = _readMetricIfPresentFromDashboard(
        ['estimatedDevelopmentCost', 'estimated_development_cost'],
      );
      if ((dashboardEstimatedCost ?? 0) > 0) {
        return dashboardEstimatedCost!;
      }
    }

    final projectEstimatedCost = _toDouble(
      _projectData['estimatedDevelopmentCost'] ??
          _projectData['estimated_development_cost'],
    );
    if (projectEstimatedCost > 0) {
      return projectEstimatedCost;
    }

    return _readMetricFromReportSources(
      ['estimatedDevelopmentCost', 'estimated_development_cost'],
    );
  }

  double _partnerCapitalContributionForReport(Map<String, dynamic> partner) {
    return _plotFieldDouble(
      partner,
      ['capitalContribution', 'capital_contribution', 'capital', 'amount'],
    );
  }

  double _partnerProfitShareForReport(
    Map<String, dynamic> partner, {
    required double estimatedDevelopmentCost,
  }) {
    final capitalVal = _partnerCapitalContributionForReport(partner);
    if (estimatedDevelopmentCost <= 0) return 0.0;
    // Match dashboard partners table logic exactly.
    return (capitalVal / estimatedDevelopmentCost) * 100;
  }

  double _partnerAllocatedProfitForReport({
    required double partnersProfitPool,
    required double estimatedDevelopmentCost,
    required double profitShareVal,
  }) {
    if (estimatedDevelopmentCost <= 0) return 0.0;
    // Match dashboard partners table logic exactly.
    return (partnersProfitPool * profitShareVal) / 100.0;
  }

  List<Map<String, dynamic>> _dashboardPartnerProfitRowsForReport(
    double partnersProfitPool,
  ) {
    if (!_hasLiveDashboardSnapshotForReport) {
      return const <Map<String, dynamic>>[];
    }
    final partnerProfitRowsRaw = _dashboardDataLocal?['partnerProfitRows'];
    final dashboardRowsRaw =
        partnerProfitRowsRaw is List && partnerProfitRowsRaw.isNotEmpty
            ? partnerProfitRowsRaw
            : _dashboardDataLocal?['partners'];
    if (dashboardRowsRaw is! List || dashboardRowsRaw.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    return dashboardRowsRaw.whereType<Map>().map((row) {
      final map = Map<String, dynamic>.from(row);
      final profitShareVal =
          _toDouble(map['profitShare'] ?? map['profit_share']);
      return <String, dynamic>{
        'name': (map['name'] ?? map['partnerName'] ?? '-').toString(),
        'capital': _toDouble(map['amount'] ?? map['capitalContribution']),
        // Keep allocation tied to the same pool rendered in the report.
        'allocated': (partnersProfitPool * profitShareVal) / 100.0,
        'share': profitShareVal,
      };
    }).toList(growable: false);
  }

  List<Map<String, dynamic>> _buildOverviewPartnerProfitRowsForReport(
    double partnersProfitPool,
  ) {
    final allPlots = _collectReportPlotsForOverview();
    final dashboardRows =
        _dashboardPartnerProfitRowsForReport(partnersProfitPool);
    if (dashboardRows.isNotEmpty) {
      return dashboardRows;
    }

    final projectPartnersRaw = _projectData['partners'] as List<dynamic>? ?? [];
    final partners = projectPartnersRaw
        .map((p) =>
            p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{})
        .toList(growable: true);

    if (partners.isEmpty) {
      final names = <String>{};
      for (final plot in allPlots) {
        for (final name in _partnerNamesFromPlotForReport(plot)) {
          if (name.trim().isEmpty || name.trim() == '-') continue;
          names.add(name.trim());
        }
      }
      for (final name in names) {
        partners.add({'name': name});
      }
    }

    final estimatedDevelopmentCost =
        _readEstimatedDevelopmentCostForPartnerReport();

    final rows = <Map<String, dynamic>>[];
    for (final p in partners) {
      final partner = Map<String, dynamic>.from(p);
      final name = (partner['name'] ??
              partner['partnerName'] ??
              partner['partner_name'] ??
              '-')
          .toString();
      final capitalVal = _partnerCapitalContributionForReport(partner);
      final profitShareVal = _partnerProfitShareForReport(
        partner,
        estimatedDevelopmentCost: estimatedDevelopmentCost,
      );
      final allocatedVal = _partnerAllocatedProfitForReport(
        partnersProfitPool: partnersProfitPool,
        estimatedDevelopmentCost: estimatedDevelopmentCost,
        profitShareVal: profitShareVal,
      );

      rows.add({
        'name': name,
        'capital': capitalVal,
        'allocated': allocatedVal,
        'share': profitShareVal,
      });
    }

    return rows;
  }

  Widget _buildProjectOverviewPartnerDistributionSectionReport() {
    final partnersProfitPool = _computePartnersProfitPoolForReport();
    final rows = _buildOverviewPartnerProfitRowsForReport(partnersProfitPool);
    final visibleRows = rows;
    final totalCapital = rows.fold<double>(
      0.0,
      (sum, row) => sum + ((row['capital'] as num?)?.toDouble() ?? 0.0),
    );
    final totalAllocated = rows.fold<double>(
      0.0,
      (sum, row) => sum + ((row['allocated'] as num?)?.toDouble() ?? 0.0),
    );
    final totalShare = rows.fold<double>(
      0.0,
      (sum, row) => sum + ((row['share'] as num?)?.toDouble() ?? 0.0),
    );

    Widget rowCell(
      String text, {
      int flex = 1,
      bool isHeader = false,
      TextAlign textAlign = TextAlign.left,
    }) {
      return Expanded(
        flex: flex,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            text,
            textAlign: textAlign,
            style: GoogleFonts.inriaSerif(
              fontSize: 10,
              fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
              color: isHeader ? Colors.white : const Color(0xFF404040),
            ),
          ),
        ),
      );
    }

    Widget buildDataRow({
      required String name,
      required String capital,
      required String allocated,
      required String share,
      bool isTotal = false,
    }) {
      final row = Row(
        children: [
          rowCell(name, flex: 3),
          rowCell(capital, flex: 3),
          rowCell(allocated, flex: 3),
          rowCell(share, flex: 2, textAlign: TextAlign.right),
        ],
      );
      return Container(
        color: isTotal ? Colors.grey.withOpacity(0.25) : null,
        decoration: isTotal
            ? null
            : BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Colors.black.withOpacity(0.25),
                    width: 0.25,
                  ),
                ),
              ),
        child: row,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '1.6  Partner(s) Profit Distribution',
          style: GoogleFonts.inriaSerif(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Partners Profit Pool: ${_formatCurrencyCompactReport(partnersProfitPool)}',
          style: GoogleFonts.inriaSerif(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFF404040),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              Container(
                color: const Color(0xFF404040),
                child: Row(
                  children: [
                    rowCell('Partner Name', flex: 3, isHeader: true),
                    rowCell(
                      'Capital Contribution (₹)',
                      flex: 3,
                      isHeader: true,
                    ),
                    rowCell('Allocated Profit (₹)', flex: 3, isHeader: true),
                    rowCell(
                      'Profit Share (%)',
                      flex: 2,
                      isHeader: true,
                      textAlign: TextAlign.right,
                    ),
                  ],
                ),
              ),
              ...visibleRows.map((row) {
                final capital = (row['capital'] as num?)?.toDouble() ?? 0.0;
                final allocated = (row['allocated'] as num?)?.toDouble() ?? 0.0;
                final share = (row['share'] as num?)?.toDouble() ?? 0.0;
                return buildDataRow(
                  name: (row['name'] ?? '-').toString(),
                  capital: _formatCurrencyCompactReport(capital),
                  allocated: _formatCurrencyCompactReport(allocated),
                  share: _formatPercentCompactReport(share),
                );
              }),
              buildDataRow(
                name: 'Total',
                capital: _formatCurrencyCompactReport(totalCapital),
                allocated: _formatCurrencyCompactReport(totalAllocated),
                share: _formatPercentCompactReport(totalShare),
                isTotal: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildProjectOverviewSalesActivitySectionReport() {
    final totalPlots = _toDouble(
      _dashboardDataLocal?['totalPlots'] ??
          _projectData['totalPlots'] ??
          _projectData['total_plots'],
    ).round();
    final amenityPlotCount = _collectAmenityAreasForReport().length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '1.7  Sales Activity',
          style: GoogleFonts.inriaSerif(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 4),
        _buildReportPage4SalesActivityChart(
          totalPlots: totalPlots + amenityPlotCount,
        ),
      ],
    );
  }

  double _estimateProjectOverviewTableHeight(int rowCount) {
    const baseHeight = 44.0; // title + header + section chrome
    const rowHeight = 20.0;
    return baseHeight + (rowCount * rowHeight);
  }

  List<List<Map<String, dynamic>>> _paginateProjectOverviewSections(
    List<Map<String, dynamic>> sections, {
    required double maxContentHeight,
  }) {
    final pages = <List<Map<String, dynamic>>>[];
    var currentPage = <Map<String, dynamic>>[];
    var remainingHeight = maxContentHeight;

    for (final section in sections) {
      final sectionType = (section['type'] ?? '').toString();
      final gapAfter = (section['gapAfter'] as num?)?.toDouble() ?? 0.0;

      if (sectionType == 'custom') {
        final sectionHeight =
            (section['estimatedHeight'] as num?)?.toDouble() ?? 0.0;
        final totalHeight = sectionHeight + gapAfter;
        if (totalHeight > remainingHeight && currentPage.isNotEmpty) {
          pages.add(currentPage);
          currentPage = <Map<String, dynamic>>[];
          remainingHeight = maxContentHeight;
        }
        currentPage.add(section);
        remainingHeight = math.max(0, remainingHeight - totalHeight);
        continue;
      }

      final title = (section['title'] ?? '').toString();
      final allowSplit = section['allowSplit'] == true;
      final rawRows = (section['rows'] as List?) ?? const [];
      final rows = rawRows
          .map<List<String>>(
            (row) => (row as List).map((cell) => cell.toString()).toList(),
          )
          .toList(growable: false);

      if (rows.isEmpty) {
        final height = _estimateProjectOverviewTableHeight(0) + gapAfter;
        if (height > remainingHeight && currentPage.isNotEmpty) {
          pages.add(currentPage);
          currentPage = <Map<String, dynamic>>[];
          remainingHeight = maxContentHeight;
        }
        currentPage.add({
          'type': 'table',
          'title': title,
          'rows': const <List<String>>[],
          'gapAfter': gapAfter,
        });
        remainingHeight = math.max(0, remainingHeight - height);
        continue;
      }

      if (!allowSplit) {
        final height =
            _estimateProjectOverviewTableHeight(rows.length) + gapAfter;
        if (height > remainingHeight && currentPage.isNotEmpty) {
          pages.add(currentPage);
          currentPage = <Map<String, dynamic>>[];
          remainingHeight = maxContentHeight;
        }
        currentPage.add({
          'type': 'table',
          'title': title,
          'rows': rows,
          'gapAfter': gapAfter,
        });
        remainingHeight = math.max(0, remainingHeight - height);
        continue;
      }

      var rowStart = 0;
      while (rowStart < rows.length) {
        final rowsRemaining = rows.length - rowStart;
        int rowsToTake = rowsRemaining;
        while (rowsToTake > 0) {
          final isFinalChunk = rowStart + rowsToTake >= rows.length;
          final chunkGapAfter = isFinalChunk ? gapAfter : 0.0;
          final chunkHeight =
              _estimateProjectOverviewTableHeight(rowsToTake) + chunkGapAfter;
          if (chunkHeight <= remainingHeight) break;
          rowsToTake--;
        }

        if (rowsToTake <= 0) {
          if (currentPage.isNotEmpty) {
            pages.add(currentPage);
            currentPage = <Map<String, dynamic>>[];
            remainingHeight = maxContentHeight;
            continue;
          }
          rowsToTake = 1;
        }

        final chunkEnd = math.min(rowStart + rowsToTake, rows.length);
        final isFinalChunk = chunkEnd >= rows.length;
        final chunkGapAfter = isFinalChunk ? gapAfter : 0.0;
        final chunkTitle = rowStart == 0 ? title : '$title (Cont.)';
        currentPage.add({
          'type': 'table',
          'title': chunkTitle,
          'rows': rows.sublist(rowStart, chunkEnd),
          'gapAfter': chunkGapAfter,
        });
        remainingHeight = math.max(
          0,
          remainingHeight -
              (_estimateProjectOverviewTableHeight(chunkEnd - rowStart) +
                  chunkGapAfter),
        );
        rowStart = chunkEnd;

        if (!isFinalChunk) {
          pages.add(currentPage);
          currentPage = <Map<String, dynamic>>[];
          remainingHeight = maxContentHeight;
        }
      }
    }

    if (currentPage.isNotEmpty) {
      pages.add(currentPage);
    }
    return pages;
  }

  Widget _buildProjectOverviewPage({
    required List<Map<String, dynamic>> sections,
    required int pageNumber,
    required bool isContinuation,
    required bool showChapterTitle,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Color(0xFF404040),
                      width: 0.5,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _reportHeaderUnitText,
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF404040),
                      ),
                    ),
                    Text(
                      _reportHeaderDateText,
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF404040),
                      ),
                    ),
                  ],
                ),
              ),
              if (showChapterTitle)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    isContinuation
                        ? '1. Project Overview (Cont.)'
                        : '1. Project Overview',
                    style: GoogleFonts.inriaSerif(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF0C8CE9),
                    ),
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    showChapterTitle ? 8 : 12,
                    16,
                    8,
                  ),
                  child: sections.isEmpty
                      ? Align(
                          alignment: Alignment.topLeft,
                          child: Text(
                            '-',
                            style: GoogleFonts.inriaSerif(
                              fontSize: 10,
                              color: const Color(0xFF404040),
                            ),
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (int i = 0; i < sections.length; i++) ...[
                              _buildProjectOverviewSection(sections[i]),
                              if (i < sections.length - 1 &&
                                  ((sections[i]['gapAfter'] as num?)
                                              ?.toDouble() ??
                                          0) >
                                      0)
                                SizedBox(
                                  height: (sections[i]['gapAfter'] as num)
                                      .toDouble(),
                                ),
                            ],
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
        _buildStandardReportFooter(pageNumber),
      ],
    );
  }

  Widget _buildProjectOverviewSection(Map<String, dynamic> section) {
    final sectionType = (section['type'] ?? '').toString();
    if (sectionType == 'custom') {
      final builder = section['builder'] as Widget Function()?;
      return builder?.call() ?? const SizedBox.shrink();
    }
    final title = (section['title'] ?? '').toString();
    final rows = ((section['rows'] as List?) ?? const [])
        .map<List<String>>(
            (row) => (row as List).map((cell) => cell.toString()).toList())
        .toList(growable: false);
    return _buildTableSection(title: title, rows: rows);
  }

  Widget _buildTableSection({
    required String title,
    required List<List<String>> rows,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: GoogleFonts.inriaSerif(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF404040),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFF404040),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              // Header
              Container(
                color: const Color(0xFF404040),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      flex: 2,
                      child: Text(
                        'Field',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Value',
                        style: GoogleFonts.inriaSerif(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),

              // Rows
              ...rows.map((row) {
                return Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.black.withOpacity(0.25),
                        width: 0.25,
                      ),
                    ),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          row[0],
                          style: GoogleFonts.inriaSerif(
                            fontSize: 10,
                            fontWeight: FontWeight.normal,
                            color: const Color(0xFF404040),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          row[1],
                          style: GoogleFonts.inriaSerif(
                            fontSize: 10,
                            fontWeight: FontWeight.normal,
                            color: const Color(0xFF404040),
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ],
          ),
        ),
      ],
    );
  }

  // Deprecated methods below - kept for reference if needed
  Widget _buildReportPageDeprecated() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Container(
          height: 55,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Colors.black.withOpacity(0.2),
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Project Expense Report',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF0C8CE9),
                ),
              ),
              Text(
                _reportHeaderDateText,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF404040),
                ),
              ),
            ],
          ),
        ),

        // Content
        SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Expense Breakdown
              Text(
                'Expense Breakdown',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF404040),
                ),
              ),
              const SizedBox(height: 8),

              // Expense Categories Summary
              Text(
                'Expense Categories Summary',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF404040),
                ),
              ),
              const SizedBox(height: 4),

              Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: const Color(0xFF404040),
                    width: 0.5,
                  ),
                ),
                child: Column(
                  children: [
                    // Header
                    Container(
                      color: const Color(0xFF404040),
                      padding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Category',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            'Value (₹)',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Category rows
                    _buildA4TableRow('Land Purchase Cost', '₹ 150L'),
                    _buildA4TableRow('Statutory & Registration', '₹ 5L'),
                    _buildA4TableRow('Legal & Professional Fees', '₹ 2L'),
                    _buildA4TableRow('Survey & Approvals', '₹ 1L'),
                    _buildA4TableRow('Construction & Development', '₹ 80L'),
                    _buildA4TableRow('Amenities & Infrastructure', '₹ 50L'),
                    _buildA4TableRow('Others', '₹ 5L'),
                    // Total
                    Container(
                      color: const Color(0xFFE0E0E0),
                      padding: const EdgeInsets.symmetric(
                          vertical: 4, horizontal: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Total',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                          Text(
                            '₹ 293L',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // Detailed Expense Items
              Text(
                'Detailed Expense Items',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF404040),
                ),
              ),
              const SizedBox(height: 4),

              // Land Purchase Cost section
              _buildA4ExpenseSection(
                'Land Purchase Cost',
                [
                  {'item': 'Land A', 'amount': '₹ 75L'},
                  {'item': 'Land B', 'amount': '₹ 75L'},
                ],
                '₹ 150L',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildA4TableRow(String field, String value) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.black.withOpacity(0.2),
            width: 0.25,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            field,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF404040),
            ),
          ),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF404040),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildA4PartnerRow(String name, String value) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.black.withOpacity(0.2),
            width: 0.25,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              name,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildA4ExpenseSection(
      String categoryName, List<Map<String, String>> items, String total) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Category label
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            '• $categoryName',
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF404040),
            ),
          ),
        ),
        const SizedBox(height: 2),
        // Items table
        Container(
          margin: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFF404040),
              width: 0.5,
            ),
          ),
          child: Column(
            children: [
              // Header
              Container(
                color: const Color(0xFF404040),
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Item',
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'Value (₹)',
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
              // Rows
              for (var item in items)
                Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Colors.black.withOpacity(0.2),
                        width: 0.25,
                      ),
                    ),
                  ),
                  padding:
                      const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        item['item'] ?? '',
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          fontWeight: FontWeight.normal,
                          color: const Color(0xFF404040),
                        ),
                      ),
                      Text(
                        item['amount'] ?? '',
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          fontWeight: FontWeight.normal,
                          color: const Color(0xFF404040),
                        ),
                      ),
                    ],
                  ),
                ),
              // Total
              Container(
                color: const Color(0xFFE0E0E0),
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total',
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                    Text(
                      total,
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildExpenseReportPreview() {
    return SingleChildScrollView(
      child: Container(
        width: 595,
        color: Colors.white,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Project Expense Report',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0C8CE9),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Divider(
              color: const Color(0xFF404040).withOpacity(0.3),
              height: 1,
              thickness: 0.5,
            ),
            const SizedBox(height: 16),

            // Project Name
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Project Name:',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF404040),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'ABC',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF404040),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Project Overview
            Text(
              'Project Overview',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF404040),
              ),
            ),
            const SizedBox(height: 8),

            // Overview Table
            Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: const Color(0xFF404040),
                  width: 0.5,
                ),
              ),
              child: Column(
                children: [
                  // Header row
                  Container(
                    color: const Color(0xFF404040),
                    padding:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Field',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          'Value',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Table rows
                  _buildOverviewTableRow('Total Project Area', '-'),
                  _buildOverviewTableRow('Saleable Plot Area', '-'),
                  _buildOverviewTableRow('Non-Sellable Area', '-'),
                  _buildOverviewTableRow('All-in Cost', '-'),
                  _buildOverviewTableRow('Estimated Project Cost', '-'),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Partner Details
            Text(
              'Partner Details',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF404040),
              ),
            ),
            const SizedBox(height: 8),

            // Partner Table
            Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: const Color(0xFF404040),
                  width: 0.5,
                ),
              ),
              child: Column(
                children: [
                  // Header
                  Container(
                    color: const Color(0xFF404040),
                    padding:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Partner Name',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'Value (₹)',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'Allocated Profit (₹)',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'Profit Share (%)',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Rows
                  _buildPartnerTableRow('ABC', '-', '-', '-'),
                  _buildPartnerTableRow('ABC', '-', '-', '-'),
                  _buildPartnerTableRow('ABC', '-', '-', '-'),
                  _buildPartnerTableRow('ABC', '-', '-', '-'),
                  // Total row
                  Container(
                    color: const Color(0xFFE0E0E0),
                    padding:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Total',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '-',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.normal,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '-',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.normal,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '-',
                            style: GoogleFonts.inter(
                              fontSize: 10,
                              fontWeight: FontWeight.normal,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverviewTableRow(String field, String value) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.black.withOpacity(0.25),
            width: 0.25,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            field,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF404040),
            ),
          ),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF404040),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPartnerTableRow(
      String name, String value, String profit, String share) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Colors.black.withOpacity(0.25),
            width: 0.25,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          Expanded(
            child: Text(
              profit,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          Expanded(
            child: Text(
              share,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF404040),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportPage4({required int pageNumber}) {
    if (_hasPendingPlotsForReport()) {
      return _buildReportPage4WithPending(pageNumber: pageNumber);
    }
    return _buildReportPage4WithoutPending(pageNumber: pageNumber);
  }

  Widget _buildReportPage4WithoutPending({required int pageNumber}) {
    final totalPlots = _toDouble(
      _dashboardDataLocal?['totalPlots'] ??
          _projectData['totalPlots'] ??
          _projectData['total_plots'],
    ).round();
    final amenityPlotCount = _collectAmenityAreasForReport().length;
    final totalPlotsIncludingAmenity = totalPlots + amenityPlotCount;
    final soldPlots = _toDouble(
      _dashboardDataLocal?['soldPlots'] ??
          _projectData['soldPlots'] ??
          _projectData['sold_plots'],
    ).round();
    final availablePlots = math.max(0, totalPlots - soldPlots);
    final avgSalesPrice = _displayRateFromSqft(
      double.tryParse(getDashboardValue('avgSalePricePerSqft')) ?? 0.0,
    );

    return Container(
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Color(0xFF404040),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Sales Activity',
              style: GoogleFonts.inriaSerif(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF0C8CE9),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Sales Activity',
              style: GoogleFonts.inriaSerif(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildTableSection(
              title: 'Sales Activity',
              rows: [
                ['Total Number of Plot', '$totalPlotsIncludingAmenity'],
                ['Total Number of Amenity Plot', '$amenityPlotCount'],
                ['Total Number of Plot Available', '$availablePlots'],
                ['Total Number of Plot Sold', '$soldPlots'],
                [
                  'Average Sales Price (₹ / $_areaUnitSuffix)',
                  _formatCurrencyOrDash(avgSalesPrice)
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildReportPage4SalesActivityChart(totalPlots: totalPlots),
          ),
          const Spacer(),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  Widget _buildReportPage4WithPending({required int pageNumber}) {
    final metrics = _buildPendingOverviewMetricsReport();
    final plots = (metrics['plots'] as List<Map<String, dynamic>>?) ?? const [];
    final soldPlotsCount = (metrics['soldPlotsCount'] as int?) ?? 0;
    final availableByStatus = (metrics['availablePlotsCount'] as int?) ?? 0;

    final totalPlots = plots.isNotEmpty
        ? plots.length
        : _toDouble(
            _dashboardDataLocal?['totalPlots'] ??
                _projectData['totalPlots'] ??
                _projectData['total_plots'],
          ).round();
    final amenityPlotCount = _collectAmenityAreasForReport().length;
    final totalPlotsIncludingAmenity = totalPlots + amenityPlotCount;
    final soldPlots = plots.isNotEmpty
        ? soldPlotsCount
        : _toDouble(
            _dashboardDataLocal?['soldPlots'] ??
                _projectData['soldPlots'] ??
                _projectData['sold_plots'],
          ).round();
    final pendingPlots = plots.isNotEmpty
        ? ((metrics['pendingPlotsCount'] as int?) ?? 0)
        : _toDouble(
            _dashboardDataLocal?['pendingPlots'] ??
                _dashboardDataLocal?['pending_plots'] ??
                _projectData['pendingPlots'] ??
                _projectData['pending_plots'],
          ).round();
    final availablePlots = plots.isNotEmpty
        ? availableByStatus
        : math.max(0, totalPlots - soldPlots - pendingPlots);
    final avgSalesPrice = _displayRateFromSqft(
      double.tryParse(getDashboardValue('avgSalePricePerSqft')) ?? 0.0,
    );

    return Container(
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Color(0xFF404040),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Sales Activity',
              style: GoogleFonts.inriaSerif(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF0C8CE9),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Sales Activity',
              style: GoogleFonts.inriaSerif(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildTableSection(
              title: 'Sales Activity',
              rows: [
                ['Total Number of Plot', '$totalPlotsIncludingAmenity'],
                ['Total Number of Amenity Plot', '$amenityPlotCount'],
                ['Total Number of Plot Available', '$availablePlots'],
                ['Total Number of Plot Sold', '$soldPlots'],
                ['Total Number of Plot Pending', '$pendingPlots'],
                [
                  'Average Sales Price (₹ / $_areaUnitSuffix)   (* Based on total sold plots *)',
                  _formatCurrencyAlwaysReport(avgSalesPrice),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildReportPage4SalesActivityChart(totalPlots: totalPlots),
          ),
          const Spacer(),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  String _normalizeSaleDateKeyForReport(dynamic rawDate) {
    if (rawDate == null) return '';
    if (rawDate is DateTime) {
      return '${rawDate.year.toString().padLeft(4, '0')}-${rawDate.month.toString().padLeft(2, '0')}-${rawDate.day.toString().padLeft(2, '0')}';
    }

    final raw = rawDate.toString().trim();
    if (raw.isEmpty || raw == '-' || raw == '—') return '';

    DateTime? parsed = DateTime.tryParse(raw);
    parsed ??= DateTime.tryParse(raw.replaceFirst(' ', 'T'));

    if (parsed == null) {
      final match =
          RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$').firstMatch(raw);
      if (match != null) {
        int first = int.tryParse(match.group(1) ?? '') ?? 0;
        int second = int.tryParse(match.group(2) ?? '') ?? 0;
        int year = int.tryParse(match.group(3) ?? '') ?? 0;
        if (year > 0 && year < 100) {
          year += 2000;
        }
        // Prefer dd/MM/yyyy; fall back to MM/dd/yyyy when obvious.
        int day = first;
        int month = second;
        if (second > 12 && first <= 12) {
          day = second;
          month = first;
        }
        if (year >= 1900 &&
            month >= 1 &&
            month <= 12 &&
            day >= 1 &&
            day <= 31) {
          parsed = DateTime.tryParse(
            '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
          );
        }
      }
    }

    if (parsed == null) return '';
    return '${parsed.year.toString().padLeft(4, '0')}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }

  Widget _buildReportPage4SalesActivityChart({required int totalPlots}) {
    int todaysSales = 0;
    final today = DateTime.now();
    final todayIso =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final daysToLookBack = 29; // 28D + today
    final dailySalesMap = <String, int>{};
    for (int i = 0; i < daysToLookBack; i++) {
      final date = today.subtract(Duration(days: i));
      final iso =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      dailySalesMap[iso] = 0;
    }

    final allPlots = _collectReportPlotsForOverview();
    for (final plot in allPlots) {
      final status = _normalizeSiteStatusForReport(
        _plotFieldStr(plot, ['status', 'plot_status', 'sale_status']),
      );
      if (status != 'sold') continue;
      final saleDateIso = _normalizeSaleDateKeyForReport(
        _readSaleDateValueForReport(plot),
      );
      if (dailySalesMap.containsKey(saleDateIso)) {
        dailySalesMap[saleDateIso] = dailySalesMap[saleDateIso]! + 1;
        if (saleDateIso == todayIso) {
          todaysSales++;
        }
      }
    }

    final amenityRows = _collectAmenityAreasForReport();
    for (final row in amenityRows) {
      if (_amenityStatusForReport(row) != 'sold') continue;
      final saleDateIso = _normalizeSaleDateKeyForReport(
        row['sale_date'] ??
            row['saleDate'] ??
            row['date_of_sale'] ??
            row['dateOfSale'],
      );
      if (dailySalesMap.containsKey(saleDateIso)) {
        dailySalesMap[saleDateIso] = dailySalesMap[saleDateIso]! + 1;
        if (saleDateIso == todayIso) {
          todaysSales++;
        }
      }
    }

    final salesData = <int>[];
    for (int i = daysToLookBack - 1; i >= 0; i--) {
      final date = today.subtract(Duration(days: i));
      final iso =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      salesData.add(dailySalesMap[iso] ?? 0);
    }

    var maxY = todaysSales;
    if (salesData.isNotEmpty) {
      final dataMax = salesData.reduce((a, b) => a > b ? a : b);
      if (dataMax > maxY) maxY = dataMax;
    }
    maxY = ((maxY + 4) ~/ 5) * 5;
    if (maxY == 0) maxY = 5;

    return Align(
      alignment: Alignment.center,
      child: _buildSalesActivityChart(
        totalPlots,
        todaysSales,
        '28D',
        salesData,
        maxY,
        compact: true,
      ),
    );
  }

  // Waterfall Chart Widget
  Widget _buildWaterfallChart({
    required double totalSalesValue,
    required double totalExpenses,
    required double grossProfit,
    required double compensation,
    required double netProfit,
  }) {
    final values = [
      {
        'label': 'Net Profit',
        'value': netProfit,
        'color': const Color(0xFF76CF68)
      },
      {
        'label': 'Compensation',
        'value': compensation,
        'color': const Color(0xFFE1A157)
      },
      {
        'label': 'Gross Profit',
        'value': grossProfit,
        'color': const Color(0xFF7CD7EC)
      },
      {
        'label': 'Total Expenses',
        'value': totalExpenses,
        'color': const Color(0xFFFB7D7D)
      },
      {
        'label': 'Total Sales Value',
        'value': totalSalesValue,
        'color': const Color(0xFF0C8CE9)
      },
    ];

    final minValue = math.min(
      netProfit,
      math.min(compensation,
          math.min(grossProfit, math.min(totalExpenses, totalSalesValue))),
    );
    final maxValue = math.max(
      netProfit,
      math.max(compensation,
          math.max(grossProfit, math.max(totalExpenses, totalSalesValue))),
    );
    final axisScale = _buildAxisScaleReport(minValue, maxValue);
    final axisRange = axisScale.axisMax - axisScale.axisMin;
    final hasNegative = axisScale.axisMin < 0;
    final hasPositive = axisScale.axisMax > 0;

    const rowHeight = 17.91;
    const dividerHeight = 0.25;
    const dividerGap = 6.716;
    const axisGap = 0.0;
    const axisLineHeight = 0.25;
    const axisTopExtension = 17.91;
    const yAxisTailAfterLastBar = 0.0;

    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        width: 424,
        height: 186,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFF404040), width: 0.1),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              const labelWidth = 90.0;
              const gap = 8.955;
              final totalWidth =
                  constraints.maxWidth.isFinite ? constraints.maxWidth : 520.0;
              final chartWidth = math.max(150.0, totalWidth - labelWidth - gap);

              const extraAfterLastTick = 16.0;
              const arrowSpace = 8.0;
              final plotAreaWidth = math.max(
                  120.0, chartWidth - (extraAfterLastTick + arrowSpace));

              final tickXs = List<double>.generate(6, (index) {
                if (axisRange <= 0) return 0.0;
                final value = axisScale.axisMin + (axisScale.step * index);
                return ((value - axisScale.axisMin) / axisRange) *
                    plotAreaWidth;
              });

              final zeroX = axisRange <= 0
                  ? 0.0
                  : ((0 - axisScale.axisMin) / axisRange) * plotAreaWidth;

              double barWidth(double value) {
                if (axisRange <= 0) return 0;
                return (value.abs().clamp(0.0, axisRange) / axisRange) *
                    plotAreaWidth;
              }

              double barEndX(double value) {
                final width = barWidth(value);
                return value < 0 ? zeroX : (zeroX + width);
              }

              final expensesEndX = barEndX(totalExpenses);
              final compensationStartX = expensesEndX;
              final compensationEndX =
                  compensationStartX + barWidth(compensation);
              final netProfitStartX = compensationEndX;

              final chartHeight = (rowHeight * 5) +
                  (dividerHeight * 4) +
                  (dividerGap * 8) +
                  axisGap +
                  axisLineHeight +
                  axisTopExtension;
              final plotHeight = chartHeight - (axisLineHeight / 2);
              final labelRowGap = (dividerGap * 2) + dividerHeight;

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: axisTopExtension),
                    child: SizedBox(
                      width: labelWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final entry in values.asMap().entries) ...[
                            SizedBox(
                              height: rowHeight,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  entry.value['label'] as String,
                                  style: GoogleFonts.inriaSerif(
                                    fontSize: 10,
                                    fontWeight: FontWeight.normal,
                                    color: const Color(0xFF404040),
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ),
                            if (entry.key < values.length - 1)
                              SizedBox(height: labelRowGap),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: gap),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: chartWidth,
                        height: chartHeight,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _VerticalGridPainterReport(
                                  tickXs: tickXs,
                                  plotHeight: plotHeight,
                                ),
                              ),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets.only(top: axisTopExtension),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _buildChartRowReport(
                                    barWidth(netProfit),
                                    const Color(0xFF76CF68),
                                    rowHeight,
                                    rowWidth: chartWidth,
                                    zeroX: zeroX,
                                    startX: netProfitStartX,
                                    isNegative: netProfit < 0,
                                    tooltipText: _formatCurrencyWithSignReport(
                                        netProfit),
                                  ),
                                  _buildChartDividerReport(
                                      chartWidth, dividerGap, dividerHeight),
                                  _buildChartRowReport(
                                    barWidth(compensation),
                                    const Color(0xFFE1A157),
                                    rowHeight,
                                    rowWidth: chartWidth,
                                    zeroX: zeroX,
                                    startX: compensationStartX,
                                    isNegative: compensation < 0,
                                    tooltipText: _formatCurrencyWithSignReport(
                                        compensation),
                                  ),
                                  _buildChartDividerReport(
                                      chartWidth, dividerGap, dividerHeight),
                                  _buildChartRowReport(
                                    barWidth(grossProfit),
                                    const Color(0xFF7CD7EC),
                                    rowHeight,
                                    rowWidth: chartWidth,
                                    zeroX: zeroX,
                                    startX: expensesEndX,
                                    isNegative: grossProfit < 0,
                                    tooltipText: _formatCurrencyWithSignReport(
                                        grossProfit),
                                  ),
                                  _buildChartDividerReport(
                                      chartWidth, dividerGap, dividerHeight),
                                  _buildChartRowReport(
                                    barWidth(totalExpenses),
                                    const Color(0xFFFB7D7D),
                                    rowHeight,
                                    rowWidth: chartWidth,
                                    zeroX: zeroX,
                                    isNegative: totalExpenses < 0,
                                    tooltipText: _formatCurrencyWithSignReport(
                                        totalExpenses),
                                  ),
                                  _buildChartDividerReport(
                                      chartWidth, dividerGap, dividerHeight),
                                  _buildChartRowReport(
                                    barWidth(totalSalesValue),
                                    const Color(0xFF0C8CE9),
                                    rowHeight,
                                    rowWidth: chartWidth,
                                    zeroX: zeroX,
                                    isNegative: totalSalesValue < 0,
                                    tooltipText: _formatCurrencyWithSignReport(
                                        totalSalesValue),
                                  ),
                                  const SizedBox(height: axisGap),
                                ],
                              ),
                            ),
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _AxisPainterReport(
                                  zeroX: zeroX,
                                  hasNegative: hasNegative,
                                  hasPositive: hasPositive,
                                  axisLineHeight: axisLineHeight,
                                  tickXs: tickXs,
                                  verticalAxisEndY: axisTopExtension +
                                      (rowHeight * 5) +
                                      (dividerHeight * 4) +
                                      (dividerGap * 8) +
                                      yAxisTailAfterLastBar,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: chartWidth,
                        height: 14.6,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: List.generate(6, (index) {
                            if (index == 0 && axisScale.axisMin == 0) {
                              return const SizedBox.shrink();
                            }
                            final value =
                                axisScale.axisMin + (axisScale.step * index);
                            final tickX = tickXs[index].clamp(0.0, chartWidth);
                            return CustomSingleChildLayout(
                              delegate:
                                  _AxisLabelLayoutDelegateReport(tickX: tickX),
                              child: _buildAxisLabelReport(
                                  _formatAxisLabelValueReport(
                                      value, axisScale)),
                            );
                          }),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _buildReportPage5LayoutBlocks() {
    final allPlots = _collectReportPlotsForOverview();
    final Map<String, List<Map<String, dynamic>>> layoutPlots = {};

    for (final plotMap in allPlots) {
      final layoutLabel = _resolveLayoutLabel(plotMap);
      final key = layoutLabel.isEmpty || layoutLabel == 'Unknown'
          ? 'Unknown'
          : layoutLabel;
      layoutPlots.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(plotMap);
    }

    final blocks = <Map<String, dynamic>>[];
    final entries = layoutPlots.entries.toList();
    for (int layoutIndex = 0; layoutIndex < entries.length; layoutIndex++) {
      final entry = entries[layoutIndex];
      blocks.add({
        'layoutIndex': layoutIndex,
        'layoutName': entry.key,
        'plots': entry.value,
      });
    }
    return blocks;
  }

  List<Widget> _buildReportPage5Pages({required int startPageNumber}) {
    final layouts = _buildReportPage5LayoutBlocks();
    if (layouts.isEmpty) {
      return [
        _buildReportPage5(
          pageNumber: startPageNumber,
          layoutBlocksOverride: const [],
        ),
      ];
    }

    // Match the rendered horizontal extent used by section 5's rotated table.
    final availableHeightPx = _landscapeSection56TableUsableExtentPx();
    const minRowsPerChunk = 1;
    int layoutIndex = 0;
    int rowStart = 0;
    final pages = <Widget>[];

    while (layoutIndex < layouts.length) {
      var remainingHeight = availableHeightPx;
      final pageBlocks = <Map<String, dynamic>>[];

      while (layoutIndex < layouts.length) {
        final layout = layouts[layoutIndex];
        final allPlots =
            (layout['plots'] as List<Map<String, dynamic>>?) ?? const [];
        final rowsRemaining = math.max(0, allPlots.length - rowStart);
        if (rowsRemaining == 0) {
          layoutIndex++;
          rowStart = 0;
          continue;
        }

        final fullTableHeight = _estimateReportPage5BlockHeightPx(
          rowsRemaining,
          isContinuationChunk: rowStart > 0,
        );
        if (fullTableHeight <= remainingHeight) {
          final chunkEnd = rowStart + rowsRemaining;
          pageBlocks.add({
            'layoutIndex': layout['layoutIndex'],
            'layoutName': layout['layoutName'],
            'allPlots': allPlots,
            'plots': allPlots.sublist(rowStart, chunkEnd),
            'continued': rowStart > 0,
            'plotStartIndex': rowStart,
          });
          remainingHeight -= fullTableHeight;
          layoutIndex++;
          rowStart = 0;
          if (remainingHeight <= 0) break;
          continue;
        }

        // If this table can't fit with existing tables, move it entirely to next page.
        if (pageBlocks.isNotEmpty) {
          break;
        }

        // Split rows only when a single table cannot fit on an empty page.
        int rowsToTake = rowsRemaining;
        while (rowsToTake > minRowsPerChunk &&
            _estimateReportPage5BlockHeightPx(
                  rowsToTake,
                  isContinuationChunk: rowStart > 0,
                ) >
                remainingHeight) {
          rowsToTake--;
        }
        rowsToTake = math.max(minRowsPerChunk, rowsToTake);
        rowsToTake = math.min(rowsToTake, rowsRemaining);
        final chunkEnd = rowStart + rowsToTake;
        pageBlocks.add({
          'layoutIndex': layout['layoutIndex'],
          'layoutName': layout['layoutName'],
          'allPlots': allPlots,
          'plots': allPlots.sublist(rowStart, chunkEnd),
          'continued': rowStart > 0,
          'plotStartIndex': rowStart,
        });
        if (chunkEnd >= allPlots.length) {
          layoutIndex++;
          rowStart = 0;
        } else {
          rowStart = chunkEnd;
        }
        break;
      }

      if (pageBlocks.isEmpty) {
        final layout = layouts[layoutIndex];
        final allPlots =
            (layout['plots'] as List<Map<String, dynamic>>?) ?? const [];
        final chunkEnd = math.min(allPlots.length, rowStart + minRowsPerChunk);
        pageBlocks.add({
          'layoutIndex': layout['layoutIndex'],
          'layoutName': layout['layoutName'],
          'allPlots': allPlots,
          'plots': allPlots.sublist(rowStart, chunkEnd),
          'continued': rowStart > 0,
          'plotStartIndex': rowStart,
        });
        if (chunkEnd >= allPlots.length) {
          layoutIndex++;
          rowStart = 0;
        } else {
          rowStart = chunkEnd;
        }
      }

      pages.add(
        _buildReportPage5(
          pageNumber: startPageNumber + pages.length,
          layoutBlocksOverride: List<Map<String, dynamic>>.from(pageBlocks),
          isContinuation: pages.isNotEmpty,
        ),
      );
    }

    return pages;
  }

  double _estimateReportPage5BlockHeightPx(
    int rows, {
    required bool isContinuationChunk,
  }) {
    // Keep estimates close to rendered dimensions to avoid early page breaks.
    // Continuation chunks don't render the summary rows.
    const headingRow = 16.0;
    const summaryRowsAndGaps = 46.0;
    const continuationGap = 6.0;
    const tableHeader = 26.0;
    const tableRow = 22.0;
    const blockBottomGap = 12.0;
    return headingRow +
        (isContinuationChunk ? continuationGap : summaryRowsAndGaps) +
        tableHeader +
        (rows * tableRow) +
        blockBottomGap;
  }

  Widget _buildReportPage5({
    required int pageNumber,
    List<Map<String, dynamic>>? layoutBlocksOverride,
    bool isContinuation = false,
  }) {
    final layoutBlocks =
        layoutBlocksOverride ?? _buildReportPage5LayoutBlocks();
    return _buildReportPage5WithoutAmenity(
      pageNumber: pageNumber,
      layoutBlocks: layoutBlocks,
      isContinuation: isContinuation,
    );
  }

  List<Map<String, dynamic>> _buildReportPage6LayoutBlocks() {
    final allPlots = _collectReportPlotsForOverview();
    final layoutPlots = <String, List<Map<String, dynamic>>>{};
    for (final plot in allPlots) {
      final layoutLabel = _resolveLayoutLabel(plot);
      final key = layoutLabel.isEmpty || layoutLabel == 'Unknown'
          ? 'Unknown'
          : layoutLabel;
      layoutPlots.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(plot);
    }

    final blocks = <Map<String, dynamic>>[];
    final entries = layoutPlots.entries.toList();
    for (int layoutIndex = 0; layoutIndex < entries.length; layoutIndex++) {
      final entry = entries[layoutIndex];
      blocks.add({
        'layoutIndex': layoutIndex,
        'layoutName': entry.key,
        'plots': entry.value,
      });
    }
    return blocks;
  }

  double _estimateReportPage6BlockHeightPx(
    int rows, {
    required bool isContinuationChunk,
  }) {
    // Keep this conservative to avoid visual overflow on dense layouts.
    const topHeaderAndGap = 20.0;
    const summaryRowAndGap = 66.0;
    const summaryRowsNoAmenityAndGap = 72.0;
    const continuationGap = 8.0;
    const tableHeader = 30.0;
    const blockBottomGap = 14.0;
    const rowHeight = 31.0;
    final summaryHeight = _hasAmenityAreaForReport()
        ? summaryRowAndGap
        : summaryRowsNoAmenityAndGap;
    return topHeaderAndGap +
        (isContinuationChunk ? continuationGap : summaryHeight) +
        tableHeader +
        blockBottomGap +
        (rows * rowHeight);
  }

  List<Widget> _buildReportPage6Pages({required int startPageNumber}) {
    final layouts = _buildReportPage6LayoutBlocks();
    if (layouts.isEmpty) {
      return [
        _buildReportPage6(
          pageNumber: startPageNumber,
          layoutBlocksOverride: const [],
        ),
      ];
    }

    final availableHeightPx = _landscapeSection56TableUsableExtentPx();
    const minRowsPerChunk = 1;
    int layoutIndex = 0;
    int rowStart = 0;
    final pages = <Widget>[];

    while (layoutIndex < layouts.length) {
      var remainingHeight = availableHeightPx;
      final pageBlocks = <Map<String, dynamic>>[];

      while (layoutIndex < layouts.length) {
        final layout = layouts[layoutIndex];
        final allPlots =
            (layout['plots'] as List<Map<String, dynamic>>?) ?? const [];
        final rowsRemaining = math.max(0, allPlots.length - rowStart);
        if (rowsRemaining == 0) {
          layoutIndex++;
          rowStart = 0;
          continue;
        }

        final fullTableHeight = _estimateReportPage6BlockHeightPx(
          rowsRemaining,
          isContinuationChunk: rowStart > 0,
        );
        if (fullTableHeight <= remainingHeight) {
          final chunkEnd = rowStart + rowsRemaining;
          pageBlocks.add({
            'layoutIndex': layout['layoutIndex'],
            'layoutName': layout['layoutName'],
            'allPlots': allPlots,
            'plots': allPlots.sublist(rowStart, chunkEnd),
            'continued': rowStart > 0,
            'plotStartIndex': rowStart,
          });
          remainingHeight -= fullTableHeight;
          layoutIndex++;
          rowStart = 0;
          if (remainingHeight <= 0) break;
          continue;
        }

        // If this table can't fit with existing tables, move it entirely to next page.
        if (pageBlocks.isNotEmpty) {
          break;
        }

        // Split rows only when a single table cannot fit on an empty page.
        int rowsToTake = rowsRemaining;
        while (rowsToTake > minRowsPerChunk &&
            _estimateReportPage6BlockHeightPx(
                  rowsToTake,
                  isContinuationChunk: rowStart > 0,
                ) >
                remainingHeight) {
          rowsToTake--;
        }
        rowsToTake = math.max(minRowsPerChunk, rowsToTake);
        rowsToTake = math.min(rowsToTake, rowsRemaining);
        final chunkEnd = rowStart + rowsToTake;
        pageBlocks.add({
          'layoutIndex': layout['layoutIndex'],
          'layoutName': layout['layoutName'],
          'allPlots': allPlots,
          'plots': allPlots.sublist(rowStart, chunkEnd),
          'continued': rowStart > 0,
          'plotStartIndex': rowStart,
        });
        if (chunkEnd >= allPlots.length) {
          layoutIndex++;
          rowStart = 0;
        } else {
          rowStart = chunkEnd;
        }
        break;
      }

      if (pageBlocks.isEmpty) {
        final layout = layouts[layoutIndex];
        final allPlots =
            (layout['plots'] as List<Map<String, dynamic>>?) ?? const [];
        final chunkEnd = math.min(allPlots.length, rowStart + minRowsPerChunk);
        pageBlocks.add({
          'layoutIndex': layout['layoutIndex'],
          'layoutName': layout['layoutName'],
          'allPlots': allPlots,
          'plots': allPlots.sublist(rowStart, chunkEnd),
          'continued': rowStart > 0,
          'plotStartIndex': rowStart,
        });
        if (chunkEnd >= allPlots.length) {
          layoutIndex++;
          rowStart = 0;
        } else {
          rowStart = chunkEnd;
        }
      }

      pages.add(
        _buildReportPage6(
          pageNumber: startPageNumber + pages.length,
          layoutBlocksOverride: List<Map<String, dynamic>>.from(pageBlocks),
          isContinuation: pages.isNotEmpty,
        ),
      );
    }

    return pages;
  }

  // Page 6: Plots table with partners/buyers/agent info
  Widget _buildReportPage6({
    required int pageNumber,
    List<Map<String, dynamic>>? layoutBlocksOverride,
    bool isContinuation = false,
  }) {
    final layoutBlocks =
        layoutBlocksOverride ?? _buildReportPage6LayoutBlocks();
    return _buildReportPage6WithoutAmenity(
      pageNumber: pageNumber,
      layoutBlocks: layoutBlocks,
      isContinuation: isContinuation,
    );
  }

  String _formatReportMetricNumber(
    double value, {
    bool zeroAsDash = false,
  }) {
    if (!value.isFinite) return zeroAsDash ? '-' : '0';
    if (value.abs() < 0.0000001) return zeroAsDash ? '-' : '0';
    final fixed = value.toStringAsFixed(2);
    if (fixed.endsWith('.00')) return fixed.substring(0, fixed.length - 3);
    if (fixed.endsWith('0')) return fixed.substring(0, fixed.length - 1);
    return fixed;
  }

  String _formatReportCurrencyNumber(
    double value, {
    bool zeroAsDash = false,
  }) {
    final formatted = _formatReportMetricNumber(value, zeroAsDash: zeroAsDash);
    return formatted == '-' ? '₹ -' : '₹ $formatted';
  }

  Widget _buildReportPage5WithoutAmenity({
    required int pageNumber,
    required List<Map<String, dynamic>> layoutBlocks,
    bool isContinuation = false,
  }) {
    final sectionTitle = isContinuation
        ? '5. Layout Wise Sales Summary (Cont.)'
        : '5. Layout Wise Sales Summary';
    return _buildSection56LandscapeScaffold(
      pageNumber: pageNumber,
      sectionTitle: sectionTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxTableExtent = math.max(
                    0.0,
                    math.min(
                      _landscapeSection56TableUsableExtentPx(),
                      constraints.maxWidth - 24.0,
                    ),
                  );
                  final tableHeight = math.min(
                    maxTableExtent,
                    constraints.maxHeight,
                  );
                  return Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 16),
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SizedBox(
                          height: tableHeight,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (layoutBlocks.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    '-',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                ),
                              ...layoutBlocks.asMap().entries.map((entry) {
                                final block = entry.value;
                                final layoutIdx =
                                    (block['layoutIndex'] as int?) ?? entry.key;
                                final layoutName =
                                    (block['layoutName'] ?? 'Unknown')
                                        .toString();
                                final continued = block['continued'] == true;
                                final plotStartIndex =
                                    (block['plotStartIndex'] as int?) ?? 0;
                                final rawPlots =
                                    block['plots'] as List<dynamic>? ??
                                        const [];
                                final plots = rawPlots
                                    .map((p) => p is Map
                                        ? Map<String, dynamic>.from(p)
                                        : <String, dynamic>{})
                                    .toList(growable: false);
                                final rawSummaryPlots =
                                    block['allPlots'] as List<dynamic>? ??
                                        rawPlots;
                                final summaryPlots = rawSummaryPlots
                                    .map((p) => p is Map
                                        ? Map<String, dynamic>.from(p)
                                        : <String, dynamic>{})
                                    .toList(growable: false);

                                int soldPlots = 0;
                                double totalAreaSqft = 0.0;
                                double totalPlotCost = 0.0;
                                double totalSaleValue = 0.0;
                                double totalSoldAreaSqft = 0.0;
                                for (final plot in summaryPlots) {
                                  final areaSqft = _plotFieldDouble(
                                      plot, ['area', 'plotArea', 'plot_area']);
                                  totalAreaSqft += areaSqft;
                                  final status = _normalizeSiteStatusForReport(
                                    _plotFieldStr(plot, [
                                      'status',
                                      'plot_status',
                                      'sale_status'
                                    ]),
                                  );
                                  if (status != 'sold') continue;
                                  soldPlots++;
                                  final allInCost = _plotFieldDouble(plot, [
                                    'allInCostPerSqft',
                                    'all_in_cost_per_sqft',
                                    'allInCost',
                                    'all_in_cost'
                                  ]);
                                  final salePrice = _plotFieldDouble(plot, [
                                    'salePrice',
                                    'sale_price',
                                    'salePricePerSqft',
                                    'sale_price_per_sqft'
                                  ]);
                                  totalPlotCost += areaSqft * allInCost;
                                  totalSaleValue += areaSqft * salePrice;
                                  totalSoldAreaSqft += areaSqft;
                                }

                                final totalSaleAllInRateSqft =
                                    totalSoldAreaSqft > 0
                                        ? (totalSaleValue / totalSoldAreaSqft)
                                        : 0.0;
                                final totalAreaDisplay =
                                    _displayAreaFromSqft(totalAreaSqft);

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            '${layoutIdx + 1}.',
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: const Color(0xFF404040),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'Layout:',
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: const Color(0xFF404040),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            continued
                                                ? '$layoutName (Cont.)'
                                                : layoutName,
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              color: const Color(0xFF404040),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (!continued) ...[
                                        const SizedBox(height: 6),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 2,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Text(
                                              '$soldPlots / ${summaryPlots.length} plots sold',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              '•',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              'Area: ${_formatReportMetricNumber(totalAreaDisplay)} $_areaUnitSuffix',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              '•',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              'Total Plot Cost: ${_formatReportCurrencyNumber(totalPlotCost)}',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              '•',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              'Total Sales Value: ${_formatReportCurrencyNumber(totalSaleValue)}',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                      ] else
                                        const SizedBox(height: 6),
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: const Color(0xFF404040),
                                            width: 0.5,
                                          ),
                                        ),
                                        child: Column(
                                          children: [
                                            Container(
                                              color: const Color(0xFF404040),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  _buildTableCell('Sl. No.', 31,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Plot Number', 70,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Area ($_areaUnitSuffix)',
                                                      108,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Plot Cost (₹)', 86,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Sale All-in Cost (₹/$_areaUnitSuffix)',
                                                      124,
                                                      isHeader: true,
                                                      singleLine: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Sale Value (₹)', 78,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Buyer Name', 88,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Buyer\'s Contact', 72,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell('Agent', 88,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Sale Date', 60,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                ],
                                              ),
                                            ),
                                            ...List.generate(plots.length,
                                                (index) {
                                              final plot = plots[index];
                                              var plotNumber = _plotFieldStr(
                                                  plot, [
                                                'plotNumber',
                                                'plot_no',
                                                'plotNo',
                                                'number'
                                              ]);
                                              if (plotNumber == '-') {
                                                plotNumber =
                                                    _inferPlotNumber(plot);
                                              }
                                              final status =
                                                  _normalizeSiteStatusForReport(
                                                _plotFieldStr(plot, [
                                                  'status',
                                                  'plot_status',
                                                  'sale_status'
                                                ]),
                                              );
                                              final isSold = status == 'sold';
                                              final areaSqft = _plotFieldDouble(
                                                  plot, [
                                                'area',
                                                'plotArea',
                                                'plot_area'
                                              ]);
                                              final allInCostVal =
                                                  _plotFieldDouble(plot, [
                                                'allInCostPerSqft',
                                                'all_in_cost_per_sqft',
                                                'allInCost',
                                                'all_in_cost'
                                              ]);
                                              final salePriceVal =
                                                  _plotFieldDouble(plot, [
                                                'salePrice',
                                                'sale_price',
                                                'salePricePerSqft',
                                                'sale_price_per_sqft'
                                              ]);
                                              final plotCostVal =
                                                  areaSqft * allInCostVal;
                                              final saleValueVal =
                                                  areaSqft * salePriceVal;
                                              final buyerName = isSold
                                                  ? _plotFieldStr(plot, [
                                                      'buyer',
                                                      'buyerName',
                                                      'buyer_name'
                                                    ])
                                                  : '-';
                                              final buyerContact = isSold
                                                  ? _plotFieldStr(plot, [
                                                      'buyerContactNumber',
                                                      'buyer_contact_number',
                                                      'buyerContact',
                                                      'buyer_contact',
                                                      'buyerPhone',
                                                      'buyer_phone'
                                                    ])
                                                  : '-';
                                              final agentName = _plotFieldStr(
                                                  plot, [
                                                'agent',
                                                'agentName',
                                                'agent_name'
                                              ]);
                                              final saleDate = isSold
                                                  ? _saleDateLabelForReport(
                                                      plot,
                                                    )
                                                  : '-';
                                              final areaDisplay =
                                                  _displayAreaFromSqft(
                                                      areaSqft);

                                              return Container(
                                                decoration: BoxDecoration(
                                                  border: Border(
                                                    bottom: BorderSide(
                                                      color: Colors.black
                                                          .withOpacity(0.2),
                                                      width: 0.25,
                                                    ),
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    _buildTableCell(
                                                      (plotStartIndex +
                                                              index +
                                                              1)
                                                          .toString(),
                                                      31,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      plotNumber,
                                                      70,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      '${_formatReportMetricNumber(areaDisplay)} $_areaUnitSuffix',
                                                      108,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      isSold
                                                          ? _formatReportCurrencyNumber(
                                                              plotCostVal)
                                                          : '₹ -',
                                                      86,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      isSold
                                                          ? _formatReportCurrencyNumber(
                                                              _displayRateFromSqft(
                                                                  salePriceVal))
                                                          : '₹ -',
                                                      124,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      isSold
                                                          ? _formatReportCurrencyNumber(
                                                              saleValueVal)
                                                          : '₹ -',
                                                      78,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      buyerName,
                                                      88,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      buyerContact,
                                                      72,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      agentName,
                                                      88,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      saleDate,
                                                      60,
                                                      keepOriginalWidth: true,
                                                    ),
                                                  ],
                                                ),
                                              );
                                            }),
                                            Container(
                                              color: const Color(0xFFCFCFCF),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  _buildTableCell('Total', 31,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell('', 70,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                    '${_formatReportMetricNumber(totalAreaDisplay)} $_areaUnitSuffix',
                                                    108,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalPlotCost),
                                                    86,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                      _displayRateFromSqft(
                                                          totalSaleAllInRateSqft),
                                                    ),
                                                    124,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalSaleValue),
                                                    78,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell('', 88,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell('', 72,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell('', 88,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell('', 60,
                                                      keepOriginalWidth: true),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportPage6WithoutAmenity({
    required int pageNumber,
    required List<Map<String, dynamic>> layoutBlocks,
    bool isContinuation = false,
  }) {
    final plotIdToPartnerLabel = _buildPlotIdToPartnerLabelMapForReport();
    final sectionTitle = isContinuation
        ? '6. Layout Wise After Sales Summary (Cont.)'
        : '6. Layout Wise After Sales Summary';
    return _buildSection56LandscapeScaffold(
      pageNumber: pageNumber,
      sectionTitle: sectionTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxTableExtent = math.max(
                    0.0,
                    math.min(
                      _landscapeSection56TableUsableExtentPx(),
                      constraints.maxWidth - 24.0,
                    ),
                  );
                  final tableHeight = math.min(
                    maxTableExtent,
                    constraints.maxHeight,
                  );
                  return Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 16),
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: SizedBox(
                          height: tableHeight,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (layoutBlocks.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    '-',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                ),
                              ...layoutBlocks.asMap().entries.map((entry) {
                                final block = entry.value;
                                final layoutIndex =
                                    (block['layoutIndex'] as int?) ?? entry.key;
                                final layoutName =
                                    (block['layoutName'] ?? 'Unknown')
                                        .toString();
                                final continued = block['continued'] == true;
                                final plotStartIndex =
                                    (block['plotStartIndex'] as int?) ?? 0;
                                final rawPlots =
                                    block['plots'] as List<dynamic>? ??
                                        const [];
                                final plots = rawPlots
                                    .map((p) => p is Map
                                        ? Map<String, dynamic>.from(p)
                                        : <String, dynamic>{})
                                    .toList(growable: false);
                                final rawSummaryPlots =
                                    block['allPlots'] as List<dynamic>? ??
                                        rawPlots;
                                final summaryPlots = rawSummaryPlots
                                    .map((p) => p is Map
                                        ? Map<String, dynamic>.from(p)
                                        : <String, dynamic>{})
                                    .toList(growable: false);

                                int soldPlots = 0;
                                double totalAreaSqft = 0.0;
                                double totalPlotCost = 0.0;
                                double totalSaleValue = 0.0;
                                double totalReceivedAmount = 0.0;
                                double totalPendingAmount = 0.0;
                                for (final plot in summaryPlots) {
                                  final areaSqft = _plotFieldDouble(
                                      plot, ['area', 'plotArea', 'plot_area']);
                                  totalAreaSqft += areaSqft;
                                  final status = _normalizeSiteStatusForReport(
                                    _plotFieldStr(plot, [
                                      'status',
                                      'plot_status',
                                      'sale_status'
                                    ]),
                                  );
                                  if (status == 'sold') {
                                    soldPlots++;
                                  }
                                  final includeFinancials =
                                      status == 'sold' || status == 'pending';
                                  if (!includeFinancials) continue;
                                  final allInCost = _plotFieldDouble(plot, [
                                    'allInCostPerSqft',
                                    'all_in_cost_per_sqft',
                                    'allInCost',
                                    'all_in_cost'
                                  ]);
                                  final salePrice = _plotFieldDouble(plot, [
                                    'salePrice',
                                    'sale_price',
                                    'salePricePerSqft',
                                    'sale_price_per_sqft'
                                  ]);
                                  final saleValue = areaSqft * salePrice;
                                  final receivedAmount =
                                      _sumSitePlotCollectionsForReport(plot);
                                  totalPlotCost += areaSqft * allInCost;
                                  totalSaleValue += saleValue;
                                  totalReceivedAmount += receivedAmount;
                                  if (status == 'pending') {
                                    totalPendingAmount += math.max(
                                        0.0, saleValue - receivedAmount);
                                  }
                                }
                                final totalGrossProfit =
                                    totalSaleValue - totalPlotCost;
                                final totalAreaDisplay =
                                    _displayAreaFromSqft(totalAreaSqft);

                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            '${layoutIndex + 1}.',
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: const Color(0xFF404040),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'Layout:',
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: const Color(0xFF404040),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            continued
                                                ? '$layoutName (Cont.)'
                                                : layoutName,
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              color: const Color(0xFF404040),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (!continued) ...[
                                        const SizedBox(height: 6),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 2,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Text(
                                              '$soldPlots / ${summaryPlots.length} plots sold',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              '•',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              'Area: ${_formatReportMetricNumber(totalAreaDisplay)} $_areaUnitSuffix',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              '•',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              'Total Plot Cost: ${_formatReportCurrencyNumber(totalPlotCost)}',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              '•',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              'Total Sales Value: ${_formatReportCurrencyNumber(totalSaleValue)}',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 2,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            Text(
                                              'Received Amount: ${_formatReportCurrencyNumber(totalReceivedAmount)}',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              '•',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              'Pending Amount: ${_formatReportCurrencyNumber(totalPendingAmount)}',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              '•',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                            Text(
                                              'Gross Profit: ${_formatReportCurrencyNumber(totalGrossProfit)}',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                      ] else
                                        const SizedBox(height: 6),
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: const Color(0xFF404040),
                                            width: 0.5,
                                          ),
                                        ),
                                        child: Column(
                                          children: [
                                            Container(
                                              color: const Color(0xFF404040),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  _buildTableCell('Sl. No.', 31,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Plot Number', 62,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Area ($_areaUnitSuffix)',
                                                      108,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Plot Cost (₹)', 86,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Sale Value (₹)', 86,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Gross Profit (₹)', 86,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Received Amount (₹)',
                                                      102,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Pending Amount (₹)', 99,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Partner(s)', 88,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      'Sale Date', 60,
                                                      isHeader: true,
                                                      keepOriginalWidth: true),
                                                ],
                                              ),
                                            ),
                                            ...List.generate(plots.length,
                                                (idx) {
                                              final plot = plots[idx];
                                              var plotNumber = _plotFieldStr(
                                                  plot, [
                                                'plotNumber',
                                                'plot_no',
                                                'plotNo',
                                                'number'
                                              ]);
                                              if (plotNumber == '-') {
                                                plotNumber =
                                                    _inferPlotNumber(plot);
                                              }
                                              final status =
                                                  _normalizeSiteStatusForReport(
                                                _plotFieldStr(plot, [
                                                  'status',
                                                  'plot_status',
                                                  'sale_status'
                                                ]),
                                              );
                                              final includeFinancials =
                                                  status == 'sold' ||
                                                      status == 'pending';
                                              final areaSqft = _plotFieldDouble(
                                                  plot, [
                                                'area',
                                                'plotArea',
                                                'plot_area'
                                              ]);
                                              final allInCostVal =
                                                  _plotFieldDouble(plot, [
                                                'allInCostPerSqft',
                                                'all_in_cost_per_sqft',
                                                'allInCost',
                                                'all_in_cost'
                                              ]);
                                              final salePriceVal =
                                                  _plotFieldDouble(plot, [
                                                'salePrice',
                                                'sale_price',
                                                'salePricePerSqft',
                                                'sale_price_per_sqft'
                                              ]);
                                              final plotCostVal =
                                                  areaSqft * allInCostVal;
                                              final saleValueVal =
                                                  areaSqft * salePriceVal;
                                              final grossProfitVal =
                                                  saleValueVal - plotCostVal;
                                              final receivedVal =
                                                  _sumSitePlotCollectionsForReport(
                                                      plot);
                                              final pendingVal = math.max(0.0,
                                                  saleValueVal - receivedVal);
                                              final plotId =
                                                  _plotIdStringForReport(plot);
                                              final normalizedPlotId =
                                                  _normalizePlotIdentityForReport(
                                                      plotId);
                                              final normalizedPlotNumber =
                                                  _normalizePlotIdentityForReport(
                                                      plotNumber);
                                              final partnerNameFromPlot =
                                                  _partnerLabelFromPlotForReport(
                                                      plot);
                                              final partnerName =
                                                  _firstNonEmptyStringReport([
                                                        partnerNameFromPlot ==
                                                                '-'
                                                            ? null
                                                            : partnerNameFromPlot,
                                                        plotIdToPartnerLabel[
                                                            plotId],
                                                        plotIdToPartnerLabel[
                                                            normalizedPlotId],
                                                        plotIdToPartnerLabel[
                                                            plotNumber],
                                                        plotIdToPartnerLabel[
                                                            normalizedPlotNumber],
                                                      ]) ??
                                                      '-';
                                              final saleDate = includeFinancials
                                                  ? _saleDateLabelForReport(
                                                      plot,
                                                    )
                                                  : '-';
                                              final areaDisplay =
                                                  _displayAreaFromSqft(
                                                      areaSqft);

                                              return Container(
                                                decoration: BoxDecoration(
                                                  border: Border(
                                                    bottom: BorderSide(
                                                      color: Colors.black
                                                          .withOpacity(0.2),
                                                      width: 0.25,
                                                    ),
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    _buildTableCell(
                                                      (plotStartIndex + idx + 1)
                                                          .toString(),
                                                      31,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      plotNumber,
                                                      62,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      '${_formatReportMetricNumber(areaDisplay)} $_areaUnitSuffix',
                                                      108,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      includeFinancials
                                                          ? _formatReportCurrencyNumber(
                                                              plotCostVal)
                                                          : '₹ -',
                                                      86,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      includeFinancials
                                                          ? _formatReportCurrencyNumber(
                                                              saleValueVal)
                                                          : '₹ -',
                                                      86,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      includeFinancials
                                                          ? _formatReportCurrencyNumber(
                                                              grossProfitVal)
                                                          : '₹ -',
                                                      86,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      includeFinancials
                                                          ? _formatReportCurrencyNumber(
                                                              receivedVal)
                                                          : '₹ -',
                                                      102,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      includeFinancials
                                                          ? _formatReportCurrencyNumber(
                                                              pendingVal)
                                                          : '₹ -',
                                                      99,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      partnerName,
                                                      88,
                                                      keepOriginalWidth: true,
                                                    ),
                                                    _buildTableCell(
                                                      saleDate,
                                                      60,
                                                      keepOriginalWidth: true,
                                                    ),
                                                  ],
                                                ),
                                              );
                                            }),
                                            Container(
                                              color: const Color(0xFFCFCFCF),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  _buildTableCell('Total', 31,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell('', 62,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                    '${_formatReportMetricNumber(totalAreaDisplay)} $_areaUnitSuffix',
                                                    108,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalPlotCost),
                                                    86,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalSaleValue),
                                                    86,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalGrossProfit),
                                                    86,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalReceivedAmount),
                                                    102,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell(
                                                    _formatReportCurrencyNumber(
                                                        totalPendingAmount),
                                                    99,
                                                    keepOriginalWidth: true,
                                                  ),
                                                  _buildTableCell('', 88,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell('', 60,
                                                      keepOriginalWidth: true),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _amenitySaleDateLabelForReport(Map<String, dynamic> row) {
    return _saleDateLabelForReport(row);
  }

  String _amenityBuyerLabelForReport(Map<String, dynamic> row) {
    return _plotFieldStr(row, ['buyer_name', 'buyerName', 'buyer']);
  }

  String _amenityAgentLabelForReport(Map<String, dynamic> row) {
    return _plotFieldStr(row, ['agent_name', 'agentName', 'agent']);
  }

  // Horizontal extent available to the rotated tables on sections 5 and 6
  // after placing landscape header/footer rails on left and right.
  double _landscapeSection56TableUsableExtentPx() {
    const pageWidth = 595.0;
    const tableInnerHorizontalPadding = 24.0; // left 8 + right 16
    return math.max(
      0.0,
      pageWidth -
          (_section56LandscapeSideRailWidth * 2) -
          tableInnerHorizontalPadding,
    );
  }

  // Max horizontal extent for rotated (landscape-style) report tables.
  // Keeps 16px breathing space from the right page edge.
  double _landscapeTableUsableExtentPx() {
    const pageWidth = 595.0;
    const containerHorizontalPadding = 32.0; // 16 left + 16 right
    const innerLeftInset = 8.0;
    const rightEdgeGap = 16.0;
    return pageWidth -
        containerHorizontalPadding -
        innerLeftInset -
        rightEdgeGap;
  }

  List<Widget> _buildReportPageAmenitySalesPages(
      {required int startPageNumber}) {
    final allRows = _collectAmenityAreasForReport();
    if (allRows.isEmpty) return const <Widget>[];

    final usableExtent = _landscapeTableUsableExtentPx();
    const baseHeight = 58.0; // summary rows + gaps + table header
    const rowHeight = 17.0;
    const totalRowHeight = 17.0;
    final pages = <Widget>[];
    int start = 0;
    while (start < allRows.length) {
      final remainingRows = allRows.length - start;
      int rowsThatFit = ((usableExtent - baseHeight) / rowHeight).floor();
      if (rowsThatFit < 1) rowsThatFit = 1;

      // If this would be the last page, reserve space for the totals row.
      if (rowsThatFit >= remainingRows &&
          baseHeight + (remainingRows * rowHeight) + totalRowHeight >
              usableExtent &&
          remainingRows > 1) {
        rowsThatFit = remainingRows - 1;
      }

      final take = math.min(rowsThatFit, remainingRows);
      final end = start + take;
      pages.add(
        _buildReportPageAmenitySales(
          pageNumber: startPageNumber + pages.length,
          allRows: allRows,
          rowsChunk: allRows.sublist(start, end),
          rowStartIndex: start,
          showTotalRow: end >= allRows.length,
          isContinuation: start > 0,
        ),
      );
      start = end;
    }

    return pages;
  }

  Widget _buildReportPageAmenitySales({
    required int pageNumber,
    required List<Map<String, dynamic>> allRows,
    required List<Map<String, dynamic>> rowsChunk,
    required int rowStartIndex,
    required bool showTotalRow,
    bool isContinuation = false,
  }) {
    final pendingRows = allRows
        .where((row) => _amenityStatusForReport(row) == 'pending')
        .toList(growable: false);
    final soldRows = allRows
        .where((row) => _amenityStatusForReport(row) == 'sold')
        .toList(growable: false);
    final soldCount = soldRows.length;
    final pendingCount = pendingRows.length;
    final availableCount =
        math.max(0, allRows.length - soldCount - pendingCount);
    final hasPendingAmenity = pendingCount > 0;
    final totalAreaSqft = allRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityAreaSqftForReport(row),
    );
    final totalPlotCost = allRows.fold<double>(
      0.0,
      (sum, row) =>
          sum +
          (_amenityAreaSqftForReport(row) *
              _amenityAllInCostSqftForReport(row)),
    );
    final totalSaleValue = soldRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenitySaleValueForReport(row),
    );
    final grossProfit = totalSaleValue - totalPlotCost;
    final actualTotalSalesValue = allRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityPaymentAmountForReport(row),
    );
    final actualGrossProfit = actualTotalSalesValue - totalPlotCost;
    final pendingAmount = pendingRows.fold<double>(
      0.0,
      (sum, row) =>
          sum +
          math.max(
              0.0,
              _amenitySaleValueForReport(row) -
                  _amenityPaymentAmountForReport(row)),
    );

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Color(0xFF404040),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 8, bottom: 8),
            child: Text(
              isContinuation
                  ? 'Amenity Area Sales Summary (Cont.)'
                  : 'Amenity Area Sales Summary',
              style: GoogleFonts.inriaSerif(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tableHeight = math.min(
                    _landscapeTableUsableExtentPx(), constraints.maxHeight);
                return Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SizedBox(
                        height: tableHeight,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Amenity Area',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                color: const Color(0xFF404040),
                              ),
                            ),
                            const SizedBox(height: 4),
                            if (hasPendingAmenity) ...[
                              Wrap(
                                spacing: 8,
                                runSpacing: 2,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    '$availableCount / ${allRows.length} plots available',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    '|',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    '$soldCount / ${allRows.length} plots sold',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    '|',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    '$pendingCount / ${allRows.length} plots pending',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    '|',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    'Area: ${_formatTo2Decimals(_displayAreaFromSqft(totalAreaSqft))} $_areaUnitSuffix',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    '|',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    'Total Plot Cost: ₹ ${_formatTo2Decimals(totalPlotCost)}',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                runSpacing: 2,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    'Total Pending Amount: ₹ ${_formatTo2Decimals(pendingAmount)}',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    '|',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    'Actual Sale Value: ₹ ${_formatTo2Decimals(actualTotalSalesValue)}',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    '|',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  Text(
                                    'Actual Gross Profit: ₹ ${_formatTo2Decimals(actualGrossProfit)}',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                ],
                              ),
                            ] else ...[
                              Row(
                                children: [
                                  Text(
                                    '$availableCount / ${allRows.length} plots available',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    width: 2,
                                    height: 12,
                                    color: const Color(0xFF404040),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '$soldCount / ${allRows.length} plots sold',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    width: 2,
                                    height: 12,
                                    color: const Color(0xFF404040),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Area: ${_formatTo2Decimals(_displayAreaFromSqft(totalAreaSqft))} $_areaUnitSuffix',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    width: 2,
                                    height: 12,
                                    color: const Color(0xFF404040),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Total Plot Cost: ₹ ${_formatTo2Decimals(totalPlotCost)}',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(
                                    'Total Sale Value: ₹ ${_formatTo2Decimals(totalSaleValue)}',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    width: 2,
                                    height: 12,
                                    color: const Color(0xFF404040),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Gross Profit: ₹ ${_formatTo2Decimals(grossProfit)}',
                                    style: GoogleFonts.inriaSerif(
                                      fontSize: 10,
                                      color: const Color(0xFF404040),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 8),
                            Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(0xFF404040),
                                  width: 0.5,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Container(
                                    color: const Color(0xFF404040),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _buildTableCell('Sl. No.', 33,
                                            isHeader: true,
                                            keepOriginalWidth: true),
                                        _buildTableCell('Amenity Plot', 68,
                                            isHeader: true,
                                            keepOriginalWidth: true),
                                        _buildTableCell(
                                            'Area ($_areaUnitSuffix)', 108,
                                            isHeader: true),
                                        _buildTableCell(
                                            'All-in Cost (₹/$_areaUnitSuffix)',
                                            108,
                                            isHeader: true),
                                        _buildTableCell('Plot Cost (₹)', 108,
                                            isHeader: true),
                                        _buildTableCell(
                                            'Sale Price (₹/$_areaUnitSuffix)',
                                            108,
                                            isHeader: true),
                                        _buildTableCell('Sale Value (₹)', 102,
                                            isHeader: true),
                                        _buildTableCell('Sale Date', 69,
                                            isHeader: true),
                                      ],
                                    ),
                                  ),
                                  ...List.generate(rowsChunk.length, (index) {
                                    final row = rowsChunk[index];
                                    final areaSqft =
                                        _amenityAreaSqftForReport(row);
                                    final allInCostSqft =
                                        _amenityAllInCostSqftForReport(row);
                                    final salePriceSqft =
                                        _amenitySalePriceSqftForReport(row);
                                    final saleValue =
                                        _amenitySaleValueForReport(row);
                                    final plotCost = areaSqft * allInCostSqft;
                                    final amenityName = _plotFieldStr(
                                      row,
                                      ['name', 'amenityName', 'amenity_name'],
                                    );

                                    return Container(
                                      decoration: BoxDecoration(
                                        border: Border(
                                          bottom: BorderSide(
                                            color:
                                                Colors.black.withOpacity(0.2),
                                            width: 0.25,
                                          ),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _buildTableCell(
                                            (rowStartIndex + index + 1)
                                                .toString(),
                                            33,
                                            keepOriginalWidth: true,
                                          ),
                                          _buildTableCell(
                                            amenityName == '-'
                                                ? ''
                                                : amenityName,
                                            68,
                                            keepOriginalWidth: true,
                                          ),
                                          _buildTableCell(
                                            '${_formatTo2Decimals(_displayAreaFromSqft(areaSqft))} $_areaUnitSuffix',
                                            108,
                                          ),
                                          _buildTableCell(
                                            '₹ ${_formatTo2Decimals(_displayRateFromSqft(allInCostSqft))}',
                                            108,
                                          ),
                                          _buildTableCell(
                                            '₹ ${_formatTo2Decimals(plotCost)}',
                                            108,
                                          ),
                                          _buildTableCell(
                                            '₹ ${_formatTo2Decimals(_displayRateFromSqft(salePriceSqft))}',
                                            108,
                                          ),
                                          _buildTableCell(
                                            '₹ ${_formatTo2Decimals(saleValue)}',
                                            102,
                                          ),
                                          _buildTableCell(
                                            _amenitySaleDateLabelForReport(row),
                                            69,
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                  if (showTotalRow)
                                    Container(
                                      color: Colors.grey.withOpacity(0.25),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _buildTableCell('', 33,
                                              keepOriginalWidth: true),
                                          _buildTableCell('Total', 68,
                                              keepOriginalWidth: true),
                                          _buildTableCell(
                                            '${_formatTo2Decimals(_displayAreaFromSqft(totalAreaSqft))} $_areaUnitSuffix',
                                            108,
                                          ),
                                          _buildTableCell('-', 108),
                                          _buildTableCell(
                                            '₹ ${_formatTo2Decimals(totalPlotCost)}',
                                            108,
                                          ),
                                          _buildTableCell('-', 108),
                                          _buildTableCell(
                                            '₹ ${_formatTo2Decimals(totalSaleValue)}',
                                            102,
                                          ),
                                          _buildTableCell('-', 69),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  List<Widget> _buildReportPageAmenityAfterSalesPages(
      {required int startPageNumber}) {
    final allRows = _collectAmenityAreasForReport();
    if (allRows.isEmpty) return const <Widget>[];

    final usableExtent = _landscapeTableUsableExtentPx();
    const baseHeight = 48.0; // heading lines + gap + table header
    const rowHeight = 17.0;
    const totalRowHeight = 17.0;
    final pages = <Widget>[];
    int start = 0;
    while (start < allRows.length) {
      final remainingRows = allRows.length - start;
      int rowsThatFit = ((usableExtent - baseHeight) / rowHeight).floor();
      if (rowsThatFit < 1) rowsThatFit = 1;

      if (rowsThatFit >= remainingRows &&
          baseHeight + (remainingRows * rowHeight) + totalRowHeight >
              usableExtent &&
          remainingRows > 1) {
        rowsThatFit = remainingRows - 1;
      }

      final take = math.min(rowsThatFit, remainingRows);
      final end = start + take;
      pages.add(
        _buildReportPageAmenityAfterSales(
          pageNumber: startPageNumber + pages.length,
          allRows: allRows,
          rowsChunk: allRows.sublist(start, end),
          rowStartIndex: start,
          showTotalRow: end >= allRows.length,
          isContinuation: start > 0,
        ),
      );
      start = end;
    }

    return pages;
  }

  Widget _buildReportPageAmenityAfterSales({
    required int pageNumber,
    required List<Map<String, dynamic>> allRows,
    required List<Map<String, dynamic>> rowsChunk,
    required int rowStartIndex,
    required bool showTotalRow,
    bool isContinuation = false,
  }) {
    final pendingRows = allRows
        .where((row) => _amenityStatusForReport(row) == 'pending')
        .toList(growable: false);
    final soldCount =
        allRows.where((row) => _amenityStatusForReport(row) == 'sold').length;
    final pendingCount = pendingRows.length;
    final availableCount =
        math.max(0, allRows.length - soldCount - pendingCount);
    final hasPendingAmenity = pendingCount > 0;
    final pendingAmount = pendingRows.fold<double>(
      0.0,
      (sum, row) =>
          sum +
          math.max(
              0.0,
              _amenitySaleValueForReport(row) -
                  _amenityPaymentAmountForReport(row)),
    );
    final totalAreaSqft = allRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityAreaSqftForReport(row),
    );

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Color(0xFF404040),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 8, bottom: 8),
            child: Text(
              isContinuation
                  ? 'Amenity Area After Sales Summary (Cont.)'
                  : 'Amenity Area After Sales Summary',
              style: GoogleFonts.inriaSerif(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final tableHeight = math.min(
                    _landscapeTableUsableExtentPx(), constraints.maxHeight);
                return Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SizedBox(
                        height: tableHeight,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Amenity Area',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                color: const Color(0xFF404040),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              hasPendingAmenity
                                  ? '$availableCount / ${allRows.length} plots available | $soldCount / ${allRows.length} plots sold | $pendingCount / ${allRows.length} plots pending | Total Pending Amount: ₹ ${_formatTo2Decimals(pendingAmount)}'
                                  : '$availableCount / ${allRows.length} plots available | $soldCount / ${allRows.length} plots sold',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                color: const Color(0xFF404040),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(0xFF404040),
                                  width: 0.5,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Container(
                                    color: const Color(0xFF404040),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _buildTableCell('Sl. No.', 37,
                                            isHeader: true,
                                            keepOriginalWidth: true),
                                        _buildTableCell('Amenity Plot', 68,
                                            isHeader: true,
                                            keepOriginalWidth: true),
                                        _buildTableCell(
                                            'Area ($_areaUnitSuffix)', 108,
                                            isHeader: true),
                                        _buildTableCell(
                                            'All-in Cost (₹/$_areaUnitSuffix)',
                                            108,
                                            isHeader: true),
                                        _buildTableCell('Partner(s) Name', 136,
                                            isHeader: true),
                                        _buildTableCell('Buyer\'s Name', 136,
                                            isHeader: true),
                                        _buildTableCell('Agent', 136,
                                            isHeader: true),
                                        _buildTableCell('Sale Date', 69,
                                            isHeader: true),
                                      ],
                                    ),
                                  ),
                                  ...List.generate(rowsChunk.length, (index) {
                                    final row = rowsChunk[index];
                                    final areaSqft =
                                        _amenityAreaSqftForReport(row);
                                    final allInCostSqft =
                                        _amenityAllInCostSqftForReport(row);
                                    final amenityName = _plotFieldStr(
                                      row,
                                      ['name', 'amenityName', 'amenity_name'],
                                    );
                                    return Container(
                                      decoration: BoxDecoration(
                                        border: Border(
                                          bottom: BorderSide(
                                            color:
                                                Colors.black.withOpacity(0.2),
                                            width: 0.25,
                                          ),
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _buildTableCell(
                                            (rowStartIndex + index + 1)
                                                .toString(),
                                            37,
                                            keepOriginalWidth: true,
                                          ),
                                          _buildTableCell(
                                            amenityName == '-'
                                                ? ''
                                                : amenityName,
                                            68,
                                            keepOriginalWidth: true,
                                          ),
                                          _buildTableCell(
                                            '${_formatTo2Decimals(_displayAreaFromSqft(areaSqft))} $_areaUnitSuffix',
                                            108,
                                          ),
                                          _buildTableCell(
                                            '₹ ${_formatTo2Decimals(_displayRateFromSqft(allInCostSqft))}',
                                            108,
                                          ),
                                          _buildTableCell(
                                            _amenityPartnerLabelForReport(row),
                                            136,
                                          ),
                                          _buildTableCell(
                                            _amenityBuyerLabelForReport(row),
                                            136,
                                          ),
                                          _buildTableCell(
                                            _amenityAgentLabelForReport(row),
                                            136,
                                          ),
                                          _buildTableCell(
                                            _amenitySaleDateLabelForReport(row),
                                            69,
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                  if (showTotalRow)
                                    Container(
                                      color: Colors.grey.withOpacity(0.25),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _buildTableCell('', 37,
                                              keepOriginalWidth: true),
                                          _buildTableCell('Total', 68,
                                              keepOriginalWidth: true),
                                          _buildTableCell(
                                            '${_formatTo2Decimals(_displayAreaFromSqft(totalAreaSqft))} $_areaUnitSuffix',
                                            108,
                                          ),
                                          _buildTableCell('-', 108),
                                          _buildTableCell('', 136),
                                          _buildTableCell('', 136),
                                          _buildTableCell('', 136),
                                          _buildTableCell('', 69),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  Widget _buildReportPage7({
    required int pageNumber,
    int startPartnerIndex = 0,
    int? partnerLimit,
    bool showSummarySection = true,
    bool showTotals = true,
    bool isContinuation = false,
  }) {
    final List<dynamic> partnersRaw = _projectData['partners'] ?? [];
    final List<Map<String, dynamic>> partners = partnersRaw
        .map((p) =>
            p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{})
        .toList();
    // fallback: derive partners from plots if none provided
    final allPlots = _collectReportPlotsForOverview();
    if (partners.isEmpty) {
      final names = <String>{};
      for (final plot in allPlots) {
        final partnerNames = _partnerNamesFromPlotForReport(plot);
        for (final name in partnerNames) {
          if (name.trim().isEmpty) continue;
          names.add(name.trim());
        }
      }
      for (var n in names) {
        partners.add({'name': n});
      }
    }

    // Use plot_partners mapping for partner-plot assignment.
    // 1. Build plotId -> plotNumber/layout map
    final plotIdToNumber = <String, String>{};
    final plotIdToLayout = <String, String>{};
    final plotNumberToLayout = <String, String>{};
    final plotIdToPartnerNames = <String, List<String>>{};
    for (final plot in allPlots) {
      final plotId = _plotIdStringForReport(plot);
      final normalizedPlotId = _normalizePlotIdentityForReport(plotId);
      final plotNumber = _plotFieldStr(
          plot, ['plotNumber', 'plot_no', 'plotNo', 'number', 'plot_number']);
      final normalizedPlotNumber = _normalizePlotIdentityForReport(plotNumber);
      final layoutLabel = _resolveLayoutLabel(plot);
      if (plotId.isNotEmpty) {
        plotIdToNumber[plotId] = plotNumber;
        plotIdToLayout[plotId] = layoutLabel;
        if (normalizedPlotId.isNotEmpty) {
          plotIdToNumber[normalizedPlotId] = plotNumber;
          plotIdToLayout[normalizedPlotId] = layoutLabel;
        }
      }
      if (plotNumber.isNotEmpty && plotNumber != '-') {
        plotNumberToLayout[plotNumber] = layoutLabel;
        plotIdToNumber[plotNumber] = plotNumber;
        plotIdToLayout[plotNumber] = layoutLabel;
        if (normalizedPlotNumber.isNotEmpty) {
          plotIdToNumber[normalizedPlotNumber] = plotNumber;
          plotIdToLayout[normalizedPlotNumber] = layoutLabel;
        }
      }
    }

    // 2. Fetch plot_partners assignments from _projectData if available
    final plotPartnersRaw =
        _projectData['plot_partners'] as List<dynamic>? ?? [];
    for (var assignment in plotPartnersRaw) {
      if (assignment is! Map) continue;
      final row = Map<String, dynamic>.from(assignment);
      final partnerNames = _extractPartnerNamesFromAnyReport(
        row['partner_name'] ??
            row['partnerName'] ??
            row['partners_name'] ??
            row['partnersName'] ??
            row['name'] ??
            row['partner'] ??
            row['partners'],
      );
      final plotId = (row['plot_id'] ??
              row['plotId'] ??
              row['id'] ??
              row['plot_number'] ??
              row['plotNumber'] ??
              row['plot_no'] ??
              row['plotNo'] ??
              row['number'] ??
              row['plot'] ??
              row['plot_identity'] ??
              row['plotIdentity'] ??
              '')
          .toString();
      if (plotId.trim().isEmpty || partnerNames.isEmpty) continue;
      final normalizedPlotId = _normalizePlotIdentityForReport(plotId);
      for (final partnerName in partnerNames) {
        plotIdToPartnerNames.putIfAbsent(plotId, () => []).add(partnerName);
        if (normalizedPlotId.isNotEmpty) {
          plotIdToPartnerNames
              .putIfAbsent(normalizedPlotId, () => [])
              .add(partnerName);
        }
      }
    }

    // 3. Build plotsByPartner from plot_partners.
    final plotsByPartner = <String, List<String>>{};
    final plotsByPartnerDetailed = <String, List<Map<String, String>>>{};
    plotIdToPartnerNames.forEach((plotId, partnerNames) {
      final plotNumber = plotIdToNumber[plotId] ?? '';
      if (plotNumber.isEmpty) return;
      final layoutLabel = plotIdToLayout[plotId] ?? 'Unknown';
      for (final partnerName in partnerNames) {
        final nameNorm = partnerName.toLowerCase().trim();
        if (nameNorm.isEmpty || nameNorm == '-') continue;
        plotsByPartner.putIfAbsent(nameNorm, () => []);
        plotsByPartner[nameNorm]!.add(plotNumber);
        plotsByPartnerDetailed.putIfAbsent(nameNorm, () => []);
        plotsByPartnerDetailed[nameNorm]!
            .add({'layout': layoutLabel, 'plot': plotNumber});
      }
    });

    // 4. Add assigned plots info to each partner (by normalized name).
    for (final p in partners) {
      final name = (p['name'] ?? p['partnerName'] ?? p['partner_name'] ?? '-')
          .toString()
          .toLowerCase()
          .trim();
      final assigned = List<String>.from(plotsByPartner[name] ?? const []);
      final assignedDetailed = List<Map<String, String>>.from(
        plotsByPartnerDetailed[name] ?? const [],
      );

      if (assignedDetailed.isEmpty) {
        final seen = <String>{};
        for (final plot in allPlots) {
          final partnerNames = _partnerNamesFromPlotForReport(plot);
          final matchesPartner = partnerNames.any((partnerName) {
            final normalized = partnerName.toLowerCase().trim();
            if (normalized.isEmpty || normalized == '-') return false;
            return normalized == name ||
                normalized.contains(name) ||
                name.contains(normalized);
          });
          if (!matchesPartner) continue;

          final plotNo = _plotFieldStr(plot, [
            'plotNumber',
            'plot_no',
            'plotNo',
            'number',
            'plot_number',
          ]);
          final normalizedPlotNo =
              plotNo == '-' ? _inferPlotNumber(plot) : plotNo;
          if (normalizedPlotNo.trim().isEmpty || normalizedPlotNo == '-') {
            continue;
          }

          final dedupeKey = normalizedPlotNo.toLowerCase();
          if (!seen.add(dedupeKey)) continue;
          assigned.add(normalizedPlotNo);
          assignedDetailed.add({
            'layout': _resolveLayoutLabel(plot),
            'plot': normalizedPlotNo,
          });
        }
      }

      p['assignedPlots'] = assigned;
      p['assignedPlotsDetailed'] = assignedDetailed;
      p['plotCount'] = assigned.length;
      p['plotNumberToLayoutMap'] = plotNumberToLayout;
    }
    final visiblePartners = partnerLimit == null
        ? partners
        : partners
            .skip(startPartnerIndex)
            .take(partnerLimit)
            .toList(growable: false);
    final showDistributionSection =
        visiblePartners.isNotEmpty || (showSummarySection && partners.isEmpty);
    final partnersProfitPool = _computePartnersProfitPoolForReport();

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            height: 55,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: const Color(0xFF404040),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _reportHeaderUnitText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
                Text(
                  _reportHeaderDateText,
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF404040),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.only(left: 0, top: 8, bottom: 8),
                    child: Text(
                      isContinuation
                          ? '2. Partner(s) Details (Cont.)'
                          : '2. Partner(s) Details',
                      style: GoogleFonts.inriaSerif(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF0C8CE9),
                      ),
                    ),
                  ),

                  // 3.1 Partner(s) Profit Distribution
                  if (showSummarySection) ...[
                    Padding(
                      padding:
                          const EdgeInsets.only(left: 0, top: 4, bottom: 8),
                      child: Text(
                        '2.1  Partner(s) Profit Distribution',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF404040)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        'Partners Profit Pool: ${_formatCurrencyWithSignReport(partnersProfitPool)}',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 10, color: const Color(0xFF404040)),
                      ),
                    ),
                  ],

                  if (showSummarySection) ...[
                    // Profit table (shown only on first page)
                    Padding(
                      padding: const EdgeInsets.only(left: 0, right: 8),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: const Color(0xFF404040), width: 0.5),
                        ),
                        child: Column(
                          children: [
                            Container(
                              color: const Color(0xFF404040),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildTableCell('Partner Name', 143,
                                      isHeader: true, keepOriginalWidth: true),
                                  _buildTableCell(
                                      'Capital Contribution (₹)', 148,
                                      isHeader: true),
                                  _buildTableCell('Allocated Profit (₹)', 148,
                                      isHeader: true),
                                  _buildTableCell('Profit Share (%)', 110,
                                      isHeader: true),
                                ],
                              ),
                            ),
                            // rows
                            ...(() {
                              final profitRows =
                                  _buildOverviewPartnerProfitRowsForReport(
                                partnersProfitPool,
                              );

                              final rowWidgets = <Widget>[];
                              for (final row in profitRows) {
                                final name = (row['name'] ?? '-').toString();
                                final capitalVal = _toDouble(row['capital']);
                                final profitShareVal = _toDouble(row['share']);
                                final allocatedVal =
                                    _toDouble(row['allocated']);

                                rowWidgets.add(Container(
                                  decoration: BoxDecoration(
                                      border: Border(
                                          bottom: BorderSide(
                                              color:
                                                  Colors.black.withOpacity(0.2),
                                              width: 0.25))),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildTableCell(name, 143,
                                          keepOriginalWidth: true),
                                      _buildTableCell(
                                          _formatCurrencyWithSignReport(
                                              capitalVal),
                                          148),
                                      _buildTableCell(
                                          _formatCurrencyWithSignReport(
                                              allocatedVal),
                                          148),
                                      _buildTableCell(
                                          '${profitShareVal.toStringAsFixed(profitShareVal % 1 == 0 ? 0 : 2)}%',
                                          110),
                                    ],
                                  ),
                                ));
                              }

                              final grandCapital = profitRows.fold<double>(
                                0.0,
                                (sum, row) => sum + _toDouble(row['capital']),
                              );
                              final grandAllocated = profitRows.fold<double>(
                                0.0,
                                (sum, row) => sum + _toDouble(row['allocated']),
                              );
                              final grandProfitShare = profitRows.fold<double>(
                                0.0,
                                (sum, row) => sum + _toDouble(row['share']),
                              );
                              rowWidgets.add(Container(
                                color: Colors.grey.withOpacity(0.25),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildTableCell('Total', 143,
                                        keepOriginalWidth: true),
                                    _buildTableCell(
                                        _formatCurrencyWithSignReport(
                                            grandCapital),
                                        148),
                                    _buildTableCell(
                                        _formatCurrencyWithSignReport(
                                            grandAllocated),
                                        148),
                                    _buildTableCell(
                                        '${grandProfitShare.toStringAsFixed(grandProfitShare % 1 == 0 ? 0 : 2)}%',
                                        110),
                                  ],
                                ),
                              ));

                              return rowWidgets;
                            }()),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  if (showDistributionSection) ...[
                    // 2.2 Partner - Plot Distribution
                    Padding(
                      padding:
                          const EdgeInsets.only(left: 0, top: 4, bottom: 8),
                      child: Text(
                        '2.2  Partner - Plot Distribution',
                        style: GoogleFonts.inriaSerif(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF404040)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 0, right: 8),
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: const Color(0xFF404040), width: 0.5),
                        ),
                        child: Column(
                          children: [
                            Container(
                              color: const Color(0xFF404040),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 4),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 143,
                                    child: Text(
                                      'Partner Name',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 96,
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        'No. of Plots Assigned',
                                        maxLines: 1,
                                        softWrap: false,
                                        style: GoogleFonts.inriaSerif(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 32),
                                  Expanded(
                                    child: Text(
                                      'Plot(s) Assigned',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            ...(() {
                              final grandTotalAssigned = partners.fold<int>(
                                0,
                                (sum, p) =>
                                    sum +
                                    (((p['plotCount'] as num?)?.toInt()) ?? 0),
                              );
                              final rows = <Widget>[];

                              if (visiblePartners.isEmpty &&
                                  showSummarySection &&
                                  partners.isNotEmpty) {
                                rows.add(
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border(
                                        bottom: BorderSide(
                                          color: Colors.black.withOpacity(0.25),
                                          width: 0.25,
                                        ),
                                      ),
                                    ),
                                    child: Text(
                                      'Rows continue on the next page due to space constraints.',
                                      style: GoogleFonts.inriaSerif(
                                        fontSize: 10,
                                        color: const Color(0xFF404040),
                                      ),
                                    ),
                                  ),
                                );
                              }

                              for (final p in visiblePartners) {
                                final name = (p['name'] ??
                                        p['partnerName'] ??
                                        p['partner_name'] ??
                                        '-')
                                    .toString();
                                final nameNorm = name.toLowerCase().trim();

                                final assignedDetailed =
                                    <Map<String, String>>[];
                                if (p['assignedPlotsDetailed'] is List &&
                                    (p['assignedPlotsDetailed'] as List)
                                        .isNotEmpty) {
                                  for (final raw
                                      in (p['assignedPlotsDetailed'] as List)) {
                                    if (raw is! Map) continue;
                                    final detail =
                                        Map<String, dynamic>.from(raw);
                                    final plotNo = (detail['plot'] ?? '')
                                        .toString()
                                        .trim();
                                    final layout = (detail['layout'] ?? '')
                                        .toString()
                                        .trim();
                                    if (plotNo.isEmpty) continue;
                                    assignedDetailed.add({
                                      'plot': plotNo,
                                      'layout':
                                          layout.isEmpty ? 'Unknown' : layout,
                                    });
                                  }
                                } else if (p['assignedPlots'] is List) {
                                  final layoutMap = <String, String>{};
                                  final layoutMapRaw =
                                      p['plotNumberToLayoutMap'];
                                  if (layoutMapRaw is Map) {
                                    layoutMapRaw.forEach((key, value) {
                                      final k = key?.toString().trim() ?? '';
                                      final v = value?.toString().trim() ?? '';
                                      if (k.isNotEmpty) {
                                        layoutMap[k] =
                                            v.isEmpty ? 'Unknown' : v;
                                      }
                                    });
                                  }
                                  for (final raw
                                      in (p['assignedPlots'] as List)) {
                                    final plotNo = raw?.toString().trim() ?? '';
                                    if (plotNo.isEmpty) continue;
                                    assignedDetailed.add({
                                      'plot': plotNo,
                                      'layout': layoutMap[plotNo] ?? 'Unknown',
                                    });
                                  }
                                }

                                if (assignedDetailed.isEmpty) {
                                  for (final plot in allPlots) {
                                    final partnerNames =
                                        _partnerNamesFromPlotForReport(plot);
                                    final matchesPartner = partnerNames.any(
                                      (partnerName) {
                                        final normalized =
                                            partnerName.toLowerCase().trim();
                                        if (normalized.isEmpty ||
                                            normalized == '-') {
                                          return false;
                                        }
                                        return normalized == nameNorm ||
                                            normalized.contains(nameNorm) ||
                                            nameNorm.contains(normalized);
                                      },
                                    );
                                    if (!matchesPartner) continue;
                                    final plotNo = _plotFieldStr(plot, [
                                      'plotNumber',
                                      'plot_no',
                                      'plotNo',
                                      'number',
                                      'plot_number',
                                    ]);
                                    final normalizedPlotNo = plotNo == '-'
                                        ? _inferPlotNumber(plot)
                                        : plotNo;
                                    if (normalizedPlotNo.trim().isEmpty ||
                                        normalizedPlotNo == '-') {
                                      continue;
                                    }
                                    assignedDetailed.add({
                                      'plot': normalizedPlotNo,
                                      'layout': _resolveLayoutLabel(plot),
                                    });
                                  }
                                }

                                final groupedByLayout =
                                    <String, List<String>>{};
                                final seen = <String>{};
                                for (final detail in assignedDetailed) {
                                  final layout = (detail['layout'] ?? 'Unknown')
                                      .toString()
                                      .trim();
                                  final plotNo =
                                      (detail['plot'] ?? '').toString().trim();
                                  if (plotNo.isEmpty) continue;
                                  final dedupeKey =
                                      '${layout.toLowerCase()}::${plotNo.toLowerCase()}';
                                  if (!seen.add(dedupeKey)) continue;
                                  groupedByLayout.putIfAbsent(
                                    layout.isEmpty ? 'Unknown' : layout,
                                    () => <String>[],
                                  );
                                  groupedByLayout[
                                          layout.isEmpty ? 'Unknown' : layout]!
                                      .add(plotNo);
                                }

                                final assignedCount = groupedByLayout.values
                                    .fold<int>(
                                        0, (sum, items) => sum + items.length);

                                rows.add(
                                  Container(
                                    decoration: BoxDecoration(
                                      border: Border(
                                        bottom: BorderSide(
                                          color: Colors.black.withOpacity(0.25),
                                          width: 0.25,
                                        ),
                                      ),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                          width: 143,
                                          child: Text(
                                            name,
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              color: const Color(0xFF404040),
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: 96,
                                          child: Align(
                                            alignment: Alignment.center,
                                            child: Text(
                                              '$assignedCount',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 32),
                                        Expanded(
                                          child: groupedByLayout.isEmpty
                                              ? Text(
                                                  '-',
                                                  style: GoogleFonts.inriaSerif(
                                                    fontSize: 10,
                                                    color:
                                                        const Color(0xFF404040),
                                                  ),
                                                )
                                              : Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: groupedByLayout
                                                      .entries
                                                      .toList()
                                                      .asMap()
                                                      .entries
                                                      .expand((layoutEntry) {
                                                    final index =
                                                        layoutEntry.key;
                                                    final entry =
                                                        layoutEntry.value;
                                                    return [
                                                      Text(
                                                        'Layout: ${entry.key}',
                                                        style: GoogleFonts
                                                            .inriaSerif(
                                                          fontSize: 10,
                                                          color: const Color(
                                                              0xFF404040),
                                                        ),
                                                      ),
                                                      const SizedBox(height: 4),
                                                      Wrap(
                                                        spacing: 4,
                                                        runSpacing: 4,
                                                        children: entry.value
                                                            .map(
                                                              (plotNo) =>
                                                                  Container(
                                                                padding: const EdgeInsets
                                                                    .symmetric(
                                                                    horizontal:
                                                                        2,
                                                                    vertical:
                                                                        1),
                                                                decoration:
                                                                    BoxDecoration(
                                                                  color: const Color(
                                                                      0xFFCFCFCF),
                                                                  borderRadius:
                                                                      BorderRadius
                                                                          .circular(
                                                                              2),
                                                                ),
                                                                child: Text(
                                                                  plotNo,
                                                                  style: GoogleFonts
                                                                      .inriaSerif(
                                                                    fontSize:
                                                                        10,
                                                                    color: const Color(
                                                                        0xFF404040),
                                                                  ),
                                                                ),
                                                              ),
                                                            )
                                                            .toList(),
                                                      ),
                                                      if (index !=
                                                          groupedByLayout
                                                                  .length -
                                                              1)
                                                        const SizedBox(
                                                            height: 8),
                                                    ];
                                                  }).toList(),
                                                ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }

                              if (showTotals) {
                                rows.add(
                                  Container(
                                    color: Colors.grey.withOpacity(0.25),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 4,
                                    ),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 143,
                                          child: Text(
                                            'Total',
                                            style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.black,
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: 96,
                                          child: Align(
                                            alignment: Alignment.center,
                                            child: Text(
                                              '$grandTotalAssigned',
                                              style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color: const Color(0xFF404040),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 32),
                                        const Expanded(
                                            child: SizedBox(height: 12)),
                                      ],
                                    ),
                                  ),
                                );
                              }

                              return rows;
                            })(),
                          ],
                        ),
                      ),
                    ),
                  ],

                  const Spacer(),
                ],
              ),
            ),
          ),

          // Footer
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  Widget _buildTableCell(String text, double width,
      {bool isHeader = false,
      bool keepOriginalWidth = false,
      bool singleLine = false,
      double? fontSize}) {
    final effectiveWidth =
        keepOriginalWidth ? width : math.max(10.0, width - 10.0);
    return Container(
      width: effectiveWidth,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        border: Border(
            right: BorderSide(
                color: isHeader ? Colors.white : Colors.black.withOpacity(0.2),
                width: isHeader ? 0.2 : 0.25)),
      ),
      child: Text(
        text,
        style: GoogleFonts.inriaSerif(
          fontSize: fontSize ?? 9,
          fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
          color: isHeader ? Colors.white : const Color(0xFF404040),
        ),
        maxLines: singleLine ? 1 : 2,
        softWrap: !singleLine,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
