import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../widgets/app_scale_metrics.dart';

class AllProjectsPage extends StatefulWidget {
  final VoidCallback? onCreateProject;
  final Function(String projectId, String projectName)? onProjectSelected;

  const AllProjectsPage({
    super.key,
    this.onCreateProject,
    this.onProjectSelected,
  });

  @override
  State<AllProjectsPage> createState() => _AllProjectsPageState();
}

class _AllProjectsPageState extends State<AllProjectsPage> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _projectsScrollController = ScrollController();
  final SupabaseClient _supabase = Supabase.instance.client;
  StreamSubscription<AuthState>? _authStateSubscription;
  List<Map<String, dynamic>> _projects = [];
  List<Map<String, dynamic>> _filteredProjects = [];
  bool _isLoading = true;
  String _searchQuery = '';
  int? _hoveredIndex; // Track which project row is being hovered
  String _selectedSort = 'Alphabetical order';
  bool _isFilterMenuOpen = false;

  @override
  void initState() {
    super.initState();
    _selectedSort = 'Alphabetical order';
    _searchController.addListener(_onSearchChanged);
    _authStateSubscription = _supabase.auth.onAuthStateChange.listen((event) {
      if (!mounted) return;
      _loadProjects();
    });
    _loadProjects();
  }

  @override
  void dispose() {
    _authStateSubscription?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _projectsScrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
      _filterProjects();
    });
  }

  void _filterProjects() {
    if (_searchQuery.isEmpty) {
      _filteredProjects = List.from(_projects);
    } else {
      _filteredProjects = _projects.where((project) {
        final name = (project['project_name'] ?? '').toString().toLowerCase();
        return name.contains(_searchQuery);
      }).toList();
    }
    _applySort();
  }

  void _applySort() {
    int sortByDateField(
        Map<String, dynamic> a, Map<String, dynamic> b, String field) {
      final aStr = a[field] as String?;
      final bStr = b[field] as String?;
      DateTime? aDate;
      DateTime? bDate;
      if (aStr != null) {
        try {
          aDate = DateTime.parse(aStr);
        } catch (_) {}
      }
      if (bStr != null) {
        try {
          bDate = DateTime.parse(bStr);
        } catch (_) {}
      }
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return bDate.compareTo(aDate);
    }

    if (_selectedSort == 'Last modified') {
      _filteredProjects.sort((a, b) => sortByDateField(a, b, 'updated_at'));
      return;
    }
    if (_selectedSort == 'Date created') {
      _filteredProjects.sort((a, b) => sortByDateField(a, b, 'created_at'));
      return;
    }
    _filteredProjects.sort((a, b) {
      final aName = (a['project_name'] ?? '').toString().toLowerCase();
      final bName = (b['project_name'] ?? '').toString().toLowerCase();
      return aName.compareTo(bName);
    });
  }

  Future<void> _loadProjects() async {
    try {
      setState(() {
        _isLoading = true;
      });

      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        setState(() {
          _isLoading = false;
          _projects = [];
          _filteredProjects = [];
        });
        return;
      }

      final response =
          await _supabase.from('projects').select().eq('user_id', userId);

      setState(() {
        _selectedSort = 'Alphabetical order';
        _projects = List<Map<String, dynamic>>.from(response);
        _filterProjects();
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading projects: $e');
      setState(() {
        _isLoading = false;
        _projects = [];
        _filteredProjects = [];
      });
    }
  }

  String _formatDate(DateTime dateTime) {
    return DateFormat('d MMM yyyy').format(dateTime);
  }

  String _formatRelativeTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    if (difference.inHours < 24) {
      return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
    }
    if (difference.inDays < 30) {
      return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
    }
    if (difference.inDays < 365) {
      final months = (difference.inDays / 30).floor();
      return '$months month${months > 1 ? 's' : ''} ago';
    }
    final years = (difference.inDays / 365).floor();
    return '$years year${years > 1 ? 's' : ''} ago';
  }

  Widget _skeletonBlock({required double width, required double height}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFE3E7EB),
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  Widget _buildAllProjectsLoadingSkeleton() {
    return Padding(
      padding: const EdgeInsets.only(left: 24, right: 24),
      child: Container(
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
            Row(
              children: [
                _skeletonBlock(width: 220, height: 20),
                const Spacer(),
                _skeletonBlock(width: 120, height: 20),
                const SizedBox(width: 24),
                _skeletonBlock(width: 100, height: 20),
              ],
            ),
            const SizedBox(height: 16),
            ...List.generate(
              8,
              (index) => Padding(
                padding: EdgeInsets.only(bottom: index == 7 ? 0 : 12),
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      _skeletonBlock(width: 220, height: 18),
                      const Spacer(),
                      _skeletonBlock(width: 120, height: 18),
                      const SizedBox(width: 24),
                      _skeletonBlock(width: 100, height: 18),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteProject(String projectId) async {
    try {
      await _supabase.from('projects').delete().eq('id', projectId);
      await _loadProjects();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Project deleted')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete project: $e')),
      );
    }
  }

  Future<void> _showDeleteProjectDialog(String projectId) async {
    final confirmController = TextEditingController();
    final confirmFocusNode = FocusNode();

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final canDelete =
                confirmController.text.trim().toLowerCase() == 'delete';

            confirmFocusNode.addListener(() => setDialogState(() {}));

            return Material(
              color: Colors.transparent,
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.only(top: 24),
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
                            onTap: () => Navigator.of(dialogContext).pop(),
                            child: Transform.rotate(
                              angle: 0.785398,
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
                      RichText(
                        text: TextSpan(
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.normal,
                            color: Colors.black.withOpacity(0.8),
                          ),
                          children: const [
                            TextSpan(text: 'This will permanently delete the '),
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
                      const SizedBox(height: 24),
                      RichText(
                        text: TextSpan(
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            color: const Color(0xFF323232),
                          ),
                          children: const [
                            TextSpan(
                              text: 'Type ',
                              style: TextStyle(fontWeight: FontWeight.normal),
                            ),
                            TextSpan(
                              text: 'delete ',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            TextSpan(
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
                              color: confirmFocusNode.hasFocus
                                  ? const Color(0xFF0C8CE9)
                                  : const Color(0xFFFF0000),
                              blurRadius: 2,
                              offset: const Offset(0, 0),
                            ),
                          ],
                        ),
                        child: TextField(
                          controller: confirmController,
                          focusNode: confirmFocusNode,
                          textAlignVertical: TextAlignVertical.center,
                          onChanged: (_) => setDialogState(() {}),
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
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          GestureDetector(
                            onTap: () => Navigator.of(dialogContext).pop(),
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
                          GestureDetector(
                            onTap: () async {
                              if (canDelete) {
                                Navigator.of(dialogContext).pop();
                                await _deleteProject(projectId);
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
                                      color: canDelete
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
                                      canDelete
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
            );
          },
        );
      },
    );

    confirmFocusNode.dispose();
    confirmController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final scaleMetrics = AppScaleMetrics.of(context);
    final designViewportWidth =
        scaleMetrics?.designViewportWidth ?? screenWidth;
    final extraRightWidth = designViewportWidth > screenWidth
        ? (designViewportWidth - screenWidth)
        : 0.0;
    final isMobile = screenWidth < 768;

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
                'All Projects',
                style: GoogleFonts.inter(
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "View and manage all projects created",
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.normal,
                  color: Colors.black.withOpacity(0.8),
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        // Action buttons row + stretched divider on wider screens
        Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: -extraRightWidth,
              bottom: 0,
              child: Container(
                height: 0.5,
                color: const Color(0xFF5C5C5C),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 24, right: 24, bottom: 16),
              child: isMobile
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Create new project button
                        GestureDetector(
                          onTap: widget.onCreateProject,
                          child: Container(
                            height: 36,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 0,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0C8CE9),
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
                              children: [
                                Text(
                                  'Create new project',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SvgPicture.asset(
                                  'assets/images/Cretae_new_projet_white.svg',
                                  width: 13,
                                  height: 13,
                                  fit: BoxFit.contain,
                                  placeholderBuilder: (context) =>
                                      const SizedBox(
                                    width: 13,
                                    height: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Theme(
                          data: Theme.of(context).copyWith(
                            hoverColor: const Color(0xFFF1F1F1),
                            highlightColor: const Color(0xFFF1F1F1),
                            splashColor: Colors.transparent,
                          ),
                          child: PopupMenuButton<String>(
                            tooltip: '',
                            color: const Color(0xFFF8F9FA),
                            surfaceTintColor: Colors.transparent,
                            constraints: const BoxConstraints.tightFor(
                                width: 164, height: 144),
                            menuPadding:
                                const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            shadowColor: const Color.fromRGBO(0, 0, 0, 0.25),
                            elevation: 2,
                            offset: const Offset(0, 44),
                            onOpened: () =>
                                setState(() => _isFilterMenuOpen = true),
                            onCanceled: () =>
                                setState(() => _isFilterMenuOpen = false),
                            onSelected: (value) {
                              setState(() {
                                _selectedSort = value;
                                _isFilterMenuOpen = false;
                                _filterProjects();
                              });
                            },
                            itemBuilder: (context) => [
                              _buildFilterMenuItem('Alphabetical order',
                                  addBottomGap: true),
                              _buildFilterMenuItem('Last modified',
                                  addBottomGap: true),
                              _buildFilterMenuItem('Date created'),
                            ],
                            child: _buildFilterButton(
                                isActive: _isFilterHighlighted),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Search bar
                        Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(32),
                            border: Border.all(
                              color: const Color(0xFF5C5C5C),
                              width: 0.5,
                            ),
                          ),
                          child: Row(
                            children: [
                              SvgPicture.asset(
                                'assets/images/Search_projects.svg',
                                width: 16,
                                height: 16,
                                fit: BoxFit.contain,
                                placeholderBuilder: (context) => const SizedBox(
                                  width: 16,
                                  height: 16,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: SizedBox(
                                  height: 20,
                                  child: TextField(
                                    controller: _searchController,
                                    textAlignVertical: TextAlignVertical.center,
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: Colors.black.withOpacity(0.8),
                                      height: 1.0,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: 'Search Documents',
                                      hintStyle: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.normal,
                                        color: Colors.black.withOpacity(0.5),
                                        height: 1.0,
                                      ),
                                      border: InputBorder.none,
                                      isDense: true,
                                      isCollapsed: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        // Create new project button
                        GestureDetector(
                          onTap: widget.onCreateProject,
                          child: Container(
                            height: 36,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0C8CE9),
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
                              children: [
                                Text(
                                  'Create new project',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SvgPicture.asset(
                                  'assets/images/Cretae_new_projet_white.svg',
                                  width: 13,
                                  height: 13,
                                  fit: BoxFit.contain,
                                  placeholderBuilder: (context) =>
                                      const SizedBox(
                                    width: 13,
                                    height: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Theme(
                          data: Theme.of(context).copyWith(
                            hoverColor: const Color(0xFFF1F1F1),
                            highlightColor: const Color(0xFFF1F1F1),
                            splashColor: Colors.transparent,
                          ),
                          child: PopupMenuButton<String>(
                            tooltip: '',
                            color: const Color(0xFFF8F9FA),
                            surfaceTintColor: Colors.transparent,
                            constraints: const BoxConstraints.tightFor(
                                width: 164, height: 144),
                            menuPadding:
                                const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            shadowColor: const Color.fromRGBO(0, 0, 0, 0.25),
                            elevation: 2,
                            offset: const Offset(0, 44),
                            onOpened: () =>
                                setState(() => _isFilterMenuOpen = true),
                            onCanceled: () =>
                                setState(() => _isFilterMenuOpen = false),
                            onSelected: (value) {
                              setState(() {
                                _selectedSort = value;
                                _isFilterMenuOpen = false;
                                _filterProjects();
                              });
                            },
                            itemBuilder: (context) => [
                              _buildFilterMenuItem('Alphabetical order',
                                  addBottomGap: true),
                              _buildFilterMenuItem('Last modified',
                                  addBottomGap: true),
                              _buildFilterMenuItem('Date created'),
                            ],
                            child: _buildFilterButton(
                                isActive: _isFilterHighlighted),
                          ),
                        ),
                        const SizedBox(width: 16),
                        // Search bar
                        Expanded(
                          child: Container(
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(32),
                              border: Border.all(
                                color: const Color(0xFF5C5C5C),
                                width: 0.5,
                              ),
                            ),
                            child: Row(
                              children: [
                                SvgPicture.asset(
                                  'assets/images/Search_projects.svg',
                                  width: 16,
                                  height: 16,
                                  fit: BoxFit.contain,
                                  placeholderBuilder: (context) =>
                                      const SizedBox(
                                    width: 16,
                                    height: 16,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: SizedBox(
                                    height: 20,
                                    child: TextField(
                                      controller: _searchController,
                                      textAlignVertical:
                                          TextAlignVertical.center,
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.normal,
                                        color: Colors.black.withOpacity(0.8),
                                        height: 1.0,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: 'Search Documents',
                                        hintStyle: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.normal,
                                          color: Colors.black.withOpacity(0.5),
                                          height: 1.0,
                                        ),
                                        border: InputBorder.none,
                                        isDense: true,
                                        isCollapsed: true,
                                        contentPadding: EdgeInsets.zero,
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
          ],
        ),
        const SizedBox(height: 24),
        // Projects list or empty state
        Expanded(
          child: _isLoading
              ? _buildAllProjectsLoadingSkeleton()
              : _filteredProjects.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(left: 24, right: 24),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Empty state icon
                            SvgPicture.asset(
                              'assets/images/Rcent_projects_folder.svg',
                              width: 108,
                              height: 80,
                              fit: BoxFit.contain,
                              placeholderBuilder: (context) => const SizedBox(
                                width: 108,
                                height: 80,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Text(
                              _searchQuery.isNotEmpty
                                  ? 'No projects found'
                                  : 'No projects yet',
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.normal,
                                color: Colors.black,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _searchQuery.isNotEmpty
                                  ? 'Try a different search term.'
                                  : 'Create your first project to get started.',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.normal,
                                color: const Color(0xFF5C5C5C),
                              ),
                              textAlign: TextAlign.center,
                            ),
                            if (_searchQuery.isEmpty) ...[
                              const SizedBox(height: 24),
                              // Create new project button (empty state)
                              GestureDetector(
                                onTap: widget.onCreateProject,
                                child: Container(
                                  height: 44,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 4,
                                  ),
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
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Create new project',
                                        style: GoogleFonts.inter(
                                          fontSize: 16,
                                          fontWeight: FontWeight.normal,
                                          color: const Color(0xFF0C8CE9),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      // Plus icon
                                      SvgPicture.asset(
                                        'assets/images/Create_new_project_blue.svg',
                                        width: 13,
                                        height: 13,
                                        fit: BoxFit.contain,
                                        placeholderBuilder: (context) =>
                                            const SizedBox(
                                          width: 13,
                                          height: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: _buildProjectsTable(extraRightWidth),
                    ),
        ),
      ],
    );
  }

  PopupMenuItem<String> _buildFilterMenuItem(String value,
      {bool addBottomGap = false}) {
    final isSelected = _selectedSort == value;
    const horizontalPadding = 16.0;
    const optionWidth = 149.0;
    const optionHeight = 36.0;

    Widget menuPill() {
      return Container(
        width: optionWidth,
        height: optionHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFECF6FD) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 2,
              offset: const Offset(0, 0),
            ),
          ],
        ),
        padding:
            EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 4),
        child: Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            fontStyle: FontStyle.normal,
            color: Colors.black,
          ),
          maxLines: 1,
          overflow: TextOverflow.visible,
          softWrap: false,
        ),
      );
    }

    return PopupMenuItem<String>(
      value: value,
      padding: EdgeInsets.zero,
      height: addBottomGap ? 46 : 36,
      child: Container(
        color: Colors.transparent,
        alignment: Alignment.topCenter,
        child: menuPill(),
      ),
    );
  }

  Widget _buildFilterButton({required bool isActive}) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: isActive ? const Color(0xFFECF6FD) : Colors.white,
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
          SvgPicture.asset(
            'assets/images/Filter.svg',
            width: 16,
            height: 10,
            fit: BoxFit.contain,
          ),
          const SizedBox(width: 8),
          Text(
            'Filter',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  bool get _isFilterHighlighted =>
      _isFilterMenuOpen || _selectedSort != 'Alphabetical order';

  Widget _buildProjectsTable(double extraRightWidth) {
    const nameColumnWidth = 562.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Table header
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              SizedBox(
                width: nameColumnWidth,
                child: Text(
                  'Project Name',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF5C5C5C),
                  ),
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final rightSectionWidth =
                        (constraints.maxWidth + extraRightWidth)
                            .clamp(452.0, double.infinity)
                            .toDouble();
                    return OverflowBox(
                      alignment: Alignment.centerLeft,
                      minWidth: rightSectionWidth,
                      maxWidth: rightSectionWidth,
                      child: SizedBox(
                        width: rightSectionWidth,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            SizedBox(
                              width: 180,
                              child: Text(
                                'Last modified',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: const Color(0xFF5C5C5C),
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: Text(
                                'Created',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: const Color(0xFF5C5C5C),
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(width: 52),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // Table rows
        Expanded(
          child: ScrollConfiguration(
            behavior:
                ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: ScrollbarTheme(
              data: ScrollbarThemeData(
                crossAxisMargin: 8,
                thumbColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.dragged)) {
                    return const Color(0xFF5C5C5C);
                  }
                  return const Color(0x665C5C5C);
                }),
              ),
              child: Scrollbar(
                controller: _projectsScrollController,
                thumbVisibility: true,
                trackVisibility: false,
                interactive: true,
                thickness: 8,
                radius: const Radius.circular(8),
                child: ListView.separated(
                  controller: _projectsScrollController,
                  itemCount: _filteredProjects.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 24),
                  itemBuilder: (context, index) {
                    final project = _filteredProjects[index];
                    final projectId = project['id'] as String;
                    final projectName =
                        (project['project_name'] ?? 'Unnamed') as String;
                    final createdAtStr = project['created_at'] as String?;
                    final updatedAtStr = project['updated_at'] as String?;
                    final isHovered = _hoveredIndex == index;

                    DateTime? createdAt;
                    DateTime? updatedAt;

                    try {
                      if (createdAtStr != null) {
                        createdAt = DateTime.parse(createdAtStr);
                      }
                      if (updatedAtStr != null) {
                        updatedAt = DateTime.parse(updatedAtStr);
                      }
                    } catch (e) {
                      print('Error parsing date: $e');
                    }

                    return MouseRegion(
                      onEnter: (_) {
                        setState(() {
                          _hoveredIndex = index;
                        });
                      },
                      onExit: (_) {
                        setState(() {
                          _hoveredIndex = null;
                        });
                      },
                      child: GestureDetector(
                        onTap: () {
                          widget.onProjectSelected
                              ?.call(projectId, projectName);
                        },
                        child: Container(
                          height: 56,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: isHovered
                                ? const Color(0xFFF1F1F1)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: nameColumnWidth,
                                child: Text(
                                  projectName,
                                  style: GoogleFonts.inter(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final rightSectionWidth =
                                        (constraints.maxWidth + extraRightWidth)
                                            .clamp(452.0, double.infinity)
                                            .toDouble();
                                    return OverflowBox(
                                      alignment: Alignment.centerLeft,
                                      minWidth: rightSectionWidth,
                                      maxWidth: rightSectionWidth,
                                      child: SizedBox(
                                        width: rightSectionWidth,
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            SizedBox(
                                              width: 180,
                                              child: Text(
                                                updatedAt != null
                                                    ? _formatRelativeTime(
                                                        updatedAt)
                                                    : 'N/A',
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.normal,
                                                  color:
                                                      const Color(0xFF5C5C5C),
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                            SizedBox(
                                              width: 180,
                                              child: Text(
                                                createdAt != null
                                                    ? _formatDate(createdAt)
                                                    : 'N/A',
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.normal,
                                                  color:
                                                      const Color(0xFF5C5C5C),
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                            PopupMenuButton<String>(
                                              tooltip: '',
                                              color: Colors.transparent,
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                      width: 165),
                                              menuPadding: EdgeInsets.zero,
                                              elevation: 0,
                                              shadowColor: Colors.transparent,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              offset: const Offset(0, 40),
                                              onSelected: (value) {
                                                if (value == 'delete') {
                                                  _showDeleteProjectDialog(
                                                      projectId);
                                                }
                                              },
                                              itemBuilder: (context) => [
                                                PopupMenuItem<String>(
                                                  value: 'delete',
                                                  height: 52,
                                                  padding: EdgeInsets.zero,
                                                  child: Container(
                                                    width: 165,
                                                    height: 52,
                                                    padding:
                                                        const EdgeInsets.all(8),
                                                    decoration: BoxDecoration(
                                                      color: const Color(
                                                          0xFFF8F9FA),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              8),
                                                      boxShadow: [
                                                        BoxShadow(
                                                          color: Colors.black
                                                              .withOpacity(0.5),
                                                          blurRadius: 2,
                                                          offset: const Offset(
                                                              0, 0),
                                                        ),
                                                      ],
                                                    ),
                                                    child: Container(
                                                      alignment:
                                                          Alignment.center,
                                                      decoration: BoxDecoration(
                                                        color: Colors.white,
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(8),
                                                        boxShadow: [
                                                          BoxShadow(
                                                            color: Colors.black
                                                                .withOpacity(
                                                                    0.5),
                                                            blurRadius: 2,
                                                            offset:
                                                                const Offset(
                                                                    0, 0),
                                                          ),
                                                        ],
                                                      ),
                                                      child: Text(
                                                        'Delete Project',
                                                        style:
                                                            GoogleFonts.inter(
                                                          fontSize: 14,
                                                          fontWeight:
                                                              FontWeight.normal,
                                                          color: Colors.red,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                              child: Container(
                                                width: 52,
                                                height: 36,
                                                decoration: BoxDecoration(
                                                  color: Colors.white,
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.black
                                                          .withOpacity(0.25),
                                                      blurRadius: 1,
                                                      offset:
                                                          const Offset(0, 0),
                                                    ),
                                                  ],
                                                ),
                                                alignment:
                                                    Alignment.centerRight,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 16,
                                                  vertical: 4,
                                                ),
                                                child: const Icon(
                                                  Icons.more_horiz,
                                                  size: 20,
                                                  color: Color(0xFF5C5C5C),
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
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
