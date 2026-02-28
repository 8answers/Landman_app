import 'package:flutter/widgets.dart';

class AppScaleMetrics extends InheritedWidget {
  const AppScaleMetrics({
    super.key,
    required this.designViewportWidth,
    required this.rightOverflowWidth,
    required super.child,
  });

  final double designViewportWidth;
  final double rightOverflowWidth;

  static AppScaleMetrics? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<AppScaleMetrics>();
  }

  @override
  bool updateShouldNotify(AppScaleMetrics oldWidget) {
    return oldWidget.designViewportWidth != designViewportWidth ||
        oldWidget.rightOverflowWidth != rightOverflowWidth;
  }
}
