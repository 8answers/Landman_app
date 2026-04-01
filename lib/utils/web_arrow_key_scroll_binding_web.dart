import 'dart:async';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
    if (!_isScrollableVisible()) return;
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

  bool _isScrollableVisible() {
    if (!_controller.hasClients) return false;
    final position = _controller.position;
    final context = position.context.notificationContext;
    if (context == null) return true;
    final offstage = context.findAncestorWidgetOfExactType<Offstage>();
    if (offstage != null && offstage.offstage) return false;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return true;
    if (!renderObject.attached || !renderObject.hasSize) return false;
    if (!_isPaintedByAncestors(renderObject)) return false;
    final size = renderObject.size;
    return size.width > 0 && size.height > 0;
  }

  bool _isPaintedByAncestors(RenderBox renderObject) {
    RenderObject current = renderObject;
    while (true) {
      final parent = current.parent;
      if (parent == null) return true;
      if (parent is RenderOffstage && parent.offstage) return false;
      if (parent is RenderIndexedStack && current is RenderBox) {
        if (!parent.paintsChild(current)) return false;
      }
      current = parent;
    }
  }
}
