import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/project_storage_service.dart';
import '../services/area_unit_service.dart';
import '../utils/area_unit_utils.dart';

class SettingsPage extends StatefulWidget {
  final String? projectId;
  final VoidCallback? onProjectDeleted;

  const SettingsPage({
    super.key,
    this.projectId,
    this.onProjectDeleted,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const double _projectBaseUnitDropdownWidth = 186;
  String _projectBaseUnitArea = AreaUnitService.defaultUnit;
  static const List<String> _allProjectBaseUnitAreaOptions = <String>[
    'Square Feet (sqft)',
    'Square Meter (sqm)',
  ];
  bool _isDropdownOpen = false;
  OverlayEntry? _overlayEntry;
  OverlayEntry? _deleteDialogOverlay;
  final GlobalKey _projectBaseUnitDropdownKey = GlobalKey();
  final TextEditingController _deleteConfirmController =
      TextEditingController();
  final FocusNode _deleteConfirmFocusNode = FocusNode();

  List<String> get _projectBaseUnitAreaOptions => _allProjectBaseUnitAreaOptions
      .where((option) => option == AreaUnitUtils.sqmUnitLabel)
      .toList();

  @override
  void initState() {
    super.initState();
    _loadProjectBaseUnitArea();
  }

  @override
  void dispose() {
    _removeOverlay();
    _removeDeleteDialog();
    _deleteConfirmController.dispose();
    _deleteConfirmFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadProjectBaseUnitArea() async {
    try {
      String? resolvedUnit;
      final projectId = widget.projectId;
      if (projectId != null && projectId.isNotEmpty) {
        final row = await Supabase.instance.client
            .from('projects')
            .select('area_unit')
            .eq('id', projectId)
            .maybeSingle();
        final dbUnit = (row?['area_unit'] ?? '').toString().trim();
        if (dbUnit.isNotEmpty) {
          resolvedUnit = AreaUnitUtils.canonicalizeAreaUnit(dbUnit);
          await AreaUnitService.setAreaUnit(projectId, resolvedUnit);
          if (resolvedUnit != dbUnit) {
            await ProjectStorageService.saveProjectData(
              projectId: projectId,
              projectAreaUnit: resolvedUnit,
            );
          }
        }
      }
      resolvedUnit ??= await AreaUnitService.getAreaUnit(widget.projectId);
      if (mounted && resolvedUnit.isNotEmpty) {
        setState(() {
          _projectBaseUnitArea = resolvedUnit!;
        });
      }
    } catch (e) {
      print('SettingsPage: failed to load project area unit: $e');
    }
  }

  Future<void> _saveProjectBaseUnitArea() async {
    try {
      await AreaUnitService.setAreaUnit(widget.projectId, _projectBaseUnitArea);
      final projectId = widget.projectId;
      if (projectId != null && projectId.isNotEmpty) {
        await ProjectStorageService.saveProjectData(
          projectId: projectId,
          projectAreaUnit: _projectBaseUnitArea,
        );
      }
    } catch (e) {
      print('SettingsPage: failed to save project area unit: $e');
    }
  }

  void _removeDeleteDialog() {
    _deleteDialogOverlay?.remove();
    _deleteDialogOverlay = null;
    _deleteConfirmController.clear();
    _deleteConfirmFocusNode.unfocus();
  }

  void _showDeleteDialog() {
    _deleteConfirmFocusNode.addListener(() {
      setState(() {}); // Rebuild to update box shadow
    });
    _deleteDialogOverlay = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // Semi-transparent black background
          Positioned.fill(
            child: GestureDetector(
              onTap: _removeDeleteDialog,
              child: Container(
                color: Colors.black.withOpacity(0.5),
              ),
            ),
          ),
          // Dialog centered at top
          Positioned(
            top: 24,
            left: MediaQuery.of(context).size.width / 2 -
                269, // Center (538/2 = 269)
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 538,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F9FA),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header with warning icon and close button
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.warning,
                              color: Colors.red,
                              size: 24,
                            ),
                            const SizedBox(width: 16),
                            Text(
                              'Delete Project?',
                              style: GoogleFonts.inter(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: Colors.black,
                              ),
                            ),
                          ],
                        ),
                        GestureDetector(
                          onTap: _removeDeleteDialog,
                          child: Transform.rotate(
                            angle: 0.785398, // 45 degrees
                            child: const Icon(
                              Icons.add,
                              size: 24,
                              color: Color(0xFF0C8CE9),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Warning message
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        RichText(
                          text: TextSpan(
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.normal,
                              color: Colors.black.withOpacity(0.8),
                            ),
                            children: const [
                              TextSpan(
                                  text: 'This will permanently delete the '),
                              TextSpan(text: 'project and all associated data'),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'This action cannot be undone.',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.normal,
                            color: Colors.black.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Confirmation input
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        RichText(
                          text: TextSpan(
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: const Color(0xFF323232),
                            ),
                            children: [
                              const TextSpan(
                                text: 'Type ',
                                style: TextStyle(fontWeight: FontWeight.normal),
                              ),
                              const TextSpan(
                                text: 'delete ',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              const TextSpan(
                                text: 'to confirm.',
                                style: TextStyle(fontWeight: FontWeight.normal),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: 150,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: _deleteConfirmFocusNode.hasFocus
                                    ? const Color(0xFF0C8CE9)
                                    : const Color(0xFFFF0000),
                                blurRadius: 2,
                                spreadRadius: 0,
                                offset: const Offset(0, 0),
                              ),
                            ],
                          ),
                          child: TextField(
                            controller: _deleteConfirmController,
                            focusNode: _deleteConfirmFocusNode,
                            textAlignVertical: TextAlignVertical.center,
                            onChanged: (value) {
                              setState(() {}); // Rebuild to update button state
                            },
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.only(
                                  left: 8, right: 8, top: 8, bottom: 16),
                            ),
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Action buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Cancel button
                        GestureDetector(
                          onTap: _removeDeleteDialog,
                          child: Container(
                            height: 44,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.25),
                                  blurRadius: 2,
                                  offset: const Offset(0, 0),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                'Cancel',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.normal,
                                  color: const Color(0xFF0C8CE9),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Delete button
                        GestureDetector(
                          onTap: () async {
                            if (_deleteConfirmController.text.toLowerCase() ==
                                'delete') {
                              if (widget.projectId != null) {
                                try {
                                  await ProjectStorageService.deleteProject(
                                      widget.projectId!);
                                  _removeDeleteDialog();
                                  // Notify parent that project was deleted
                                  if (widget.onProjectDeleted != null) {
                                    widget.onProjectDeleted!();
                                  }
                                } catch (e) {
                                  print('Error deleting project: $e');
                                  // Show error message
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                            'Failed to delete project: $e'),
                                        backgroundColor: Colors.red,
                                      ),
                                    );
                                  }
                                }
                              }
                            }
                          },
                          child: Container(
                            height: 44,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.25),
                                  blurRadius: 2,
                                  offset: const Offset(0, 0),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                Text(
                                  'Delete Project',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: _deleteConfirmController.text
                                                .toLowerCase() ==
                                            'delete'
                                        ? Colors.red
                                        : Colors.red.withOpacity(0.5),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SvgPicture.asset(
                                  'assets/images/Delete_layout.svg',
                                  width: 13,
                                  height: 16,
                                  colorFilter: ColorFilter.mode(
                                    _deleteConfirmController.text
                                                .toLowerCase() ==
                                            'delete'
                                        ? Colors.red
                                        : Colors.red.withOpacity(0.5),
                                    BlendMode.srcIn,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_deleteDialogOverlay!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _isDropdownOpen = false;
  }

  void _toggleDropdown(BuildContext context) {
    if (_isDropdownOpen) {
      _removeOverlay();
    } else {
      _showDropdown(context);
    }
  }

  void _showDropdown(BuildContext context) {
    final RenderBox? renderBox = _projectBaseUnitDropdownKey.currentContext
        ?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final optionChipWidth = _getBaseUnitOptionChipWidth(context);
    final dropdownWidth = optionChipWidth + 8;

    _overlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          // Invisible barrier to detect outside clicks
          Positioned.fill(
            child: GestureDetector(
              onTap: _removeOverlay,
              behavior: HitTestBehavior.translucent,
            ),
          ),
          // Dropdown menu
          Positioned(
            left: offset.dx,
            top: offset.dy + size.height,
            child: Material(
              color: Colors.transparent,
              child: SizedBox(
                width: dropdownWidth,
                child: Container(
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
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _projectBaseUnitAreaOptions
                          .asMap()
                          .entries
                          .expand((entry) {
                        final isFirst = entry.key == 0;
                        return [
                          if (!isFirst) const SizedBox(height: 8),
                          _buildDropdownItem(entry.value, optionChipWidth),
                        ];
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
    setState(() => _isDropdownOpen = true);
  }

  double _getBaseUnitOptionChipWidth(BuildContext context) {
    final textStyle = GoogleFonts.inter(
      fontSize: 11,
      fontWeight: FontWeight.normal,
      color: Colors.black,
    );
    double maxLabelWidth = 0;
    for (final option in _projectBaseUnitAreaOptions) {
      final textPainter = TextPainter(
        text: TextSpan(text: option, style: textStyle),
        maxLines: 1,
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      if (textPainter.width > maxLabelWidth) {
        maxLabelWidth = textPainter.width;
      }
    }
    // Add a bit of extra width so option chips are slightly wider than text.
    return maxLabelWidth + 38;
  }

  Widget _buildDropdownItem(String option, double optionWidth) {
    final isSelected = option == _projectBaseUnitArea;
    final textStyle = GoogleFonts.inter(
      fontSize: 11,
      fontWeight: FontWeight.normal,
      color: Colors.black,
    );

    return GestureDetector(
      onTap: () {
        setState(() {
          _projectBaseUnitArea = option;
        });
        _saveProjectBaseUnitArea();
        _removeOverlay();
      },
      child: SizedBox(
        width: optionWidth,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFECF6FD) : Colors.white,
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
            child: Text(
              option,
              style: textStyle,
              maxLines: 1,
              softWrap: false,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header section
        Padding(
          padding: const EdgeInsets.only(
            top: 24,
            left: 24,
            right: 24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Project Settings',
                style: GoogleFonts.inter(
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Manage project configuration',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.normal,
                  color: Colors.black.withOpacity(0.8),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        // Tabs section
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Color(0xFF5C5C5C),
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            children: [
              // General tab (active)
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
                    'General',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFF0C8CE9),
                      height: 1.43,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 40),
        // Content section
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Project section
              Container(
                width: 617,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F9FA),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Project',
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Update the operational status of this project.',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Project Base Unit Area: ${AreaUnitUtils.sqmUnitLabel}',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),
              // Delete Project section
              Container(
                width: 617,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8F9FA),
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Delete Project',
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Permanently remove this project and all associated data. This action cannot be undone.',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Delete button
                    GestureDetector(
                      onTap: _showDeleteDialog,
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.25),
                              blurRadius: 2,
                              offset: const Offset(0, 0),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Delete Project',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.normal,
                                color: Colors.red,
                              ),
                            ),
                            const SizedBox(width: 8),
                            SvgPicture.asset(
                              'assets/images/Delete_layout.svg',
                              width: 13,
                              height: 16,
                            ),
                          ],
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
}
