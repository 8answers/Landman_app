import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/app_scale_metrics.dart';
import '../widgets/search_highlight_text.dart';
import '../services/projects_list_cache_service.dart';
import '../services/project_access_service.dart';
import '../utils/web_arrow_key_scroll_binding.dart';

class AllProjectsPage extends StatefulWidget {
  final VoidCallback? onCreateProject;
  final VoidCallback? onProjectsMutated;
  final Future<void> Function(String projectId, String projectName)?
      onProjectSelected;

  const AllProjectsPage({
    super.key,
    this.onCreateProject,
    this.onProjectsMutated,
    this.onProjectSelected,
  });

  @override
  State<AllProjectsPage> createState() => _AllProjectsPageState();
}

class _AllProjectsPageState extends State<AllProjectsPage> {
  static const Duration _cacheFreshFor = Duration(seconds: 45);
  static const Color _projectNameTextColor = Color(0xFF5C5C5C);
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _projectsScrollController = ScrollController();
  late final WebArrowKeyScrollBinding _arrowKeyScrollBinding =
      WebArrowKeyScrollBinding(controller: _projectsScrollController);
  final SupabaseClient _supabase = Supabase.instance.client;
  StreamSubscription<AuthState>? _authStateSubscription;
  List<Map<String, dynamic>> _projects = [];
  List<Map<String, dynamic>> _filteredProjects = [];
  bool _isLoading = true;
  bool _isFetchingProjects = false;
  String _searchQuery = '';
  int? _hoveredIndex; // Track which project row is being hovered
  String _selectedSort = 'Alphabetical order';
  bool _isFilterMenuOpen = false;
  String? _openingProjectId;
  final GlobalKey _filterButtonKey = GlobalKey();
  OverlayEntry? _filterMenuOverlayEntry;
  OverlayEntry? _filterMenuBackdropEntry;

  @override
  void initState() {
    super.initState();
    _selectedSort = 'Alphabetical order';
    _searchController.addListener(_onSearchChanged);
    _seedFromCacheIfAvailable();
    _arrowKeyScrollBinding.attach();
    _authStateSubscription =
        _supabase.auth.onAuthStateChange.listen((authState) {
      if (!mounted) return;
      if (authState.event == AuthChangeEvent.initialSession) return;
      _loadProjects(forceRefresh: true);
    });
    _loadProjects();
  }

  void _seedFromCacheIfAvailable() {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    final cachedProjects = ProjectsListCacheService.getAllProjects(userId);
    if (cachedProjects == null) return;

    _projects = cachedProjects;
    _filterProjects();
    _isLoading = false;
  }

  @override
  void dispose() {
    _removeFilterMenuOverlay(updateState: false);
    _authStateSubscription?.cancel();
    _arrowKeyScrollBinding.detach();
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

  Future<void> _openProjectFromRow(
    String projectId,
    String projectName,
  ) async {
    if (_openingProjectId != null) return;
    if (widget.onProjectSelected == null) return;

    setState(() {
      _openingProjectId = projectId;
    });

    try {
      await widget.onProjectSelected!(projectId, projectName);
    } finally {
      if (mounted && _openingProjectId == projectId) {
        setState(() {
          _openingProjectId = null;
        });
      }
    }
  }

  Future<void> _loadProjects({bool forceRefresh = false}) async {
    if (_isFetchingProjects) return;
    _isFetchingProjects = true;
    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _projects = [];
            _filteredProjects = [];
          });
        }
        return;
      }

      final cachedProjects = ProjectsListCacheService.getAllProjects(userId);
      final hasFreshCache = !forceRefresh &&
          ProjectsListCacheService.getAllProjects(
                userId,
                maxAge: _cacheFreshFor,
              ) !=
              null;

      if (cachedProjects != null && mounted) {
        setState(() {
          _projects = cachedProjects;
          _selectedSort = 'Alphabetical order';
          _filterProjects();
          _isLoading = false;
        });
      } else if (mounted) {
        setState(() {
          _isLoading = true;
        });
      }

      // If cache is fresh but empty, still hit backend once to avoid hiding
      // newly granted invite-access projects until cache expiry.
      if (hasFreshCache && (cachedProjects?.isNotEmpty ?? false)) return;

      // Ensure invite acceptance/membership upsert is applied for all roles
      // (agent / project_manager / partner) before loading project list.
      try {
        final prefs = await SharedPreferences.getInstance();
        final inviteProjectId =
            (prefs.getString('nav_project_id') ?? '').trim();
        final inviteRole =
            (prefs.getString('nav_invited_project_role') ?? '').trim();
        final hasInviteContext =
            prefs.getBool('nav_has_invite_context') ?? false;
        if (hasInviteContext && inviteProjectId.isNotEmpty) {
          await ProjectAccessService.acceptPendingInviteForCurrentUser(
            projectId: inviteProjectId,
            roleHint: inviteRole.isEmpty ? null : inviteRole,
          );
        }
      } catch (_) {
        // Best-effort repair; continue with normal list loading.
      }

      final currentUserEmail =
          (_supabase.auth.currentUser?.email ?? '').trim().toLowerCase();
      final inviteProjectIds = <String>{};
      bool isBlockedInviteStatus(String status) {
        return status == 'revoked' || status == 'paused' || status == 'expired';
      }

      if (currentUserEmail.isNotEmpty) {
        try {
          final inviteRowsByEmail = await _supabase
              .from('project_access_invites')
              .select('project_id, status, accepted_user_id')
              .eq('invited_email', currentUserEmail);
          for (final row in inviteRowsByEmail) {
            final projectId = (row['project_id'] ?? '').toString().trim();
            final status =
                (row['status'] ?? '').toString().trim().toLowerCase();
            final acceptedUserId =
                (row['accepted_user_id'] ?? '').toString().trim();
            if (projectId.isEmpty || isBlockedInviteStatus(status)) {
              continue;
            }
            final isAccepted = status == 'accepted' || status == 'active';
            final isAcceptedForCurrentUser =
                acceptedUserId.isNotEmpty && acceptedUserId == userId;
            if (isAccepted || isAcceptedForCurrentUser) {
              inviteProjectIds.add(projectId);
            }
          }
        } catch (_) {
          // Best-effort; continue with owner projects only.
        }
      }

      try {
        final inviteRowsByAcceptedUserId = await _supabase
            .from('project_access_invites')
            .select('project_id, status')
            .eq('accepted_user_id', userId);
        for (final row in inviteRowsByAcceptedUserId) {
          final projectId = (row['project_id'] ?? '').toString().trim();
          final status = (row['status'] ?? '').toString().trim().toLowerCase();
          if (projectId.isEmpty || isBlockedInviteStatus(status)) {
            continue;
          }
          inviteProjectIds.add(projectId);
        }
      } catch (_) {
        // Best-effort; continue with owner projects only.
      }

      final projectSelect = _supabase
          .from('projects')
          .select('id, user_id, project_name, created_at, updated_at');
      final response = inviteProjectIds.isEmpty
          ? await projectSelect.eq('user_id', userId)
          : await projectSelect
              .or('user_id.eq.$userId,id.in.(${inviteProjectIds.join(',')})');

      final projectRows = List<Map<String, dynamic>>.from(response);
      final dedupedById = <String, Map<String, dynamic>>{};
      for (final project in projectRows) {
        final id = (project['id'] ?? '').toString().trim();
        if (id.isEmpty || dedupedById.containsKey(id)) continue;
        dedupedById[id] = project;
      }
      final projects = dedupedById.values.toList(growable: false);
      ProjectsListCacheService.setAllProjects(userId, projects);

      if (!mounted) return;
      setState(() {
        _selectedSort = 'Alphabetical order';
        _projects = projects;
        _filterProjects();
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading projects: $e');
      if (mounted && _projects.isEmpty) {
        setState(() {
          _isLoading = false;
          _projects = [];
          _filteredProjects = [];
        });
      }
    } finally {
      _isFetchingProjects = false;
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
      final deleteResult =
          await ProjectAccessService.deleteProjectForCurrentUser(
        projectId: projectId,
      );
      final userId = _supabase.auth.currentUser?.id;
      if (userId != null && userId.isNotEmpty) {
        ProjectsListCacheService.invalidateUser(userId);
      }
      await _loadProjects(forceRefresh: true);
      widget.onProjectsMutated?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deleteResult.deletedForEveryone
                ? 'Project deleted'
                : 'Project removed from your list',
          ),
        ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final scaleMetrics = AppScaleMetrics.of(context);
        // Match Recent Projects behavior so the right-side menu stays visible
        // across responsive widths in sidebar layouts.
        final extraRightWidth = scaleMetrics?.rightOverflowWidth ?? 0.0;
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
            SizedBox(
              width: double.infinity,
              child: Stack(
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
                    padding: EdgeInsets.only(
                        left: 24, right: isMobile ? 24 : 0, bottom: 16),
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
                              GestureDetector(
                                key: _filterButtonKey,
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _showFilterMenuOverlay(context),
                                child: _buildFilterButton(
                                  isActive: _isFilterHighlighted,
                                ),
                              ),
                              const SizedBox(height: 16),
                              // Search bar
                              Container(
                                height: 36,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(32),
                                  border: Border.all(
                                    color: const Color(0xFF5C5C5C),
                                    width: 0.5,
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
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
                                            color:
                                                Colors.black.withOpacity(0.8),
                                            height: 1.0,
                                          ),
                                          decoration: InputDecoration(
                                            hintText: 'Search Documents',
                                            hintStyle: GoogleFonts.inter(
                                              fontSize: 14,
                                              fontWeight: FontWeight.normal,
                                              color:
                                                  Colors.black.withOpacity(0.5),
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
                        : SizedBox(
                            height: 36,
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final actionRowWidth =
                                    constraints.maxWidth + extraRightWidth;
                                const actionRowHeight = 36.0;
                                return OverflowBox(
                                  alignment: Alignment.centerLeft,
                                  minWidth: actionRowWidth,
                                  maxWidth: actionRowWidth,
                                  minHeight: actionRowHeight,
                                  maxHeight: actionRowHeight,
                                  child: SizedBox(
                                    width: actionRowWidth,
                                    height: actionRowHeight,
                                    child: Row(
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
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withOpacity(0.25),
                                                  blurRadius: 2,
                                                  offset: const Offset(0, 0),
                                                  spreadRadius: 0,
                                                ),
                                              ],
                                            ),
                                            clipBehavior: Clip.antiAlias,
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  'Create new project',
                                                  style: GoogleFonts.inter(
                                                    fontSize: 14,
                                                    fontWeight:
                                                        FontWeight.normal,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                SvgPicture.asset(
                                                  'assets/images/Cretae_new_projet_white.svg',
                                                  width: 13,
                                                  height: 13,
                                                  fit: BoxFit.contain,
                                                  placeholderBuilder:
                                                      (context) =>
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
                                        GestureDetector(
                                          key: _filterButtonKey,
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () =>
                                              _showFilterMenuOverlay(context),
                                          child: _buildFilterButton(
                                            isActive: _isFilterHighlighted,
                                          ),
                                        ),
                                        const SizedBox(width: 16),
                                        // Search bar
                                        Expanded(
                                          child: Container(
                                            height: 36,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10),
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(32),
                                              border: Border.all(
                                                color: const Color(0xFF5C5C5C),
                                                width: 0.5,
                                              ),
                                            ),
                                            clipBehavior: Clip.antiAlias,
                                            child: Row(
                                              children: [
                                                SvgPicture.asset(
                                                  'assets/images/Search_projects.svg',
                                                  width: 16,
                                                  height: 16,
                                                  fit: BoxFit.contain,
                                                  placeholderBuilder:
                                                      (context) =>
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
                                                      controller:
                                                          _searchController,
                                                      textAlignVertical:
                                                          TextAlignVertical
                                                              .center,
                                                      style: GoogleFonts.inter(
                                                        fontSize: 14,
                                                        fontWeight:
                                                            FontWeight.normal,
                                                        color: Colors.black
                                                            .withOpacity(0.8),
                                                        height: 1.0,
                                                      ),
                                                      decoration:
                                                          InputDecoration(
                                                        hintText:
                                                            'Search Documents',
                                                        hintStyle:
                                                            GoogleFonts.inter(
                                                          fontSize: 14,
                                                          fontWeight:
                                                              FontWeight.normal,
                                                          color: Colors.black
                                                              .withOpacity(0.5),
                                                          height: 1.0,
                                                        ),
                                                        border:
                                                            InputBorder.none,
                                                        isDense: true,
                                                        isCollapsed: true,
                                                        contentPadding:
                                                            EdgeInsets.zero,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Projects list or empty state
            Expanded(
              child: _isLoading
                  ? _buildAllProjectsLoadingSkeleton()
                  : _filteredProjects.isEmpty
                      ? LayoutBuilder(
                          builder: (context, emptyConstraints) {
                            return SizedBox(
                              width: emptyConstraints.maxWidth,
                              height: emptyConstraints.maxHeight,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                  ),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      // Empty state icon
                                      SvgPicture.asset(
                                        'assets/images/Rcent_projects_folder.svg',
                                        width: 108,
                                        height: 80,
                                        fit: BoxFit.contain,
                                        placeholderBuilder: (context) =>
                                            const SizedBox(
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
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withOpacity(0.25),
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
                                                    fontWeight:
                                                        FontWeight.normal,
                                                    color:
                                                        const Color(0xFF0C8CE9),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                // Plus icon
                                                SvgPicture.asset(
                                                  'assets/images/Create_new_project_blue.svg',
                                                  width: 13,
                                                  height: 13,
                                                  fit: BoxFit.contain,
                                                  placeholderBuilder:
                                                      (context) =>
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
                              ),
                            );
                          },
                        )
                      : Padding(
                          padding: const EdgeInsets.only(left: 24),
                          child: LayoutBuilder(
                            builder: (context, tableConstraints) {
                              final tableWidth =
                                  tableConstraints.maxWidth + extraRightWidth;
                              final tableHeight = tableConstraints.maxHeight;
                              return OverflowBox(
                                alignment: Alignment.topLeft,
                                minWidth: tableWidth,
                                maxWidth: tableWidth,
                                minHeight: tableHeight,
                                maxHeight: tableHeight,
                                child: SizedBox(
                                  width: tableWidth,
                                  height: tableHeight,
                                  child: _buildProjectsTable(0),
                                ),
                              );
                            },
                          ),
                        ),
            ),
          ],
        );
      },
    );
  }

  void _removeFilterMenuOverlay({bool updateState = true}) {
    _filterMenuOverlayEntry?.remove();
    _filterMenuBackdropEntry?.remove();
    _filterMenuOverlayEntry = null;
    _filterMenuBackdropEntry = null;
    if (updateState && mounted && _isFilterMenuOpen) {
      setState(() => _isFilterMenuOpen = false);
    }
  }

  double _measureTextWidth(
    BuildContext context,
    String text,
    TextStyle style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
    )..layout();
    return painter.width;
  }

  Widget _buildFilterOverlayOption(
    String value, {
    required bool isSelected,
    required double width,
  }) {
    return Container(
      width: width,
      height: 32,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFECF6FD) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 2,
            offset: const Offset(0, 0),
          ),
        ],
      ),
      child: Text(
        value,
        textAlign: TextAlign.left,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w400,
          color: Colors.black,
        ),
      ),
    );
  }

  void _showFilterMenuOverlay(BuildContext context) {
    final triggerContext = _filterButtonKey.currentContext;
    if (triggerContext == null) return;
    final triggerRenderBox = triggerContext.findRenderObject() as RenderBox?;
    if (triggerRenderBox == null) return;

    if (_filterMenuOverlayEntry != null) {
      _removeFilterMenuOverlay();
      return;
    }

    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox;
    final offset =
        triggerRenderBox.localToGlobal(Offset.zero, ancestor: overlayBox);

    const options = <String>[
      'Alphabetical order',
      'Last modified',
      'Date created',
    ];
    const optionGap = 8.0;
    const listPadding = EdgeInsets.symmetric(vertical: 8, horizontal: 8);
    const optionHorizontalPadding = 8.0;
    final optionTextStyle = GoogleFonts.inter(
      fontSize: 11,
      fontWeight: FontWeight.w400,
      color: Colors.black,
    );
    final optionWidth = _measureTextWidth(
          context,
          options.first,
          optionTextStyle,
        ) +
        (optionHorizontalPadding * 2) +
        5;
    final menuWidth = optionWidth + listPadding.horizontal;
    final menuHeight = listPadding.vertical +
        (options.length * 32) +
        ((options.length - 1) * optionGap);

    _filterMenuBackdropEntry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _removeFilterMenuOverlay,
          child: const SizedBox.expand(),
        ),
      ),
    );

    _filterMenuOverlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: offset.dx,
        top: offset.dy + 44,
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
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 2,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
            child: Padding(
              padding: listPadding,
              child: Column(
                children: [
                  for (int i = 0; i < options.length; i++) ...[
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        if (_selectedSort != options[i]) {
                          setState(() {
                            _selectedSort = options[i];
                            _filterProjects();
                          });
                        }
                        _removeFilterMenuOverlay();
                      },
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: _buildFilterOverlayOption(
                          options[i],
                          isSelected: _selectedSort == options[i],
                          width: optionWidth,
                        ),
                      ),
                    ),
                    if (i != options.length - 1)
                      const SizedBox(height: optionGap),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(_filterMenuBackdropEntry!);
    overlay.insert(_filterMenuOverlayEntry!);
    if (mounted) setState(() => _isFilterMenuOpen = true);
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

  Widget _buildProjectRowMenu(String projectId, {required bool isOpening}) {
    return PopupMenuButton<String>(
      enabled: !isOpening && _openingProjectId == null,
      tooltip: '',
      color: Colors.transparent,
      constraints: const BoxConstraints.tightFor(width: 165),
      menuPadding: EdgeInsets.zero,
      elevation: 0,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      offset: const Offset(0, 40),
      onSelected: (value) {
        if (value == 'delete') {
          _showDeleteProjectDialog(projectId);
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
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 1,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
            child: SizedBox(
              width: 149,
              height: 36,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.5),
                      blurRadius: 1,
                      offset: const Offset(0, 0),
                    ),
                  ],
                ),
                child: Text(
                  'Delete Project',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.red,
                  ),
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
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 1,
              offset: const Offset(0, 0),
            ),
          ],
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 4,
        ),
        child: isOpening
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Color(0xFF5C5C5C),
                  ),
                ),
              )
            : const Icon(
                Icons.more_horiz,
                size: 20,
                color: Color(0xFF5C5C5C),
              ),
      ),
    );
  }

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
                crossAxisMargin: 0,
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
                    final isOpeningProject = _openingProjectId == projectId;

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
                        onTap: () async {
                          await _openProjectFromRow(projectId, projectName);
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
                                child: SearchHighlightText(
                                  text: projectName,
                                  query: _searchQuery,
                                  style: GoogleFonts.inter(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: _projectNameTextColor,
                                  ),
                                  maxLines: 1,
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
                                            _buildProjectRowMenu(
                                              projectId,
                                              isOpening: isOpeningProject,
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
