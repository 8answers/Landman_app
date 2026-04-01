import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

class WebArrowKeyScrollBinding {
  WebArrowKeyScrollBinding({
    required ScrollController controller,
    this.step = 64,
  }) : _controller = controller;

  final ScrollController _controller;
  final double step;
  bool _attached = false;

  void attach() {
    if (_attached) return;
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _attached = true;
  }

  void detach() {
    if (!_attached) return;
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _attached = false;
  }

  bool _isTextInputFocused() {
    final focusedNode = FocusManager.instance.primaryFocus;
    if (focusedNode == null) return false;
    final context = focusedNode.context;
    if (context == null) return false;
    return context.widget is EditableText;
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!_controller.hasClients) return false;
    if (!_isScrollableVisible()) return false;
    if (_isTextInputFocused()) return false;

    double delta = 0;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      delta = step;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      delta = -step;
    } else {
      return false;
    }

    final position = _controller.position;
    final target = (position.pixels + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((target - position.pixels).abs() < 0.5) return false;

    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
    );
    return true;
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
