import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/app_scale_metrics.dart';
import '../widgets/search_highlight_text.dart';
import '../services/offline_project_sync_service.dart';
import '../services/projects_list_cache_service.dart';
import '../services/project_access_service.dart';
import '../services/project_storage_service.dart';
import '../utils/web_arrow_key_scroll_binding.dart';

class RecentProjectsPage extends StatefulWidget {
  final VoidCallback? onCreateProject;
  final VoidCallback? onProjectsMutated;
  final Future<void> Function(String projectId, String projectName)?
      onProjectSelected;

  const RecentProjectsPage({
    super.key,
    this.onCreateProject,
    this.onProjectsMutated,
    this.onProjectSelected,
  });

  @override
  State<RecentProjectsPage> createState() => _RecentProjectsPageState();
}

class _RecentProjectsPageState extends State<RecentProjectsPage> {
  static const Duration _cacheFreshFor = Duration(seconds: 45);
  static const Color _projectNameTextColor = Color(0xFF5C5C5C);
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _projectsScrollController = ScrollController();
  late final WebArrowKeyScrollBinding _arrowKeyScrollBinding =
      WebArrowKeyScrollBinding(controller: _projectsScrollController);
  final ScrollController _calculationNoteScrollController = ScrollController();
  final SupabaseClient _supabase = Supabase.instance.client;
  StreamSubscription<AuthState>? _authStateSubscription;
  List<Map<String, dynamic>> _projects = [];
  List<Map<String, dynamic>> _filteredProjects = [];
  bool _isLoading = true;
  bool _isFetchingProjects = false;
  String _searchQuery = '';
  String? _openingProjectId;
  int? _hoveredIndex; // Track which project row is being hovered
  bool _hasCheckedCalculationNotePopup = false;

  @override
  void initState() {
    super.initState();
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowCalculationNotePopupAfterLogin();
    });
  }

  void _seedFromCacheIfAvailable() {
    unawaited(() async {
      final userId =
          await OfflineProjectSyncService.resolveCurrentOrLastKnownUserId(
        supabase: _supabase,
      );
      if (userId == null || userId.isEmpty) return;

      final cachedProjects = ProjectsListCacheService.getRecentProjects(userId);
      if (cachedProjects == null || !mounted) return;

      setState(() {
        _projects = cachedProjects;
        _filterProjects();
        _isLoading = false;
      });
    }());
  }

  @override
  void dispose() {
    _authStateSubscription?.cancel();
    _arrowKeyScrollBinding.detach();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _projectsScrollController.dispose();
    _calculationNoteScrollController.dispose();
    super.dispose();
  }

  Widget _buildHeaderRefreshButton(VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 2,
              offset: Offset(0, 0),
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
    );
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

  String _roundingPopupModeKey(String userId) =>
      'rounding_note_popup_mode_$userId';

  String _roundingPopupLastShownKey(String userId) =>
      'rounding_note_popup_last_shown_$userId';

  String _showRoundingPopupAfterLoginKey(String userId) =>
      'show_rounding_note_after_login_$userId';

  Future<void> _maybeShowCalculationNotePopupAfterLogin() async {
    if (_hasCheckedCalculationNotePopup || !mounted) return;
    _hasCheckedCalculationNotePopup = true;

    final userId = _supabase.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final showAfterLogin =
        prefs.getBool(_showRoundingPopupAfterLoginKey(userId)) ?? false;
    if (!showAfterLogin) return;

    if (!mounted) return;
    final selection = await _showCalculationNotePopup();
    if (selection == 'always' || selection == 'weekly') {
      await prefs.setString(_roundingPopupModeKey(userId), selection!);
      await prefs.setInt(
        _roundingPopupLastShownKey(userId),
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    await prefs.setBool(_showRoundingPopupAfterLoginKey(userId), false);
  }

  Future<String?> _showCalculationNotePopup() {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.35),
      builder: (dialogContext) {
        final media = MediaQuery.of(dialogContext).size;
        final width = math.min(760.0, media.width - 24);
        final height = math.min(874.0, media.height - 24);
        return Dialog(
          insetPadding: const EdgeInsets.all(12),
          backgroundColor: const Color(0xFFF8F9FA),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          child: SizedBox(
            width: width,
            height: height,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SvgPicture.asset(
                        'assets/images/Calculation_note.svg',
                        width: 20,
                        height: 20,
                        fit: BoxFit.contain,
                        placeholderBuilder: (context) => const SizedBox(
                          width: 20,
                          height: 20,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Text(
                        'Calculation note',
                        style: GoogleFonts.inter(
                          fontSize: 36 / 1.8,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => Navigator.of(dialogContext).pop(),
                        child: const SizedBox(
                          width: 16,
                          height: 16,
                          child: Icon(
                            Icons.close,
                            size: 16,
                            color: Color(0xFF0C8CE9),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'All values are computed with high precision internally.',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Colors.black.withOpacity(0.8),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Display rounding may cause small differences between individual plot totals and the system total.',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Colors.black.withOpacity(0.8),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildRoundingBadge(
                        label: 'Area (sqm) values',
                        value: '3 decimal places',
                      ),
                      const SizedBox(width: 24),
                      _buildRoundingBadge(
                        label: 'Rupee (₹) values',
                        value: '2 decimal places',
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: ScrollbarTheme(
                      data: const ScrollbarThemeData(
                        crossAxisMargin: 0,
                        mainAxisMargin: 10,
                      ),
                      child: Scrollbar(
                        controller: _calculationNoteScrollController,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _calculationNoteScrollController,
                          child: Column(
                            children: [
                              _buildCalculationExampleCard(),
                              const SizedBox(height: 16),
                              _buildCalculationInfoBanner(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Show this note again on opening the application?',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildCalculationChoiceButton(
                        label: 'Always Show',
                        onTap: () => Navigator.of(dialogContext).pop('always'),
                      ),
                      _buildCalculationChoiceButton(
                        label: 'Once a week',
                        onTap: () => Navigator.of(dialogContext).pop('weekly'),
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
  }

  Widget _buildRoundingBadge({
    required String label,
    required String value,
  }) {
    return Column(
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: 150,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.95),
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(
                color: Color(0xFF0C8CE9),
                blurRadius: 2,
              ),
            ],
          ),
          child: Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.black,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCalculationExampleCard() {
    final borderColor = Colors.black.withOpacity(0.55);
    final rowLabelStyle = GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      color: Colors.black.withOpacity(0.8),
    );
    final rowValueStyle = GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: Colors.black.withOpacity(0.8),
    );
    final displayBlue = const Color(0xFF0C8CE9);

    Widget simpleSplitRow({
      required String leftA,
      required String rightA,
      required String leftB,
      required String rightB,
      Color rightBColor = const Color(0xFF0C8CE9),
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: Text(leftA, style: rowLabelStyle)),
                Text(rightA, style: rowValueStyle),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text(leftB, style: rowLabelStyle)),
                Text(
                  rightB,
                  style: rowValueStyle.copyWith(color: rightBColor),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final plotRows = <List<String>>[
      [
        'Plot 1',
        '223',
        '6,666.6666...',
        '6,666.67',
        '₹ 1,486,666.6666…',
        '₹ 14,86,666.67'
      ],
      [
        'Plot 2',
        '223',
        '6,666.6666...',
        '6,666.67',
        '₹ 1,486,666.6666…',
        '₹ 14,86,666.67'
      ],
      [
        'Plot 3',
        '223',
        '6,666.6666...',
        '6,666.67',
        '₹ 1,486,666.6666…',
        '₹ 14,86,666.67'
      ],
      [
        'Plot 4',
        '223',
        '6,666.6666...',
        '6,666.67',
        '₹ 1,486,666.6666…',
        '₹ 14,86,666.67'
      ],
      [
        'Plot 5',
        '223',
        '6,666.6666...',
        '6,666.67',
        '₹ 1,486,666.6666…',
        '₹ 14,86,666.67'
      ],
      [
        'Plot 6',
        '223',
        '6,666.6666...',
        '6,666.67',
        '₹ 25,66,666.6666…',
        '₹ 25,66,666.67'
      ],
    ];

    Widget cellText(
      String value, {
      bool blue = false,
      bool bold = false,
      TextAlign align = TextAlign.center,
      double size = 14,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(
          value,
          style: GoogleFonts.inter(
            fontSize: size,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            color: blue ? displayBlue : Colors.black.withOpacity(0.8),
          ),
          textAlign: align,
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: borderColor, width: 0.5),
              ),
            ),
            child: Text(
              'Example',
              style: GoogleFonts.inter(
                fontSize: 32 / 1.6,
                fontWeight: FontWeight.w700,
                color: Colors.black.withOpacity(0.8),
              ),
            ),
          ),
          simpleSplitRow(
            leftA: 'Total area',
            rightA: '1,500 sqm',
            leftB: 'Total expense',
            rightB: '₹ 1,00,00,000',
            rightBColor: Colors.black.withOpacity(0.8),
          ),
          Container(height: 0.5, color: borderColor),
          simpleSplitRow(
            leftA: 'Actual all-in cost',
            rightA: '₹/sqm 6,666.666666...',
            leftB: 'Displayed as',
            rightB: '₹/sqm 6,666.67',
          ),
          Container(height: 0.5, color: borderColor),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              'Plot Cost Table',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.black.withOpacity(0.8),
              ),
            ),
          ),
          Container(height: 0.5, color: borderColor),
          Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            columnWidths: const <int, TableColumnWidth>{
              0: FlexColumnWidth(1.0),
              1: FlexColumnWidth(1.0),
              2: FlexColumnWidth(1.8),
              3: FlexColumnWidth(1.5),
              4: FlexColumnWidth(2.6),
              5: FlexColumnWidth(2.1),
            },
            border: TableBorder.symmetric(
              outside: BorderSide.none,
              inside: BorderSide(color: borderColor, width: 0.5),
            ),
            children: [
              TableRow(
                decoration: const BoxDecoration(color: Color(0xFFEBEBEB)),
                children: [
                  cellText('Plot'),
                  cellText('Area\n(sqm)'),
                  cellText('Actual\nAll-in Cost\n(₹/sqm)', size: 13),
                  cellText('Displayed\nAll-in Cost\n(₹/sqm)',
                      blue: true, size: 13),
                  cellText('Actual\nPlot Cost'),
                  cellText('Displayed\nPlot Cost', blue: true),
                ],
              ),
              ...plotRows.map(
                (row) => TableRow(
                  children: [
                    cellText(row[0]),
                    cellText(row[1]),
                    cellText(row[2]),
                    cellText(row[3], blue: true),
                    cellText(row[4]),
                    cellText(row[5], blue: true),
                  ],
                ),
              ),
            ],
          ),
          Container(height: 0.5, color: borderColor),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Manual Sum [Displayed Plot Cost]',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.black.withOpacity(0.8),
                        ),
                      ),
                    ),
                    Text(
                      '₹1,00,00,000.02',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(0.8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'System total [Displayed Plot Cost]',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.black.withOpacity(0.8),
                        ),
                      ),
                    ),
                    Text(
                      '₹1,00,00,000',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: displayBlue,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalculationInfoBanner() {
    return Container(
      width: 653,
      height: 80,
      padding: const EdgeInsets.fromLTRB(16, 19, 16, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0C8CE9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline,
            color: Colors.white,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'This difference occurs due to rounding at the display level.\nThe system aims to keep totals as close as possible to the actual expense.',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                height: 1.35,
              ),
              maxLines: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalculationChoiceButton({
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 243,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 2,
              offset: const Offset(0, 0),
            ),
          ],
        ),
        child: Center(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF0C8CE9),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadProjects({bool forceRefresh = false}) async {
    if (_isFetchingProjects) return;
    _isFetchingProjects = true;
    try {
      final userId =
          await OfflineProjectSyncService.resolveCurrentOrLastKnownUserId(
        supabase: _supabase,
      );
      if (userId == null || userId.isEmpty) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _projects = [];
            _filteredProjects = [];
          });
        }
        return;
      }
      unawaited(
        OfflineProjectSyncService.flushPendingCreates(
          supabase: _supabase,
          userId: userId,
        ),
      );

      final cachedProjects = ProjectsListCacheService.getRecentProjects(userId);
      final hasFreshCache = !forceRefresh &&
          ProjectsListCacheService.getRecentProjects(
                userId,
                maxAge: _cacheFreshFor,
              ) !=
              null;
      final mergedCachedProjects =
          await OfflineProjectSyncService.mergeWithPendingProjectsForUser(
        userId: userId,
        remoteProjects: cachedProjects ?? const <Map<String, dynamic>>[],
      );

      if ((cachedProjects != null || mergedCachedProjects.isNotEmpty) &&
          mounted) {
        setState(() {
          _projects = mergedCachedProjects;
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
      if (hasFreshCache && mergedCachedProjects.isNotEmpty) return;

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
          ((await OfflineProjectSyncService.resolveCurrentOrLastKnownUserEmail(
                    supabase: _supabase,
                  ) ??
                  '')
              .trim()
              .toLowerCase());
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
          ? await projectSelect
              .eq('user_id', userId)
              .order('updated_at', ascending: false)
              .limit(50)
          : await projectSelect
              .or('user_id.eq.$userId,id.in.(${inviteProjectIds.join(',')})')
              .order('updated_at', ascending: false)
              .limit(50);

      await OfflineProjectSyncService.flushPendingCreates(
        supabase: _supabase,
        userId: userId,
      );
      final projectRows = List<Map<String, dynamic>>.from(response);
      final dedupedById = <String, Map<String, dynamic>>{};
      for (final project in projectRows) {
        final id = (project['id'] ?? '').toString().trim();
        if (id.isEmpty || dedupedById.containsKey(id)) continue;
        dedupedById[id] = project;
      }
      final projects =
          await OfflineProjectSyncService.mergeWithPendingProjectsForUser(
        userId: userId,
        remoteProjects: dedupedById.values.toList(growable: false),
      );
      ProjectsListCacheService.setRecentProjects(userId, projects);

      if (!mounted) return;
      setState(() {
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

  Future<void> _deleteProject(String projectId) async {
    try {
      final userId =
          await OfflineProjectSyncService.resolveCurrentOrLastKnownUserId(
        supabase: _supabase,
      );
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
        await ProjectStorageService.removePendingOfflineSavesForProject(
          projectId,
        );
        if (userId != null && userId.isNotEmpty) {
          ProjectsListCacheService.invalidateUser(userId);
        }
        await _loadProjects(forceRefresh: true);
        widget.onProjectsMutated?.call();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Local project removed')),
        );
        return;
      }
      final deleteResult =
          await ProjectAccessService.deleteProjectForCurrentUser(
        projectId: projectId,
      );
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

  String _formatRelativeTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} min ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} hour${difference.inHours > 1 ? 's' : ''} ago';
    } else if (difference.inDays < 30) {
      return '${difference.inDays} day${difference.inDays > 1 ? 's' : ''} ago';
    } else if (difference.inDays < 365) {
      final months = (difference.inDays / 30).floor();
      return '$months month${months > 1 ? 's' : ''} ago';
    } else {
      final years = (difference.inDays / 365).floor();
      return '$years year${years > 1 ? 's' : ''} ago';
    }
  }

  String _formatDate(DateTime dateTime) {
    return DateFormat('d MMM yyyy').format(dateTime);
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

  Widget _buildRecentProjectsLoadingSkeleton() {
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final scaleMetrics = AppScaleMetrics.of(context);
        // In sidebar layouts, constraints.maxWidth is content width (not full
        // canvas width). Using designViewportWidth - constraints.maxWidth
        // incorrectly includes sidebar width and causes ratio-dependent drift.
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
                              'Recent Projects ',
                              style: GoogleFonts.inter(
                                fontSize: 32,
                                fontWeight: FontWeight.w600,
                                color: Colors.black,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(width: 12),
                            _buildHeaderRefreshButton(
                              () => _loadProjects(forceRefresh: true),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Quick access to projects you've worked on recently.",
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
                  ? _buildRecentProjectsLoadingSkeleton()
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
                                            : 'No recent projects yet',
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
                                            : 'Projects you open will appear here.',
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
        // Projects list
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
                    final projectName = project['project_name'] ?? '';
                    final updatedAt = project['updated_at'] != null
                        ? DateTime.parse(project['updated_at'])
                        : null;
                    final createdAt = project['created_at'] != null
                        ? DateTime.parse(project['created_at'])
                        : null;
                    final projectId = project['id']?.toString() ?? '';
                    final isOpeningProject = _openingProjectId == projectId;
                    final isHovered = _hoveredIndex == index;

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
                                            PopupMenuButton<String>(
                                              enabled: !isOpeningProject &&
                                                  _openingProjectId == null,
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
                                                          blurRadius: 1,
                                                          offset: const Offset(
                                                              0, 0),
                                                        ),
                                                      ],
                                                    ),
                                                    child: SizedBox(
                                                      width: 149,
                                                      height: 36,
                                                      child: Container(
                                                        alignment:
                                                            Alignment.center,
                                                        decoration:
                                                            BoxDecoration(
                                                          color: Colors.white,
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(8),
                                                          boxShadow: [
                                                            BoxShadow(
                                                              color: Colors
                                                                  .black
                                                                  .withOpacity(
                                                                      0.5),
                                                              blurRadius: 1,
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
                                                                FontWeight
                                                                    .normal,
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
                                                child: isOpeningProject
                                                    ? const SizedBox(
                                                        width: 16,
                                                        height: 16,
                                                        child:
                                                            CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          valueColor:
                                                              AlwaysStoppedAnimation<
                                                                  Color>(
                                                            Color(0xFF5C5C5C),
                                                          ),
                                                        ),
                                                      )
                                                    : const Icon(
                                                        Icons.more_horiz,
                                                        size: 20,
                                                        color:
                                                            Color(0xFF5C5C5C),
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

  // Public method to refresh projects list
  void refreshProjects() {
    _loadProjects(forceRefresh: true);
  }
}
