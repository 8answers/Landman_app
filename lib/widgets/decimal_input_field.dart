import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// A custom TextField widget that displays ".00" as a grey placeholder suffix while typing
/// This gives users visual feedback that decimal input is expected
class DecimalInputField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onEditingComplete;
  final VoidCallback? onTap;
  final VoidCallback? onTapOutside;
  final TextStyle? style;
  final TextStyle? hintStyle;
  final String? suffix;
  final TextStyle? suffixStyle;
  final EdgeInsets? contentPadding;
  final bool isDense;
  final int decimalPlaces;
  final TextAlign textAlign;
  final TextInputAction textInputAction;
  final ScrollPhysics? scrollPhysics;

  const DecimalInputField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText = '0',
    this.keyboardType = TextInputType.number,
    this.inputFormatters,
    this.onChanged,
    this.onEditingComplete,
    this.onTap,
    this.onTapOutside,
    this.style,
    this.hintStyle,
    this.suffix,
    this.suffixStyle,
    this.contentPadding,
    this.isDense = true,
    this.decimalPlaces = 2,
    this.textAlign = TextAlign.left,
    this.textInputAction = TextInputAction.next,
    this.scrollPhysics,
  });

  @override
  State<DecimalInputField> createState() => _DecimalInputFieldState();
}

class _DecimalInputFieldState extends State<DecimalInputField> {
  late FocusNode _internalFocusNode;
  late TextEditingController _displayController;
  late bool _ownsInternalFocusNode;
  bool _hasFocus = false;
  bool _isUpdatingController = false;
  bool _skipFocusLossEditingCompleteOnce = false;

  @override
  void initState() {
    super.initState();
    _ownsInternalFocusNode = widget.focusNode == null;
    _internalFocusNode = widget.focusNode ?? FocusNode();
    _internalFocusNode.addListener(_handleFocusChange);
    widget.controller.addListener(_handleTextChange);

    // Create a display controller that syncs with the original (full text)
    _displayController = TextEditingController(text: widget.controller.text);
    _displayController.addListener(_handleDisplayTextChange);
  }

  @override
  void didUpdateWidget(covariant DecimalInputField oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleTextChange);
      widget.controller.addListener(_handleTextChange);
      _updateDisplayController();
    }

    if (oldWidget.focusNode != widget.focusNode) {
      _internalFocusNode.removeListener(_handleFocusChange);
      if (_ownsInternalFocusNode) {
        _internalFocusNode.dispose();
      }
      _ownsInternalFocusNode = widget.focusNode == null;
      _internalFocusNode = widget.focusNode ?? FocusNode();
      _internalFocusNode.addListener(_handleFocusChange);
      _hasFocus = _internalFocusNode.hasFocus;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleTextChange);
    _internalFocusNode.removeListener(_handleFocusChange);
    _displayController.removeListener(_handleDisplayTextChange);
    _displayController.dispose();
    if (_ownsInternalFocusNode) {
      _internalFocusNode.dispose();
    }
    super.dispose();
  }

  void _handleFocusChange() {
    if (!mounted) return;
    final hadFocus = _hasFocus;
    setState(() {
      _hasFocus = _internalFocusNode.hasFocus;
      _updateDisplayController();

      // When focus is gained, position cursor appropriately
      if (_hasFocus) {
        final text = _displayController.text;
        // Position cursor at the end of the text
        final cursorPosition = text.length;
        _displayController.selection =
            TextSelection.collapsed(offset: cursorPosition);
        // Request focus to ensure cursor is visible
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_internalFocusNode.hasFocus) {
            _displayController.selection =
                TextSelection.collapsed(offset: cursorPosition);
          }
        });
      }
      // When focus is lost, trigger onEditingComplete (acts like pressing Enter)
      else if (hadFocus && !_hasFocus) {
        if (_skipFocusLossEditingCompleteOnce) {
          _skipFocusLossEditingCompleteOnce = false;
          return;
        }
        widget.onEditingComplete?.call();
      }
    });
  }

  void _handleTextChange() {
    if (!_isUpdatingController) {
      setState(() {
        _updateDisplayController();
      });
    }
  }

  void _handleDisplayTextChange() {
    if (!_isUpdatingController) {
      _isUpdatingController = true;
      String displayText = _displayController.text;

      // If user typed decimal digits, limit to 2 decimal places
      if (displayText.contains('.')) {
        final parts = displayText.split('.');
        final integerPart = parts[0];
        final decimalDigits = parts.length > 1 ? parts[1] : '';

        // Limit to specified decimal places
        final limitedDecimalDigits = decimalDigits.length > widget.decimalPlaces
            ? decimalDigits.substring(0, widget.decimalPlaces)
            : decimalDigits;
        final fullText = integerPart + '.' + limitedDecimalDigits;

        // Update widget controller with the full text
        widget.controller.text = fullText;
        widget.onChanged?.call(fullText);

        // If we had to truncate, update the display controller
        if (decimalDigits.length > widget.decimalPlaces) {
          final currentSelection = _displayController.selection;
          _displayController.value = TextEditingValue(
            text: fullText,
            selection: TextSelection.collapsed(
              offset: currentSelection.baseOffset <= fullText.length
                  ? currentSelection.baseOffset
                  : fullText.length,
            ),
          );
        }
      } else {
        // No decimal point, just update normally
        widget.controller.text = displayText;
        widget.onChanged?.call(displayText);
      }

      _isUpdatingController = false;
    }
  }

  void _updateDisplayController() {
    if (!_isUpdatingController) {
      _isUpdatingController = true;
      final fullText = widget.controller.text;
      final selection = _displayController.selection;

      if (_displayController.text != fullText) {
        _displayController.value = TextEditingValue(
          text: fullText,
          selection: selection.baseOffset <= fullText.length
              ? selection
              : TextSelection.collapsed(offset: fullText.length),
        );
      }
      _isUpdatingController = false;
    }
  }

  String _getDisplayDecimalSuffix() {
    final text = widget.controller.text;

    // Don't show suffix if field is empty OR doesn't contain a decimal point
    if (text.isEmpty || !text.contains('.')) {
      return '';
    }

    // Check if text contains a decimal point
    if (text.contains('.')) {
      final parts = text.split('.');
      if (parts.length == 2) {
        final decimalPart = parts[1];

        // If decimal part is empty (user just typed "."), show zeros in grey while focused
        if (decimalPart.isEmpty && _hasFocus) {
          return '0' * widget.decimalPlaces;
        }
      }
    }

    // Don't show grey suffix if user has typed actual decimal digits
    return '';
  }

  bool _isZeroValue(String text) {
    if (text.isEmpty) return false;
    // Remove commas and spaces for checking
    final cleaned = text.replaceAll(',', '').replaceAll(' ', '').trim();
    if (cleaned.isEmpty) return false;
    // Check if it's "0", "0.0", "0.00", etc.
    final numValue = double.tryParse(cleaned);
    return numValue != null && numValue == 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final decimalSuffix = _getDisplayDecimalSuffix();
    final text = widget.controller.text;
    // Calculate what to show in TextField vs overlay
    // Show all actual typed text in black (integer + decimal point + typed decimal digits)
    // Only show grey placeholder zeros when user just typed "." with no digits after
    final displayText = text;
    // Check if the value is zero - if so, display in grey like a placeholder
    final isZero = _isZeroValue(text);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // The actual TextField - decimal digits will be transparent
        TextField(
          controller: _displayController,
          focusNode: _internalFocusNode,
          keyboardType: widget.keyboardType,
          textAlignVertical: TextAlignVertical.center,
          scrollPhysics: widget.scrollPhysics,
          textAlign: widget.textAlign,
          showCursor: true,
          cursorColor: Colors.black,
          textInputAction: widget.textInputAction,
          inputFormatters: widget.inputFormatters,
          onTap: () {
            // Ensure cursor is visible on tap
            widget.onTap?.call();
            // Request focus and position cursor
            if (!_internalFocusNode.hasFocus) {
              _internalFocusNode.requestFocus();
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (_internalFocusNode.hasFocus) {
                final text = _displayController.text;
                final cursorPosition = text.length;
                _displayController.selection =
                    TextSelection.collapsed(offset: cursorPosition);
              }
            });
          },
          onTapOutside: (event) {
            // Let parent decide outside-tap behavior; forced unfocus here can
            // steal first-click cursor in dense table layouts.
            widget.onTapOutside?.call();
          },
          onChanged: (value) {
            // Handled by _handleDisplayTextChange listener
          },
          onEditingComplete: () {
            if (_skipFocusLossEditingCompleteOnce) return;
            widget.onEditingComplete?.call();
          },
          onSubmitted: (value) {
            // Let caller-defined onEditingComplete fully control submit focus.
            // This avoids hidden traversal/unfocus side effects in table cells.
            _skipFocusLossEditingCompleteOnce = true;
            widget.onEditingComplete?.call();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _skipFocusLossEditingCompleteOnce = false;
            });
          },
          decoration: InputDecoration(
            hintText: widget.hintText,
            hintStyle: widget.hintStyle ??
                GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color.fromARGB(191, 173, 173, 173),
                ),
            border: InputBorder.none,
            contentPadding: widget.contentPadding ?? EdgeInsets.zero,
            isDense: widget.isDense,
          ),
          style: widget.style ??
              GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                // Show text in black while typing
                color: Colors.black,
              ),
        ),
        // Removed overlay text - now showing text directly in TextField
        // Removed decimal suffix overlay - showing text directly in TextField
      ],
    );
  }
}
