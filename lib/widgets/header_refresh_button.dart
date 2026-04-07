import 'package:flutter/material.dart';

class HeaderRefreshButton extends StatefulWidget {
  const HeaderRefreshButton({
    super.key,
    required this.onTap,
  });

  final VoidCallback onTap;

  @override
  State<HeaderRefreshButton> createState() => _HeaderRefreshButtonState();
}

class _HeaderRefreshButtonState extends State<HeaderRefreshButton> {
  static const BorderRadius _radius = BorderRadius.all(Radius.circular(8));
  bool _isHovered = false;
  bool _isPressed = false;

  Color _backgroundColor() {
    if (_isPressed) return const Color(0xFFEDEDED);
    if (_isHovered) return const Color(0xFFF0F0F0);
    return Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() {
        _isHovered = false;
        _isPressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _backgroundColor(),
            borderRadius: _radius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 2,
                offset: const Offset(0, 0),
                spreadRadius: 0,
              ),
            ],
          ),
          child: const Center(
            child: Icon(
              Icons.refresh_rounded,
              size: 22,
              color: Color(0xFF121212),
            ),
          ),
        ),
      ),
    );
  }
}
