import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/project_storage_service.dart';
import '../services/area_unit_service.dart';
import '../utils/area_unit_utils.dart';
import '../utils/web_print.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math' as math;
import '../widgets/app_scale_metrics.dart';

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

  const ReportPage(
      {super.key, this.projectData, this.projectId, this.dashboardData});

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

      final plots = _projectData['plots'] as List<dynamic>? ?? [];
      final allInCost =
          double.tryParse((_projectData['allInCost'] ?? '0').toString()) ?? 0.0;

      if (isLumpSum) {
        double totalGrossProfit = 0.0;
        for (var plot in plots) {
          final status = (plot['status'] ?? '').toString().toLowerCase();
          if (status == 'sold') {
            final salePrice = _toDouble(
              plot['sale_price'] ??
                  plot['salePrice'] ??
                  plot['salePricePerSqft'],
            );
            final area = _toDouble(
                plot['area'] ?? plot['plotArea'] ?? plot['plot_area']);
            final saleValue = salePrice * area;
            final plotCost = area * allInCost;
            totalGrossProfit += (saleValue - plotCost);
          }
        }
        final totalAgentCompensation = _calculateTotalAgentCompensationReport();
        final remainingAfterAgent = totalGrossProfit - totalAgentCompensation;
        return (remainingAfterAgent * percentage) / 100;
      }

      double totalEarnings = 0.0;
      final isSellingPriceBased = earningType == 'Selling Price Per Plot' ||
          earningType == '% of Selling Price per Plot' ||
          (lowerEarning.contains('selling price') &&
              lowerEarning.contains('plot'));

      for (var plot in plots) {
        final status = (plot['status'] ?? '').toString().toLowerCase();
        if (status == 'sold') {
          final salePrice = _toDouble(
            plot['sale_price'] ?? plot['salePrice'] ?? plot['salePricePerSqft'],
          );
          final area =
              _toDouble(plot['area'] ?? plot['plotArea'] ?? plot['plot_area']);
          final saleValue = salePrice * area;
          final agentCompOnPlot =
              _calculateAgentCompensationForPlotReport(plot);

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
      }

      return totalEarnings;
    }

    return 0.0;
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

  // 8th page: Project Manager(s) Details (Figma design)
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
    final managers = managersRaw
        .map((m) => {
              'name': m['name'] ?? '-',
              'compensationType': m['compensation_type'] ?? '-',
              'earningType':
                  (m['compensation_type'] ?? '') == 'Percentage Bonus'
                      ? _formatProjectManagerEarningTypeReport(
                          (m['earning_type'] ?? '-').toString(),
                          (m['percentage'] as num?)?.toDouble() ?? 0.0,
                        )
                      : 'NA',
              'earningsValue': _calculateProjectManagerEarningsReport(
                  m as Map<String, dynamic>),
              'earnings':
                  '₹ ${_formatTo2Decimals(_calculateProjectManagerEarningsReport(m as Map<String, dynamic>))}',
            })
        .toList();
    final visibleManagers = managerLimit == null
        ? managers
        : managers
            .skip(managerStartIndex)
            .take(managerLimit)
            .toList(growable: false);
    final totalEarnings = managers.fold<double>(
        0.0, (sum, m) => sum + (m['earningsValue'] as double));

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header (same as page 5)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
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
                  ? '4. Project Manager(s) Details (Cont.)'
                  : '4. Project Manager(s) Details',
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
              '4.1  Project Manager(s) Earnings',
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
          const SizedBox(height: 12),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  bool _agentHasSoldPlotReport(String agentName) {
    final normalized = agentName.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    final plots = _projectData['plots'] as List<dynamic>? ?? [];
    for (final raw in plots) {
      final plot =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      final status = (plot['status'] ?? '').toString().toLowerCase();
      final plotAgent = (plot['agent_name'] ?? plot['agent'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (status == 'sold' && plotAgent == normalized) return true;
    }
    return false;
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

  String _buildAgentEarningTypeDisplayReport(Map<String, dynamic> agent) {
    final compensationType = (agent['compensation_type'] ?? '').toString();
    final earningType = (agent['earning_type'] ?? '').toString();
    final percentage = (agent['percentage'] as num?)?.toDouble() ?? 0.0;
    final fixedFee = (agent['fixed_fee'] as num?)?.toDouble() ?? 0.0;
    final monthlyFee = (agent['monthly_fee'] as num?)?.toDouble() ?? 0.0;
    final months = (agent['months'] as num?)?.toInt() ?? 0;
    final perSqftFee = (agent['per_sqft_fee'] as num?)?.toDouble() ?? 0.0;

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
    final compensationType = (agent['compensation_type'] ?? '').toString();
    final earningType = (agent['earning_type'] ?? '').toString();
    final agentName = (agent['name'] ?? '').toString().trim();

    if (!_agentHasSoldPlotReport(agentName)) return 0.0;

    if (compensationType == 'Fixed Fee') {
      return (agent['fixed_fee'] as num?)?.toDouble() ?? 0.0;
    }
    if (compensationType == 'Monthly Fee') {
      final monthlyFee = (agent['monthly_fee'] as num?)?.toDouble() ?? 0.0;
      final months = (agent['months'] as num?)?.toInt() ?? 0;
      return monthlyFee * months;
    }
    if (compensationType == 'Per Sqft Fee' ||
        compensationType == 'Per Sqm Fee' ||
        compensationType == 'Per sqft rate') {
      final perSqftFee = (agent['per_sqft_fee'] as num?)?.toDouble() ?? 0.0;
      double totalSoldArea = 0.0;
      final plots = _projectData['plots'] as List<dynamic>? ?? [];
      for (final raw in plots) {
        final plot =
            raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        final status = (plot['status'] ?? '').toString().toLowerCase();
        final plotAgent =
            (plot['agent_name'] ?? plot['agent'] ?? '').toString().trim();
        if (status == 'sold' && plotAgent == agentName) {
          totalSoldArea +=
              _toDouble(plot['area'] ?? plot['plotArea'] ?? plot['plot_area']);
        }
      }
      return perSqftFee * totalSoldArea;
    }
    if (compensationType == 'Percentage Bonus') {
      final percentage = (agent['percentage'] as num?)?.toDouble() ?? 0.0;
      final lowerEarningType = earningType.toLowerCase();
      final isSellingPriceBased = earningType == 'Selling Price Per Plot' ||
          earningType == '% of Selling Price per Plot' ||
          (lowerEarningType.contains('selling price') &&
              lowerEarningType.contains('plot'));
      final isLumpSum = earningType == 'Lump Sum' ||
          earningType == '% of Total Project Profit' ||
          (lowerEarningType.contains('total project profit') ||
              lowerEarningType.contains('lump'));
      final plots = _projectData['plots'] as List<dynamic>? ?? [];
      final allInCost =
          double.tryParse((_projectData['allInCost'] ?? '0').toString()) ?? 0.0;

      if (isLumpSum) {
        double totalGrossProfit = 0.0;
        for (final raw in plots) {
          final plot =
              raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
          final status = (plot['status'] ?? '').toString().toLowerCase();
          if (status == 'sold') {
            final salePrice = _toDouble(
              plot['sale_price'] ??
                  plot['salePrice'] ??
                  plot['salePricePerSqft'],
            );
            final area = _toDouble(
                plot['area'] ?? plot['plotArea'] ?? plot['plot_area']);
            final saleValue = salePrice * area;
            final plotCost = area * allInCost;
            totalGrossProfit += (saleValue - plotCost);
          }
        }
        return (totalGrossProfit * percentage) / 100;
      }

      double total = 0.0;
      for (final raw in plots) {
        final plot =
            raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        final status = (plot['status'] ?? '').toString().toLowerCase();
        final plotAgent =
            (plot['agent_name'] ?? plot['agent'] ?? '').toString().trim();
        if (status == 'sold' && plotAgent == agentName) {
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
      return total;
    }
    return 0.0;
  }

  double? _calculateAgentPlotEarningsReport(
      Map<String, dynamic> plot, Map<String, dynamic>? agent) {
    if (agent == null) return null;
    final status = (plot['status'] ?? '').toString().toLowerCase();
    if (status != 'sold') return null;
    final compensationType = (agent['compensation_type'] ?? '').toString();
    final earningType = (agent['earning_type'] ?? '').toString();
    final salePrice = _toDouble(
      plot['sale_price'] ?? plot['salePrice'] ?? plot['salePricePerSqft'],
    );
    final area =
        _toDouble(plot['area'] ?? plot['plotArea'] ?? plot['plot_area']);
    final saleValue = salePrice * area;

    if (compensationType == 'Per Sqft Fee' ||
        compensationType == 'Per Sqm Fee' ||
        compensationType == 'Per sqft rate') {
      final perSqftFee = (agent['per_sqft_fee'] as num?)?.toDouble() ?? 0.0;
      return perSqftFee * area;
    }
    if (compensationType == 'Percentage Bonus') {
      final percentage = (agent['percentage'] as num?)?.toDouble() ?? 0.0;
      final lowerEarningType = earningType.toLowerCase();
      final isSellingPriceBased = earningType == 'Selling Price Per Plot' ||
          earningType == '% of Selling Price per Plot' ||
          (lowerEarningType.contains('selling price') &&
              lowerEarningType.contains('plot'));
      if (isSellingPriceBased) return (saleValue * percentage) / 100;
      final allInCost =
          double.tryParse((_projectData['allInCost'] ?? '0').toString()) ?? 0.0;
      final plotCost = area * allInCost;
      final plotProfit = saleValue - plotCost;
      return (plotProfit * percentage) / 100;
    }
    return null;
  }

  double _calculateTotalAgentCompensationReport() {
    final agentsRaw = (_projectData['agents'] ?? _projectData['agentDetails'])
            as List<dynamic>? ??
        [];
    double total = 0.0;
    for (final raw in agentsRaw) {
      final agent =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      total += _calculateAgentEarningsReport(agent);
    }
    return total;
  }

  double _calculateAgentCompensationForPlotReport(Map<String, dynamic> plot) {
    final plotAgentName = (plot['agent_name'] ?? plot['agent'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (plotAgentName.isEmpty) return 0.0;

    final agentsRaw = (_projectData['agents'] ?? _projectData['agentDetails'])
            as List<dynamic>? ??
        [];
    for (final raw in agentsRaw) {
      final agent =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      final agentName = (agent['name'] ?? '').toString().trim().toLowerCase();
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
    final agentsRaw = (_projectData['agents'] ?? _projectData['agentDetails'])
            as List<dynamic>? ??
        [];
    final agents = agentsRaw
        .map((a) =>
            a is Map ? Map<String, dynamic>.from(a) : <String, dynamic>{})
        .toList();
    final agentsWithEarnings = agents
        .map((agent) => {
              'name': (agent['name'] ?? '-').toString(),
              'compensationType':
                  (agent['compensation_type'] ?? '-').toString(),
              'earningType': _buildAgentEarningTypeDisplayReport(agent),
              'earningsValue': _calculateAgentEarningsReport(agent),
            })
        .toList();
    final totalAgentEarnings = agentsWithEarnings.fold<double>(
      0.0,
      (sum, a) => sum + ((a['earningsValue'] as num?)?.toDouble() ?? 0.0),
    );

    final agentsByName = <String, Map<String, dynamic>>{};
    for (final agent in agents) {
      final key = (agent['name'] ?? '').toString().trim().toLowerCase();
      if (key.isNotEmpty) agentsByName[key] = agent;
    }
    final layoutBlocks =
        layoutBlocksOverride ?? _buildReportPage9LayoutBlocks();

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                  ? '5. Agent(s) Details (Cont.)'
                  : '5. Agent(s) Details',
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
                '5.1  Agent(s) Earnings',
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
              '5.2 Agent - Plot Distribution & Earnings',
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
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '-',
                style: GoogleFonts.inriaSerif(
                  fontSize: 10,
                  color: const Color(0xFF404040),
                ),
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
                          final status =
                              (plot['status'] ?? '').toString().toLowerCase();
                          final plotNumber = _plotFieldStr(plot, [
                            'plotNumber',
                            'plot_no',
                            'plotNo',
                            'number',
                            'plot_number'
                          ]);
                          final area =
                              (plot['area'] as num?)?.toDouble() ?? 0.0;
                          final salePrice =
                              (plot['sale_price'] as num?)?.toDouble() ?? 0.0;
                          final saleValue =
                              status == 'sold' ? area * salePrice : 0.0;
                          final plotAgentName = _plotFieldStr(
                              plot, ['agent_name', 'agent', 'agentName']);
                          final normalizedAgent =
                              plotAgentName.trim().toLowerCase();
                          final matchedAgent = agentsByName[normalizedAgent];
                          final rowEarnings = _calculateAgentPlotEarningsReport(
                              plot, matchedAgent);
                          final saleDate = _plotFieldStr(plot,
                              ['dateOfSale', 'date_of_sale', 'sale_date']);
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
                                      plotAgentName == '-'
                                          ? (status == 'sold'
                                              ? 'Direct Sale'
                                              : '-')
                                          : plotAgentName,
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
                                    saleDate == '-' ? '-' : saleDate,
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
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              '6. Expense Details',
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
                        '6.1  Expense Categories Summary',
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
                        '6.2  Expense Breakdown',
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: const Color(0xFF858585).withOpacity(0.8),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SvgPicture.asset(
                      'assets/images/8answers.svg',
                      width: 82,
                      height: 16,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '8answers.com',
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF0C8CE9),
                      ),
                    ),
                  ],
                ),
                Text(
                  '8',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0C8CE9),
                  ),
                ),
              ],
            ),
          ),
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
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: const Color(0xFF858585).withOpacity(0.8),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SvgPicture.asset(
                      'assets/images/8answers.svg',
                      width: 82,
                      height: 16,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '8answers.com',
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF0C8CE9),
                      ),
                    ),
                  ],
                ),
                Text(
                  '9',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0C8CE9),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  double _estimateExpenseBreakdownBlockHeightReport(int rowCount) {
    return 52.0 + (rowCount * 20.0);
  }

  List<Map<String, dynamic>> _buildExpenseBreakdownBlocksReport(
    Map<String, List<Map<String, dynamic>>> grouped,
  ) {
    const rowsPerBlock = 4;
    final blocks = <Map<String, dynamic>>[];
    for (final category in grouped.keys) {
      final rows = grouped[category] ?? const <Map<String, dynamic>>[];
      for (int i = 0; i < rows.length; i += rowsPerBlock) {
        final end = math.min(i + rowsPerBlock, rows.length);
        blocks.add({
          'category': category,
          'rows': rows.sublist(i, end),
          'showBullet': i == 0,
        });
      }
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
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                '6. Expense Details',
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
                      '6.1  Expense Categories Summary',
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
                      '6.2  Expense Breakdown',
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: const Color(0xFF858585).withOpacity(0.8),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SvgPicture.asset(
                      'assets/images/8answers.svg',
                      width: 82,
                      height: 16,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '8answers.com',
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF0C8CE9),
                      ),
                    ),
                  ],
                ),
                Text(
                  '$pageNumber',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0C8CE9),
                  ),
                ),
              ],
            ),
          ),
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
    var isFirstPage = true;

    for (final block in breakdownBlocks) {
      final rows = block['rows'] as List<Map<String, dynamic>>;
      final cost = _estimateExpenseBreakdownBlockHeightReport(rows.length);
      if (current.isNotEmpty && cost > remaining) {
        pagesBlocks.add(current);
        current = <Map<String, dynamic>>[];
        isFirstPage = false;
        remaining = nextPageCapacity;
      }
      current.add(block);
      remaining -= cost;
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
    final projectName =
        _projectData['projectName'] ?? _projectData['name'] ?? 'Project Name';
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
              '7. Formulas',
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
                        'Total Expenses', 'Approved Selling Area'),
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
                    _buildFormulaFractionReport(
                        'Net Profit', 'Total Sales Value'),
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: const Color(0xFF858585).withOpacity(0.8),
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SvgPicture.asset(
                      'assets/images/8answers.svg',
                      width: 82,
                      height: 16,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '8answers.com',
                      style: GoogleFonts.inriaSerif(
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF0C8CE9),
                      ),
                    ),
                  ],
                ),
                Text(
                  '$pageNumber',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0C8CE9),
                  ),
                ),
              ],
            ),
          ),
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
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
  String get _reportHeaderUnitText => '*Unit: $_areaUnitSuffix*';
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

  String _formatRateWithUnit(dynamic ratePerSqft) {
    final formatted = _formatTo2Decimals(_displayRateFromSqft(ratePerSqft));
    return formatted == '—' ? '—' : '₹/$_areaUnitSuffix $formatted';
  }

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
  final List<GlobalKey> _reportPagePrintKeys = <GlobalKey>[];
  final ScrollController _thumbnailScrollController = ScrollController();
  final ScrollController _mainPreviewScrollController = ScrollController();
  bool _isSyncingPreviewScroll = false;
  bool _isPrintingReport = false;
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
    _mainPreviewScrollController.addListener(_syncMainToThumbnails);
    _loadProjectData();
    _loadReportIdentitySettings();
  }

  @override
  void dispose() {
    _mainPreviewScrollController.removeListener(_syncMainToThumbnails);
    _mainPreviewScrollController.dispose();
    _thumbnailScrollController.dispose();
    super.dispose();
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
    final computedPage = ((_mainPreviewScrollController.offset +
                    (_reportPreviewPageExtent / 2)) /
                _reportPreviewPageExtent)
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
    final targetOffset =
        ((safePage - 1) * _reportPreviewPageExtent).clamp(0.0, maxOffset);

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

  Future<void> _loadProjectData() async {
    try {
      _areaUnit = await AreaUnitService.getAreaUnit(widget.projectId);

      // Load dashboard data if provided or from SharedPreferences
      if (widget.dashboardData != null) {
        print('DEBUG: Loading dashboard data from widget parameter');
        setState(() => _dashboardDataLocal = widget.dashboardData);
      } else if (widget.projectId != null) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final dashboardJson =
              prefs.getString('dashboard_data_${widget.projectId}');
          print('DEBUG: Dashboard JSON from SharedPreferences: $dashboardJson');
          if (dashboardJson != null) {
            _dashboardDataLocal = jsonDecode(dashboardJson);
            print('DEBUG: Loaded dashboard data: $_dashboardDataLocal');
            setState(() {});
          } else {
            print(
                'DEBUG: No dashboard data found in SharedPreferences for key: dashboard_data_${widget.projectId}');
          }
        } catch (e) {
          print('Warning: Could not load dashboard data: $e');
        }
      }

      if (widget.projectData != null) {
        setState(() => _projectData = widget.projectData!);
        _buildLayoutIdNameMap();
      } else if (widget.projectId != null) {
        // Try to fetch from Supabase first
        final supabaseData =
            await ProjectStorageService.fetchProjectDataById(widget.projectId!);
        if (supabaseData != null) {
          setState(() => _projectData = supabaseData);
          _buildLayoutIdNameMap();
        } else {
          // fallback to SharedPreferences if Supabase fetch fails
          final prefs = await SharedPreferences.getInstance();
          final projectJson =
              prefs.getString('project_data_${widget.projectId}');
          if (projectJson != null) {
            setState(() => _projectData = jsonDecode(projectJson));
            _buildLayoutIdNameMap();
          } else {
            // fallback to current_project_data for backward compatibility
            final fallbackJson = prefs.getString('current_project_data');
            if (fallbackJson != null) {
              setState(() => _projectData = jsonDecode(fallbackJson));
              _buildLayoutIdNameMap();
            }
          }
        }
      } else {
        final prefs = await SharedPreferences.getInstance();
        final projectJson = prefs.getString('current_project_data');
        if (projectJson != null) {
          setState(() => _projectData = jsonDecode(projectJson));
          _buildLayoutIdNameMap();
        }
      }
    } catch (e) {
      print('Error loading project data: $e');
    }
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
    return _readStringFromMap(_projectData, [
      'projectName',
      'project_name',
      'name',
      'project',
    ]);
  }

  String _reportCoverProjectLocation() {
    return _readStringFromMap(_projectData, [
      'projectAddress',
      'project_address',
      'projectLocation',
      'location',
      'address',
      'google_maps_link',
      'googleMapsLink',
    ]);
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
    print('DEBUG projectData keys: ${_projectData.keys}');
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
        print('DEBUG found layout list at key: $key -> ${_projectData[key]}');
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
              print('DEBUG map add: ${id.toString()} -> ${name.toString()}');
            }
            if ((idx != null) && name != null) {
              _layoutIdNameMap[idx.toString()] = name.toString();
              print(
                  'DEBUG map add idx: ${idx.toString()} -> ${name.toString()}');
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
    print('DEBUG layoutIdNameMap: $_layoutIdNameMap');
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
                final headingSection = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Report',
                      style: GoogleFonts.inter(
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
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
                );

                return headingSection;
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Select Panel - fixed width 344px
                  SizedBox(
                    width: 344,
                    child: _buildSelectPanel(),
                  ),
                  const SizedBox(width: 16),
                  // Preview Panel - fills remaining space
                  Expanded(
                    child: _buildPreviewPanel(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
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
          const SizedBox(height: 16),
          _buildProjectAreaUnitPanel(),
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
                          onTap: () {},
                          child: SvgPicture.asset(
                            'assets/icons/zoom_out.svg',
                            width: 40,
                            height: 40,
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Zoom percentage
                        Text(
                          '100%',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.normal,
                            color: Colors.black.withOpacity(0.75),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Zoom in button
                        GestureDetector(
                          onTap: () {},
                          child: SvgPicture.asset(
                            'assets/icons/zoom_in.svg',
                            width: 40,
                            height: 40,
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

  // Get or calculate dashboard values
  // If dashboard data available, use it directly
  // If not, use pre-calculated values from project data
  String getDashboardValue(String key, [dynamic defaultValue]) {
    // First try dashboard data
    if (_dashboardDataLocal != null && _dashboardDataLocal!.isNotEmpty) {
      final value = _dashboardDataLocal![key];
      if (value != null) {
        print('✓ getDashboardValue: Using DASHBOARD DATA for $key = $value');
        // Format all numeric values to 2 decimal places
        return _formatTo2Decimals(value);
      }
    }

    // Fallback: Use pre-calculated values from project data (ProjectStorageService calculates these)
    print(
        '✓ getDashboardValue: Using PROJECT DATA (pre-calculated by ProjectStorageService) for $key');

    switch (key) {
      case 'profitMargin':
      case 'roi':
      case 'grossProfit':
      case 'netProfit':
      case 'totalSalesValue':
      case 'totalCompensation':
      case 'totalAgentCompensation':
      case 'totalProjectManagerCompensation':
        // These are already calculated by ProjectStorageService
        final value = _projectData[key] ?? defaultValue;
        return _formatTo2Decimals(value);

      case 'avgSalePricePerSqft':
        final value = _projectData['avgSalePricePerSqft'] ??
            _projectData['avgSalesPrice'] ??
            defaultValue;
        return _formatTo2Decimals(value);

      default:
        return _formatTo2Decimals(_projectData[key] ?? defaultValue);
    }
  }

  List<Widget> _buildReportPage7Pages({required int startPageNumber}) {
    final allPlots = _projectData['plots'] as List<dynamic>? ?? [];
    final partnersRaw = _projectData['partners'] as List<dynamic>? ?? [];
    final partners = partnersRaw
        .map((p) =>
            p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{})
        .toList();

    if (partners.isEmpty) {
      final names = <String>{};
      for (final raw in allPlots) {
        final plot =
            raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        final name = _plotFieldStr(plot, [
          'partner',
          'partnerName',
          'partner_name',
          'partnersName',
          'partners_name'
        ]);
        if (name.isNotEmpty && name != '-') names.add(name);
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
    for (final raw in allPlots) {
      final plot =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      final id = (plot['id'] ?? '').toString();
      final number = _plotFieldStr(
          plot, ['plotNumber', 'plot_no', 'plotNo', 'number', 'plot_number']);
      final layout = _resolveLayoutLabel(plot);
      if (id.isNotEmpty && number.isNotEmpty && number != '-') {
        plotIdToNumber[id] = number;
      }
      if (id.isNotEmpty) {
        plotIdToLayout[id] = layout;
      }
    }

    final assignedCountByPartner = <String, int>{};
    final plotPartnersRaw =
        _projectData['plot_partners'] as List<dynamic>? ?? const [];
    for (final raw in plotPartnersRaw) {
      if (raw is! Map) continue;
      final assignment = Map<String, dynamic>.from(raw);
      final partner =
          (assignment['partner_name'] ?? '').toString().trim().toLowerCase();
      final plotId = (assignment['plot_id'] ?? '').toString().trim();
      final number = plotIdToNumber[plotId];
      if (partner.isEmpty || number == null || number.isEmpty) continue;
      assignedCountByPartner.update(partner, (v) => v + 1, ifAbsent: () => 1);
    }

    if (assignedCountByPartner.isEmpty) {
      for (final raw in allPlots) {
        final plot =
            raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        final partner = _plotFieldStr(plot, [
          'partner',
          'partnerName',
          'partner_name',
          'partnersName',
          'partners_name'
        ]).toLowerCase();
        if (partner.isEmpty || partner == '-') continue;
        final number = _plotFieldStr(
            plot, ['plotNumber', 'plot_no', 'plotNo', 'number', 'plot_number']);
        if (number.isEmpty || number == '-') continue;
        assignedCountByPartner.update(partner, (v) => v + 1, ifAbsent: () => 1);
      }
    }

    final partnerLayoutPlotCounts = <String, Map<String, int>>{};
    for (final raw in plotPartnersRaw) {
      if (raw is! Map) continue;
      final assignment = Map<String, dynamic>.from(raw);
      final partner =
          (assignment['partner_name'] ?? '').toString().trim().toLowerCase();
      final plotId = (assignment['plot_id'] ?? '').toString().trim();
      if (partner.isEmpty || plotId.isEmpty) continue;
      final layout = (plotIdToLayout[plotId] ?? 'Unknown').trim();
      partnerLayoutPlotCounts.putIfAbsent(partner, () => <String, int>{});
      partnerLayoutPlotCounts[partner]!
          .update(layout, (v) => v + 1, ifAbsent: () => 1);
    }

    if (partnerLayoutPlotCounts.isEmpty) {
      for (final raw in allPlots) {
        final plot =
            raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        final partner = _plotFieldStr(plot, [
          'partner',
          'partnerName',
          'partner_name',
          'partnersName',
          'partners_name'
        ]).toLowerCase();
        if (partner.isEmpty || partner == '-') continue;
        final layout = _resolveLayoutLabel(plot);
        partnerLayoutPlotCounts.putIfAbsent(partner, () => <String, int>{});
        partnerLayoutPlotCounts[partner]!
            .update(layout, (v) => v + 1, ifAbsent: () => 1);
      }
    }

    int _estimateWrapLinesForPlotCount(int count) {
      if (count <= 0) return 1;
      // Balanced estimate to avoid unnecessary row pushes while still
      // protecting against overflow.
      const chipsPerLine = 8;
      return math.max(1, (count / chipsPerLine).ceil());
    }

    double _estimatePartnerDistributionRowCost(String partnerNameNorm) {
      final assignedCount = assignedCountByPartner[partnerNameNorm] ?? 0;
      final layoutCounts =
          partnerLayoutPlotCounts[partnerNameNorm] ?? const <String, int>{};
      final layoutGroups = math.max(1, layoutCounts.length);
      int wrapLines = 0;
      if (layoutCounts.isEmpty) {
        wrapLines = _estimateWrapLinesForPlotCount(assignedCount);
      } else {
        for (final count in layoutCounts.values) {
          wrapLines += _estimateWrapLinesForPlotCount(count);
        }
      }

      // 3.2 partner distribution row cost only (3.1 table stays on first page).
      // Keep moderately conservative: only move rows that are likely to overflow.
      return 1.15 + (layoutGroups * 0.50) + (wrapLines * 0.75);
    }

    final chunks = <Map<String, int>>[];
    const firstPageCapacity = 18.0;
    const nextPageCapacity = 26.0;
    final firstPageBaseCost = 6.8 + (partners.length * 0.85);
    const nextPageBaseCost = 4.2;
    const totalsRowCost = 1.5;
    var start = 0;
    var remaining = firstPageCapacity - firstPageBaseCost;
    var isFirstPage = true;

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
        final rowCost = _estimatePartnerDistributionRowCost(name);
        final isLastPartner = i == partners.length - 1;
        final effectiveRowCost =
            rowCost + (isLastPartner ? totalsRowCost : 0.0);
        if (count > 0 && effectiveRowCost > localRemaining) break;
        if (effectiveRowCost > localRemaining && count == 0) {
          if (!isFirstPage) {
            // On continuation pages, ensure forward progress even for a very
            // large single row.
            count = 1;
          }
          break;
        }
        count++;
        localRemaining -= rowCost;
        if (isLastPartner) {
          localRemaining -= totalsRowCost;
        }
      }

      if (count <= 0) {
        // If first page has no room for even one distribution row, keep it as
        // a summary-only page and start rows from next page.
        if (isFirstPage) {
          chunks.add({'start': start, 'count': 0});
          isFirstPage = false;
          remaining = nextPageCapacity - nextPageBaseCost;
          continue;
        }
        // Non-first page with a very large single row: place at least one row.
        count = 1;
      }

      chunks.add({'start': start, 'count': count});
      start += count;
      if (isFirstPage) {
        isFirstPage = false;
        remaining = nextPageCapacity - nextPageBaseCost;
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
    final allPlotsRaw = _projectData['plots'] as List<dynamic>? ?? const [];
    final layoutPlots = <String, List<Map<String, dynamic>>>{};
    for (final raw in allPlotsRaw) {
      final plot =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
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
    final hasPendingPlots = _hasPendingPlotsForReport();
    final hasAmenityArea = _hasAmenityAreaForReport();
    final layoutWiseStartPage = hasPendingPlots ? 4 : 3;
    final layoutWisePages =
        _buildReportPage5Pages(startPageNumber: layoutWiseStartPage);
    final page6Number = layoutWiseStartPage + layoutWisePages.length;
    final page6Pages = _buildReportPage6Pages(startPageNumber: page6Number);
    final amenitySalesStartPage = page6Number + page6Pages.length;
    final amenitySalesPages = hasAmenityArea
        ? _buildReportPageAmenitySalesPages(
            startPageNumber: amenitySalesStartPage)
        : <Widget>[];
    final amenityAfterSalesStartPage =
        amenitySalesStartPage + amenitySalesPages.length;
    final amenityAfterSalesPages = hasAmenityArea
        ? _buildReportPageAmenityAfterSalesPages(
            startPageNumber: amenityAfterSalesStartPage)
        : <Widget>[];
    final page7Number =
        amenityAfterSalesStartPage + amenityAfterSalesPages.length;
    final partnerPages = _buildReportPage7Pages(startPageNumber: page7Number);
    final page8Number = page7Number + partnerPages.length;
    final managerPages = _buildReportPage8Pages(startPageNumber: page8Number);
    final page9Number = page8Number + managerPages.length;
    final agentPages = _buildReportPage9Pages(startPageNumber: page9Number);
    final pages = <Widget>[
      _buildReportPage1(),
      _buildReportPage2(),
      _buildReportPage3(),
      if (hasPendingPlots) _buildPendingCompensationReportPage(pageNumber: 2),
      _buildReportPage4(pageNumber: hasPendingPlots ? 3 : 2),
      ...layoutWisePages,
      ...page6Pages,
      ...amenitySalesPages,
      ...amenityAfterSalesPages,
      ...partnerPages,
      ...managerPages,
      ...agentPages,
    ];
    final expenseStartPage = pages.length + 1;
    final expensePages =
        _buildExpenseDetailsPages(startPageNumber: expenseStartPage);
    pages.addAll(expensePages);
    final formulasPageNumber = expenseStartPage + expensePages.length;
    pages.add(_buildReportPageFormulas(pageNumber: formulasPageNumber));
    final compensationBonusCalcPageNumber = formulasPageNumber + 1;
    final compensationBonusSellingPricePageNumber =
        compensationBonusCalcPageNumber + 1;
    pages.add(
      _buildReportPageCompensationBonusCalculations(
          pageNumber: compensationBonusCalcPageNumber),
    );
    pages.add(
      _buildReportPageCompensationSellingPriceCalculations(
          pageNumber: compensationBonusSellingPricePageNumber),
    );
    pages.add(
      _buildReportPageCompensationSellingPriceCaseC(
          pageNumber: compensationBonusSellingPricePageNumber + 1),
    );
    return pages;
  }

  Widget _buildPaginatedReportPreview() {
    final pages = _buildAllReportPagesForPreview();
    _ensureReportPagePrintKeys(pages.length);
    return Column(
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
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
                      const SizedBox(height: 24),
                      SizedBox(
                        width: 100,
                        height: 50,
                        child: ClipRect(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: 100,
                              height: 50,
                              child: _buildCoverLogo(
                                width: 100,
                                height: 50,
                                fit: BoxFit.contain,
                                alignment: Alignment.centerLeft,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                    ] else
                      const SizedBox(height: 72),
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
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 16,
                  ),
                  color: const Color(0x0A404040),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 1,
                        color: const Color(0xFF0C8CE9),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: _buildCoverDotPattern(
                              rows: 3,
                              columns: 16,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '8Answers',
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: const Color(0xFF0C8CE9),
                                ),
                              ),
                              Text(
                                'Generated using 8Answers\nwww.8answers.com',
                                textAlign: TextAlign.right,
                                style: GoogleFonts.inriaSerif(
                                  fontSize: 7,
                                  fontWeight: FontWeight.w400,
                                  color: const Color(0xFF0C8CE9),
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ],
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
  }

  Widget _buildReportPage2() {
    final hasPendingPlots = _hasPendingPlotsForReport();
    final hasAmenityArea = _hasAmenityAreaForReport();
    final pageLayoutWiseSalesStart = hasPendingPlots ? 4 : 3;
    final layoutWisePagesCount =
        _buildReportPage5Pages(startPageNumber: pageLayoutWiseSalesStart)
            .length;
    final pageLayoutWiseAfterSales =
        pageLayoutWiseSalesStart + layoutWisePagesCount;
    final layoutWiseAfterSalesPagesCount =
        _buildReportPage6Pages(startPageNumber: pageLayoutWiseAfterSales)
            .length;
    final pageAmenitySales =
        pageLayoutWiseAfterSales + layoutWiseAfterSalesPagesCount;
    final amenitySalesPagesCount = hasAmenityArea
        ? _buildReportPageAmenitySalesPages(startPageNumber: pageAmenitySales)
            .length
        : 0;
    final pageAmenityAfterSales = pageAmenitySales + amenitySalesPagesCount;
    final amenityAfterSalesPagesCount = hasAmenityArea
        ? _buildReportPageAmenityAfterSalesPages(
                startPageNumber: pageAmenityAfterSales)
            .length
        : 0;
    final pagePartnerDetails =
        pageAmenityAfterSales + amenityAfterSalesPagesCount;
    final partnerPagesCount =
        _buildReportPage7Pages(startPageNumber: pagePartnerDetails).length;
    final pageProjectManagers = pagePartnerDetails + partnerPagesCount;
    final managerPagesCount =
        _buildReportPage8Pages(startPageNumber: pageProjectManagers).length;
    final pageAgents = pageProjectManagers + managerPagesCount;
    final agentPagesCount =
        _buildReportPage9Pages(startPageNumber: pageAgents).length;
    final expenseStartPage = pageAgents + agentPagesCount;
    final expensePages =
        _buildExpenseDetailsPages(startPageNumber: expenseStartPage);
    final hasExpenseDetails = expensePages.isNotEmpty;
    final formulasPage = expenseStartPage + expensePages.length;
    final compensationBonusCalcPage = formulasPage + 1;
    final compensationBonusSellingPricePage = compensationBonusCalcPage + 1;
    final compensationBonusSellingPriceCaseCPage =
        compensationBonusSellingPricePage + 1;

    // Table of Contents data structure (page numbers aligned with generated content)
    final tocItems = [
      {
        'number': '1.',
        'title': 'Project Overview',
        'page': '1',
        'subitems': [
          {'number': '1.1', 'title': 'Project Cost & Area', 'page': '1'},
          {'number': '1.2', 'title': 'Site Overview', 'page': '1'},
          {'number': '1.3', 'title': 'Profit and ROI', 'page': '1'},
          {'number': '1.4', 'title': 'Sales Highlights', 'page': '1'},
          {'number': '1.5', 'title': 'Compensation', 'page': '1'},
        ],
      },
      {
        'number': '2.',
        'title': 'Sales Summary',
        'page': '2',
        'subitems': [
          {'number': '2.1', 'title': 'Financial Summary', 'page': '2'},
          {'number': '2.2', 'title': 'Sales Activity', 'page': '2'},
          {
            'number': '2.3',
            'title': 'Layout Wise Sales Summary',
            'page': '$pageLayoutWiseSalesStart'
          },
          {
            'number': '2.4',
            'title': 'Layout Wise After Sales Summary',
            'page': '$pageLayoutWiseAfterSales'
          },
          if (hasAmenityArea)
            {
              'number': '2.5',
              'title': 'Amenity Area Sales Summary',
              'page': '$pageAmenitySales'
            },
          if (hasAmenityArea)
            {
              'number': '2.6',
              'title': 'Amenity Area After Sales Summary',
              'page': '$pageAmenityAfterSales'
            },
        ],
      },
      {
        'number': '3.',
        'title': 'Partner Details',
        'page': '$pagePartnerDetails',
        'subitems': [
          {
            'number': '3.1',
            'title': 'Partners Profit Distribution',
            'page': '$pagePartnerDetails'
          },
          {
            'number': '3.2',
            'title': 'Partner Plot Distribution',
            'page': '$pagePartnerDetails'
          },
        ],
      },
      {
        'number': '4.',
        'title': 'Project Manager(s) Details',
        'page': '$pageProjectManagers',
        'subitems': [
          {
            'number': '4.1',
            'title': 'Project Manager(s) Earnings',
            'page': '$pageProjectManagers'
          },
        ],
      },
      {
        'number': '5.',
        'title': 'Agent(s) Details',
        'page': '$pageAgents',
        'subitems': [
          {
            'number': '5.1',
            'title': 'Agent(s) Earnings',
            'page': '$pageAgents'
          },
          {
            'number': '5.2',
            'title': 'Agent - Plot Distribution & Earnings',
            'page': '$pageAgents'
          },
        ],
      },
      if (hasExpenseDetails)
        {
          'number': '6.',
          'title': 'Expense Details',
          'page': '$expenseStartPage',
          'subitems': [
            {
              'number': '6.1',
              'title': 'Expense Categories Summary',
              'page': '$expenseStartPage'
            },
            {
              'number': '6.2',
              'title': 'Expense Breakdown',
              'page': '$expenseStartPage'
            },
          ],
        },
      {
        'number': '7.',
        'title': 'Formulas',
        'page': '$formulasPage',
        'subitems': [],
      },
      {
        'number': '8.',
        'title': 'Compensation in Percentage Bonus',
        'page': '$compensationBonusCalcPage',
        'subitems': [
          {
            'number': '8.1',
            'title': '(%) of Profit on Each Sold Plot',
            'page': '$compensationBonusCalcPage'
          },
          {
            'number': '8.2',
            'title': '(%) of Total Project Profit',
            'page': '$compensationBonusCalcPage'
          },
          {
            'number': '8.3',
            'title': '(%) of Selling Price per Plot',
            'page': '$compensationBonusSellingPricePage'
          },
          {
            'number': '8.4',
            'title': 'Sale Value = Purchase Prize',
            'page': '$compensationBonusSellingPriceCaseCPage'
          },
        ],
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
    final tocItemStyle = GoogleFonts.inriaSerif(
      fontSize: 12,
      fontWeight: FontWeight.bold,
      color: const Color(0xFF404040),
    );

    Widget buildLeaderLine() {
      return Expanded(
        child: Container(
          margin: const EdgeInsets.only(left: 2, right: 2, bottom: 2),
          height: 0.5,
          color: const Color(0xFF858585),
        ),
      );
    }

    Widget buildTocRow({
      required String number,
      required String title,
      required String page,
      bool isSub = false,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (isSub) const SizedBox(width: 6),
            Text(number, style: tocItemStyle),
            const SizedBox(width: 6),
            Text(title, style: tocItemStyle),
            buildLeaderLine(),
            Text(page, style: tocItemStyle),
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
          ),
          if (subitems.isNotEmpty) const SizedBox(height: 2),
          for (var index = 0; index < subitems.length; index++) ...[
            buildTocRow(
              number: (subitems[index]['number'] ?? '').toString(),
              title: (subitems[index]['title'] ?? '').toString(),
              page: (subitems[index]['page'] ?? '').toString(),
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
        Container(
          height: 55,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.8),
            border: const Border(
              top: BorderSide(
                color: Color(0xFF858585),
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SvgPicture.asset(
                    'assets/images/8answers.svg',
                    width: 82,
                    height: 16,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '8answers.com',
                    style: GoogleFonts.inriaSerif(
                      fontSize: 10,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF0C8CE9),
                    ),
                  ),
                ],
              ),
              Text(
                '2',
                style: GoogleFonts.inriaSerif(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF0C8CE9),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStandardReportFooter(int pageNumber) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: const Color(0xFF858585),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SvgPicture.asset(
                  'assets/images/8answers.svg',
                  width: 82,
                  height: 16,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 4),
                Text(
                  '8answers.com',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 10,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF0C8CE9),
                  ),
                ),
              ],
            ),
          ),
          Text(
            '$pageNumber',
            style: GoogleFonts.inriaSerif(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF0C8CE9),
            ),
          ),
        ],
      ),
    );
  }

  String _formatCurrencyCompactReport(double value) {
    final absValue = value.abs();
    final hasFraction = absValue % 1 != 0;
    final formatted = absValue.toStringAsFixed(hasFraction ? 2 : 0);
    return value < 0 ? '-₹ $formatted' : '₹ $formatted';
  }

  Map<String, double> _buildCompensationTotalsForReport() {
    final totalAgentCompensation = _toDouble(
      _dashboardDataLocal?['totalAgentCompensation'] ??
          _dashboardDataLocal?['total_agent_compensation'] ??
          _projectData['totalAgentCompensation'] ??
          _projectData['total_agent_compensation'],
    );
    final totalProjectManagerCompensation = _toDouble(
      _dashboardDataLocal?['totalProjectManagerCompensation'] ??
          _dashboardDataLocal?['totalPMCompensation'] ??
          _dashboardDataLocal?['total_project_manager_compensation'] ??
          _projectData['totalProjectManagerCompensation'] ??
          _projectData['totalPMCompensation'] ??
          _projectData['total_project_manager_compensation'],
    );
    final totalCompensation = _toDouble(
      _dashboardDataLocal?['totalCompensation'] ??
          _dashboardDataLocal?['total_compensation'] ??
          _projectData['totalCompensation'] ??
          _projectData['total_compensation'],
    );

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
                      '*Project Name*',
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

  Widget _buildReportPage3() {
    if (_hasPendingPlotsForReport()) {
      return _buildReportPage3WithPending();
    }
    return _buildReportPage3WithoutPending();
  }

  Widget _buildReportPage3WithoutPending() {
    // Helper function to safely get and format values from project data (sections 1.1, 1.2)
    String getValue(String key, [dynamic defaultValue]) {
      final value = _projectData[key] ?? defaultValue;
      return _displayOrDash(value);
    }

    final nonSellableAreas = _collectNonSellableAreasForReport();
    final amenityAreas = _collectAmenityAreasForReport();
    final hasAmenityArea = amenityAreas.isNotEmpty;
    final totalAmenityAreaSqft = amenityAreas.fold<double>(
      0.0,
      (sum, area) => sum + _amenityAreaSqftForReport(area),
    );
    final projectCostRows = <List<String>>[
      ['Total Project Area', _formatAreaWithUnit(getValue('totalArea'))],
      ['Approved Selling Area', _formatAreaWithUnit(getValue('sellingArea'))],
      ['Non-Sellable Area', _formatAreaWithUnit(getValue('nonSellableArea'))],
      ...nonSellableAreas.map((row) {
        final label = _plotFieldStr(row, ['name']);
        return <String>[
          '. ${label == '-' ? 'Non-Sellable Area' : label}',
          _formatAreaWithUnit(_toDouble(row['area'])),
        ];
      }),
      if (hasAmenityArea)
        ['Amenity Area', _formatAreaWithUnit(totalAmenityAreaSqft)],
      ...amenityAreas.map((row) {
        final label =
            _plotFieldStr(row, ['name', 'amenityName', 'amenity_name']);
        return <String>[
          '. ${label == '-' ? 'Amenity Area' : label}',
          _formatAreaWithUnit(_amenityAreaSqftForReport(row)),
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
      if (hasAmenityArea)
        ['Total Number of Amenity Plot', '${amenityAreas.length}'],
      ['Total Number of Plot Sold', getValue('soldPlots')],
      ['Total Number of Plot Available', getValue('availablePlots')],
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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

              // Page Title
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '1. Project Overview',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0C8CE9),
                  ),
                ),
              ),

              // Content
              Expanded(
                child: SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1.1 Project Cost & Area
                      _buildTableSection(
                        title: '1.1  Project Cost & Area',
                        rows: projectCostRows,
                      ),
                      const SizedBox(height: 8),

                      // 1.2 Site Overview
                      _buildTableSection(
                        title: '1.2  Site Overview',
                        rows: siteOverviewRows,
                      ),
                      const SizedBox(height: 8),

                      // 1.3 Profit and ROI (from dashboard data - NO calculations)
                      _buildTableSection(
                        title: '1.3  Profit and ROI',
                        rows: [
                          [
                            'Profit Margin (%)',
                            _formatPercentOrDash(
                                getDashboardValue('profitMargin'))
                          ],
                          [
                            'ROI (%)',
                            _formatPercentOrDash(getDashboardValue('roi'))
                          ],
                          [
                            'Gross Profit',
                            _formatCurrencyOrDash(
                                getDashboardValue('grossProfit'))
                          ],
                          [
                            'Net Profit',
                            _formatCurrencyOrDash(
                                getDashboardValue('netProfit'))
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),

                      // 1.4 Sales Highlights (from dashboard data - NO calculations)
                      _buildTableSection(
                        title: '1.4  Sales Highlights',
                        rows: [
                          [
                            'Total Sales Value',
                            _formatCurrencyOrDash(
                                getDashboardValue('totalSalesValue'))
                          ],
                          [
                            'Average Sales Price (₹ / $_areaUnitSuffix) (* based on total sold plots *)',
                            _formatCurrencyOrDash(_displayRateFromSqft(
                                getDashboardValue('avgSalePricePerSqft')))
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),

                      // 1.5 Compensation (from dashboard data - NO calculations)
                      _buildTableSection(
                        title: '1.5  Compensation',
                        rows: [
                          [
                            'Total Agent Compensation',
                            _formatCurrencyOrDash(
                                getDashboardValue('totalAgentCompensation'))
                          ],
                          [
                            'Total Project Manager Compensation',
                            _formatCurrencyOrDash(getDashboardValue(
                                'totalProjectManagerCompensation'))
                          ],
                          [
                            'Total Compensation',
                            _formatCurrencyOrDash(
                                getDashboardValue('totalCompensation'))
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        _buildStandardReportFooter(1),
      ],
    );
  }

  List<Map<String, dynamic>> _collectReportPlotsForOverview() {
    final plots = <Map<String, dynamic>>[];
    final seenKeys = <String>{};

    void addPlot(dynamic rawPlot, {String? layoutName}) {
      if (rawPlot is! Map) return;
      final plot = Map<String, dynamic>.from(rawPlot);
      if (layoutName != null && layoutName.trim().isNotEmpty) {
        plot.putIfAbsent('layout', () => layoutName.trim());
      }

      final id = (plot['id'] ?? '').toString().trim();
      final plotNumber = _plotFieldStr(plot,
          ['plotNumber', 'plot_no', 'plotNo', 'number', 'plot_number']).trim();
      final layoutLabel = _resolveLayoutLabel(plot).trim();
      final fallbackIdentity =
          plotNumber == '-' ? jsonEncode(plot) : plotNumber;

      final dedupeKey = id.isNotEmpty
          ? 'id:$id'
          : 'plot:${layoutLabel.toLowerCase()}::${fallbackIdentity.toLowerCase()}';
      if (seenKeys.add(dedupeKey)) {
        plots.add(plot);
      }
    }

    if (_projectData['layouts'] is List) {
      for (final rawLayout in (_projectData['layouts'] as List)) {
        if (rawLayout is! Map) continue;
        final layout = Map<String, dynamic>.from(rawLayout);
        final layoutName = (layout['name'] ?? '').toString();
        final layoutPlots = layout['plots'];
        if (layoutPlots is List) {
          for (final rawPlot in layoutPlots) {
            addPlot(rawPlot, layoutName: layoutName);
          }
        }
      }
    }

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

  Map<String, dynamic> _buildPendingOverviewMetricsReport() {
    final plots = _collectReportPlotsForOverview();

    var soldPlotsRevenue = 0.0;
    var collectionsReceived = 0.0;
    var expectedRevenue = 0.0;
    var soldPlotsCount = 0;
    var pendingPlotsCount = 0;
    var availablePlotsCount = 0;

    for (final plot in plots) {
      final status = _plotFieldStr(plot, ['status']).toLowerCase().trim();
      final isSold = status == 'sold';
      final isPending = status == 'pending' || status == 'reserved';
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
        final status = _plotFieldStr(plot, ['status']).toLowerCase().trim();
        if (status == 'pending' || status == 'reserved') {
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
      final hasContent = name != '-' ||
          areaSqft > 0 ||
          allInCostSqft > 0 ||
          salePriceSqft > 0 ||
          saleValue > 0 ||
          buyerName != '-';
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
    final status = (rawStatus ?? '').toString().trim().toLowerCase();
    if (status == 'reserved' || status == 'pending') return 'pending';
    if (status == 'sold') return 'sold';
    return 'available';
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

  Widget _buildReportPage3WithPending() {
    String getValue(String key, [dynamic defaultValue]) {
      final value = _projectData[key] ?? defaultValue;
      return _displayOrDash(value);
    }

    final metrics = _buildPendingOverviewMetricsReport();
    final plots = (metrics['plots'] as List<Map<String, dynamic>>?) ?? const [];
    final soldPlotsRevenue = (metrics['soldPlotsRevenue'] as double?) ?? 0.0;
    final collectionsReceived =
        (metrics['collectionsReceived'] as double?) ?? 0.0;
    final expectedRevenue = (metrics['expectedRevenue'] as double?) ?? 0.0;
    final soldPlotsCount = (metrics['soldPlotsCount'] as int?) ?? 0;
    final pendingPlotsCount = (metrics['pendingPlotsCount'] as int?) ?? 0;
    final availableByStatus = (metrics['availablePlotsCount'] as int?) ?? 0;

    final totalExpenses = _toDouble(
      _dashboardDataLocal?['totalExpenses'] ??
          _dashboardDataLocal?['total_expenses'] ??
          _projectData['totalExpenses'] ??
          _projectData['total_expenses'],
    );
    final totalCompensation = _toDouble(
      _dashboardDataLocal?['totalCompensation'] ??
          _dashboardDataLocal?['total_compensation'] ??
          _projectData['totalCompensation'] ??
          _projectData['total_compensation'],
    );

    final actualGrossProfit = collectionsReceived - totalExpenses;
    final bookedGrossProfit = soldPlotsRevenue - totalExpenses;
    final expectedGrossProfit = expectedRevenue - totalExpenses;

    final actualNetProfit = actualGrossProfit - totalCompensation;
    final bookedNetProfit = bookedGrossProfit - totalCompensation;
    final expectedNetProfit = expectedGrossProfit - totalCompensation;

    final actualRoi =
        totalExpenses > 0 ? (actualNetProfit / totalExpenses) * 100 : 0.0;
    final bookedRoi =
        totalExpenses > 0 ? (bookedNetProfit / totalExpenses) * 100 : 0.0;
    final expectedRoi =
        totalExpenses > 0 ? (expectedNetProfit / totalExpenses) * 100 : 0.0;

    final actualProfitMargin = collectionsReceived > 0
        ? (actualNetProfit / collectionsReceived) * 100
        : 0.0;
    final bookedProfitMargin =
        soldPlotsRevenue > 0 ? (bookedNetProfit / soldPlotsRevenue) * 100 : 0.0;
    final expectedProfitMargin =
        expectedRevenue > 0 ? (expectedNetProfit / expectedRevenue) * 100 : 0.0;

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

    final availablePlots = plots.isNotEmpty
        ? availableByStatus
        : math.max(0, totalPlots - soldPlots - pendingPlotsCount);
    final nonSellableAreas = _collectNonSellableAreasForReport();
    final amenityAreas = _collectAmenityAreasForReport();
    final hasAmenityArea = amenityAreas.isNotEmpty;
    final totalAmenityAreaSqft = amenityAreas.fold<double>(
      0.0,
      (sum, area) => sum + _amenityAreaSqftForReport(area),
    );
    final projectCostRows = <List<String>>[
      ['Total Project Area', _formatAreaWithUnit(getValue('totalArea'))],
      ['Approved Selling Area', _formatAreaWithUnit(getValue('sellingArea'))],
      ['Non-Sellable Area', _formatAreaWithUnit(getValue('nonSellableArea'))],
      ...nonSellableAreas.map((row) {
        final label = _plotFieldStr(row, ['name']);
        return <String>[
          '. ${label == '-' ? 'Non-Sellable Area' : label}',
          _formatAreaWithUnit(_toDouble(row['area'])),
        ];
      }),
      if (hasAmenityArea)
        ['Amenity Area', _formatAreaWithUnit(totalAmenityAreaSqft)],
      ...amenityAreas.map((row) {
        final label =
            _plotFieldStr(row, ['name', 'amenityName', 'amenity_name']);
        return <String>[
          '. ${label == '-' ? 'Amenity Area' : label}',
          _formatAreaWithUnit(_amenityAreaSqftForReport(row)),
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
      if (hasAmenityArea)
        ['Total Number of Amenity Plot', '${amenityAreas.length}'],
      ['Total Number of Plot Sold', '$soldPlots'],
      ['Total Number of Plot Available', '$availablePlots'],
      ['Total Number of Plot Pending', '$pendingPlotsCount'],
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
                  '1. Project Overview',
                  style: GoogleFonts.inriaSerif(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF0C8CE9),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildTableSection(
                        title: '1.1  Project Cost & Area',
                        rows: projectCostRows,
                      ),
                      const SizedBox(height: 16),
                      _buildTableSection(
                        title: '1.2  Site Overview',
                        rows: siteOverviewRows,
                      ),
                      const SizedBox(height: 16),
                      _buildPendingProfitAndRoiTableReport(
                        actualGrossProfit: actualGrossProfit,
                        bookedGrossProfit: bookedGrossProfit,
                        expectedGrossProfit: expectedGrossProfit,
                        actualNetProfit: actualNetProfit,
                        bookedNetProfit: bookedNetProfit,
                        expectedNetProfit: expectedNetProfit,
                        actualRoi: actualRoi,
                        bookedRoi: bookedRoi,
                        expectedRoi: expectedRoi,
                        actualProfitMargin: actualProfitMargin,
                        bookedProfitMargin: bookedProfitMargin,
                        expectedProfitMargin: expectedProfitMargin,
                      ),
                      const SizedBox(height: 16),
                      _buildTableSection(
                        title: '1.4  Sales Highlights',
                        rows: [
                          [
                            'Sold Plots Revenue   (* Based on total sold plots *)',
                            _formatCurrencyAlwaysReport(soldPlotsRevenue),
                          ],
                          [
                            'Collections Received   (* Based on partial payments from pending & sold plots *)',
                            _formatCurrencyAlwaysReport(collectionsReceived),
                          ],
                          [
                            'Expected Revenue   (* Based on full value of pending & sold plots *)',
                            _formatCurrencyAlwaysReport(expectedRevenue),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        _buildStandardReportFooter(1),
      ],
    );
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                DateTime.now().toString().split(' ')[0],
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
                  _buildOverviewTableRow('Approved Selling Area', '-'),
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
    final totalSalesValue =
        double.tryParse(getDashboardValue('totalSalesValue')) ?? 0.0;
    final totalExpenses = _toDouble(
      _dashboardDataLocal?['totalExpenses'] ??
          _dashboardDataLocal?['total_expenses'] ??
          _projectData['totalExpenses'] ??
          _projectData['total_expenses'],
    );
    final grossProfit =
        double.tryParse(getDashboardValue('grossProfit')) ?? 0.0;
    final totalCompensation =
        double.tryParse(getDashboardValue('totalCompensation')) ?? 0.0;
    final netProfit = double.tryParse(getDashboardValue('netProfit')) ?? 0.0;

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
              '2. Sales Summary',
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
              '2.1  Financial Summary',
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
              title: 'Financial Summary',
              rows: [
                ['Total Sales Value', _formatCurrencyOrDash(totalSalesValue)],
                ['Total Expenses', _formatCurrencyOrDash(totalExpenses)],
                ['Gross Profit', _formatCurrencyOrDash(grossProfit)],
                ['Compensation', _formatCurrencyOrDash(totalCompensation)],
                ['Net Profit', _formatCurrencyOrDash(netProfit)],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '2.2  Sales Activity',
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
    final soldPlotsRevenue = (metrics['soldPlotsRevenue'] as double?) ?? 0.0;
    final collectionsReceived =
        (metrics['collectionsReceived'] as double?) ?? 0.0;
    final expectedSalesValue = (metrics['expectedRevenue'] as double?) ?? 0.0;
    final totalPendingAmount =
        math.max(0.0, expectedSalesValue - collectionsReceived);
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
              '2. Sales Summary',
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
              '2.1  Financial Summary',
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
              title: 'Financial Summary',
              rows: [
                [
                  'Sold Plots Revenue   (* Based on only total sold plots *)',
                  _formatCurrencyAlwaysReport(soldPlotsRevenue),
                ],
                [
                  'Collections Received   (* Based on partial payments from pending & sold plots *)',
                  _formatCurrencyAlwaysReport(collectionsReceived),
                ],
                [
                  'Expected Sales Value   (* Based on full value of pending & sold plots *)',
                  _formatCurrencyAlwaysReport(expectedSalesValue),
                ],
                [
                  'Total Pending Amount',
                  _formatCurrencyAlwaysReport(totalPendingAmount),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '2.2  Sales Activity',
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

  Widget _buildReportPage4SalesActivityChart({required int totalPlots}) {
    int todaysSales = 0;
    final today = DateTime.now();
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
      final status = _plotFieldStr(plot, ['status']).toLowerCase().trim();
      if (status != 'sold') continue;
      final saleDate =
          _plotFieldStr(plot, ['dateOfSale', 'date_of_sale', 'sale_date'])
              .trim();
      if (dailySalesMap.containsKey(saleDate)) {
        dailySalesMap[saleDate] = dailySalesMap[saleDate]! + 1;
        if (saleDate ==
            '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}') {
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

  List<Widget> _buildReportPage5Pages({required int startPageNumber}) {
    final List<dynamic> allPlots = _projectData['plots'] ?? [];
    final Map<String, List<Map<String, dynamic>>> layoutPlots = {};
    for (var plot in allPlots) {
      if (plot is! Map) continue;
      final plotMap = Map<String, dynamic>.from(plot);
      final layoutLabel = _resolveLayoutLabel(plotMap);
      final key = layoutLabel.isEmpty || layoutLabel == 'Unknown'
          ? 'Unknown'
          : layoutLabel;
      layoutPlots.putIfAbsent(key, () => []);
      layoutPlots[key]!.add(plotMap);
    }

    if (layoutPlots.isEmpty) {
      return [_buildReportPage5(pageNumber: startPageNumber)];
    }

    final entries = layoutPlots.entries.toList();
    final pages = <Widget>[];
    const int maxUnitsPerPage = 12;
    var currentEntries = <MapEntry<String, List<Map<String, dynamic>>>>[];
    var currentUnits = 0;
    var chunkStartIndex = 0;

    for (int entryIndex = 0; entryIndex < entries.length; entryIndex++) {
      final entry = entries[entryIndex];
      final units = 3 + entry.value.length;
      final shouldBreak =
          currentEntries.isNotEmpty && (currentUnits + units > maxUnitsPerPage);
      if (shouldBreak) {
        pages.add(_buildReportPage5(
          layoutEntriesOverride:
              List<MapEntry<String, List<Map<String, dynamic>>>>.from(
                  currentEntries),
          layoutIndexStart: chunkStartIndex,
          pageNumber: startPageNumber + pages.length,
        ));
        chunkStartIndex += currentEntries.length;
        currentEntries = <MapEntry<String, List<Map<String, dynamic>>>>[];
        currentUnits = 0;
      }
      currentEntries.add(entry);
      currentUnits += units;
    }

    if (currentEntries.isNotEmpty) {
      pages.add(_buildReportPage5(
        layoutEntriesOverride:
            List<MapEntry<String, List<Map<String, dynamic>>>>.from(
                currentEntries),
        layoutIndexStart: chunkStartIndex,
        pageNumber: startPageNumber + pages.length,
      ));
    }

    return pages;
  }

  Widget _buildReportPage5({
    List<MapEntry<String, List<Map<String, dynamic>>>>? layoutEntriesOverride,
    int layoutIndexStart = 0,
    required int pageNumber,
  }) {
    final List<dynamic> allPlots = _projectData['plots'] ?? [];
    final projectName =
        _projectData['projectName'] ?? _projectData['name'] ?? 'Project Name';
    print('DEBUG: allPlots = ' + allPlots.toString());
    if (allPlots.isNotEmpty) {
      print('DEBUG: first plot keys = ' + allPlots.first.keys.toString());
    }
    final List<MapEntry<String, List<Map<String, dynamic>>>> layoutEntries =
        layoutEntriesOverride ??
            (() {
              final grouped = <String, List<Map<String, dynamic>>>{};
              for (var plot in allPlots) {
                if (plot is! Map) continue;
                final plotMap = Map<String, dynamic>.from(plot);
                final layoutLabel = _resolveLayoutLabel(plotMap);
                final key = layoutLabel.isEmpty || layoutLabel == 'Unknown'
                    ? 'Unknown'
                    : layoutLabel;
                grouped.putIfAbsent(key, () => []);
                grouped[key]!.add(plotMap);
              }
              return grouped.entries.toList();
            })();

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header (copied from page 4)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
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
          // Title (not rotated)
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 8, bottom: 8),
            child: Text(
              '2.3  Layout Wise Sales Summary',
              style: GoogleFonts.inriaSerif(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF404040),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Rotated content (summary and table) — fixed at bottom of the A4 page and non-scrollable
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              final tableHeight = math.min(
                _landscapeTableUsableExtentPx(),
                constraints.maxHeight,
              );
              return Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: RotatedBox(
                    quarterTurns: 3, // 270 degrees
                    child: SizedBox(
                      height: tableHeight,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: layoutEntries.asMap().entries.map((entry) {
                          final layoutIdx = entry.key;
                          final layoutName = entry.value.key;
                          final plots = entry.value.value;
                          double totalArea = 0;
                          double totalPlotCost = 0;
                          double totalSaleValue = 0;
                          int plotsSold = 0;
                          double grossProfit = 0;
                          double netProfit = 0;

                          for (var plot in plots) {
                            final area = _plotFieldDouble(
                                plot, ['area', 'plotArea', 'plot_area']);
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
                            final status = _plotFieldStr(plot, [
                              'status',
                              'plot_status',
                              'sale_status'
                            ]).toLowerCase();
                            totalArea += area;
                            totalPlotCost += (area * allInCost);
                            if (status == 'sold') {
                              plotsSold++;
                              totalSaleValue += (area * salePrice);
                            }
                          }

                          grossProfit = totalSaleValue - totalPlotCost;

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text('${layoutIndexStart + layoutIdx + 1}.',
                                        style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: const Color(0xFF404040))),
                                    const SizedBox(width: 4),
                                    Text('Layout:',
                                        style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: const Color(0xFF404040))),
                                    const SizedBox(width: 4),
                                    Text(layoutName,
                                        style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            color: const Color(0xFF404040))),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Text(
                                        '$plotsSold / ${plots.length} plots sold',
                                        style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            color: const Color(0xFF404040))),
                                    const SizedBox(width: 8),
                                    Container(
                                        width: 2,
                                        height: 12,
                                        color: const Color(0xFF404040)),
                                    const SizedBox(width: 8),
                                    Text(
                                        'Area: ${_formatTo2Decimals(_displayAreaFromSqft(totalArea))} $_areaUnitSuffix',
                                        style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            color: const Color(0xFF404040))),
                                    const SizedBox(width: 8),
                                    Container(
                                        width: 2,
                                        height: 12,
                                        color: const Color(0xFF404040)),
                                    const SizedBox(width: 8),
                                    Text(
                                        'Total Plot Cost: ₹ ${_formatTo2Decimals(totalPlotCost)}',
                                        style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            color: const Color(0xFF404040))),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Text(
                                        'Actual Sales Value: ₹ ${_formatTo2Decimals(totalSaleValue)}',
                                        style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            color: const Color(0xFF404040))),
                                    const SizedBox(width: 8),
                                    Container(
                                        width: 2,
                                        height: 12,
                                        color: const Color(0xFF404040)),
                                    const SizedBox(width: 8),
                                    Text(
                                        'Actual Gross Profit: ₹ ${_formatTo2Decimals(grossProfit)}',
                                        style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            color: const Color(0xFF404040))),
                                    const SizedBox(width: 8),
                                    Container(
                                        width: 2,
                                        height: 12,
                                        color: const Color(0xFF404040)),
                                    const SizedBox(width: 8),
                                    Text(
                                        'Actual Net Profit: ₹ ${_formatTo2Decimals(netProfit)}',
                                        style: GoogleFonts.inriaSerif(
                                            fontSize: 10,
                                            color: const Color(0xFF404040))),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                // Table (non-scrollable)
                                Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: const Color(0xFF404040),
                                        width: 0.5),
                                  ),
                                  child: Column(
                                    children: [
                                      // Header
                                      Container(
                                        color: const Color(0xFF404040),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            _buildTableCell('Sl. No.', 33,
                                                isHeader: true,
                                                keepOriginalWidth: true),
                                            _buildTableCell('Plot Number', 68,
                                                isHeader: true,
                                                keepOriginalWidth: true),
                                            _buildTableCell(
                                                'Area ($_areaUnitSuffix)', 108,
                                                isHeader: true),
                                            _buildTableCell(
                                                'All-in Cost (₹/$_areaUnitSuffix)',
                                                108,
                                                isHeader: true),
                                            _buildTableCell(
                                                'Plot Cost (₹)', 108,
                                                isHeader: true),
                                            _buildTableCell(
                                                'Sale Price (₹/$_areaUnitSuffix)',
                                                108,
                                                isHeader: true),
                                            _buildTableCell(
                                                'Sale Value (₹)', 102,
                                                isHeader: true),
                                            _buildTableCell('Sale Date', 69,
                                                isHeader: true),
                                          ],
                                        ),
                                      ),
                                      ...List.generate(plots.length, (index) {
                                        final plot = plots[index];
                                        var plotNumber = _plotFieldStr(plot, [
                                          'plotNumber',
                                          'plot_no',
                                          'plotNo',
                                          'number'
                                        ]);
                                        if (plotNumber == '-')
                                          plotNumber = _inferPlotNumber(plot);
                                        final areaVal = _plotFieldDouble(plot,
                                            ['area', 'plotArea', 'plot_area']);
                                        final allInCostVal = _plotFieldDouble(
                                            plot, [
                                          'allInCostPerSqft',
                                          'all_in_cost_per_sqft',
                                          'allInCost',
                                          'all_in_cost'
                                        ]);
                                        final plotCostVal =
                                            areaVal * allInCostVal;
                                        final salePriceVal = _plotFieldDouble(
                                            plot, [
                                          'salePrice',
                                          'sale_price',
                                          'salePricePerSqft'
                                        ]);
                                        final saleValueVal =
                                            areaVal * salePriceVal;
                                        final saleDate = _plotFieldStr(plot, [
                                          'dateOfSale',
                                          'date_of_sale',
                                          'sale_date'
                                        ]);
                                        final area = _formatTo2Decimals(
                                            _displayAreaFromSqft(areaVal));
                                        final allInCost = _formatTo2Decimals(
                                            _displayRateFromSqft(allInCostVal));
                                        final plotCost =
                                            _formatTo2Decimals(plotCostVal);
                                        final salePrice = _formatTo2Decimals(
                                            _displayRateFromSqft(salePriceVal));
                                        final saleValue =
                                            _formatTo2Decimals(saleValueVal);
                                        return Container(
                                          decoration: BoxDecoration(
                                            border: Border(
                                                bottom: BorderSide(
                                                    color: Colors.black
                                                        .withOpacity(0.2),
                                                    width: 0.25)),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              _buildTableCell(
                                                  (index + 1).toString(), 33,
                                                  keepOriginalWidth: true),
                                              _buildTableCell(plotNumber, 68,
                                                  keepOriginalWidth: true),
                                              _buildTableCell(
                                                  '$area $_areaUnitSuffix',
                                                  108),
                                              _buildTableCell(
                                                  '₹ $allInCost', 108),
                                              _buildTableCell(
                                                  '₹ $plotCost', 108),
                                              _buildTableCell(
                                                  '₹ $salePrice', 108),
                                              _buildTableCell(
                                                  '₹ $saleValue', 102),
                                              _buildTableCell(saleDate, 69),
                                            ],
                                          ),
                                        );
                                      }),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),

          // Footer (copied from page 4)
          const SizedBox(height: 12),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  Widget _buildLayoutSection(
      String layoutName, List<Map<String, dynamic>> plots) {
    // Calculate totals
    double totalArea = 0;
    double totalPlotCost = 0;
    double totalSaleValue = 0;
    int plotsSold = 0;

    for (var plot in plots) {
      final area = double.tryParse(plot['area']?.toString() ?? '0') ?? 0;
      final allInCost =
          double.tryParse(plot['allInCostPerSqft']?.toString() ?? '0') ?? 0;
      final salePrice =
          double.tryParse(plot['salePrice']?.toString() ?? '0') ?? 0;
      final status = plot['status'] ?? '';

      totalArea += area;
      totalPlotCost += (area * allInCost);
      if (status == 'sold') {
        plotsSold++;
        totalSaleValue += (area * salePrice);
      }
    }

    final grossProfit = totalSaleValue - totalPlotCost;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Summary info
        Container(
          width: 150,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFF404040), width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Layout: $layoutName',
                style: GoogleFonts.inriaSerif(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF404040),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$plotsSold / ${plots.length} plots sold',
                style: GoogleFonts.inriaSerif(
                  fontSize: 9,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Area: ${_formatTo2Decimals(_displayAreaFromSqft(totalArea))} $_areaUnitSuffix',
                style: GoogleFonts.inriaSerif(
                  fontSize: 9,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Total Cost: ₹ ${_formatTo2Decimals(totalPlotCost)}',
                style: GoogleFonts.inriaSerif(
                  fontSize: 9,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Sale Value: ₹ ${_formatTo2Decimals(totalSaleValue)}',
                style: GoogleFonts.inriaSerif(
                  fontSize: 9,
                  color: const Color(0xFF404040),
                ),
              ),
              Text(
                'Gross Profit: ₹ ${_formatTo2Decimals(grossProfit)}',
                style: GoogleFonts.inriaSerif(
                  fontSize: 9,
                  color: const Color(0xFF404040),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Table
        SizedBox(
          height: 200,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Container(
                      color: const Color(0xFF404040),
                      child: Row(
                        children: [
                          _buildTableCell('Sl. No.', 30,
                              isHeader: true, keepOriginalWidth: true),
                          _buildTableCell('Plot No.', 50,
                              isHeader: true, keepOriginalWidth: true),
                          _buildTableCell('Area ($_areaUnitSuffix)', 60,
                              isHeader: true),
                          _buildTableCell('Cost (₹/$_areaUnitSuffix)', 70,
                              isHeader: true),
                          _buildTableCell('Plot Cost (₹)', 80, isHeader: true),
                          _buildTableCell('Sale Date', 76, isHeader: true),
                        ],
                      ),
                    ),
                    // Data rows (resolve multiple possible field names)
                    ...List.generate(plots.length, (index) {
                      final plot = plots[index];
                      var plotNumber = _plotFieldStr(
                          plot, ['plotNumber', 'plot_no', 'plotNo', 'number']);
                      if (plotNumber == '-')
                        plotNumber = _inferPlotNumber(plot);
                      final areaVal = _plotFieldDouble(
                          plot, ['area', 'plotArea', 'plot_area']);
                      final allInCostVal = _plotFieldDouble(plot, [
                        'allInCostPerSqft',
                        'all_in_cost_per_sqft',
                        'allInCost',
                        'all_in_cost'
                      ]);
                      final plotCostVal = areaVal * allInCostVal;
                      final saleDate = _plotFieldStr(
                          plot, ['dateOfSale', 'date_of_sale', 'sale_date']);
                      final area =
                          _formatTo2Decimals(_displayAreaFromSqft(areaVal));
                      final allInCost = _formatTo2Decimals(
                          _displayRateFromSqft(allInCostVal));
                      final plotCost = _formatTo2Decimals(plotCostVal);

                      return Container(
                        decoration: BoxDecoration(
                          border: Border(
                              bottom: BorderSide(
                                  color: Colors.black.withOpacity(0.2),
                                  width: 0.25)),
                        ),
                        child: Row(
                          children: [
                            _buildTableCell((index + 1).toString(), 30,
                                keepOriginalWidth: true),
                            _buildTableCell(plotNumber, 50,
                                keepOriginalWidth: true),
                            _buildTableCell('$area $_areaUnitSuffix', 60),
                            _buildTableCell('₹ $allInCost', 70),
                            _buildTableCell('₹ $plotCost', 80),
                            _buildTableCell(saleDate, 76),
                          ],
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Map<String, dynamic>> _buildReportPage6LayoutBlocks() {
    final allPlots = _projectData['plots'] as List<dynamic>? ?? const [];
    final layoutPlots = <String, List<Map<String, dynamic>>>{};
    for (final raw in allPlots) {
      final plot =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
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

  double _estimateReportPage6BlockHeightPx(int rows) {
    // Match real rendered heights more closely (table cells can use 2 lines).
    const topHeaderAndGap = 16.0;
    const summaryRowAndGap = 20.0;
    const tableHeader = 26.0;
    const blockBottomGap = 12.0;
    const rowHeight = 22.0;
    return topHeaderAndGap +
        summaryRowAndGap +
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

    final availableHeightPx = _landscapeTableUsableExtentPx();
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

        final fullTableHeight =
            _estimateReportPage6BlockHeightPx(rowsRemaining);
        if (fullTableHeight <= remainingHeight) {
          final chunkEnd = rowStart + rowsRemaining;
          pageBlocks.add({
            'layoutIndex': layout['layoutIndex'],
            'layoutName': layout['layoutName'],
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
            _estimateReportPage6BlockHeightPx(rowsToTake) > remainingHeight) {
          rowsToTake--;
        }
        rowsToTake = math.max(minRowsPerChunk, rowsToTake);
        rowsToTake = math.min(rowsToTake, rowsRemaining);
        final chunkEnd = rowStart + rowsToTake;
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

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 8, bottom: 8),
            child: Text(
              isContinuation
                  ? '2.4  Layout wise after sales summary (Cont.)'
                  : '2.4  Layout wise after sales summary',
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
                  _landscapeTableUsableExtentPx(),
                  constraints.maxHeight,
                );
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
                                  (block['layoutName'] ?? 'Unknown').toString();
                              final continued = block['continued'] == true;
                              final plotStartIndex =
                                  (block['plotStartIndex'] as int?) ?? 0;
                              final rawPlots =
                                  block['plots'] as List<dynamic>? ?? const [];
                              final plots = rawPlots
                                  .map((p) => p is Map
                                      ? Map<String, dynamic>.from(p)
                                      : <String, dynamic>{})
                                  .toList(growable: false);

                              int plotsSold = plots.where((p) {
                                final st = _plotFieldStr(p, [
                                  'status',
                                  'plot_status',
                                  'sale_status'
                                ]).toLowerCase();
                                return st == 'sold' || st == 'sold ';
                              }).length;
                              double pendingAmount = 0.0;
                              for (final plot in plots) {
                                final status = _plotFieldStr(plot, [
                                  'status',
                                  'plot_status',
                                  'sale_status'
                                ]).toLowerCase().trim();
                                if (status != 'pending' &&
                                    status != 'reserved') {
                                  continue;
                                }
                                final area = _plotFieldDouble(
                                    plot, ['area', 'plotArea', 'plot_area']);
                                final salePrice = _plotFieldDouble(plot, [
                                  'salePrice',
                                  'sale_price',
                                  'salePricePerSqft',
                                  'sale_price_per_sqft'
                                ]);
                                final saleValue = area * salePrice;
                                final paidAmount =
                                    _sumPlotPaymentAmountReport(plot);
                                pendingAmount +=
                                    math.max(0.0, saleValue - paidAmount);
                              }

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text('${layoutIndex + 1}.',
                                            style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color:
                                                    const Color(0xFF404040))),
                                        const SizedBox(width: 4),
                                        Text('Layout:',
                                            style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color:
                                                    const Color(0xFF404040))),
                                        const SizedBox(width: 4),
                                        Text(
                                          continued
                                              ? '$layoutName (Cont.)'
                                              : layoutName,
                                          style: GoogleFonts.inriaSerif(
                                              fontSize: 10,
                                              color: const Color(0xFF404040)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Text(
                                            '$plotsSold / ${plots.length} plots sold',
                                            style: GoogleFonts.inriaSerif(
                                                fontSize: 10,
                                                color:
                                                    const Color(0xFF404040))),
                                        const SizedBox(width: 8),
                                        Container(
                                          width: 2,
                                          height: 12,
                                          color: const Color(0xFF404040),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Pending Amount: ${_formatCurrencyAlwaysReport(pendingAmount)}',
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
                                            width: 0.5),
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
                                                _buildTableCell(
                                                    'Plot Number', 68,
                                                    isHeader: true,
                                                    keepOriginalWidth: true),
                                                _buildTableCell(
                                                    'Area ($_areaUnitSuffix)',
                                                    108,
                                                    isHeader: true),
                                                _buildTableCell(
                                                    'Partner\'s Name', 136,
                                                    isHeader: true),
                                                _buildTableCell(
                                                    'Buyer\'s Name', 136,
                                                    isHeader: true),
                                                _buildTableCell('Agent', 136,
                                                    isHeader: true),
                                                _buildTableCell('Sale Date', 69,
                                                    isHeader: true),
                                              ],
                                            ),
                                          ),
                                          ...List.generate(plots.length, (idx) {
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
                                            final areaVal = _plotFieldDouble(
                                                plot, [
                                              'area',
                                              'plotArea',
                                              'plot_area'
                                            ]);
                                            final area = _formatTo2Decimals(
                                                _displayAreaFromSqft(areaVal));
                                            final partnerName = _plotFieldStr(
                                                plot, [
                                              'partner',
                                              'partnerName',
                                              'partner_name',
                                              'partnersName',
                                              'partners_name'
                                            ]);
                                            final buyerName = _plotFieldStr(
                                                plot, [
                                              'buyer',
                                              'buyerName',
                                              'buyer_name'
                                            ]);
                                            final agentName = _plotFieldStr(
                                                plot, [
                                              'agent',
                                              'agentName',
                                              'agent_name'
                                            ]);
                                            final saleDate = _plotFieldStr(
                                                plot, [
                                              'dateOfSale',
                                              'date_of_sale',
                                              'sale_date'
                                            ]);

                                            return Container(
                                              decoration: BoxDecoration(
                                                border: Border(
                                                    bottom: BorderSide(
                                                        color: Colors.black
                                                            .withOpacity(0.2),
                                                        width: 0.25)),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  _buildTableCell(
                                                      (plotStartIndex + idx + 1)
                                                          .toString(),
                                                      37,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      plotNumber, 68,
                                                      keepOriginalWidth: true),
                                                  _buildTableCell(
                                                      '$area $_areaUnitSuffix',
                                                      108),
                                                  _buildTableCell(
                                                      partnerName, 136),
                                                  _buildTableCell(
                                                      buyerName, 136),
                                                  _buildTableCell(
                                                      agentName, 136),
                                                  _buildTableCell(saleDate, 69),
                                                ],
                                              ),
                                            );
                                          }),
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
          const SizedBox(height: 12),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  String _amenitySaleDateLabelForReport(Map<String, dynamic> row) {
    return _plotFieldStr(row, ['sale_date', 'saleDate', 'date_of_sale']);
  }

  String _amenityBuyerLabelForReport(Map<String, dynamic> row) {
    return _plotFieldStr(row, ['buyer_name', 'buyerName', 'buyer']);
  }

  String _amenityAgentLabelForReport(Map<String, dynamic> row) {
    return _plotFieldStr(row, ['agent_name', 'agentName', 'agent']);
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
    final soldRows = allRows
        .where(
            (row) => _normalizeAmenityStatusForReport(row['status']) == 'sold')
        .toList(growable: false);
    final soldCount = soldRows.length;
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
    final netProfit = grossProfit;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                  ? '2.5  Amenity Area Sales Summary (Cont.)'
                  : '2.5  Amenity Area Sales Summary',
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
                            Row(
                              children: [
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
                                const SizedBox(width: 8),
                                Container(
                                  width: 2,
                                  height: 12,
                                  color: const Color(0xFF404040),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Net Profit: ₹ ${_formatTo2Decimals(netProfit)}',
                                  style: GoogleFonts.inriaSerif(
                                    fontSize: 10,
                                    color: const Color(0xFF404040),
                                  ),
                                ),
                              ],
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
          const SizedBox(height: 12),
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
    final soldCount = allRows
        .where(
            (row) => _normalizeAmenityStatusForReport(row['status']) == 'sold')
        .length;
    final totalAreaSqft = allRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityAreaSqftForReport(row),
    );

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                  ? '2.6 Amenity Area After Sales Summary (Cont.)'
                  : '2.6 Amenity Area After Sales Summary',
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
                              '$soldCount / ${allRows.length} plots sold',
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
          const SizedBox(height: 12),
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
    final List<dynamic> allPlots = _projectData['plots'] ?? [];
    if (partners.isEmpty) {
      final names = <String>{};
      for (var raw in allPlots) {
        final plot =
            raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        final name = _plotFieldStr(plot, [
          'partner',
          'partnerName',
          'partner_name',
          'partnersName',
          'partners_name'
        ]);
        if (name.isNotEmpty && name != '-') names.add(name);
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
    for (var raw in allPlots) {
      final plot =
          raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      final plotId = plot['id']?.toString() ?? '';
      final plotNumber = _plotFieldStr(
          plot, ['plotNumber', 'plot_no', 'plotNo', 'number', 'plot_number']);
      final layoutLabel = _resolveLayoutLabel(plot);
      if (plotId.isNotEmpty) {
        plotIdToNumber[plotId] = plotNumber;
        plotIdToLayout[plotId] = layoutLabel;
      }
      if (plotNumber.isNotEmpty && plotNumber != '-') {
        plotNumberToLayout[plotNumber] = layoutLabel;
      }
    }

    // 2. Fetch plot_partners assignments from _projectData if available
    final plotPartnersRaw =
        _projectData['plot_partners'] as List<dynamic>? ?? [];
    for (var assignment in plotPartnersRaw) {
      final partnerName = (assignment['partner_name'] ?? '').toString();
      final plotId = (assignment['plot_id'] ?? '').toString();
      if (plotId.isEmpty || partnerName.isEmpty) continue;
      plotIdToPartnerNames.putIfAbsent(plotId, () => []).add(partnerName);
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
      final assigned = plotsByPartner[name] ?? [];
      final assignedDetailed = plotsByPartnerDetailed[name] ?? [];
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
    final showDistributionSection = visiblePartners.isNotEmpty;

    double parseNum(dynamic v) {
      if (v == null) return 0.0;
      if (v is num) return v.toDouble();
      final cleaned = v.toString().replaceAll(RegExp(r'[^0-9.\-]'), '');
      return double.tryParse(cleaned) ?? 0.0;
    }

    double readMetric(List<String> keys) {
      for (final key in keys) {
        if (_dashboardDataLocal != null &&
            _dashboardDataLocal!.containsKey(key)) {
          final parsed = parseNum(_dashboardDataLocal![key]);
          if (parsed != 0) return parsed;
        }
        if (_projectData.containsKey(key)) {
          final parsed = parseNum(_projectData[key]);
          if (parsed != 0) return parsed;
        }
      }
      return 0.0;
    }

    final totalSalesValue = readMetric(
      ['totalSalesValue', 'total_sales_value'],
    );
    final totalExpenses = readMetric(
      ['totalExpenses', 'total_expenses'],
    );
    final totalAgentCompensation = readMetric(
      ['totalAgentCompensation', 'total_agent_compensation'],
    );
    final totalProjectManagerCompensation = readMetric(
      [
        'totalProjectManagerCompensation',
        'totalPMCompensation',
        'total_project_manager_compensation',
      ],
    );
    final totalCompensation = readMetric(
      ['totalCompensation', 'total_compensation'],
    );
    final combinedCompensation = totalCompensation != 0
        ? totalCompensation
        : (totalAgentCompensation + totalProjectManagerCompensation);
    final partnersProfitPool =
        (totalSalesValue - totalExpenses) - combinedCompensation;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
          Padding(
            padding: const EdgeInsets.only(left: 0, top: 8, bottom: 8),
            child: Text(
              isContinuation
                  ? '3. Partner(s) Details (Cont.)'
                  : '3. Partner(s) Details',
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
              padding: const EdgeInsets.only(left: 0, top: 4, bottom: 8),
              child: Text(
                '3.1  Partner(s) Profit Distribution',
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
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    'Total Agent Compensation: ${_formatCurrencyWithSignReport(totalAgentCompensation)}',
                    style: GoogleFonts.inriaSerif(
                      fontSize: 10,
                      color: const Color(0xFF404040),
                    ),
                  ),
                  Text(
                    'Total Project Manager Compensation: ${_formatCurrencyWithSignReport(totalProjectManagerCompensation)}',
                    style: GoogleFonts.inriaSerif(
                      fontSize: 10,
                      color: const Color(0xFF404040),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (showSummarySection) ...[
            // Profit table (shown only on first page)
            Padding(
              padding: const EdgeInsets.only(left: 0, right: 8),
              child: Column(
                children: [
                  Container(
                    color: const Color(0xFF404040),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildTableCell('Partner Name', 143,
                            isHeader: true, keepOriginalWidth: true),
                        _buildTableCell('Capital Contribution (₹)', 148,
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
                    final totalCapitalContributions = partners.fold<double>(
                      0.0,
                      (sum, p) =>
                          sum +
                          _plotFieldDouble(
                            p as Map<String, dynamic>,
                            [
                              'capitalContribution',
                              'capital_contribution',
                              'capital',
                              'amount',
                            ],
                          ),
                    );

                    double parsePercent(dynamic value) {
                      if (value == null) return 0.0;
                      if (value is num) {
                        final numVal = value.toDouble();
                        return (numVal > 0 && numVal <= 1)
                            ? numVal * 100
                            : numVal;
                      }
                      final raw = value.toString().trim();
                      if (raw.isEmpty) return 0.0;
                      final cleaned = raw.replaceAll(RegExp(r'[^0-9.\-]'), '');
                      final parsed = double.tryParse(cleaned) ?? 0.0;
                      return (parsed > 0 && parsed <= 1)
                          ? parsed * 100
                          : parsed;
                    }

                    final rowWidgets = <Widget>[];
                    for (final p in partners) {
                      final name = (p['name'] ??
                              p['partnerName'] ??
                              p['partner_name'] ??
                              '-')
                          .toString();
                      final capitalVal = _plotFieldDouble(
                          p as Map<String, dynamic>, [
                        'capitalContribution',
                        'capital_contribution',
                        'capital',
                        'amount'
                      ]);
                      final explicitShareVal = parsePercent(
                        p['profitShare'] ??
                            p['profit_share'] ??
                            p['share'] ??
                            p['percentage'],
                      );
                      final profitShareVal = explicitShareVal > 0
                          ? explicitShareVal
                          : (totalCapitalContributions > 0
                              ? (capitalVal / totalCapitalContributions) * 100
                              : 0.0);

                      final explicitAllocatedVal = _plotFieldDouble(
                        p,
                        [
                          'allocatedProfit',
                          'allocated_profit',
                          'allocatedAmount',
                          'allocated_amount',
                          'profitAmount',
                          'profit_amount',
                        ],
                      );
                      final allocatedVal = explicitAllocatedVal != 0
                          ? explicitAllocatedVal
                          : (partnersProfitPool * profitShareVal) / 100.0;

                      rowWidgets.add(Container(
                        decoration: BoxDecoration(
                            border: Border(
                                bottom: BorderSide(
                                    color: Colors.black.withOpacity(0.2),
                                    width: 0.25))),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildTableCell(name, 143, keepOriginalWidth: true),
                            _buildTableCell(
                                _formatCurrencyWithSignReport(capitalVal), 148),
                            _buildTableCell(
                                _formatCurrencyWithSignReport(allocatedVal),
                                148),
                            _buildTableCell(
                                '${profitShareVal.toStringAsFixed(profitShareVal % 1 == 0 ? 0 : 2)}%',
                                110),
                          ],
                        ),
                      ));
                    }

                    double grandCapital = 0.0;
                    double grandAllocated = 0.0;
                    double grandProfitShare = 0.0;
                    for (final p in partners) {
                      final capitalVal = _plotFieldDouble(
                          p as Map<String, dynamic>, [
                        'capitalContribution',
                        'capital_contribution',
                        'capital',
                        'amount'
                      ]);
                      final explicitShareVal = parsePercent(
                        p['profitShare'] ??
                            p['profit_share'] ??
                            p['share'] ??
                            p['percentage'],
                      );
                      final profitShareVal = explicitShareVal > 0
                          ? explicitShareVal
                          : (totalCapitalContributions > 0
                              ? (capitalVal / totalCapitalContributions) * 100
                              : 0.0);
                      final explicitAllocatedVal = _plotFieldDouble(
                        p,
                        [
                          'allocatedProfit',
                          'allocated_profit',
                          'allocatedAmount',
                          'allocated_amount',
                          'profitAmount',
                          'profit_amount',
                        ],
                      );
                      final allocatedVal = explicitAllocatedVal != 0
                          ? explicitAllocatedVal
                          : (partnersProfitPool * profitShareVal) / 100.0;
                      grandCapital += capitalVal;
                      grandAllocated += allocatedVal;
                      grandProfitShare += profitShareVal;
                    }
                    rowWidgets.add(Container(
                      color: Colors.grey.withOpacity(0.25),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildTableCell('Total', 143,
                              keepOriginalWidth: true),
                          _buildTableCell(
                              _formatCurrencyWithSignReport(grandCapital), 148),
                          _buildTableCell(
                              _formatCurrencyWithSignReport(grandAllocated),
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
            const SizedBox(height: 12),
          ],

          if (showDistributionSection) ...[
            // 3.2 Partner - Plot Distribution
            Padding(
              padding: const EdgeInsets.only(left: 0, top: 4, bottom: 8),
              child: Text(
                '3.2  Partner - Plot Distribution',
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
                  border:
                      Border.all(color: const Color(0xFF404040), width: 0.5),
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
                            child: Text(
                              'No. of Plots Assigned',
                              style: GoogleFonts.inriaSerif(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
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
                            sum + (((p['plotCount'] as num?)?.toInt()) ?? 0),
                      );
                      final rows = <Widget>[];

                      for (final p in visiblePartners) {
                        final name = (p['name'] ??
                                p['partnerName'] ??
                                p['partner_name'] ??
                                '-')
                            .toString();
                        final nameNorm = name.toLowerCase().trim();

                        final assignedDetailed = <Map<String, String>>[];
                        if (p['assignedPlotsDetailed'] is List) {
                          for (final raw
                              in (p['assignedPlotsDetailed'] as List)) {
                            if (raw is! Map) continue;
                            final detail = Map<String, dynamic>.from(raw);
                            final plotNo =
                                (detail['plot'] ?? '').toString().trim();
                            final layout =
                                (detail['layout'] ?? '').toString().trim();
                            if (plotNo.isEmpty) continue;
                            assignedDetailed.add({
                              'plot': plotNo,
                              'layout': layout.isEmpty ? 'Unknown' : layout,
                            });
                          }
                        } else if (p['assignedPlots'] is List) {
                          final layoutMap = <String, String>{};
                          final layoutMapRaw = p['plotNumberToLayoutMap'];
                          if (layoutMapRaw is Map) {
                            layoutMapRaw.forEach((key, value) {
                              final k = key?.toString().trim() ?? '';
                              final v = value?.toString().trim() ?? '';
                              if (k.isNotEmpty) {
                                layoutMap[k] = v.isEmpty ? 'Unknown' : v;
                              }
                            });
                          }
                          for (final raw in (p['assignedPlots'] as List)) {
                            final plotNo = raw?.toString().trim() ?? '';
                            if (plotNo.isEmpty) continue;
                            assignedDetailed.add({
                              'plot': plotNo,
                              'layout': layoutMap[plotNo] ?? 'Unknown',
                            });
                          }
                        } else {
                          for (final raw in allPlots) {
                            final plot = raw is Map
                                ? Map<String, dynamic>.from(raw)
                                : <String, dynamic>{};
                            var pname = _plotFieldStr(plot, [
                              'partner',
                              'partnerName',
                              'partner_name',
                              'partnersName',
                              'partners_name',
                            ]);
                            pname = pname.toLowerCase().trim();
                            if (pname == '-' || pname.isEmpty) continue;
                            if (pname == nameNorm ||
                                pname.contains(nameNorm) ||
                                nameNorm.contains(pname)) {
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
                        }

                        final groupedByLayout = <String, List<String>>{};
                        final seen = <String>{};
                        for (final detail in assignedDetailed) {
                          final layout =
                              (detail['layout'] ?? 'Unknown').toString().trim();
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
                          groupedByLayout[layout.isEmpty ? 'Unknown' : layout]!
                              .add(plotNo);
                        }

                        final assignedCount = groupedByLayout.values
                            .fold<int>(0, (sum, items) => sum + items.length);

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
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                                            color: const Color(0xFF404040),
                                          ),
                                        )
                                      : Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: groupedByLayout.entries
                                              .toList()
                                              .asMap()
                                              .entries
                                              .expand((layoutEntry) {
                                            final index = layoutEntry.key;
                                            final entry = layoutEntry.value;
                                            return [
                                              Text(
                                                'Layout: ${entry.key}',
                                                style: GoogleFonts.inriaSerif(
                                                  fontSize: 10,
                                                  color:
                                                      const Color(0xFF404040),
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Wrap(
                                                spacing: 4,
                                                runSpacing: 4,
                                                children: entry.value
                                                    .map(
                                                      (plotNo) => Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                                horizontal: 2,
                                                                vertical: 1),
                                                        decoration:
                                                            BoxDecoration(
                                                          color: const Color(
                                                              0xFFCFCFCF),
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(2),
                                                        ),
                                                        child: Text(
                                                          plotNo,
                                                          style: GoogleFonts
                                                              .inriaSerif(
                                                            fontSize: 10,
                                                            color: const Color(
                                                                0xFF404040),
                                                          ),
                                                        ),
                                                      ),
                                                    )
                                                    .toList(),
                                              ),
                                              if (index !=
                                                  groupedByLayout.length - 1)
                                                const SizedBox(height: 8),
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
                            color: const Color(0x40404040),
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
                                const Expanded(child: SizedBox(height: 12)),
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

          // Footer
          const SizedBox(height: 12),
          _buildStandardReportFooter(pageNumber),
        ],
      ),
    );
  }

  Widget _buildTableCell(String text, double width,
      {bool isHeader = false, bool keepOriginalWidth = false}) {
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
          fontSize: 9,
          fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
          color: isHeader ? Colors.white : const Color(0xFF404040),
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
