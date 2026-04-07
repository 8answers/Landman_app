import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/offline_project_sync_service.dart';
import '../services/project_access_service.dart';
import '../services/project_storage_service.dart';
import '../services/project_trash_service.dart';
import '../services/projects_list_cache_service.dart';
import '../widgets/app_scale_metrics.dart';
import '../widgets/header_refresh_button.dart';
import '../widgets/search_highlight_text.dart';
import '../utils/web_arrow_key_scroll_binding.dart';

class TrashPage extends StatefulWidget {
  final VoidCallback? onProjectsMutated;

  const TrashPage({
    super.key,
    this.onProjectsMutated,
  });

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  static const Color _projectNameTextColor = Color(0xFF5C5C5C);
  static const Duration _forcedRefreshSkeletonMin = Duration(milliseconds: 320);

  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _projectsScrollController = ScrollController();
  late final WebArrowKeyScrollBinding _arrowKeyScrollBinding =
      WebArrowKeyScrollBinding(controller: _projectsScrollController);

  List<Map<String, dynamic>> _projects = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _filteredProjects = <Map<String, dynamic>>[];
  bool _isLoading = true;
  bool _isFetching = false;
  String _searchQuery = '';
  String? _restoringProjectId;
  String? _deletingProjectId;
  int? _hoveredIndex;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _arrowKeyScrollBinding.attach();
    _loadDeletedProjects();
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _projectsScrollController.dispose();
    _arrowKeyScrollBinding.detach();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.trim().toLowerCase();
      _filterProjects();
    });
  }

  void _filterProjects() {
    if (_searchQuery.isEmpty) {
      _filteredProjects = List<Map<String, dynamic>>.from(_projects);
      return;
    }
    _filteredProjects = _projects.where((project) {
      final name = (project['project_name'] ?? '').toString().toLowerCase();
      return name.contains(_searchQuery);
    }).toList(growable: false);
  }

  Future<void> _loadDeletedProjects({
    bool showLoading = true,
    bool forceFullPageSkeleton = false,
  }) async {
    if (_isFetching) return;
    _isFetching = true;
    if (forceFullPageSkeleton) {
      showLoading = true;
    }
    final forcedSkeletonStartedAt =
        forceFullPageSkeleton ? DateTime.now() : null;
    Future<void> ensureForcedSkeletonDelay() async {
      if (forcedSkeletonStartedAt == null) return;
      final elapsed = DateTime.now().difference(forcedSkeletonStartedAt);
      final remaining = _forcedRefreshSkeletonMin - elapsed;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }

    try {
      final userId =
          await OfflineProjectSyncService.resolveCurrentOrLastKnownUserId(
        supabase: _supabase,
      );
      if (userId == null || userId.isEmpty) {
        await ensureForcedSkeletonDelay();
        if (!mounted) return;
        setState(() {
          _projects = <Map<String, dynamic>>[];
          _filteredProjects = <Map<String, dynamic>>[];
          _isLoading = false;
        });
        return;
      }

      if (showLoading && mounted) {
        setState(() {
          _isLoading = true;
          if (forceFullPageSkeleton) {
            _projects = <Map<String, dynamic>>[];
            _filteredProjects = <Map<String, dynamic>>[];
          }
        });
      }

      final trashRows =
          await ProjectTrashService.trashedProjectsForUser(userId);
      if (!mounted) return;
      await ensureForcedSkeletonDelay();
      setState(() {
        _projects = trashRows;
        _filterProjects();
        _isLoading = false;
      });
    } finally {
      _isFetching = false;
    }
  }

  String _formatDeletedAt(Map<String, dynamic> project) {
    final deletedAtMs = (project['deleted_at_ms'] as num?)?.toInt();
    if (deletedAtMs == null || deletedAtMs <= 0) return 'N/A';
    final deletedAt = DateTime.fromMillisecondsSinceEpoch(deletedAtMs);
    return DateFormat('d MMM yyyy, hh:mm a').format(deletedAt);
  }

  String _formatCreatedAt(Map<String, dynamic> project) {
    final createdRaw = (project['created_at'] ?? '').toString().trim();
    if (createdRaw.isEmpty) return 'N/A';
    try {
      final createdAt = DateTime.parse(createdRaw);
      return DateFormat('d MMM yyyy').format(createdAt);
    } catch (_) {
      return 'N/A';
    }
  }

  Widget _buildHeaderRefreshButton(VoidCallback onTap) {
    return HeaderRefreshButton(onTap: onTap);
  }

  Future<void> _restoreProject(Map<String, dynamic> project) async {
    final userId =
        await OfflineProjectSyncService.resolveCurrentOrLastKnownUserId(
      supabase: _supabase,
    );
    if (userId == null || userId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to restore project right now')),
      );
      return;
    }

    final projectId = (project['id'] ?? '').toString().trim();
    if (projectId.isEmpty) return;
    if (_restoringProjectId != null || _deletingProjectId != null) return;
    setState(() {
      _restoringProjectId = projectId;
    });

    try {
      await ProjectTrashService.restoreFromTrash(
        userId: userId,
        projectId: projectId,
      );
      ProjectsListCacheService.invalidateUser(userId);
      await _loadDeletedProjects(showLoading: false);
      widget.onProjectsMutated?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Project restored')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to restore project: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _restoringProjectId = null;
        });
      }
    }
  }

  Future<void> _deleteProjectPermanently(Map<String, dynamic> project) async {
    final userId =
        await OfflineProjectSyncService.resolveCurrentOrLastKnownUserId(
      supabase: _supabase,
    );
    if (userId == null || userId.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to delete project right now')),
      );
      return;
    }

    final projectId = (project['id'] ?? '').toString().trim();
    if (projectId.isEmpty) return;
    if (_deletingProjectId != null || _restoringProjectId != null) return;
    setState(() {
      _deletingProjectId = projectId;
    });

    try {
      final isPendingLocal =
          await OfflineProjectSyncService.isPendingLocalProject(
        projectId: projectId,
        userId: userId,
      );
      if (isPendingLocal) {
        await OfflineProjectSyncService.removePendingProject(
          projectId: projectId,
          userId: userId,
        );
      } else {
        await ProjectAccessService.deleteProjectForCurrentUser(
          projectId: projectId,
        );
      }

      await ProjectStorageService.removePendingOfflineSavesForProject(
          projectId);
      ProjectStorageService.invalidateProjectCache(projectId);
      await ProjectTrashService.restoreFromTrash(
        userId: userId,
        projectId: projectId,
      );
      ProjectsListCacheService.invalidateUser(userId);
      await _loadDeletedProjects(showLoading: false);
      widget.onProjectsMutated?.call();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Project deleted permanently')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete permanently: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _deletingProjectId = null;
        });
      }
    }
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

  Widget _buildTrashLoadingSkeleton() {
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
                _skeletonBlock(width: 180, height: 20),
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
                      _skeletonBlock(width: 180, height: 18),
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

  PopupMenuItem<String> _buildTrashActionOption({
    required String value,
    required String text,
    required Color textColor,
    required bool hasBottomGap,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: hasBottomGap ? 44 : 36,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.only(bottom: hasBottomGap ? 8 : 0),
        child: Container(
          width: 149,
          height: 36,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 1,
                offset: const Offset(0, 0),
              ),
            ],
          ),
          child: Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final scaleMetrics = AppScaleMetrics.of(context);
        final extraRightWidth = scaleMetrics?.rightOverflowWidth ?? 0.0;
        final isMobile = screenWidth < 768;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(
                top: 24,
                left: 24,
                right: 24,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Trash',
                              style: GoogleFonts.inter(
                                fontSize: 32,
                                fontWeight: FontWeight.w600,
                                color: Colors.black,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(width: 12),
                            _buildHeaderRefreshButton(
                              () => _loadDeletedProjects(
                                forceFullPageSkeleton: true,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Deleted projects can be restored from here.',
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
                ],
              ),
            ),
            const SizedBox(height: 24),
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
                      left: 24,
                      right: isMobile ? 24 : 0,
                      bottom: 16,
                    ),
                    child: SizedBox(
                      height: 36,
                      child: Row(
                        children: [
                          Expanded(
                            child: Container(
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
                                          color: Colors.black.withOpacity(0.8),
                                          height: 1.0,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: 'Search Deleted Projects',
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
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: _isLoading
                  ? _buildTrashLoadingSkeleton()
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
                                            : 'No deleted projects yet',
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
                                            : 'Deleted projects will appear here.',
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.normal,
                                          color: const Color(0xFF5C5C5C),
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
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

  Widget _buildProjectsTable(double extraRightWidth) {
    const nameColumnWidth = 562.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                                'Deleted date & time',
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
                    final projectName =
                        (project['project_name'] ?? '').toString();
                    final projectId = (project['id'] ?? '').toString().trim();
                    final isHovered = _hoveredIndex == index;
                    final isRestoring = _restoringProjectId == projectId;
                    final isDeleting = _deletingProjectId == projectId;
                    final isBusy = isRestoring || isDeleting;

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
                                text: projectName.isEmpty
                                    ? 'Untitled project'
                                    : projectName,
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
                                              _formatDeletedAt(project),
                                              style: GoogleFonts.inter(
                                                fontSize: 14,
                                                fontWeight: FontWeight.normal,
                                                color: const Color(0xFF5C5C5C),
                                              ),
                                              textAlign: TextAlign.center,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          SizedBox(
                                            width: 180,
                                            child: Text(
                                              _formatCreatedAt(project),
                                              style: GoogleFonts.inter(
                                                fontSize: 14,
                                                fontWeight: FontWeight.normal,
                                                color: const Color(0xFF5C5C5C),
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            enabled: !isBusy,
                                            tooltip: '',
                                            color: const Color(0xFFF8F9FA),
                                            constraints:
                                                const BoxConstraints.tightFor(
                                              width: 165,
                                            ),
                                            menuPadding:
                                                const EdgeInsets.all(8),
                                            elevation: 1,
                                            shadowColor: Colors.black
                                                .withValues(alpha: 0.5),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            offset: const Offset(0, 40),
                                            onSelected: (value) {
                                              if (value == 'restore') {
                                                unawaited(
                                                  _restoreProject(project),
                                                );
                                                return;
                                              }
                                              if (value == 'delete') {
                                                unawaited(
                                                  _deleteProjectPermanently(
                                                    project,
                                                  ),
                                                );
                                              }
                                            },
                                            itemBuilder: (context) => [
                                              _buildTrashActionOption(
                                                value: 'restore',
                                                text: 'Restore',
                                                textColor:
                                                    const Color(0xFF0C8CE9),
                                                hasBottomGap: true,
                                              ),
                                              _buildTrashActionOption(
                                                value: 'delete',
                                                text: 'Delete',
                                                textColor: Colors.red,
                                                hasBottomGap: false,
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
                                                    offset: const Offset(0, 0),
                                                  ),
                                                ],
                                              ),
                                              alignment: Alignment.centerRight,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 16,
                                                vertical: 4,
                                              ),
                                              child: isBusy
                                                  ? const SizedBox(
                                                      width: 16,
                                                      height: 16,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                    )
                                                  : const Icon(
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
