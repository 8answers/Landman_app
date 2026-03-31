import 'dart:async';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:flutter/material.dart';

class WebArrowKeyScrollBinding {
  WebArrowKeyScrollBinding({
    required ScrollController controller,
    this.step = 64,
  }) : _controller = controller;

  final ScrollController _controller;
  final double step;
  StreamSubscription<html.KeyboardEvent>? _subscription;

  void attach() {
    _subscription?.cancel();
    _subscription = html.window.onKeyDown.listen(_handleKeyDown);
  }

  void detach() {
    _subscription?.cancel();
    _subscription = null;
  }

  bool _isTextInputFocused() {
    final activeElement = html.document.activeElement;
    if (activeElement == null) return false;
    final tagName = activeElement.tagName.toLowerCase();
    if (tagName == 'input' || tagName == 'textarea' || tagName == 'select') {
      return true;
    }
    return activeElement.isContentEditable == true;
  }

  void _handleKeyDown(html.KeyboardEvent event) {
    if (!_controller.hasClients) return;
    if (_isTextInputFocused()) return;

    double delta = 0;
    if (event.key == 'ArrowDown') {
      delta = step;
    } else if (event.key == 'ArrowUp') {
      delta = -step;
    } else {
      return;
    }

    event.preventDefault();
    final position = _controller.position;
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((target - position.pixels).abs() < 0.5) return;

    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
    );
  }
}
