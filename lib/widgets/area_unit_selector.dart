import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/area_unit_utils.dart';

const List<String> _allAreaUnitOptions = [
  'Square Feet (sqft)',
  'Square Meter (sqm)'
];
const double _areaUnitDropdownWidth = 180;
const double _areaUnitMenuWidth = 180;
const double _areaUnitTriggerHeight = 28;
const double _areaUnitMenuItemHeight = 24;

class AreaUnitDisplay extends StatelessWidget {
  final String unitLabel;

  const AreaUnitDisplay({
    super.key,
    this.unitLabel = AreaUnitUtils.sqmUnitLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      alignment: Alignment.centerLeft,
      child: Text(
        'Project Area Unit: ${AreaUnitUtils.canonicalizeAreaUnit(unitLabel)}',
        style: GoogleFonts.inter(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: Colors.black,
        ),
      ),
    );
  }
}

class AreaUnitSelector extends StatefulWidget {
  final String selectedUnit;
  final String? projectId;
  final ValueChanged<String> onUnitChanged;

  const AreaUnitSelector({
    super.key,
    required this.selectedUnit,
    required this.onUnitChanged,
    this.projectId,
  });

  @override
  State<AreaUnitSelector> createState() => _AreaUnitSelectorState();
}

class _AreaUnitSelectorState extends State<AreaUnitSelector> {
  final GlobalKey _triggerKey = GlobalKey();
  OverlayEntry? _dropdownEntry;
  OverlayEntry? _backdropEntry;

  List<String> get _visibleAreaUnitOptions => _allAreaUnitOptions
      .where((option) => option == AreaUnitUtils.sqmUnitLabel)
      .toList();

  String _canonicalUnitLabel(String unit) {
    return AreaUnitUtils.canonicalizeAreaUnit(unit);
  }

  void _closeDropdown() {
    _dropdownEntry?.remove();
    _backdropEntry?.remove();
    _dropdownEntry = null;
    _backdropEntry = null;
  }

  void _showDropdown(BuildContext context) {
    _closeDropdown();
    final selectedUnit = _canonicalUnitLabel(widget.selectedUnit);
    final RenderBox? renderBox =
        _triggerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final overlayBox = overlay.context.findRenderObject() as RenderBox;
    final topLeft = renderBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final topRight = renderBox.localToGlobal(
      Offset(renderBox.size.width, 0),
      ancestor: overlayBox,
    );
    final bottomLeft = renderBox.localToGlobal(
      Offset(0, renderBox.size.height),
      ancestor: overlayBox,
    );
    final menuWidth = (topRight.dx - topLeft.dx).abs();
    final left = topRight.dx - menuWidth;
    final top = bottomLeft.dy + 8;
    const double menuPadding = 4;
    final menuHeight = (menuPadding * 2) +
        (_visibleAreaUnitOptions.length * _areaUnitMenuItemHeight) +
        ((_visibleAreaUnitOptions.length - 1) * 8);

    _backdropEntry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: GestureDetector(
          onTap: _closeDropdown,
          child: Container(color: Colors.transparent),
        ),
      ),
    );

    _dropdownEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: left,
        top: top,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: menuWidth,
            height: menuHeight,
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 2,
                  offset: const Offset(0, 0),
                  spreadRadius: 0,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(menuPadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children:
                    _visibleAreaUnitOptions.asMap().entries.expand((entry) {
                  final isFirst = entry.key == 0;
                  final option = entry.value;
                  final isSelected = option == selectedUnit;
                  return [
                    if (!isFirst) const SizedBox(height: 8),
                    GestureDetector(
                      onTap: () async {
                        if (option != selectedUnit) {
                          widget.onUnitChanged(option);
                        }
                        _closeDropdown();
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: double.infinity,
                        height: _areaUnitMenuItemHeight,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFFECF6FD)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.25),
                              blurRadius: 2,
                              offset: const Offset(0, 0),
                              spreadRadius: 0,
                            ),
                          ],
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              option,
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.normal,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ];
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(_backdropEntry!);
    overlay.insert(_dropdownEntry!);
  }

  @override
  void dispose() {
    _closeDropdown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedUnit = _canonicalUnitLabel(widget.selectedUnit);
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 2,
            offset: const Offset(0, 0),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'Project Area Unit:',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.black,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            key: _triggerKey,
            width: _areaUnitDropdownWidth,
            height: _areaUnitTriggerHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 2,
                  offset: const Offset(0, 0),
                  spreadRadius: 0,
                ),
              ],
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  selectedUnit,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                  maxLines: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
