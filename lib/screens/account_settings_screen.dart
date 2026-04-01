import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/sidebar_navigation.dart';
import '../widgets/account_settings_content.dart';
import '../widgets/create_project_dialog.dart';
import '../widgets/project_save_status.dart';
import '../models/navigation_page.dart';
import '../pages/notifications_page.dart';
import '../pages/to_do_list_page.dart';
import '../pages/recent_projects_page.dart';
import '../pages/all_projects_page.dart';
import '../pages/trash_page.dart';
import '../pages/help_page.dart';
import '../pages/project_details_page.dart';
import '../pages/dashboard_page.dart';
import '../pages/plot_status_page.dart';
import '../pages/documents_page.dart';
import '../pages/report_page.dart';
import '../pages/settings_page.dart';
import '../pages/login_page.dart';
import '../services/project_storage_service.dart';
import '../services/offline_project_sync_service.dart';
import '../services/projects_list_cache_service.dart';
import '../services/project_access_service.dart';
import '../utils/web_navigation_context.dart' as web_nav;

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({
    super.key,
    this.forceRecentStart = false,
  });

  final bool forceRecentStart;

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen>
    with WidgetsBindingObserver {
  static const String _projectDataEntryTabPrefSuffix = '_data_entry_active_tab';
  static const String _projectDashboardTabPrefSuffix = '_dashboard_active_tab';
  static const String _projectPlotStatusTabPrefSuffix =
      '_plot_status_active_tab';
  static const String _projectSettingsTabPrefPrefix =
      'nav_settings_active_tab_';

  static const List<NavigationPage> _retainedPageOrder = <NavigationPage>[
    NavigationPage.account,
    NavigationPage.notifications,
    NavigationPage.toDoList,
    NavigationPage.report,
    NavigationPage.recentProjects,
    NavigationPage.allProjects,
    NavigationPage.trash,
    NavigationPage.help,
    NavigationPage.dataEntry,
    NavigationPage.dashboard,
    NavigationPage.plotStatus,
    NavigationPage.documents,
    NavigationPage.settings,
  ];

  NavigationPage _currentPage = NavigationPage.recentProjects;
  NavigationPage? _previousPage;
  final List<NavigationPage> _pageHistory = <NavigationPage>[];
  final Set<NavigationPage> _initializedRetainedPages = <NavigationPage>{
    NavigationPage.recentProjects,
  };
  String? _projectName;
  String? _projectId;
  ProjectSaveStatusType _saveStatus = ProjectSaveStatusType.saved;
  String? _savedTimeAgo;
  bool _hasDataEntryErrors = false;
  bool _hasPlotStatusErrors = false;
  bool _hasAreaErrors = false;
  bool _hasPartnerErrors = false;
  bool _hasExpenseErrors = false;
  bool _hasSiteErrors = false;
  bool _hasProjectManagerErrors = false;
  bool _hasAgentErrors = false;
  bool _hasAboutErrors = false;
  bool _hasAboutWarningOnly = false;
  bool _hasProjectManagerWarningOnly = false;
  bool _hasAgentWarningOnly = false;
  bool _hasAccountErrors = false;
  bool _isRestoringNavState = true;
  bool _isDashboardPageLoading = false;
  bool _isPlotStatusPageLoading = false;
  int _errorBadgeRefreshGeneration = 0;
  int _projectDataVersion = 0;
  int _projectsListVersion = 0;
  bool _projectDataDirty = false;
  bool _pendingDataEntryBadgeRecalc = false;
  Timer? _savingStatusReconcileTimer;
  Timer? _projectSyncTimer;
  bool _isProjectSyncTickRunning = false;
  String? _lastSeenProjectIdForSync;
  DateTime? _lastSeenProjectUpdatedAt;
  String? _projectAccessRole;
  String? _projectOwnerEmail;
  List<String> _projectAccessRoleOptions = <String>[];
  Set<String> _activeProjectRoles = <String>{};
  Set<String> _deniedProjectRoles = <String>{};
  bool _hasResolvedProjectRoles = false;
  bool _isPausedOverlayRoleSwitching = false;
  String? _pausedOverlaySwitchingRole;
  bool _isPausedRoleOptionsRefreshRunning = false;
  DateTime? _lastPausedRoleOptionsRefreshAt;
  ProjectTab? _requestedDataEntryTab;
  int _requestedDataEntryTabRequestId = 0;
  String _lastSyncedBrowserPath = '';
  final GlobalKey _globalRoleDropdownTriggerKey = GlobalKey();
  OverlayEntry? _globalRoleDropdownOverlayEntry;
  OverlayEntry? _globalRoleDropdownBackdropEntry;

  String _normalizeAuthParam(String? authValue) {
    var normalized = (authValue ?? '').trim();
    if (normalized.isEmpty) return '';
    for (var i = 0; i < 3; i++) {
      if (!normalized.contains('%')) break;
      try {
        final decoded = Uri.decodeComponent(normalized).trim();
        if (decoded.isEmpty || decoded == normalized) break;
        normalized = decoded;
      } catch (_) {
        break;
      }
    }
    return normalized;
  }

  Map<String, String> _extractInviteContextFromAuthValue(String? authValue) {
    final raw = _normalizeAuthParam(authValue);
    if (raw.isEmpty) return const <String, String>{};
    final separatorIndex = raw.indexOf(':');
    if (separatorIndex <= 0) return const <String, String>{};
    final provider = raw.substring(0, separatorIndex).trim().toLowerCase();
    if (provider != 'google') return const <String, String>{};
    final encodedPayload = raw.substring(separatorIndex + 1).trim();
    if (encodedPayload.isEmpty) return const <String, String>{};
    try {
      final decoded =
          utf8.decode(base64Url.decode(base64.normalize(encodedPayload)));
      final payload = jsonDecode(decoded);
      if (payload is! Map) return const <String, String>{};
      final projectId = (payload['projectId'] ?? '').toString().trim();
      if (projectId.isEmpty) return const <String, String>{};
      final projectRole = (payload['projectRole'] ?? '').toString().trim();
      final projectName = (payload['projectName'] ?? '').toString().trim();
      final ownerEmail = (payload['ownerEmail'] ?? '').toString().trim();
      return <String, String>{
        'projectId': projectId,
        if (projectRole.isNotEmpty) 'projectRole': projectRole,
        if (projectName.isNotEmpty) 'projectName': projectName,
        if (ownerEmail.isNotEmpty) 'ownerEmail': ownerEmail,
      };
    } catch (_) {
      return const <String, String>{};
    }
  }

  bool _isRestrictedInviteRole(String? role) {
    final normalized = (role ?? '').trim().toLowerCase();
    return normalized == 'partner' || normalized == 'paused';
  }

  bool get _isPartnerRestricted => _isRestrictedInviteRole(_projectAccessRole);
  bool get _isAgentInviteRole =>
      (_projectAccessRole ?? '').trim().toLowerCase() == 'agent';
  bool get _isInviteNavigationRestricted =>
      _isPartnerRestricted || _isAgentInviteRole;

  bool get _isProjectManagerInviteRole =>
      (_projectAccessRole ?? '').trim().toLowerCase() == 'project_manager';

  String? _roleBadgeLabelForViewer(String? rawRole) {
    final normalized = (rawRole ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'agent':
        return 'Agent';
      case 'partner':
      case 'paused':
        return 'Partner';
      case 'project_manager':
        return 'Project Manager';
      case 'admin':
      case 'owner':
        return 'Admin';
      default:
        return null;
    }
  }

  String _roleLabelForOption(String role) {
    final normalized = role.trim().toLowerCase();
    switch (normalized) {
      case 'agent':
        return 'Agent';
      case 'partner':
      case 'paused':
        return 'Partner';
      case 'project_manager':
        return 'Project Manager';
      case 'admin':
      case 'owner':
        return 'Admin';
      default:
        return role;
    }
  }

  List<String> _pausedOverlaySwitchRoleOptions() {
    final current = (_projectAccessRole ?? '').trim().toLowerCase();
    final options = <String>[];
    for (final role in _projectAccessRoleOptions) {
      final normalized = _normalizeRoleOption(role);
      if (normalized.isEmpty) continue;
      if (normalized == current) continue;
      if (_deniedProjectRoles.contains(normalized)) continue;
      if (options.contains(normalized)) continue;
      options.add(normalized);
    }
    return options;
  }

  List<String> _globalRoleOptions() {
    final currentRole = _normalizeRoleOption(_projectAccessRole ?? '');
    return _mergeAndSortRoleOptions(
      _projectAccessRoleOptions,
      includeRole: currentRole.isNotEmpty ? currentRole : null,
    );
  }

  Widget _buildGlobalRoleBadge({
    required String roleLabel,
    required String selectedRole,
    required List<String> roleOptions,
  }) {
    final normalizedSelectedRole = _normalizeRoleOption(selectedRole);
    final canSwitchRole =
        normalizedSelectedRole.isNotEmpty && roleOptions.length > 1;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
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
      child: Row(
        children: [
          Text(
            'Role:',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 180,
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
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
            alignment: Alignment.centerLeft,
            child: canSwitchRole
                ? GestureDetector(
                    key: _globalRoleDropdownTriggerKey,
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      _showGlobalRoleDropdown(
                        context,
                        roleOptions: roleOptions,
                        selectedRole: normalizedSelectedRole,
                        tapGlobalPosition: details.globalPosition,
                      );
                    },
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            roleLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SvgPicture.asset(
                          'assets/images/Drrrop_down.svg',
                          width: 14,
                          height: 7,
                          fit: BoxFit.contain,
                          colorFilter: const ColorFilter.mode(
                            Colors.black,
                            BlendMode.srcIn,
                          ),
                          placeholderBuilder: (_) => const SizedBox(
                            width: 14,
                            height: 7,
                          ),
                        ),
                      ],
                    ),
                  )
                : Text(
                    roleLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: Colors.black,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _removeGlobalRoleDropdown() {
    _globalRoleDropdownOverlayEntry?.remove();
    _globalRoleDropdownBackdropEntry?.remove();
    _globalRoleDropdownOverlayEntry = null;
    _globalRoleDropdownBackdropEntry = null;
  }

  void _showGlobalRoleDropdown(
    BuildContext context, {
    required List<String> roleOptions,
    required String selectedRole,
    Offset? tapGlobalPosition,
  }) {
    if (roleOptions.length < 2 || selectedRole.trim().isEmpty) {
      return;
    }

    final renderBox = _globalRoleDropdownTriggerKey.currentContext
        ?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    _removeGlobalRoleDropdown();

    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final topRight = renderBox.localToGlobal(
      Offset(renderBox.size.width, 0),
      ancestor: overlayBox,
    );

    const double listTopPadding = 8;
    const double listBottomPadding = 8;
    const double optionHeight = 32;
    const double triggerGap = 0;
    const double optionGap = 8;
    final double dropdownWidth =
        math.max(1.0, (topRight.dx - offset.dx) + 14.0);
    const double popupOptionFontSize = 11.0;
    final int optionCount = roleOptions.length;
    final double calculatedMenuHeight = listTopPadding +
        (optionCount * optionHeight) +
        ((optionCount - 1) * optionGap) +
        listBottomPadding;
    final double overlayHeight = overlayBox.size.height;
    final double cellTop = offset.dy;
    final double cellBottom = offset.dy + renderBox.size.height;
    final double topBelow = cellBottom + triggerGap;
    final double spaceBelow = overlayHeight - topBelow - triggerGap;
    final double spaceAbove = cellTop - triggerGap;
    final bool shouldOpenUpward =
        calculatedMenuHeight > spaceBelow && spaceAbove > spaceBelow;
    final double availableHeight =
        shouldOpenUpward ? math.max(0, spaceAbove) : math.max(0, spaceBelow);
    final double maxMenuHeight =
        math.min(calculatedMenuHeight, availableHeight);
    final double top = (shouldOpenUpward
            ? math.max(triggerGap, cellTop - triggerGap - maxMenuHeight)
            : topBelow) +
        4.0;
    final double left = math.max(0.0, offset.dx - 6.0);

    String? hoveredRole;

    _globalRoleDropdownBackdropEntry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: GestureDetector(
          onTap: _removeGlobalRoleDropdown,
          child: Container(color: Colors.transparent),
        ),
      ),
    );

    _globalRoleDropdownOverlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: left,
        top: top,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: dropdownWidth,
            height: maxMenuHeight,
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 2,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
            child: StatefulBuilder(
              builder: (popupContext, setPopupState) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.only(
                          left: 8,
                          right: 8,
                          top: listTopPadding,
                          bottom: listBottomPadding,
                        ),
                        itemCount: roleOptions.length,
                        separatorBuilder: (_, __) => const SizedBox(
                          height: optionGap,
                        ),
                        itemBuilder: (_, index) {
                          final role = roleOptions[index];
                          final isSelected = role == selectedRole;
                          final isHovered = hoveredRole == role;
                          final roleLabel = _roleLabelForOption(role);
                          final optionBg = (isSelected || isHovered)
                              ? const Color(0xFFECF6FD)
                              : Colors.white;

                          return MouseRegion(
                            cursor: SystemMouseCursors.click,
                            onEnter: (_) => setPopupState(() {
                              hoveredRole = role;
                            }),
                            onExit: (_) => setPopupState(() {
                              if (hoveredRole == role) {
                                hoveredRole = null;
                              }
                            }),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                _removeGlobalRoleDropdown();
                                if (role == selectedRole) return;
                                unawaited(_handleDashboardRoleChanged(role));
                              },
                              child: SizedBox(
                                height: optionHeight,
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: optionBg,
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.25),
                                        blurRadius: 2,
                                        offset: const Offset(0, 0),
                                      ),
                                    ],
                                  ),
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    roleLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.inter(
                                      fontSize: popupOptionFontSize,
                                      fontWeight: FontWeight.normal,
                                      color: const Color(0xFF000000),
                                      height: 1.0,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );

    overlay.insert(_globalRoleDropdownBackdropEntry!);
    overlay.insert(_globalRoleDropdownOverlayEntry!);
  }

  Widget _buildScreenWithOverlays({
    required Widget layout,
    required bool showPausedAccessOverlay,
    required bool showRoleBadge,
    String? roleBadgeLabel,
    required String selectedRole,
    required List<String> roleOptions,
  }) {
    if (!showPausedAccessOverlay && !showRoleBadge) return layout;
    final children = <Widget>[layout];
    if (showPausedAccessOverlay) {
      children.add(_buildPausedAccessOverlay());
    }
    if (showRoleBadge && roleBadgeLabel != null) {
      children.add(
        Positioned(
          top: 24,
          right: 24,
          child: _buildGlobalRoleBadge(
            roleLabel: roleBadgeLabel,
            selectedRole: selectedRole,
            roleOptions: roleOptions,
          ),
        ),
      );
    }
    return Stack(children: children);
  }

  bool _isPageAllowedForInviteRole(
    NavigationPage page, {
    String? roleOverride,
  }) {
    final normalizedRole =
        (roleOverride ?? _projectAccessRole ?? '').trim().toLowerCase();
    if (normalizedRole == 'agent') {
      return page == NavigationPage.home ||
          page == NavigationPage.dashboard ||
          page == NavigationPage.documents ||
          page == NavigationPage.settings;
    }
    if (normalizedRole == 'partner' || normalizedRole == 'paused') {
      return page == NavigationPage.home ||
          page == NavigationPage.dashboard ||
          page == NavigationPage.documents ||
          page == NavigationPage.settings;
    }
    return true;
  }

  String _normalizeRoleOption(String rawRole) {
    final normalized = (rawRole).trim().toLowerCase();
    if (normalized.isEmpty) return '';
    if (normalized == 'paused') return '';
    if (normalized == 'owner' ||
        normalized == 'admin' ||
        normalized == 'partner' ||
        normalized == 'project_manager' ||
        normalized == 'agent') {
      return normalized;
    }
    return ProjectAccessService.normalizeRole(normalized);
  }

  String _normalizeRoleOptionStrict(String rawRole) {
    final normalized = (rawRole).trim().toLowerCase();
    if (normalized == 'owner' ||
        normalized == 'admin' ||
        normalized == 'partner' ||
        normalized == 'project_manager' ||
        normalized == 'agent') {
      return normalized;
    }
    return '';
  }

  List<String> _mergeAndSortRoleOptions(
    Iterable<String> rawRoles, {
    String? includeRole,
  }) {
    final merged = <String>{};
    for (final role in rawRoles) {
      final normalized = _normalizeRoleOption(role);
      if (normalized.isEmpty) continue;
      merged.add(normalized);
    }
    final includeNormalized = _normalizeRoleOption(includeRole ?? '');
    if (includeNormalized.isNotEmpty) {
      merged.add(includeNormalized);
    }
    return ProjectAccessService.sortRolesForUi(merged);
  }

  Future<Set<String>> _resolveDeniedRolesForCurrentUser({
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedEmail =
        (Supabase.instance.client.auth.currentUser?.email ?? '')
            .trim()
            .toLowerCase();
    if (normalizedProjectId.isEmpty || normalizedEmail.isEmpty) {
      return <String>{};
    }

    try {
      final inviteRows = await Supabase.instance.client
          .from('project_access_invites')
          .select('role, status, requested_at')
          .eq('project_id', normalizedProjectId)
          .eq('invited_email', normalizedEmail)
          .order('requested_at', ascending: false);

      final latestStatusByRole = <String, String>{};
      for (final row in inviteRows) {
        final normalizedRole =
            _normalizeRoleOptionStrict((row['role'] ?? '').toString());
        if (normalizedRole.isEmpty ||
            latestStatusByRole.containsKey(normalizedRole)) {
          continue;
        }
        final status = (row['status'] ?? '').toString().trim().toLowerCase();
        if (status.isEmpty) continue;
        latestStatusByRole[normalizedRole] = status;
      }

      final deniedRoles = <String>{};
      latestStatusByRole.forEach((role, status) {
        if (status == 'revoked' || status == 'paused' || status == 'expired') {
          deniedRoles.add(role);
        }
      });
      return deniedRoles;
    } catch (_) {
      return <String>{};
    }
  }

  Future<String?> _resolvePreferredActiveRoleForProject({
    required String projectId,
    String? preferredRole,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return null;

    List<String> resolvedRoles = const <String>[];
    try {
      resolvedRoles =
          await ProjectAccessService.resolveCurrentUserRolesForProject(
        projectId: normalizedProjectId,
      );
    } catch (_) {
      resolvedRoles = const <String>[];
    }

    final activeRoles = resolvedRoles
        .map((role) => _normalizeRoleOption(role))
        .where((role) => role.isNotEmpty)
        .toSet();
    if (activeRoles.isEmpty) return null;
    if (activeRoles.contains('owner')) return 'owner';

    final deniedRoles = await _resolveDeniedRolesForCurrentUser(
      projectId: normalizedProjectId,
    );
    final normalizedPreferred = _normalizeRoleOption(preferredRole ?? '');
    if (normalizedPreferred.isNotEmpty &&
        activeRoles.contains(normalizedPreferred) &&
        !deniedRoles.contains(normalizedPreferred)) {
      return normalizedPreferred;
    }

    final eligibleRoles = ProjectAccessService.sortRolesForUi(
      activeRoles.where((role) => !deniedRoles.contains(role)),
    );
    if (eligibleRoles.isEmpty) return null;
    return eligibleRoles.first;
  }

  Future<void> _refreshProjectRoleOptions({
    String? projectId,
    String? selectedRole,
  }) async {
    final normalizedProjectId = (projectId ?? _projectId ?? '').trim();
    if (normalizedProjectId.isEmpty) {
      if (!mounted) return;
      _setStateSafely(() {
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = false;
      });
      return;
    }

    List<String> resolvedRoles = const <String>[];
    Set<String> deniedRoles = <String>{};
    try {
      resolvedRoles =
          await ProjectAccessService.resolveCurrentUserRolesForProject(
        projectId: normalizedProjectId,
      );
    } catch (_) {
      resolvedRoles = const <String>[];
    }

    deniedRoles = await _resolveDeniedRolesForCurrentUser(
      projectId: normalizedProjectId,
    );

    final currentRole =
        (selectedRole ?? _projectAccessRole ?? '').trim().toLowerCase();
    final activeRoles = resolvedRoles
        .map((role) => _normalizeRoleOption(role))
        .where((role) => role.isNotEmpty)
        .toSet();
    final shouldAutoSwitchRole = currentRole.isNotEmpty &&
        deniedRoles.contains(currentRole) &&
        !activeRoles.contains(currentRole) &&
        activeRoles.isNotEmpty;
    final nextSelectedRole = shouldAutoSwitchRole
        ? ProjectAccessService.sortRolesForUi(activeRoles).first
        : currentRole;
    final nextOptions = _mergeAndSortRoleOptions(
      resolvedRoles,
      includeRole: nextSelectedRole.isNotEmpty ? nextSelectedRole : null,
    );

    if (!mounted) return;
    _setStateSafely(() {
      _projectAccessRoleOptions = nextOptions;
      _activeProjectRoles = activeRoles;
      _deniedProjectRoles = deniedRoles;
      _hasResolvedProjectRoles = true;
      if (nextSelectedRole.isNotEmpty &&
          nextSelectedRole != (_projectAccessRole ?? '').trim().toLowerCase()) {
        _projectAccessRole = nextSelectedRole;
      }
    });
    if (shouldAutoSwitchRole && mounted) {
      unawaited(_persistNavState());
    }
  }

  bool _isSelectedRoleDenied() {
    final currentRole = (_projectAccessRole ?? '').trim().toLowerCase();
    if (currentRole.isEmpty) return false;
    if (currentRole == 'paused') return true;
    if (!_hasResolvedProjectRoles) return false;
    if (_activeProjectRoles.contains(currentRole)) return false;
    return _deniedProjectRoles.contains(currentRole);
  }

  Future<void> _handleDashboardRoleChanged(String selectedRole) async {
    final normalizedRole = _normalizeRoleOption(selectedRole);
    if (normalizedRole.isEmpty) return;
    if (normalizedRole == (_projectAccessRole ?? '').trim().toLowerCase()) {
      return;
    }

    final pageAllowed = _isPageAllowedForInviteRole(
      _currentPage,
      roleOverride: normalizedRole,
    );
    final nextPage = pageAllowed ? _currentPage : NavigationPage.dashboard;
    _ensureRetainedPageInitialized(nextPage);

    _setStateSafely(() {
      _projectAccessRole = normalizedRole;
      if (!pageAllowed) {
        _previousPage = _currentPage;
        _currentPage = NavigationPage.dashboard;
      }
    });

    if (!pageAllowed) {
      _initializeHistory(NavigationPage.dashboard);
    }

    await _persistNavState();
    await _refreshProjectRoleOptions(selectedRole: normalizedRole);
  }

  bool _computeDataEntryHardErrorState() {
    final hasProjectManagerHardErrors =
        _hasProjectManagerErrors && !_hasProjectManagerWarningOnly;
    final hasAgentHardErrors = _hasAgentErrors && !_hasAgentWarningOnly;
    return _hasAreaErrors ||
        _hasPartnerErrors ||
        _hasExpenseErrors ||
        _hasSiteErrors ||
        hasProjectManagerHardErrors ||
        hasAgentHardErrors ||
        _hasAboutErrors;
  }

  void _scheduleDataEntryBadgeRecalc() {
    if (_pendingDataEntryBadgeRecalc) return;
    _pendingDataEntryBadgeRecalc = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingDataEntryBadgeRecalc = false;
      if (!mounted) return;
      final next = _computeDataEntryHardErrorState();
      if (_hasDataEntryErrors == next) return;
      setState(() {
        _hasDataEntryErrors = next;
      });
    });
  }

  void _setStateSafely(VoidCallback fn) {
    if (!mounted) return;
    final phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      setState(fn);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(fn);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startProjectSyncTimer();
    _restoreNavState();
  }

  @override
  void dispose() {
    _removeGlobalRoleDropdown();
    _savingStatusReconcileTimer?.cancel();
    _projectSyncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _startProjectSyncTimer() {
    _projectSyncTimer?.cancel();
    _projectSyncTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) {
        unawaited(_pollProjectUpdates());
      },
    );
  }

  DateTime? _parseUtcTimestamp(dynamic raw) {
    final value = (raw ?? '').toString().trim();
    if (value.isEmpty) return null;
    return DateTime.tryParse(value)?.toUtc();
  }

  Future<DateTime?> _computeProjectSyncWatermark(String projectId) async {
    DateTime? latest;

    void absorb(DateTime? value) {
      if (value == null) return;
      if (latest == null || value.isAfter(latest!)) {
        latest = value;
      }
    }

    try {
      final projectRow = await Supabase.instance.client
          .from('projects')
          .select('updated_at')
          .eq('id', projectId)
          .maybeSingle();
      absorb(_parseUtcTimestamp(projectRow?['updated_at']));
    } catch (_) {}

    try {
      final latestAmenity = await Supabase.instance.client
          .from('amenity_areas')
          .select('updated_at')
          .eq('project_id', projectId)
          .order('updated_at', ascending: false)
          .limit(1)
          .maybeSingle();
      absorb(_parseUtcTimestamp(latestAmenity?['updated_at']));
    } catch (_) {}

    List<Map<String, dynamic>> layoutRows = const <Map<String, dynamic>>[];
    try {
      final layouts = await Supabase.instance.client
          .from('layouts')
          .select('id,updated_at')
          .eq('project_id', projectId);
      layoutRows = List<Map<String, dynamic>>.from(layouts);
      for (final row in layoutRows) {
        absorb(_parseUtcTimestamp(row['updated_at']));
      }
    } catch (_) {}

    final layoutIds = layoutRows
        .map((row) => (row['id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (layoutIds.isNotEmpty) {
      try {
        final latestPlot = await Supabase.instance.client
            .from('plots')
            .select('updated_at')
            .inFilter('layout_id', layoutIds)
            .order('updated_at', ascending: false)
            .limit(1)
            .maybeSingle();
        absorb(_parseUtcTimestamp(latestPlot?['updated_at']));
      } catch (_) {}
    }

    return latest;
  }

  Future<void> _pollProjectUpdates() async {
    if (!mounted || _isProjectSyncTickRunning) return;

    final projectId = (_projectId ?? '').trim();
    if (projectId.isEmpty) {
      _lastSeenProjectIdForSync = null;
      _lastSeenProjectUpdatedAt = null;
      return;
    }

    // Avoid interrupting in-progress editors on this client.
    if (_currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails) {
      return;
    }

    if (_lastSeenProjectIdForSync != projectId) {
      _lastSeenProjectIdForSync = projectId;
      _lastSeenProjectUpdatedAt = null;
    }

    if (_isSelectedRoleDenied()) {
      final now = DateTime.now().toUtc();
      final lastRefresh = _lastPausedRoleOptionsRefreshAt;
      final shouldRefreshRoleOptions = !_isPausedRoleOptionsRefreshRunning &&
          (lastRefresh == null ||
              now.difference(lastRefresh) >= const Duration(seconds: 4));
      if (shouldRefreshRoleOptions) {
        _isPausedRoleOptionsRefreshRunning = true;
        unawaited(() async {
          try {
            await _refreshProjectRoleOptions(
              projectId: projectId,
              selectedRole: _projectAccessRole,
            );
          } finally {
            _isPausedRoleOptionsRefreshRunning = false;
            _lastPausedRoleOptionsRefreshAt = DateTime.now().toUtc();
          }
        }());
      }
    }

    _isProjectSyncTickRunning = true;
    try {
      final updatedAt = await _computeProjectSyncWatermark(projectId);
      if (updatedAt == null) return;

      final previous = _lastSeenProjectUpdatedAt;
      if (previous == null) {
        _lastSeenProjectUpdatedAt = updatedAt;
        return;
      }

      if (updatedAt.isAfter(previous)) {
        _lastSeenProjectUpdatedAt = updatedAt;
        _setStateSafely(() {
          _projectDataVersion++;
          if (_currentPage == NavigationPage.dashboard) {
            _isDashboardPageLoading = true;
          }
        });
        _refreshErrorBadgesFromStoredData();
      }
    } catch (_) {
      // Best effort sync poll.
    } finally {
      _isProjectSyncTickRunning = false;
    }
  }

  void _startSavingStatusReconcile() {
    _savingStatusReconcileTimer?.cancel();
    _savingStatusReconcileTimer = Timer.periodic(
      const Duration(seconds: 2),
      (timer) async {
        if (!mounted) {
          timer.cancel();
          return;
        }
        final shouldReconcile = _saveStatus == ProjectSaveStatusType.saving ||
            _saveStatus == ProjectSaveStatusType.notSaved ||
            _saveStatus == ProjectSaveStatusType.queuedOffline;
        if (!shouldReconcile) {
          timer.cancel();
          return;
        }
        final projectId = _projectId?.trim();
        if (projectId == null || projectId.isEmpty) {
          timer.cancel();
          return;
        }

        try {
          final prefs = await SharedPreferences.getInstance();
          final localEditMs =
              prefs.getInt('project_${projectId}_last_local_edit_ms') ?? 0;
          final remoteSaveMs =
              prefs.getInt('project_${projectId}_last_remote_save_ms') ?? 0;
          if (_saveStatus == ProjectSaveStatusType.queuedOffline) {
            final currentUserId = Supabase.instance.client.auth.currentUser?.id;
            final hasPendingCreate =
                await OfflineProjectSyncService.isPendingLocalProject(
              projectId: projectId,
              userId: currentUserId,
            );
            final hasPendingSave =
                await ProjectStorageService.hasPendingOfflineSaves(
              projectId: projectId,
            );
            if (hasPendingCreate || hasPendingSave) {
              return;
            }
          }

          // If remote save caught up with the latest local edit,
          // resolve stale "Saving..." / "Not saved" UI to Saved.
          final isSynced = (localEditMs == 0 && remoteSaveMs == 0) ||
              (localEditMs > 0 && remoteSaveMs >= localEditMs);
          if (isSynced) {
            _setStateSafely(() {
              if (_saveStatus == ProjectSaveStatusType.saving ||
                  _saveStatus == ProjectSaveStatusType.notSaved ||
                  _saveStatus == ProjectSaveStatusType.queuedOffline) {
                _saveStatus = ProjectSaveStatusType.saved;
                _savedTimeAgo = 'Just now';
                _projectDataDirty = false;
              }
            });
            timer.cancel();
          }
        } catch (_) {
          // Keep current status; next poll can retry.
        }
      },
    );
  }

  void _recordPageVisit(NavigationPage page) {
    if (_pageHistory.isEmpty || _pageHistory.last != page) {
      _pageHistory.add(page);
    }
  }

  void _initializeHistory(NavigationPage current) {
    _pageHistory
      ..clear()
      ..add(current);
  }

  NavigationPage _normalizePageForRetention(NavigationPage page) {
    switch (page) {
      case NavigationPage.projectDetails:
        return NavigationPage.dataEntry;
      case NavigationPage.home:
        return _previousPage ?? NavigationPage.recentProjects;
      case NavigationPage.logout:
        return NavigationPage.account;
      default:
        return page;
    }
  }

  bool _isProjectScopedPage(NavigationPage page) {
    return page == NavigationPage.projectDetails ||
        page == NavigationPage.dataEntry ||
        page == NavigationPage.dashboard ||
        page == NavigationPage.plotStatus ||
        page == NavigationPage.documents ||
        page == NavigationPage.settings ||
        page == NavigationPage.report;
  }

  NavigationPage? _pageFromBrowserPath(String rawPath) {
    final normalizedPath = rawPath.trim().toLowerCase();
    if (normalizedPath.isEmpty ||
        normalizedPath == '/' ||
        normalizedPath.endsWith('/index.html')) {
      return null;
    }
    final segments = normalizedPath
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) return null;
    final lastSegment = Uri.decodeComponent(segments.last).trim().toLowerCase();
    switch (lastSegment) {
      case 'dataentry':
      case 'data-entry':
      case 'data entry':
        return NavigationPage.dataEntry;
      case 'plotstatus':
      case 'plot-status':
      case 'plot status':
        return NavigationPage.plotStatus;
      case 'documents':
        return NavigationPage.documents;
      case 'report':
      case 'reports':
        return NavigationPage.report;
      case 'settings':
        return NavigationPage.settings;
      case 'dashboard':
        return NavigationPage.dashboard;
      case 'recent':
      case 'recentprojects':
      case 'recent-projects':
        return NavigationPage.recentProjects;
      case 'allprojects':
      case 'all-projects':
        return NavigationPage.allProjects;
      case 'help':
        return NavigationPage.help;
      case 'trash':
        return NavigationPage.trash;
      case 'account':
        return NavigationPage.account;
      case 'notifications':
        return NavigationPage.notifications;
      case 'todo':
      case 'to-do':
      case 'to-do-list':
      case 'todolist':
        return NavigationPage.toDoList;
      default:
        return null;
    }
  }

  String _browserPathForPage(NavigationPage page) {
    if (_isProjectScopedPage(page) && (_projectId ?? '').trim().isEmpty) {
      return '/Recent-Projects';
    }
    switch (page) {
      case NavigationPage.projectDetails:
      case NavigationPage.dataEntry:
        return '/DataEntry';
      case NavigationPage.plotStatus:
        return '/Plot-Status';
      case NavigationPage.documents:
        return '/Documents';
      case NavigationPage.report:
        return '/Reports';
      case NavigationPage.settings:
        return '/Settings';
      case NavigationPage.dashboard:
        return '/Dashboard';
      case NavigationPage.recentProjects:
      case NavigationPage.home:
        return '/Recent-Projects';
      case NavigationPage.allProjects:
        return '/All-Projects';
      case NavigationPage.help:
        return '/Help';
      case NavigationPage.trash:
        return '/Trash';
      case NavigationPage.account:
        return '/Account';
      case NavigationPage.notifications:
        return '/Notifications';
      case NavigationPage.toDoList:
        return '/To-Do-List';
      case NavigationPage.logout:
        return '/Logout';
    }
  }

  void _syncBrowserPathWithCurrentPage() {
    final targetPath = _browserPathForPage(_currentPage);
    if (_lastSyncedBrowserPath == targetPath) return;
    _lastSyncedBrowserPath = targetPath;
    web_nav.replaceBrowserPath(targetPath);
  }

  void _ensureRetainedPageInitialized(NavigationPage page) {
    _initializedRetainedPages.add(_normalizePageForRetention(page));
  }

  Future<void> _handleBrowserBackNavigation() async {
    _removeGlobalRoleDropdown();
    if (_isInviteNavigationRestricted) {
      if (_currentPage == NavigationPage.dashboard) return;
      _ensureRetainedPageInitialized(NavigationPage.dashboard);
      _setStateSafely(() {
        _currentPage = NavigationPage.dashboard;
        _previousPage = null;
      });
      _initializeHistory(NavigationPage.dashboard);
      await _persistNavState();
      return;
    }

    if (_currentPage == NavigationPage.recentProjects) {
      return;
    }
    _ensureRetainedPageInitialized(NavigationPage.recentProjects);
    _setStateSafely(() {
      _currentPage = NavigationPage.recentProjects;
      _previousPage = null;
    });
    _initializeHistory(NavigationPage.recentProjects);
    await _persistNavState();
    _refreshErrorBadgesFromStoredData();
  }

  @override
  Future<bool> didPopRoute() async {
    await _handleBrowserBackNavigation();
    return true;
  }

  Future<void> _restoreNavState() async {
    final prefs = await SharedPreferences.getInstance();
    final params = Uri.base.queryParameters;
    final pageFromPath = _pageFromBrowserPath(Uri.base.path);
    final authInviteContext =
        _extractInviteContextFromAuthValue(params['auth']);
    final isReload = await web_nav.isReloadNavigation();
    final forceRecentOnNextOpen =
        prefs.getBool('nav_force_recent_on_next_open') ?? false;
    final openInviteDashboardOnce =
        prefs.getBool('nav_open_invite_dashboard_once') ?? false;
    final pageName = pageFromPath?.name ?? prefs.getString('nav_current_page');
    final prevPageName = prefs.getString('nav_previous_page');
    final projectId = prefs.getString('nav_project_id');
    var projectName =
        prefs.getString('nav_project_name') ?? authInviteContext['projectName'];
    var projectOwnerEmail = ((prefs.getString('nav_project_owner_email') ??
                authInviteContext['ownerEmail'] ??
                params['ownerEmail'] ??
                '')
            .trim())
        .toLowerCase();
    final hasInviteContextFlag =
        prefs.getBool('nav_has_invite_context') ?? false;
    final rawProjectAccessRole = prefs.getString('nav_invited_project_role');
    final projectAccessRole = (rawProjectAccessRole ?? '').trim().toLowerCase();
    final inviteProjectIdFromUrl =
        (params['projectId'] ?? authInviteContext['projectId'] ?? '').trim();
    final hasInviteMarkerInUrl =
        params['invite'] == '1' || inviteProjectIdFromUrl.isNotEmpty;
    final normalizedProjectIdFromPrefs = (projectId ?? '').trim();
    final hasPersistedMemberContext = normalizedProjectIdFromPrefs.isNotEmpty &&
        (hasInviteContextFlag ||
            openInviteDashboardOnce ||
            projectAccessRole.isNotEmpty);
    final normalizedProjectId = normalizedProjectIdFromPrefs.isNotEmpty
        ? normalizedProjectIdFromPrefs
        : inviteProjectIdFromUrl;
    final inviteProjectRoleFromUrl =
        (params['projectRole'] ?? authInviteContext['projectRole'] ?? '')
            .trim()
            .toLowerCase();
    final effectiveProjectAccessRole = projectAccessRole.isNotEmpty
        ? projectAccessRole
        : inviteProjectRoleFromUrl;
    var hasInviteContext = normalizedProjectId.isNotEmpty &&
        (hasInviteContextFlag ||
            openInviteDashboardOnce ||
            effectiveProjectAccessRole.isNotEmpty ||
            params['invite'] == '1' ||
            inviteProjectIdFromUrl.isNotEmpty);
    var resolvedInviteRole =
        hasInviteContext && effectiveProjectAccessRole.isEmpty
            ? 'partner'
            : effectiveProjectAccessRole;

    var validatedProjectId = normalizedProjectId;
    if (validatedProjectId.isNotEmpty) {
      var isPendingLocalProject = false;
      try {
        isPendingLocalProject =
            await OfflineProjectSyncService.isPendingLocalProject(
          projectId: validatedProjectId,
          userId: Supabase.instance.client.auth.currentUser?.id,
        );
      } catch (_) {
        isPendingLocalProject = false;
      }
      String? validatedRole;
      if (isPendingLocalProject) {
        validatedRole = 'owner';
      } else {
        try {
          validatedRole = await _resolvePreferredActiveRoleForProject(
            projectId: validatedProjectId,
            preferredRole: resolvedInviteRole,
          );
        } catch (_) {
          validatedRole = null;
        }
      }

      final normalizedValidatedRole =
          (validatedRole ?? '').trim().toLowerCase();
      if (normalizedValidatedRole.isEmpty) {
        final shouldPreservePersistedMemberContext = isReload &&
            hasPersistedMemberContext &&
            !hasInviteMarkerInUrl &&
            normalizedProjectIdFromPrefs.isNotEmpty;
        final shouldPreserveOfflineProjectContext = isPendingLocalProject;
        if (shouldPreservePersistedMemberContext ||
            shouldPreserveOfflineProjectContext) {
          if (shouldPreserveOfflineProjectContext) {
            hasInviteContext = false;
            resolvedInviteRole = '';
            await prefs.remove('nav_invited_project_role');
            await prefs.remove('nav_has_invite_context');
            await prefs.setBool('nav_force_recent_on_next_open', false);
          } else {
            hasInviteContext = true;
            resolvedInviteRole = projectAccessRole.isNotEmpty
                ? projectAccessRole
                : (resolvedInviteRole.isEmpty ? 'partner' : resolvedInviteRole);
            await prefs.setBool('nav_has_invite_context', true);
            if (resolvedInviteRole.isNotEmpty) {
              await prefs.setString(
                  'nav_invited_project_role', resolvedInviteRole);
            }
            await prefs.setBool('nav_force_recent_on_next_open', false);
          }
        } else {
          validatedProjectId = '';
          projectName = null;
          projectOwnerEmail = '';
          hasInviteContext = false;
          resolvedInviteRole = '';
          await prefs.remove('nav_project_id');
          await prefs.remove('nav_project_name');
          await prefs.remove('nav_project_owner_email');
          await prefs.remove('nav_invited_project_role');
          await prefs.remove('nav_has_invite_context');
          await prefs.remove('nav_open_invite_dashboard_once');
        }
      } else if (normalizedValidatedRole == 'owner') {
        hasInviteContext = false;
        resolvedInviteRole = '';
        await prefs.remove('nav_invited_project_role');
        await prefs.remove('nav_has_invite_context');
      } else {
        hasInviteContext = true;
        resolvedInviteRole = normalizedValidatedRole;
        await prefs.setString(
            'nav_invited_project_role', normalizedValidatedRole);
        await prefs.setBool('nav_has_invite_context', true);
      }
      await prefs.remove('nav_access_denied_notice');
    }

    final hasMissingProjectName =
        (projectName == null || projectName.trim().isEmpty) &&
            validatedProjectId.isNotEmpty;
    if (hasMissingProjectName) {
      try {
        final projectData = await ProjectStorageService.fetchProjectDataById(
            validatedProjectId);
        final resolvedProjectName =
            (projectData?['projectName'] ?? projectData?['project_name'] ?? '')
                .toString()
                .trim();
        if (resolvedProjectName.isNotEmpty) {
          projectName = resolvedProjectName;
          await prefs.setString('nav_project_name', resolvedProjectName);
        }
      } catch (_) {
        // Continue with available navigation context.
      }
      if (projectName == null || projectName.trim().isEmpty) {
        final currentUserId = Supabase.instance.client.auth.currentUser?.id;
        if (currentUserId != null && currentUserId.trim().isNotEmpty) {
          final pendingProjects =
              await OfflineProjectSyncService.getPendingProjectsForUser(
            currentUserId,
          );
          String pendingName = '';
          for (final project in pendingProjects) {
            final id = (project['id'] ?? '').toString().trim();
            if (id != validatedProjectId) continue;
            pendingName = (project['project_name'] ?? '').toString().trim();
            break;
          }
          if (pendingName.isNotEmpty) {
            projectName = pendingName;
            await prefs.setString('nav_project_name', pendingName);
          }
        }
      }
    }

    final hasPersistedCurrentPage =
        pageName != null && pageName.trim().isNotEmpty;
    final shouldForceRecent = widget.forceRecentStart ||
        forceRecentOnNextOpen ||
        (!isReload && !hasPersistedCurrentPage);

    if (hasInviteContext &&
        validatedProjectId.isNotEmpty &&
        (openInviteDashboardOnce ||
            shouldForceRecent ||
            pageName == null ||
            pageName == NavigationPage.recentProjects.name)) {
      if (openInviteDashboardOnce) {
        await prefs.setBool('nav_open_invite_dashboard_once', false);
      }
      if (!hasInviteContextFlag) {
        await prefs.setBool('nav_has_invite_context', true);
      }
      if (normalizedProjectIdFromPrefs.isEmpty) {
        await prefs.setString('nav_project_id', validatedProjectId);
      }
      if (resolvedInviteRole.isNotEmpty &&
          effectiveProjectAccessRole != resolvedInviteRole) {
        await prefs.setString('nav_invited_project_role', resolvedInviteRole);
      }
      await prefs.remove('nav_force_recent_on_next_open');
      await prefs.setString('nav_current_page', NavigationPage.dashboard.name);
      await prefs.remove('nav_previous_page');
      _ensureRetainedPageInitialized(NavigationPage.dashboard);
      setState(() {
        _currentPage = NavigationPage.dashboard;
        _previousPage = null;
        _projectId = validatedProjectId;
        _projectName = projectName;
        _projectAccessRole = resolvedInviteRole;
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = false;
        _projectOwnerEmail =
            projectOwnerEmail.isEmpty ? null : projectOwnerEmail;
        _isRestoringNavState = false;
      });
      _initializeHistory(NavigationPage.dashboard);
      unawaited(
        _refreshProjectRoleOptions(
          projectId: validatedProjectId,
          selectedRole: resolvedInviteRole,
        ),
      );
      _refreshErrorBadgesFromStoredData();
      unawaited(_showPendingAccessDeniedNotice());
      _syncBrowserPathWithCurrentPage();
      return;
    }

    if (shouldForceRecent) {
      await prefs.remove('nav_force_recent_on_next_open');
      await prefs.setString(
          'nav_current_page', NavigationPage.recentProjects.name);
      await prefs.remove('nav_previous_page');
      _ensureRetainedPageInitialized(NavigationPage.recentProjects);
      setState(() {
        _currentPage = NavigationPage.recentProjects;
        _previousPage = null;
        _projectId = validatedProjectId.isEmpty ? null : validatedProjectId;
        _projectName = projectName;
        _projectAccessRole = hasInviteContext ? resolvedInviteRole : null;
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = false;
        _projectOwnerEmail =
            projectOwnerEmail.isEmpty ? null : projectOwnerEmail;
        _isRestoringNavState = false;
      });
      _initializeHistory(NavigationPage.recentProjects);
      if (hasInviteContext) {
        unawaited(
          _refreshProjectRoleOptions(
            projectId: validatedProjectId,
            selectedRole: resolvedInviteRole,
          ),
        );
      }
      _refreshErrorBadgesFromStoredData();
      unawaited(_showPendingAccessDeniedNotice());
      _syncBrowserPathWithCurrentPage();
      return;
    }

    if (pageName != null) {
      final page = NavigationPage.values.firstWhere(
        (e) => e.name == pageName,
        orElse: () => NavigationPage.recentProjects,
      );
      final prevPage = prevPageName != null
          ? NavigationPage.values.firstWhere(
              (e) => e.name == prevPageName,
              orElse: () => NavigationPage.recentProjects,
            )
          : null;
      final isInviteRestrictedForRestore = hasInviteContext &&
          (resolvedInviteRole == 'agent' ||
              _isRestrictedInviteRole(resolvedInviteRole));
      var normalizedPage = (isInviteRestrictedForRestore &&
              !_isPageAllowedForInviteRole(
                page,
                roleOverride: resolvedInviteRole,
              ))
          ? NavigationPage.dashboard
          : page;
      if (_isProjectScopedPage(normalizedPage) && validatedProjectId.isEmpty) {
        normalizedPage = NavigationPage.recentProjects;
      }

      // Don't restore logout
      if (normalizedPage != NavigationPage.logout) {
        _ensureRetainedPageInitialized(normalizedPage);
        final normalizedPrevPage = (prevPage != null &&
                _isProjectScopedPage(prevPage) &&
                validatedProjectId.isEmpty)
            ? null
            : prevPage;
        setState(() {
          _currentPage = normalizedPage;
          _previousPage = normalizedPrevPage;
          _projectId = validatedProjectId.isEmpty ? null : validatedProjectId;
          _projectName = projectName;
          _projectAccessRole = hasInviteContext ? resolvedInviteRole : null;
          _projectAccessRoleOptions = <String>[];
          _activeProjectRoles = <String>{};
          _deniedProjectRoles = <String>{};
          _hasResolvedProjectRoles = false;
          _projectOwnerEmail =
              projectOwnerEmail.isEmpty ? null : projectOwnerEmail;
          _isRestoringNavState = false;
        });
        _initializeHistory(normalizedPage);
        if (hasInviteContext) {
          unawaited(
            _refreshProjectRoleOptions(
              projectId: validatedProjectId,
              selectedRole: resolvedInviteRole,
            ),
          );
        }
        _refreshErrorBadgesFromStoredData();
        unawaited(_showPendingAccessDeniedNotice());
        _syncBrowserPathWithCurrentPage();
        return;
      }
    }

    _ensureRetainedPageInitialized(NavigationPage.recentProjects);
    setState(() {
      _currentPage = NavigationPage.recentProjects;
      _previousPage = null;
      _projectId = validatedProjectId.isEmpty ? null : validatedProjectId;
      _projectName = projectName;
      _projectAccessRole = hasInviteContext ? resolvedInviteRole : null;
      _projectAccessRoleOptions = <String>[];
      _activeProjectRoles = <String>{};
      _deniedProjectRoles = <String>{};
      _hasResolvedProjectRoles = false;
      _projectOwnerEmail = projectOwnerEmail.isEmpty ? null : projectOwnerEmail;
      _isRestoringNavState = false;
    });
    _initializeHistory(NavigationPage.recentProjects);
    if (hasInviteContext) {
      unawaited(
        _refreshProjectRoleOptions(
          projectId: validatedProjectId,
          selectedRole: resolvedInviteRole,
        ),
      );
    }
    _refreshErrorBadgesFromStoredData();
    unawaited(_showPendingAccessDeniedNotice());
    _syncBrowserPathWithCurrentPage();
  }

  Future<void> _persistNavState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nav_current_page', _currentPage.name);
    if (_previousPage != null) {
      await prefs.setString('nav_previous_page', _previousPage!.name);
    } else {
      await prefs.remove('nav_previous_page');
    }
    if (_projectId != null) {
      await prefs.setString('nav_project_id', _projectId!);
    } else {
      await prefs.remove('nav_project_id');
    }
    if (_projectName != null) {
      await prefs.setString('nav_project_name', _projectName!);
    } else {
      await prefs.remove('nav_project_name');
    }
    if (_projectOwnerEmail != null && _projectOwnerEmail!.trim().isNotEmpty) {
      await prefs.setString(
        'nav_project_owner_email',
        _projectOwnerEmail!.trim().toLowerCase(),
      );
    } else {
      await prefs.remove('nav_project_owner_email');
    }
    if (_projectAccessRole != null && _projectAccessRole!.trim().isNotEmpty) {
      await prefs.setString('nav_invited_project_role', _projectAccessRole!);
      await prefs.setBool('nav_has_invite_context', true);
    } else {
      await prefs.remove('nav_invited_project_role');
      await prefs.remove('nav_has_invite_context');
    }
    _syncBrowserPathWithCurrentPage();
  }

  Future<void> _clearPersistedNavState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('nav_current_page');
    await prefs.remove('nav_previous_page');
    await prefs.remove('nav_project_id');
    await prefs.remove('nav_project_name');
    await prefs.remove('nav_project_owner_email');
    await prefs.remove('nav_invited_project_role');
    await prefs.remove('nav_has_invite_context');
    await prefs.remove('nav_open_invite_dashboard_once');
  }

  Future<void> _showPendingAccessDeniedNotice() async {
    final prefs = await SharedPreferences.getInstance();
    final message = (prefs.getString('nav_access_denied_notice') ?? '').trim();
    if (message.isEmpty) return;
    await prefs.remove('nav_access_denied_notice');
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
    });
  }

  Future<void> _resetProjectSectionSelections({
    required SharedPreferences prefs,
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    await prefs.setString(
      'project_$normalizedProjectId$_projectDataEntryTabPrefSuffix',
      ProjectTab.about.name,
    );
    await prefs.setString(
      'project_$normalizedProjectId$_projectDashboardTabPrefSuffix',
      DashboardTab.overview.name,
    );
    await prefs.setString(
      'project_$normalizedProjectId$_projectPlotStatusTabPrefSuffix',
      PlotStatusContentTab.site.name,
    );
    await prefs.setBool(
      '$_projectSettingsTabPrefPrefix$normalizedProjectId',
      false,
    );
  }

  bool _isMissingNumeric(dynamic value) {
    if (value == null) return true;
    if (value is num) return value <= 0;
    final parsed = double.tryParse(
      value.toString().replaceAll(',', '').replaceAll('₹', '').trim(),
    );
    return parsed == null || parsed <= 0;
  }

  double _parseNumeric(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(
      value.toString().replaceAll(',', '').replaceAll('₹', '').trim(),
    );
    return parsed ?? 0;
  }

  Map<String, dynamic> _toStringKeyedMap(dynamic value) {
    if (value is! Map) return const <String, dynamic>{};
    final result = <String, dynamic>{};
    value.forEach((key, nestedValue) {
      result[key.toString()] = nestedValue;
    });
    return result;
  }

  List<Map<String, dynamic>> _toMapList(dynamic value) {
    if (value is! List) return const <Map<String, dynamic>>[];
    final rows = <Map<String, dynamic>>[];
    for (final row in value) {
      rows.add(_toStringKeyedMap(row));
    }
    return rows;
  }

  Future<void> _refreshErrorBadgesFromStoredData() async {
    await _refreshAccountWarningBadge();

    final projectId = _projectId;
    if (projectId == null || projectId.trim().isEmpty) return;
    final generation = ++_errorBadgeRefreshGeneration;

    try {
      final rawData =
          await ProjectStorageService.fetchProjectDataById(projectId);
      if (!mounted || generation != _errorBadgeRefreshGeneration) return;
      if (rawData == null) return;
      final data = _toStringKeyedMap(rawData);

      final totalAreaValue = _parseNumeric(data['totalArea']);
      final sellingAreaValue = _parseNumeric(data['sellingArea']);

      final nonSellableAreas = _toMapList(data['nonSellableAreas']);
      final amenityAreas = _toMapList(data['amenityAreas']);
      final partners = _toMapList(data['partners']);
      final expenses = _toMapList(data['expenses']);
      final layouts = _toMapList(data['layouts']);
      final plots = _toMapList(data['plots']);
      final plotPartners = _toMapList(data['plot_partners']);
      final projectManagers = _toMapList(data['project_managers']);
      final agents = _toMapList(data['agents']);

      final partnersByPlotId = <String, List<String>>{};
      for (final row in plotPartners) {
        final plotId = (row['plot_id'] ?? '').toString();
        final partnerName = (row['partner_name'] ?? '').toString().trim();
        if (plotId.isEmpty || partnerName.isEmpty) continue;
        partnersByPlotId.putIfAbsent(plotId, () => <String>[]);
        partnersByPlotId[plotId]!.add(partnerName);
      }

      final hasAreaErrors = totalAreaValue <= 0 ||
          sellingAreaValue <= 0 ||
          sellingAreaValue > totalAreaValue ||
          nonSellableAreas.any((a) =>
              (a['name'] ?? '').toString().trim().isEmpty ||
              _isMissingNumeric(a['area'])) ||
          amenityAreas.any((a) =>
              (a['name'] ?? '').toString().trim().isEmpty ||
              _isMissingNumeric(a['area']) ||
              _isMissingNumeric(a['all_in_cost']));

      final totalNonSellableArea = nonSellableAreas.fold<double>(
        0.0,
        (sum, row) => sum + _parseNumeric(row['area']),
      );
      final totalAmenityArea = amenityAreas.fold<double>(
        0.0,
        (sum, row) => sum + _parseNumeric(row['area']),
      );
      final remainingArea = totalAreaValue -
          totalNonSellableArea -
          totalAmenityArea -
          sellingAreaValue;
      final hasSingleDefaultNonSellableRow = nonSellableAreas.length == 1 &&
          (() {
            final areaRaw = (nonSellableAreas.first['area'] ?? '')
                .toString()
                .replaceAll(',', '')
                .trim();
            return areaRaw.isEmpty || areaRaw == '0' || areaRaw == '0.00';
          })();
      final remainingAreaIsRed =
          (sellingAreaValue > totalAreaValue && totalAreaValue > 0) ||
              (remainingArea != 0 &&
                  nonSellableAreas.isNotEmpty &&
                  !hasSingleDefaultNonSellableRow);
      final effectiveAreaErrors = hasAreaErrors || remainingAreaIsRed;

      final hasPartnerErrors = partners.any((p) =>
          (p['name'] ?? '').toString().trim().isEmpty ||
          _isMissingNumeric(p['amount']));

      final hasExpenseErrors = expenses.any((e) =>
          (e['item'] ?? '').toString().trim().isEmpty ||
          (e['category'] ?? '').toString().trim().isEmpty ||
          _isMissingNumeric(e['amount']));

      final plotsByLayout = <String, List<Map<String, dynamic>>>{};
      for (final plot in plots) {
        final layoutId = (plot['layout_id'] ?? '').toString();
        if (layoutId.isEmpty) continue;
        plotsByLayout.putIfAbsent(layoutId, () => <Map<String, dynamic>>[]);
        plotsByLayout[layoutId]!.add(plot);
      }

      var hasSiteErrors = false;
      var hasPlotStatusErrors = false;
      for (final layout in layouts) {
        final layoutId = (layout['id'] ?? '').toString();
        final layoutName = (layout['name'] ?? '').toString().trim();
        if (layoutName.isEmpty) {
          hasSiteErrors = true;
        }
        final layoutPlots = plotsByLayout[layoutId] ?? const [];
        for (final plot in layoutPlots) {
          final plotId = (plot['id'] ?? '').toString();
          final plotNumber = (plot['plot_number'] ?? '').toString().trim();
          final areaMissing = _isMissingNumeric(plot['area']);
          final selectedPartners = partnersByPlotId[plotId] ?? const <String>[];

          // Mirror Data Entry live validation:
          // ignore fully untouched placeholder rows.
          final rowHasAnyInput = plotNumber.isNotEmpty ||
              !areaMissing ||
              selectedPartners.isNotEmpty;
          if (rowHasAnyInput &&
              (plotNumber.isEmpty || areaMissing || selectedPartners.isEmpty)) {
            hasSiteErrors = true;
          }

          final status = (plot['status'] ?? '').toString().trim().toLowerCase();
          if (status == 'sold' || status == 'reserved') {
            final salePriceMissing = _isMissingNumeric(plot['sale_price']);
            final buyerMissing =
                (plot['buyer_name'] ?? '').toString().trim().isEmpty;
            final agentMissing =
                (plot['agent_name'] ?? '').toString().trim().isEmpty;
            final dateMissing =
                (plot['sale_date'] ?? '').toString().trim().isEmpty;
            final payments = plot['payments'] as List<dynamic>? ?? const [];
            final hasPaymentMethod = payments.any((payment) {
              if (payment is Map<String, dynamic>) {
                final method = (payment['paymentMethod'] ??
                        payment['payment_method'] ??
                        '')
                    .toString()
                    .trim();
                return method.isNotEmpty;
              }
              if (payment is Map) {
                final method = (payment['paymentMethod'] ??
                        payment['payment_method'] ??
                        '')
                    .toString()
                    .trim();
                return method.isNotEmpty;
              }
              return false;
            });
            if (salePriceMissing ||
                buyerMissing ||
                agentMissing ||
                dateMissing ||
                !hasPaymentMethod) {
              hasPlotStatusErrors = true;
            }
          }
        }
      }

      bool hasProjectManagerErrors = false;
      for (final pm in projectManagers) {
        final name = (pm['name'] ?? '').toString().trim();
        final compensation = (pm['compensation_type'] ?? '').toString().trim();
        final earningType = (pm['earning_type'] ?? '').toString().trim();
        final nameEmpty = name.isEmpty;
        final compensationEmpty = compensation.isEmpty;
        final percentageBonusMissingEarningType =
            compensation == 'Percentage Bonus' && earningType.isEmpty;
        if (nameEmpty ||
            compensationEmpty ||
            percentageBonusMissingEarningType) {
          hasProjectManagerErrors = true;
          break;
        }
      }

      final hasProjectManagerWarningOnly = projectManagers.length == 1 &&
          (projectManagers.first['name'] ?? '').toString().trim().isEmpty &&
          (projectManagers.first['compensation_type'] ?? '')
              .toString()
              .trim()
              .isEmpty;

      bool hasAgentErrors = false;
      for (final agent in agents) {
        final name = (agent['name'] ?? '').toString().trim();
        final compensation =
            (agent['compensation_type'] ?? '').toString().trim();
        final earningType = (agent['earning_type'] ?? '').toString().trim();
        final nameEmpty = name.isEmpty;
        final compensationEmpty =
            compensation.isEmpty || compensation == 'None';
        final percentageBonusMissingEarningType =
            compensation == 'Percentage Bonus' && earningType.isEmpty;
        if (nameEmpty ||
            compensationEmpty ||
            percentageBonusMissingEarningType) {
          hasAgentErrors = true;
          break;
        }
      }

      final hasAgentWarningOnly = agents.length == 1 &&
          (agents.first['name'] ?? '').toString().trim().isEmpty &&
          (() {
            final compensation =
                (agents.first['compensation_type'] ?? '').toString().trim();
            return compensation.isEmpty || compensation == 'None';
          })();

      final projectName = (data['projectName'] ?? '').toString().trim();
      final projectAddress = (data['projectAddress'] ?? '').toString().trim();
      final googleMapsLink = (data['googleMapsLink'] ?? '').toString().trim();
      final uri = Uri.tryParse(googleMapsLink);
      final validMapPattern = RegExp(
        r'^(https?://)?(www\.)?(google\.com/maps|goo\.gl/maps|maps\.app\.goo\.gl|share\.google/)[\w\-]+',
        caseSensitive: false,
      );
      final isGoogleSearchLocation = uri != null &&
          uri.host.contains('google.com') &&
          uri.path.contains('search') &&
          (uri.queryParameters.containsKey('kgmid') ||
              uri.queryParameters.containsKey('kgs'));
      final isMapsAppGooGl =
          uri != null && uri.host.contains('maps.app.goo.gl');
      final isShareGoogle = uri != null && uri.host.contains('share.google');
      final locationValid = googleMapsLink.isNotEmpty &&
          (isGoogleSearchLocation ||
              isMapsAppGooGl ||
              isShareGoogle ||
              validMapPattern.hasMatch(googleMapsLink));
      final locationInvalid = googleMapsLink.isNotEmpty && !locationValid;
      final hasAboutErrors = projectName.isEmpty || locationInvalid;
      final hasAboutWarningOnly =
          !hasAboutErrors && (projectAddress.isEmpty || googleMapsLink.isEmpty);
      final hasProjectManagerHardErrors =
          hasProjectManagerErrors && !hasProjectManagerWarningOnly;
      final hasAgentHardErrors = hasAgentErrors && !hasAgentWarningOnly;
      final mergedAreaErrors = effectiveAreaErrors;
      final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
          _currentPage == NavigationPage.projectDetails;

      _setStateSafely(() {
        // Keep Data Entry badge driven by live section callbacks.
        // Avoid overriding it from DB snapshots when user is on other pages
        // (Dashboard/Documents/etc), which can cause false positives.
        if (isDataEntryContext) {
          _hasAreaErrors = mergedAreaErrors;
          _hasPartnerErrors = hasPartnerErrors;
          _hasExpenseErrors = hasExpenseErrors;
          _hasSiteErrors = hasSiteErrors;
          _hasProjectManagerErrors = hasProjectManagerErrors;
          _hasAgentErrors = hasAgentErrors;
          _hasProjectManagerWarningOnly = hasProjectManagerWarningOnly;
          _hasAgentWarningOnly = hasAgentWarningOnly;
          _hasAboutErrors = hasAboutErrors;
          _hasAboutWarningOnly = hasAboutWarningOnly;
          _hasDataEntryErrors = mergedAreaErrors ||
              hasPartnerErrors ||
              hasExpenseErrors ||
              hasSiteErrors ||
              hasProjectManagerHardErrors ||
              hasAgentHardErrors ||
              hasAboutErrors;
        }
        _hasPlotStatusErrors = hasPlotStatusErrors;
      });
    } catch (e) {
      print('Error refreshing sidebar error badges: $e');
    }
  }

  Future<void> _refreshAccountWarningBadge() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      _setStateSafely(() {
        _hasAccountErrors = false;
      });
      return;
    }

    try {
      final row = await Supabase.instance.client
          .from('account_report_identity_settings')
          .select(
              'full_name, organization, role, logo_storage_path, logo_svg, logo_base64')
          .eq('user_id', userId)
          .maybeSingle();

      final fullName = (row?['full_name'] ?? '').toString().trim();
      final organization = (row?['organization'] ?? '').toString().trim();
      final role = (row?['role'] ?? '').toString().trim();
      final logoStoragePath =
          (row?['logo_storage_path'] ?? '').toString().trim();
      final logoSvg = (row?['logo_svg'] ?? '').toString().trim();
      final logoBase64 = (row?['logo_base64'] ?? '').toString().trim();

      final hasUploadedLogo = logoStoragePath.isNotEmpty ||
          logoSvg.isNotEmpty ||
          logoBase64.isNotEmpty;
      final hasWarnings = fullName.isEmpty ||
          organization.isEmpty ||
          role.isEmpty ||
          !hasUploadedLogo;

      _setStateSafely(() {
        _hasAccountErrors = hasWarnings;
      });
    } catch (e) {
      print('Error refreshing account warning badge: $e');
    }
  }

  Widget _getPageContentForPage(NavigationPage page) {
    switch (page) {
      case NavigationPage.account:
        return AccountSettingsContent(
          onReportIdentityErrorsChanged: _handleAccountErrorsChanged,
        );
      case NavigationPage.notifications:
        return const NotificationsPage();
      case NavigationPage.toDoList:
        return const ToDoListPage();
      case NavigationPage.report:
        return ReportPage(
          projectId: _projectId,
          dataVersion: _projectDataVersion,
        );
      case NavigationPage.recentProjects:
        return RecentProjectsPage(
          key: ValueKey<String>('recent_projects_$_projectsListVersion'),
          onCreateProject: () => _showCreateProjectDialog(),
          onProjectsMutated: _handleProjectsListMutation,
          onProjectSelected: _openProjectFromList,
        );
      case NavigationPage.allProjects:
        return AllProjectsPage(
          key: ValueKey<String>('all_projects_$_projectsListVersion'),
          onCreateProject: () => _showCreateProjectDialog(),
          onProjectsMutated: _handleProjectsListMutation,
          onProjectSelected: _openProjectFromList,
        );
      case NavigationPage.trash:
        return const TrashPage();
      case NavigationPage.help:
        return const HelpPage();
      case NavigationPage.logout:
        return AccountSettingsContent(
          onReportIdentityErrorsChanged: _handleAccountErrorsChanged,
        );
      case NavigationPage.projectDetails:
        return ProjectDetailsPage(
          initialProjectName: _projectName,
          projectId: _projectId,
          onProjectNameChanged: (name) {
            setState(() {
              _projectName = name;
            });
          },
          onSaveStatusChanged: (status) => _handleSaveStatusChangedFromPage(
              NavigationPage.projectDetails, status),
          onErrorStateChanged: _handleErrorStateChanged,
          onAreaErrorsChanged: _handleAreaErrorsChanged,
          onPartnerErrorsChanged: _handlePartnerErrorsChanged,
          onExpenseErrorsChanged: _handleExpenseErrorsChanged,
          onSiteErrorsChanged: _handleSiteErrorsChanged,
          onProjectManagerErrorsChanged: _handleProjectManagerErrorsChanged,
          onAgentErrorsChanged: _handleAgentErrorsChanged,
          onProjectManagerWarningOnlyChanged:
              _handleProjectManagerWarningOnlyChanged,
          onAgentWarningOnlyChanged: _handleAgentWarningOnlyChanged,
          onPlotStatusErrorsChanged: _handlePlotStatusErrorsChanged,
          onAboutErrorsChanged: _handleAboutErrorsChanged,
          onAboutWarningOnlyChanged: _handleAboutWarningOnlyChanged,
        );
      case NavigationPage.home:
        return _previousPage != null
            ? _getPageContentForPage(_previousPage!)
            : AccountSettingsContent(
                onReportIdentityErrorsChanged: _handleAccountErrorsChanged,
              );
      case NavigationPage.dashboard:
        return DashboardPage(
          projectId: _projectId,
          dataVersion: _projectDataVersion,
          isAgentView: _isAgentInviteRole,
          viewerRole: _projectAccessRole,
          availableRoles: _projectAccessRoleOptions,
          onRoleChanged: _handleDashboardRoleChanged,
          onLoadingStateChanged: _handleDashboardLoadingStateChanged,
          onNavigateToDataEntrySite: _openDataEntrySiteSection,
        );
      case NavigationPage.dataEntry:
        return ProjectDetailsPage(
          initialProjectName: _projectName,
          projectId: _projectId,
          requestedTab: _requestedDataEntryTab,
          requestedTabRequestId: _requestedDataEntryTabRequestId,
          onProjectNameChanged: (name) {
            setState(() {
              _projectName = name;
            });
          },
          onSaveStatusChanged: (status) => _handleSaveStatusChangedFromPage(
              NavigationPage.dataEntry, status),
          onErrorStateChanged: _handleErrorStateChanged,
          onAreaErrorsChanged: _handleAreaErrorsChanged,
          onPartnerErrorsChanged: _handlePartnerErrorsChanged,
          onExpenseErrorsChanged: _handleExpenseErrorsChanged,
          onSiteErrorsChanged: _handleSiteErrorsChanged,
          onProjectManagerErrorsChanged: _handleProjectManagerErrorsChanged,
          onAgentErrorsChanged: _handleAgentErrorsChanged,
          onProjectManagerWarningOnlyChanged:
              _handleProjectManagerWarningOnlyChanged,
          onAgentWarningOnlyChanged: _handleAgentWarningOnlyChanged,
          onPlotStatusErrorsChanged: _handlePlotStatusErrorsChanged,
          onAboutErrorsChanged: _handleAboutErrorsChanged,
          onAboutWarningOnlyChanged: _handleAboutWarningOnlyChanged,
        ); // Data Entry shows Project Details page
      case NavigationPage.plotStatus:
        return PlotStatusPage(
          projectId: _projectId,
          dataVersion: _projectDataVersion,
          onNavigateToDataEntrySite: _openDataEntrySiteSection,
          onSaveStatusChanged: (status) => _handleSaveStatusChangedFromPage(
              NavigationPage.plotStatus, status),
          onPlotStatusErrorsChanged: _handlePlotStatusErrorsChanged,
          onLoadingStateChanged: _handlePlotStatusLoadingStateChanged,
        );
      case NavigationPage.documents:
        return DocumentsPage(
          projectId: _projectId,
          dataVersion: _projectDataVersion,
          isAgentView: _isAgentInviteRole,
          isPartnerView: _isPartnerRestricted,
          onSaveStatusChanged: (status) => _handleSaveStatusChangedFromPage(
              NavigationPage.documents, status),
        );
      case NavigationPage.settings:
        return SettingsPage(
          projectId: _projectId,
          projectName: _projectName,
          projectOwnerEmail: _projectOwnerEmail,
          viewerRole: _projectAccessRole,
          isRestrictedViewer: _isInviteNavigationRestricted,
          isAccessControlReadOnly: _isProjectManagerInviteRole,
          allowAgentSectionEditing: _isProjectManagerInviteRole,
          hideAccessControlSection: _isAgentInviteRole,
          onProjectDeleted: _handleProjectDeleted,
        );
    }
  }

  Widget _getPageContent() {
    final normalizedCurrent = _normalizePageForRetention(_currentPage);
    final currentIndex = _retainedPageOrder.indexOf(normalizedCurrent);
    final safeIndex = currentIndex >= 0
        ? currentIndex
        : _retainedPageOrder.indexOf(NavigationPage.recentProjects);

    return IndexedStack(
      index: safeIndex,
      children: _retainedPageOrder.map((page) {
        if (!_initializedRetainedPages.contains(page) &&
            page != normalizedCurrent) {
          return const SizedBox.shrink();
        }
        return _getPageContentForPage(page);
      }).toList(growable: false),
    );
  }

  void _handleProjectDeleted() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null && userId.isNotEmpty) {
      ProjectsListCacheService.invalidateUser(userId);
    }
    _ensureRetainedPageInitialized(NavigationPage.allProjects);
    setState(() {
      _projectsListVersion++;
      _projectName = null;
      _projectId = null;
      _projectAccessRole = null;
      _projectAccessRoleOptions = <String>[];
      _activeProjectRoles = <String>{};
      _deniedProjectRoles = <String>{};
      _hasResolvedProjectRoles = false;
      _projectOwnerEmail = null;
      _currentPage = NavigationPage.allProjects;
      _previousPage = null;
    });
    _persistNavState();
  }

  void _handleProjectsListMutation() {
    if (!mounted) return;
    setState(() {
      _projectsListVersion++;
    });
  }

  void _showCreateProjectDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const CreateProjectDialog(),
    );

    if (result != null && result['projectName'] != null) {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null && userId.isNotEmpty) {
        ProjectsListCacheService.invalidateUser(userId);
      }
      _ensureRetainedPageInitialized(NavigationPage.dataEntry);
      final projectName = result['projectName'] as String;
      final projectId = result['projectId'] as String?;
      final savedLocally = result['savedLocally'] == true;

      setState(() {
        _projectName = projectName;
        _projectId = projectId;
        _requestedDataEntryTab = ProjectTab.about;
        _requestedDataEntryTabRequestId++;
        _projectsListVersion++;
        _projectAccessRole = null;
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = false;
        _projectOwnerEmail = null;
        _saveStatus = savedLocally
            ? ProjectSaveStatusType.queuedOffline
            : ProjectSaveStatusType.saved;
        _savedTimeAgo = savedLocally ? null : 'Just now';
        _previousPage = _currentPage;
        _currentPage = NavigationPage.dataEntry;
      });
      if (savedLocally) {
        _startSavingStatusReconcile();
      }
      _recordPageVisit(_currentPage);
      _persistNavState();
      _refreshErrorBadgesFromStoredData();
      if (savedLocally && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Project saved in your system. It will sync automatically when online.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _openProjectFromList(
      String projectId, String projectName) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    unawaited(
      OfflineProjectSyncService.flushPendingCreates(
        supabase: Supabase.instance.client,
        userId: currentUserId,
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await _resetProjectSectionSelections(
      prefs: prefs,
      projectId: normalizedProjectId,
    );
    final isPendingLocalProject =
        await OfflineProjectSyncService.isPendingLocalProject(
      projectId: normalizedProjectId,
      userId: currentUserId,
    );
    if (isPendingLocalProject) {
      if (!mounted) return;
      _ensureRetainedPageInitialized(NavigationPage.dataEntry);
      setState(() {
        _projectName = projectName;
        _projectId = normalizedProjectId;
        _requestedDataEntryTab = ProjectTab.about;
        _requestedDataEntryTabRequestId++;
        _projectAccessRole = null;
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = false;
        _projectOwnerEmail = null;
        _saveStatus = ProjectSaveStatusType.queuedOffline;
        _savedTimeAgo = null;
        _previousPage = _currentPage;
        _currentPage = NavigationPage.dataEntry;
      });
      _startSavingStatusReconcile();
      _recordPageVisit(_currentPage);
      await _persistNavState();
      _refreshErrorBadgesFromStoredData();
      return;
    }

    String? resolvedRole;
    try {
      resolvedRole = await _resolvePreferredActiveRoleForProject(
        projectId: normalizedProjectId,
        preferredRole: _projectAccessRole,
      );
    } catch (_) {
      // Offline fallback: allow opening cached/local project data.
      resolvedRole = 'owner';
    }
    String ownerEmail = '';
    try {
      final projectRow = await Supabase.instance.client
          .from('projects')
          .select('owner_email')
          .eq('id', normalizedProjectId)
          .maybeSingle();
      ownerEmail = (projectRow?['owner_email'] ?? '').toString().trim();
    } catch (_) {
      ownerEmail = '';
    }
    if (ownerEmail.isEmpty) {
      ownerEmail =
          (prefs.getString('nav_project_owner_email_$normalizedProjectId') ??
                  prefs.getString('nav_project_owner_email') ??
                  '')
              .trim();
    }
    if (ownerEmail.isEmpty) {
      try {
        final adminInvite = await Supabase.instance.client
            .from('project_access_invites')
            .select('invited_email')
            .eq('project_id', normalizedProjectId)
            .eq('role', 'admin')
            .order('requested_at', ascending: false)
            .limit(1)
            .maybeSingle();
        ownerEmail = (adminInvite?['invited_email'] ?? '').toString().trim();
      } catch (_) {
        ownerEmail = '';
      }
    }
    ownerEmail = ownerEmail.toLowerCase();
    if (ownerEmail.isNotEmpty) {
      await prefs.setString(
          'nav_project_owner_email_$normalizedProjectId', ownerEmail);
      await prefs.setString('nav_project_owner_email', ownerEmail);
    }
    resolvedRole = (resolvedRole ?? '').trim().toLowerCase();
    if (resolvedRole.isEmpty) {
      final deniedRoles = await _resolveDeniedRolesForCurrentUser(
        projectId: normalizedProjectId,
      );
      final currentNormalized = _normalizeRoleOption(_projectAccessRole ?? '');
      String pausedViewerRole = 'paused';
      if (currentNormalized.isNotEmpty &&
          deniedRoles.contains(currentNormalized)) {
        pausedViewerRole = currentNormalized;
      } else if (deniedRoles.isNotEmpty) {
        pausedViewerRole =
            ProjectAccessService.sortRolesForUi(deniedRoles).first;
      }
      if (!mounted) return;
      _ensureRetainedPageInitialized(NavigationPage.dashboard);
      setState(() {
        _projectName = projectName;
        _projectId = normalizedProjectId;
        _projectAccessRole = pausedViewerRole;
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = deniedRoles;
        _hasResolvedProjectRoles = true;
        _projectOwnerEmail = ownerEmail.isEmpty ? null : ownerEmail;
        _previousPage = _currentPage;
        _currentPage = NavigationPage.dashboard;
      });
      _recordPageVisit(_currentPage);
      await _persistNavState();
      _refreshErrorBadgesFromStoredData();
      unawaited(
        _refreshProjectRoleOptions(
          projectId: normalizedProjectId,
          selectedRole: pausedViewerRole,
        ),
      );
      return;
    }
    final isInviteRestrictedForProject =
        resolvedRole == 'agent' || _isRestrictedInviteRole(resolvedRole);
    final roleForNavState = resolvedRole == 'owner' ? null : resolvedRole;
    final targetPage = isInviteRestrictedForProject
        ? NavigationPage.dashboard
        : NavigationPage.dataEntry;

    if (!mounted) return;
    _ensureRetainedPageInitialized(targetPage);
    setState(() {
      _projectName = projectName;
      _projectId = normalizedProjectId;
      _projectAccessRole = roleForNavState;
      _projectAccessRoleOptions = <String>[];
      _activeProjectRoles = <String>{};
      _deniedProjectRoles = <String>{};
      _hasResolvedProjectRoles = false;
      _projectOwnerEmail = ownerEmail.isEmpty ? null : ownerEmail;
      _previousPage = _currentPage;
      _currentPage = targetPage;
    });
    _recordPageVisit(_currentPage);
    unawaited(
      _refreshProjectRoleOptions(
        projectId: normalizedProjectId,
        selectedRole: roleForNavState,
      ),
    );
    _persistNavState();
    _refreshErrorBadgesFromStoredData();
  }

  void _handleErrorStateChanged(bool hasErrors) {
    // Keep Data Entry badge stable and based on full section state.
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAreaErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasAreaErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handlePartnerErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasPartnerErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleExpenseErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasExpenseErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleSiteErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasSiteErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleProjectManagerErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasProjectManagerErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleProjectManagerWarningOnlyChanged(bool hasWarningOnly) {
    _setStateSafely(() {
      _hasProjectManagerWarningOnly = hasWarningOnly;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAgentErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasAgentErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAgentWarningOnlyChanged(bool hasWarningOnly) {
    _setStateSafely(() {
      _hasAgentWarningOnly = hasWarningOnly;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAboutErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasAboutErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAboutWarningOnlyChanged(bool hasWarningOnly) {
    _setStateSafely(() {
      _hasAboutWarningOnly = hasWarningOnly;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAccountErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasAccountErrors = hasErrors;
    });
  }

  void _handlePlotStatusErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasPlotStatusErrors = hasErrors;
    });
  }

  void _handleDashboardLoadingStateChanged(bool isLoading) {
    if (_isDashboardPageLoading == isLoading) return;
    _setStateSafely(() {
      _isDashboardPageLoading = isLoading;
    });
  }

  void _handlePlotStatusLoadingStateChanged(bool isLoading) {
    if (_isPlotStatusPageLoading == isLoading) return;
    _setStateSafely(() {
      _isPlotStatusPageLoading = isLoading;
    });
  }

  void _handleSaveStatusChanged(ProjectSaveStatusType status) {
    final previousStatus = _saveStatus;
    final wasDirty = _projectDataDirty;
    if (status == ProjectSaveStatusType.saving ||
        status == ProjectSaveStatusType.notSaved ||
        status == ProjectSaveStatusType.connectionLost ||
        status == ProjectSaveStatusType.queuedOffline) {
      _projectDataDirty = true;
    }
    if (status == ProjectSaveStatusType.saving ||
        status == ProjectSaveStatusType.notSaved ||
        status == ProjectSaveStatusType.queuedOffline) {
      _startSavingStatusReconcile();
    } else {
      _savingStatusReconcileTimer?.cancel();
    }
    _setStateSafely(() {
      _saveStatus = status;
      if (status == ProjectSaveStatusType.saved) {
        // Update saved time when status changes to saved
        _savedTimeAgo = 'Just now';
        final cameFromDirtyStatus =
            previousStatus == ProjectSaveStatusType.saving ||
                previousStatus == ProjectSaveStatusType.notSaved ||
                previousStatus == ProjectSaveStatusType.connectionLost ||
                previousStatus == ProjectSaveStatusType.queuedOffline;
        if (wasDirty || _projectDataDirty || cameFromDirtyStatus) {
          _projectDataVersion++;
          final isOnDataEntryContext =
              _currentPage == NavigationPage.dataEntry ||
                  _currentPage == NavigationPage.projectDetails;
          // Keep Data Entry badge stable while editing by trusting live
          // per-section callbacks instead of round-tripping through DB snapshots.
          if (isOnDataEntryContext) {
            _scheduleDataEntryBadgeRecalc();
          } else {
            _refreshErrorBadgesFromStoredData();
          }
        }
        _projectDataDirty = false;
        // You could implement a more sophisticated time tracking here
        // For example, using DateTime to calculate actual time difference
      }
    });
  }

  void _handleSaveStatusChangedFromPage(
    NavigationPage sourcePage,
    ProjectSaveStatusType status,
  ) {
    final isDataEntryContextSource = sourcePage == NavigationPage.dataEntry ||
        sourcePage == NavigationPage.projectDetails;
    final normalizedStatus =
        (isDataEntryContextSource && status == ProjectSaveStatusType.notSaved)
            ? ProjectSaveStatusType.saving
            : status;
    // Pages are retained in an IndexedStack; hidden pages can still emit
    // callbacks. Ignore save-status events from non-visible pages so the
    // sidebar status reflects the active screen only.
    if (_currentPage != sourcePage) {
      final shouldAdoptBackgroundDataEntryStatus = isDataEntryContextSource &&
          (_saveStatus == ProjectSaveStatusType.loading ||
              ((_saveStatus == ProjectSaveStatusType.saving ||
                      _saveStatus == ProjectSaveStatusType.notSaved ||
                      _saveStatus == ProjectSaveStatusType.queuedOffline) &&
                  normalizedStatus == ProjectSaveStatusType.saved));
      if (shouldAdoptBackgroundDataEntryStatus) {
        _handleSaveStatusChanged(normalizedStatus);
      }
      // If Data Entry finishes saving after user already moved to Dashboard,
      // force a dashboard refresh so latest edits appear without manual reload.
      final shouldRefreshDashboardFromBackgroundSave =
          _currentPage == NavigationPage.dashboard &&
              isDataEntryContextSource &&
              normalizedStatus == ProjectSaveStatusType.saved;
      if (shouldRefreshDashboardFromBackgroundSave) {
        _setStateSafely(() {
          _projectDataVersion++;
          _projectDataDirty = false;
        });
        _refreshErrorBadgesFromStoredData();
      }
      return;
    }
    _handleSaveStatusChanged(normalizedStatus);
    if (sourcePage == NavigationPage.documents &&
        normalizedStatus == ProjectSaveStatusType.saved) {
      // Documents mutations (delete/rename/move/upload) can affect Site/Amenity
      // image metadata shown in Data Entry / Plot Status / Dashboard.
      // These pages are retained in an IndexedStack, so force a fresh rebuild
      // on next visit to avoid stale in-memory image state.
      _setStateSafely(() {
        _initializedRetainedPages.remove(NavigationPage.dataEntry);
        _initializedRetainedPages.remove(NavigationPage.plotStatus);
        _initializedRetainedPages.remove(NavigationPage.dashboard);
      });
    }
  }

  void _handleLogout() async {
    // Clear persisted navigation state
    await _clearPersistedNavState();
    // Sign out from Supabase
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (e) {
      print('Error signing out: $e');
    }

    // Clear any session data and navigate to login page
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const LoginPage()),
        (route) => false,
      );
    }
  }

  Widget _buildPausedAccessOverlay() {
    final switchRoleOptions = _pausedOverlaySwitchRoleOptions();
    final canSwitchRole = switchRoleOptions.isNotEmpty;
    final viewerRoleLabel = _roleLabelForOption(_projectAccessRole ?? '');
    final assignedRoles = <String>{
      ..._activeProjectRoles,
      ..._deniedProjectRoles
    };
    final hideViewingAsSection = _hasResolvedProjectRoles &&
        assignedRoles.length > 1 &&
        _activeProjectRoles.isEmpty &&
        _deniedProjectRoles.isNotEmpty;
    final cardHeight =
        canSwitchRole ? null : (hideViewingAsSection ? 430.0 : 490.0);

    final baseGap = canSwitchRole ? 32.0 : 24.0;

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.white,
        child: Center(
          child: Container(
            width: 685,
            height: cardHeight,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
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
              mainAxisSize: canSwitchRole ? MainAxisSize.min : MainAxisSize.max,
              mainAxisAlignment: canSwitchRole
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                SvgPicture.asset(
                  'assets/images/Access_denied.svg',
                  width: 56,
                  height: 56,
                ),
                SizedBox(height: baseGap),
                Text(
                  'Access Paused.',
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
                SizedBox(height: baseGap),
                SizedBox(
                  width: 390,
                  child: Text(
                    'Please contact your Admin to restore access.',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
                SizedBox(height: baseGap),
                if (!hideViewingAsSection) ...[
                  Column(
                    children: [
                      Text(
                        'Viewing as',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 186,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xF2FFFFFF),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.125),
                              blurRadius: 2,
                              offset: const Offset(0, 0),
                            ),
                          ],
                        ),
                        child: Text(
                          viewerRoleLabel,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: baseGap),
                ],
                Container(
                  width: 521,
                  height: 52,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      SvgPicture.asset(
                        'assets/images/info_icon.svg',
                        width: 20,
                        height: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Your permissions have been temporarily suspended by the Admin.',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF0C8CE9),
                          ),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.visible,
                        ),
                      ),
                    ],
                  ),
                ),
                if (canSwitchRole) ...[
                  const SizedBox(height: 32),
                  Text(
                    'Switch to:',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Column(
                    children: switchRoleOptions.map((role) {
                      final normalized = role.trim().toLowerCase();
                      final isLoading = _isPausedOverlayRoleSwitching &&
                          _pausedOverlaySwitchingRole == normalized;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Container(
                          width: 243,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.125),
                                blurRadius: 2,
                                offset: const Offset(0, 0),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: _isPausedOverlayRoleSwitching
                                  ? null
                                  : () async {
                                      _setStateSafely(() {
                                        _isPausedOverlayRoleSwitching = true;
                                        _pausedOverlaySwitchingRole =
                                            normalized;
                                      });
                                      try {
                                        await _handleDashboardRoleChanged(
                                          normalized,
                                        );
                                      } finally {
                                        _setStateSafely(() {
                                          _isPausedOverlayRoleSwitching = false;
                                          _pausedOverlaySwitchingRole = null;
                                        });
                                      }
                                    },
                              child: Center(
                                child: isLoading
                                    ? SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                            const Color(0xFF0C8CE9),
                                          ),
                                        ),
                                      )
                                    : Text(
                                        _roleLabelForOption(normalized),
                                        style: GoogleFonts.inter(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w400,
                                          color: const Color(0xFF0C8CE9),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(growable: false),
                  ),
                  Container(
                    width: 355,
                    height: 1,
                    color: Colors.black.withOpacity(0.25),
                  ),
                ],
                SizedBox(height: canSwitchRole ? 16 : baseGap),
                Container(
                  width: 243,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0C8CE9),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        blurRadius: 2,
                        offset: const Offset(0, 0),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _isPausedOverlayRoleSwitching
                          ? null
                          : () async {
                              _ensureRetainedPageInitialized(
                                NavigationPage.recentProjects,
                              );
                              _setStateSafely(() {
                                _currentPage = NavigationPage.recentProjects;
                                _previousPage = null;
                              });
                              _initializeHistory(NavigationPage.recentProjects);
                              await _persistNavState();
                            },
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SvgPicture.asset(
                            'assets/images/Back_doc.svg',
                            width: 16,
                            height: 16,
                            colorFilter: const ColorFilter.mode(
                              Colors.white,
                              BlendMode.srcIn,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            'Recent Projects',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w400,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (canSwitchRole) const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handlePageChange(NavigationPage page) async {
    _removeGlobalRoleDropdown();
    // Handle logout separately
    if (page == NavigationPage.logout) {
      _handleLogout();
      return;
    }
    if (_isInviteNavigationRestricted && !_isPageAllowedForInviteRole(page)) {
      return;
    }

    final isOnDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    final isLeavingDataEntryContext = isOnDataEntryContext &&
        page != NavigationPage.dataEntry &&
        page != NavigationPage.projectDetails;
    final isEnteringDataEntryContext = page == NavigationPage.dataEntry ||
        page == NavigationPage.projectDetails;
    final shouldWaitForDataEntrySave =
        isLeavingDataEntryContext && page == NavigationPage.dashboard;
    final shouldForceDashboardRefreshOnEntry = shouldWaitForDataEntrySave &&
        (_projectDataDirty ||
            _saveStatus == ProjectSaveStatusType.saving ||
            _saveStatus == ProjectSaveStatusType.notSaved ||
            _saveStatus == ProjectSaveStatusType.connectionLost ||
            _saveStatus == ProjectSaveStatusType.queuedOffline);

    if (isLeavingDataEntryContext) {
      // Commit any focused text edit so ProjectDetails autosave can run.
      FocusManager.instance.primaryFocus?.unfocus();
      // Brief delay so the autosave debounce can fire; the dashboard will
      // show skeleton loading until the Supabase save finishes.
      await Future.delayed(const Duration(milliseconds: 350));
      if (shouldWaitForDataEntrySave) {
        try {
          await ProjectDetailsPage.pendingSave
              .timeout(const Duration(milliseconds: 1800));
        } catch (_) {
          // Continue navigation; dashboard will refresh again when save settles.
        }
      }
      if (!mounted) return;
    }

    if (page == NavigationPage.home) {
      _ensureRetainedPageInitialized(NavigationPage.recentProjects);
      setState(() {
        _currentPage = NavigationPage.recentProjects;
        _previousPage = null;
      });
      _recordPageVisit(_currentPage);
      _persistNavState();
      if (isLeavingDataEntryContext) {
        // Keep Data Entry badge aligned with live section callbacks instead of
        // immediately recomputing from potentially stale DB snapshots.
        _scheduleDataEntryBadgeRecalc();
      } else {
        _refreshErrorBadgesFromStoredData();
      }
    } else {
      // Track previous page when navigating to project details context pages
      if (page == NavigationPage.projectDetails ||
          page == NavigationPage.dataEntry ||
          page == NavigationPage.dashboard ||
          page == NavigationPage.plotStatus) {
        // Only track if we're not already in project details context
        if (_currentPage != NavigationPage.projectDetails &&
            _currentPage != NavigationPage.dataEntry &&
            _currentPage != NavigationPage.dashboard &&
            _currentPage != NavigationPage.plotStatus) {
          setState(() {
            _previousPage = _currentPage;
            _currentPage = page;
            if (page == NavigationPage.dashboard &&
                shouldForceDashboardRefreshOnEntry) {
              _projectDataVersion++;
              _isDashboardPageLoading = true;
            }
          });
          _recordPageVisit(_currentPage);
        } else {
          // Already in project details context, just switch pages
          setState(() {
            _currentPage = page;
            if (page == NavigationPage.dashboard &&
                shouldForceDashboardRefreshOnEntry) {
              _projectDataVersion++;
              _isDashboardPageLoading = true;
            }
          });
          _recordPageVisit(_currentPage);
        }
      } else {
        setState(() {
          _currentPage = page;
        });
        _recordPageVisit(_currentPage);
      }
      _ensureRetainedPageInitialized(_currentPage);
      _persistNavState();
      if (isLeavingDataEntryContext || isEnteringDataEntryContext) {
        // Avoid false Data Entry badge toggles while saves settle after
        // leaving or re-entering Data Entry.
        _scheduleDataEntryBadgeRecalc();
      } else {
        _refreshErrorBadgesFromStoredData();
      }
    }
  }

  void _openDataEntrySiteSection() {
    setState(() {
      _requestedDataEntryTab = ProjectTab.site;
      _requestedDataEntryTabRequestId++;
    });
    _handlePageChange(NavigationPage.dataEntry);
  }

  @override
  Widget build(BuildContext context) {
    // Show loading while restoring navigation state from SharedPreferences
    if (_isRestoringNavState) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0C8CE9)),
          ),
        ),
      );
    }

    final isProjectContextPage =
        _currentPage == NavigationPage.projectDetails ||
            _currentPage == NavigationPage.dashboard ||
            _currentPage == NavigationPage.dataEntry ||
            _currentPage == NavigationPage.plotStatus ||
            _currentPage == NavigationPage.documents ||
            _currentPage == NavigationPage.settings ||
            _currentPage == NavigationPage.report;
    final isSidebarLoading = isProjectContextPage && _projectId == null;
    final isContentSkeletonLoading =
        (_currentPage == NavigationPage.dashboard && _isDashboardPageLoading) ||
            (_currentPage == NavigationPage.plotStatus &&
                _isPlotStatusPageLoading);
    final hasActiveSaveState = _saveStatus == ProjectSaveStatusType.saving ||
        _saveStatus == ProjectSaveStatusType.notSaved ||
        _saveStatus == ProjectSaveStatusType.connectionLost ||
        _saveStatus == ProjectSaveStatusType.queuedOffline;
    final shouldShowPausedAccessOverlay = _isSelectedRoleDenied() &&
        isProjectContextPage &&
        (_projectId?.trim().isNotEmpty ?? false);
    final effectiveSaveStatus =
        (isContentSkeletonLoading && !hasActiveSaveState)
            ? ProjectSaveStatusType.loading
            : _saveStatus;
    final effectiveSavedTimeAgo =
        (isContentSkeletonLoading && !hasActiveSaveState)
            ? null
            : _savedTimeAgo;
    final roleBadgeLabel = _roleBadgeLabelForViewer(_projectAccessRole) ??
        (isProjectContextPage && (_projectId?.trim().isNotEmpty ?? false)
            ? 'Admin'
            : null);
    final selectedGlobalRole = _normalizeRoleOption(_projectAccessRole ?? '');
    final globalRoleOptions = _globalRoleOptions();
    final hasMultipleProjectRoles = _projectAccessRoleOptions.length > 1;
    final showGlobalRoleBadge = roleBadgeLabel != null &&
        isProjectContextPage &&
        (_currentPage != NavigationPage.dashboard &&
                _currentPage != NavigationPage.documents ||
            (shouldShowPausedAccessOverlay && hasMultipleProjectRoles));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBrowserBackNavigation();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: LayoutBuilder(
          builder: (context, constraints) {
            // Responsive breakpoints
            if (constraints.maxWidth < 768) {
              // Mobile: Stack sidebar and content
              final layout = MobileLayout(
                currentPage: _currentPage,
                projectName: _projectName,
                saveStatus: effectiveSaveStatus,
                savedTimeAgo: effectiveSavedTimeAgo,
                hasDataEntryErrors: _hasDataEntryErrors,
                hasPlotStatusErrors: _hasPlotStatusErrors,
                hasAreaErrors: _hasAreaErrors,
                hasPartnerErrors: _hasPartnerErrors,
                hasExpenseErrors: _hasExpenseErrors,
                hasSiteErrors: _hasSiteErrors,
                hasProjectManagerErrors: _hasProjectManagerErrors,
                hasAgentErrors: _hasAgentErrors,
                hasProjectManagerWarningOnly: _hasProjectManagerWarningOnly,
                hasAgentWarningOnly: _hasAgentWarningOnly,
                hasAboutErrors: _hasAboutErrors,
                hasAboutWarningOnly: _hasAboutWarningOnly,
                hasAccountErrors: _hasAccountErrors,
                isSidebarLoading: isSidebarLoading,
                isPartnerRestricted: _isPartnerRestricted,
                isAgentRestricted: _isAgentInviteRole,
                onPageChanged: _handlePageChange,
                pageContent: _getPageContent(),
              );
              return _buildScreenWithOverlays(
                layout: layout,
                showPausedAccessOverlay: shouldShowPausedAccessOverlay,
                showRoleBadge: showGlobalRoleBadge,
                roleBadgeLabel: roleBadgeLabel,
                selectedRole: selectedGlobalRole,
                roleOptions: globalRoleOptions,
              );
            } else if (constraints.maxWidth < 1024) {
              // Tablet: Sidebar and content side by side
              final layout = TabletLayout(
                currentPage: _currentPage,
                projectName: _projectName,
                saveStatus: effectiveSaveStatus,
                savedTimeAgo: effectiveSavedTimeAgo,
                hasDataEntryErrors: _hasDataEntryErrors,
                hasPlotStatusErrors: _hasPlotStatusErrors,
                hasAreaErrors: _hasAreaErrors,
                hasPartnerErrors: _hasPartnerErrors,
                hasExpenseErrors: _hasExpenseErrors,
                hasSiteErrors: _hasSiteErrors,
                hasProjectManagerErrors: _hasProjectManagerErrors,
                hasAgentErrors: _hasAgentErrors,
                hasProjectManagerWarningOnly: _hasProjectManagerWarningOnly,
                hasAgentWarningOnly: _hasAgentWarningOnly,
                hasAboutErrors: _hasAboutErrors,
                hasAboutWarningOnly: _hasAboutWarningOnly,
                hasAccountErrors: _hasAccountErrors,
                isSidebarLoading: isSidebarLoading,
                isPartnerRestricted: _isPartnerRestricted,
                isAgentRestricted: _isAgentInviteRole,
                onPageChanged: _handlePageChange,
                pageContent: _getPageContent(),
              );
              return _buildScreenWithOverlays(
                layout: layout,
                showPausedAccessOverlay: shouldShowPausedAccessOverlay,
                showRoleBadge: showGlobalRoleBadge,
                roleBadgeLabel: roleBadgeLabel,
                selectedRole: selectedGlobalRole,
                roleOptions: globalRoleOptions,
              );
            } else {
              // Desktop: Full layout with fixed sidebar
              final layout = DesktopLayout(
                currentPage: _currentPage,
                projectName: _projectName,
                saveStatus: effectiveSaveStatus,
                savedTimeAgo: effectiveSavedTimeAgo,
                hasDataEntryErrors: _hasDataEntryErrors,
                hasPlotStatusErrors: _hasPlotStatusErrors,
                hasAreaErrors: _hasAreaErrors,
                hasPartnerErrors: _hasPartnerErrors,
                hasExpenseErrors: _hasExpenseErrors,
                hasSiteErrors: _hasSiteErrors,
                hasProjectManagerErrors: _hasProjectManagerErrors,
                hasAgentErrors: _hasAgentErrors,
                hasProjectManagerWarningOnly: _hasProjectManagerWarningOnly,
                hasAgentWarningOnly: _hasAgentWarningOnly,
                hasAboutErrors: _hasAboutErrors,
                hasAboutWarningOnly: _hasAboutWarningOnly,
                hasAccountErrors: _hasAccountErrors,
                isSidebarLoading: isSidebarLoading,
                isPartnerRestricted: _isPartnerRestricted,
                isAgentRestricted: _isAgentInviteRole,
                onPageChanged: _handlePageChange,
                pageContent: _getPageContent(),
              );
              return _buildScreenWithOverlays(
                layout: layout,
                showPausedAccessOverlay: shouldShowPausedAccessOverlay,
                showRoleBadge: showGlobalRoleBadge,
                roleBadgeLabel: roleBadgeLabel,
                selectedRole: selectedGlobalRole,
                roleOptions: globalRoleOptions,
              );
            }
          },
        ),
      ),
    );
  }
}

class DesktopLayout extends StatelessWidget {
  final NavigationPage currentPage;
  final Function(NavigationPage) onPageChanged;
  final Widget pageContent;
  final String? projectName;
  final ProjectSaveStatusType? saveStatus;
  final String? savedTimeAgo;
  final bool? hasDataEntryErrors;
  final bool? hasPlotStatusErrors;
  final bool? hasAreaErrors;
  final bool? hasPartnerErrors;
  final bool? hasExpenseErrors;
  final bool? hasSiteErrors;
  final bool? hasProjectManagerErrors;
  final bool? hasAgentErrors;
  final bool? hasProjectManagerWarningOnly;
  final bool? hasAgentWarningOnly;
  final bool? hasAboutErrors;
  final bool? hasAboutWarningOnly;
  final bool? hasAccountErrors;
  final bool isSidebarLoading;
  final bool isPartnerRestricted;
  final bool isAgentRestricted;

  const DesktopLayout({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    required this.pageContent,
    this.projectName,
    this.saveStatus,
    this.savedTimeAgo,
    this.hasDataEntryErrors,
    this.hasPlotStatusErrors,
    this.hasAreaErrors,
    this.hasPartnerErrors,
    this.hasExpenseErrors,
    this.hasSiteErrors,
    this.hasProjectManagerErrors,
    this.hasAgentErrors,
    this.hasProjectManagerWarningOnly,
    this.hasAgentWarningOnly,
    this.hasAboutErrors,
    this.hasAboutWarningOnly,
    this.hasAccountErrors,
    this.isSidebarLoading = false,
    this.isPartnerRestricted = false,
    this.isAgentRestricted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SidebarNavigation(
          currentPage: currentPage,
          onPageChanged: onPageChanged,
          projectName: projectName,
          saveStatus: saveStatus,
          savedTimeAgo: savedTimeAgo,
          hasDataEntryErrors: hasDataEntryErrors,
          hasPlotStatusErrors: hasPlotStatusErrors,
          hasAreaErrors: hasAreaErrors,
          hasPartnerErrors: hasPartnerErrors,
          hasExpenseErrors: hasExpenseErrors,
          hasSiteErrors: hasSiteErrors,
          hasProjectManagerErrors: hasProjectManagerErrors,
          hasAgentErrors: hasAgentErrors,
          hasProjectManagerWarningsOnly: hasProjectManagerWarningOnly,
          hasAgentWarningsOnly: hasAgentWarningOnly,
          hasAboutErrors: hasAboutErrors,
          hasAboutWarningsOnly: hasAboutWarningOnly,
          hasAccountErrors: hasAccountErrors,
          isLoading: isSidebarLoading,
          isPartnerRestricted: isPartnerRestricted,
          isAgentRestricted: isAgentRestricted,
        ),
        Expanded(
          child: pageContent,
        ),
      ],
    );
  }
}

class TabletLayout extends StatelessWidget {
  final NavigationPage currentPage;
  final Function(NavigationPage) onPageChanged;
  final Widget pageContent;
  final String? projectName;
  final ProjectSaveStatusType? saveStatus;
  final String? savedTimeAgo;
  final bool? hasDataEntryErrors;
  final bool? hasPlotStatusErrors;
  final bool? hasAreaErrors;
  final bool? hasPartnerErrors;
  final bool? hasExpenseErrors;
  final bool? hasSiteErrors;
  final bool? hasProjectManagerErrors;
  final bool? hasAgentErrors;
  final bool? hasProjectManagerWarningOnly;
  final bool? hasAgentWarningOnly;
  final bool? hasAboutErrors;
  final bool? hasAboutWarningOnly;
  final bool? hasAccountErrors;
  final bool isSidebarLoading;
  final bool isPartnerRestricted;
  final bool isAgentRestricted;

  const TabletLayout({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    required this.pageContent,
    this.projectName,
    this.saveStatus,
    this.savedTimeAgo,
    this.hasDataEntryErrors,
    this.hasPlotStatusErrors,
    this.hasAreaErrors,
    this.hasPartnerErrors,
    this.hasExpenseErrors,
    this.hasSiteErrors,
    this.hasProjectManagerErrors,
    this.hasAgentErrors,
    this.hasProjectManagerWarningOnly,
    this.hasAgentWarningOnly,
    this.hasAboutErrors,
    this.hasAboutWarningOnly,
    this.hasAccountErrors,
    this.isSidebarLoading = false,
    this.isPartnerRestricted = false,
    this.isAgentRestricted = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SidebarNavigation(
          currentPage: currentPage,
          onPageChanged: onPageChanged,
          projectName: projectName,
          saveStatus: saveStatus,
          savedTimeAgo: savedTimeAgo,
          hasDataEntryErrors: hasDataEntryErrors,
          hasPlotStatusErrors: hasPlotStatusErrors,
          hasAreaErrors: hasAreaErrors,
          hasPartnerErrors: hasPartnerErrors,
          hasExpenseErrors: hasExpenseErrors,
          hasSiteErrors: hasSiteErrors,
          hasProjectManagerErrors: hasProjectManagerErrors,
          hasAgentErrors: hasAgentErrors,
          hasProjectManagerWarningsOnly: hasProjectManagerWarningOnly,
          hasAgentWarningsOnly: hasAgentWarningOnly,
          hasAboutErrors: hasAboutErrors,
          hasAboutWarningsOnly: hasAboutWarningOnly,
          hasAccountErrors: hasAccountErrors,
          isLoading: isSidebarLoading,
          isPartnerRestricted: isPartnerRestricted,
          isAgentRestricted: isAgentRestricted,
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.only(
              left: 24,
              top: 24,
              right: 24,
              bottom: 24,
            ),
            child: pageContent,
          ),
        ),
      ],
    );
  }
}

class MobileLayout extends StatefulWidget {
  final NavigationPage currentPage;
  final Function(NavigationPage) onPageChanged;
  final Widget pageContent;
  final String? projectName;
  final ProjectSaveStatusType? saveStatus;
  final String? savedTimeAgo;
  final bool? hasDataEntryErrors;
  final bool? hasPlotStatusErrors;
  final bool? hasAreaErrors;
  final bool? hasPartnerErrors;
  final bool? hasExpenseErrors;
  final bool? hasSiteErrors;
  final bool? hasProjectManagerErrors;
  final bool? hasAgentErrors;
  final bool? hasProjectManagerWarningOnly;
  final bool? hasAgentWarningOnly;
  final bool? hasAboutErrors;
  final bool? hasAboutWarningOnly;
  final bool? hasAccountErrors;
  final bool isSidebarLoading;
  final bool isPartnerRestricted;
  final bool isAgentRestricted;

  const MobileLayout({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    required this.pageContent,
    this.projectName,
    this.saveStatus,
    this.savedTimeAgo,
    this.hasDataEntryErrors,
    this.hasPlotStatusErrors,
    this.hasAreaErrors,
    this.hasPartnerErrors,
    this.hasExpenseErrors,
    this.hasSiteErrors,
    this.hasProjectManagerErrors,
    this.hasAgentErrors,
    this.hasProjectManagerWarningOnly,
    this.hasAgentWarningOnly,
    this.hasAboutErrors,
    this.hasAboutWarningOnly,
    this.hasAccountErrors,
    this.isSidebarLoading = false,
    this.isPartnerRestricted = false,
    this.isAgentRestricted = false,
  });

  @override
  State<MobileLayout> createState() => _MobileLayoutState();
}

class _MobileLayoutState extends State<MobileLayout> {
  bool _sidebarOpen = false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Main content
        Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // Menu button
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () {
                    setState(() {
                      _sidebarOpen = !_sidebarOpen;
                    });
                  },
                ),
              ),
              Expanded(
                child: widget.pageContent,
              ),
            ],
          ),
        ),
        // Sidebar overlay
        if (_sidebarOpen)
          GestureDetector(
            onTap: () {
              setState(() {
                _sidebarOpen = false;
              });
            },
            child: Container(
              color: Colors.black.withOpacity(0.5),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Material(
                  elevation: 8,
                  child: SizedBox(
                    width: 252,
                    child: SidebarNavigation(
                      currentPage: widget.currentPage,
                      onPageChanged: (page) {
                        widget.onPageChanged(page);
                        setState(() {
                          _sidebarOpen = false;
                        });
                      },
                      projectName: widget.projectName,
                      saveStatus: widget.saveStatus,
                      savedTimeAgo: widget.savedTimeAgo,
                      hasDataEntryErrors: widget.hasDataEntryErrors,
                      hasPlotStatusErrors: widget.hasPlotStatusErrors,
                      hasAreaErrors: widget.hasAreaErrors,
                      hasPartnerErrors: widget.hasPartnerErrors,
                      hasExpenseErrors: widget.hasExpenseErrors,
                      hasSiteErrors: widget.hasSiteErrors,
                      hasProjectManagerErrors: widget.hasProjectManagerErrors,
                      hasAgentErrors: widget.hasAgentErrors,
                      hasProjectManagerWarningsOnly:
                          widget.hasProjectManagerWarningOnly,
                      hasAgentWarningsOnly: widget.hasAgentWarningOnly,
                      hasAboutErrors: widget.hasAboutErrors,
                      hasAboutWarningsOnly: widget.hasAboutWarningOnly,
                      hasAccountErrors: widget.hasAccountErrors,
                      isLoading: widget.isSidebarLoading,
                      isPartnerRestricted: widget.isPartnerRestricted,
                      isAgentRestricted: widget.isAgentRestricted,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
