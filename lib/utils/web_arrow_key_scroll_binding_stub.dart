import 'package:flutter/material.dart';

class WebArrowKeyScrollBinding {
  WebArrowKeyScrollBinding({
    required ScrollController controller,
    this.step = 64,
  });

  final double step;

  void attach() {}

  void detach() {}
}
