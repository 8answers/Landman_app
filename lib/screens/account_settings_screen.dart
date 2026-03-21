import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
  bool _projectDataDirty = false;
  bool _pendingDataEntryBadgeRecalc = false;
  Timer? _savingStatusReconcileTimer;
  String? _projectAccessRole;
  String? _projectOwnerEmail;
  List<String> _projectAccessRoleOptions = <String>[];

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

  bool get _isProjectAccessPaused =>
      (_projectAccessRole ?? '').trim().toLowerCase() == 'paused';

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

  Future<void> _refreshProjectRoleOptions({
    String? projectId,
    String? selectedRole,
  }) async {
    final normalizedProjectId = (projectId ?? _projectId ?? '').trim();
    if (normalizedProjectId.isEmpty) {
      if (!mounted) return;
      _setStateSafely(() {
        _projectAccessRoleOptions = <String>[];
      });
      return;
    }

    List<String> resolvedRoles = const <String>[];
    try {
      resolvedRoles =
          await ProjectAccessService.resolveCurrentUserRolesForProject(
        projectId: normalizedProjectId,
      );
    } catch (_) {
      resolvedRoles = const <String>[];
    }

    final nextOptions = _mergeAndSortRoleOptions(
      resolvedRoles,
      includeRole: selectedRole ?? _projectAccessRole,
    );

    if (!mounted) return;
    _setStateSafely(() {
      _projectAccessRoleOptions = nextOptions;
    });
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
    _restoreNavState();
  }

  @override
  void dispose() {
    _savingStatusReconcileTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
            _saveStatus == ProjectSaveStatusType.notSaved;
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

          // If remote save caught up with the latest local edit,
          // resolve stale "Saving..." / "Not saved" UI to Saved.
          final isSynced = (localEditMs == 0 && remoteSaveMs == 0) ||
              (localEditMs > 0 && remoteSaveMs >= localEditMs);
          if (isSynced) {
            _setStateSafely(() {
              if (_saveStatus == ProjectSaveStatusType.saving ||
                  _saveStatus == ProjectSaveStatusType.notSaved) {
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

  void _ensureRetainedPageInitialized(NavigationPage page) {
    _initializedRetainedPages.add(_normalizePageForRetention(page));
  }

  Future<void> _handleBrowserBackNavigation() async {
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
    final authInviteContext =
        _extractInviteContextFromAuthValue(params['auth']);
    final isReload = await web_nav.isReloadNavigation();
    final forceRecentOnNextOpen =
        prefs.getBool('nav_force_recent_on_next_open') ?? false;
    final openInviteDashboardOnce =
        prefs.getBool('nav_open_invite_dashboard_once') ?? false;
    final pageName = prefs.getString('nav_current_page');
    final prevPageName = prefs.getString('nav_previous_page');
    final projectId = prefs.getString('nav_project_id');
    var projectName =
        prefs.getString('nav_project_name') ?? authInviteContext['projectName'];
    final projectOwnerEmail = ((prefs.getString('nav_project_owner_email') ??
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
    final normalizedProjectIdFromPrefs = (projectId ?? '').trim();
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
    final hasInviteContext = normalizedProjectId.isNotEmpty &&
        (hasInviteContextFlag ||
            openInviteDashboardOnce ||
            effectiveProjectAccessRole.isNotEmpty ||
            params['invite'] == '1' ||
            inviteProjectIdFromUrl.isNotEmpty);
    var resolvedInviteRole =
        hasInviteContext && effectiveProjectAccessRole.isEmpty
            ? 'partner'
            : effectiveProjectAccessRole;

    if (hasInviteContext && normalizedProjectId.isNotEmpty) {
      try {
        final dbRole =
            await ProjectAccessService.resolveCurrentUserRoleForProject(
          projectId: normalizedProjectId,
        );
        if (dbRole != null &&
            dbRole.trim().isNotEmpty &&
            dbRole.trim().toLowerCase() != 'owner') {
          resolvedInviteRole = dbRole.trim().toLowerCase();
        }
      } catch (_) {
        // Keep role resolved from persisted navigation state.
      }
    }

    final hasMissingProjectName =
        (projectName == null || projectName.trim().isEmpty) &&
            normalizedProjectId.isNotEmpty;
    if (hasMissingProjectName) {
      try {
        final projectData = await ProjectStorageService.fetchProjectDataById(
            normalizedProjectId);
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
    }

    final shouldForceRecent =
        widget.forceRecentStart || forceRecentOnNextOpen || !isReload;

    if (hasInviteContext &&
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
        await prefs.setString('nav_project_id', normalizedProjectId);
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
        _projectId = normalizedProjectId;
        _projectName = projectName;
        _projectAccessRole = resolvedInviteRole;
        _projectAccessRoleOptions = <String>[];
        _projectOwnerEmail =
            projectOwnerEmail.isEmpty ? null : projectOwnerEmail;
        _isRestoringNavState = false;
      });
      _initializeHistory(NavigationPage.dashboard);
      unawaited(
        _refreshProjectRoleOptions(
          projectId: normalizedProjectId,
          selectedRole: resolvedInviteRole,
        ),
      );
      _refreshErrorBadgesFromStoredData();
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
        _projectId = normalizedProjectId.isEmpty ? null : normalizedProjectId;
        _projectName = projectName;
        _projectAccessRole = hasInviteContext ? resolvedInviteRole : null;
        _projectAccessRoleOptions = <String>[];
        _projectOwnerEmail =
            projectOwnerEmail.isEmpty ? null : projectOwnerEmail;
        _isRestoringNavState = false;
      });
      _initializeHistory(NavigationPage.recentProjects);
      if (hasInviteContext) {
        unawaited(
          _refreshProjectRoleOptions(
            projectId: normalizedProjectId,
            selectedRole: resolvedInviteRole,
          ),
        );
      }
      _refreshErrorBadgesFromStoredData();
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
      final normalizedPage = (isInviteRestrictedForRestore &&
              !_isPageAllowedForInviteRole(
                page,
                roleOverride: resolvedInviteRole,
              ))
          ? NavigationPage.dashboard
          : page;

      // Don't restore logout
      if (normalizedPage != NavigationPage.logout) {
        _ensureRetainedPageInitialized(normalizedPage);
        setState(() {
          _currentPage = normalizedPage;
          _previousPage = prevPage;
          _projectId = normalizedProjectId.isEmpty ? null : normalizedProjectId;
          _projectName = projectName;
          _projectAccessRole = hasInviteContext ? resolvedInviteRole : null;
          _projectAccessRoleOptions = <String>[];
          _projectOwnerEmail =
              projectOwnerEmail.isEmpty ? null : projectOwnerEmail;
          _isRestoringNavState = false;
        });
        _initializeHistory(normalizedPage);
        if (hasInviteContext) {
          unawaited(
            _refreshProjectRoleOptions(
              projectId: normalizedProjectId,
              selectedRole: resolvedInviteRole,
            ),
          );
        }
        _refreshErrorBadgesFromStoredData();
        return;
      }
    }

    _ensureRetainedPageInitialized(NavigationPage.recentProjects);
    setState(() {
      _currentPage = NavigationPage.recentProjects;
      _previousPage = null;
      _projectId = normalizedProjectId.isEmpty ? null : normalizedProjectId;
      _projectName = projectName;
      _projectAccessRole = hasInviteContext ? resolvedInviteRole : null;
      _projectAccessRoleOptions = <String>[];
      _projectOwnerEmail = projectOwnerEmail.isEmpty ? null : projectOwnerEmail;
      _isRestoringNavState = false;
    });
    _initializeHistory(NavigationPage.recentProjects);
    if (hasInviteContext) {
      unawaited(
        _refreshProjectRoleOptions(
          projectId: normalizedProjectId,
          selectedRole: resolvedInviteRole,
        ),
      );
    }
    _refreshErrorBadgesFromStoredData();
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
          onCreateProject: () => _showCreateProjectDialog(),
          onProjectSelected: (projectId, projectName) {
            _openProjectFromList(projectId, projectName);
          },
        );
      case NavigationPage.allProjects:
        return AllProjectsPage(
          onCreateProject: () => _showCreateProjectDialog(),
          onProjectSelected: (projectId, projectName) {
            _openProjectFromList(projectId, projectName);
          },
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
          onSaveStatusChanged: _handleSaveStatusChanged,
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
        );
      case NavigationPage.dataEntry:
        return ProjectDetailsPage(
          initialProjectName: _projectName,
          projectId: _projectId,
          onProjectNameChanged: (name) {
            setState(() {
              _projectName = name;
            });
          },
          onSaveStatusChanged: _handleSaveStatusChanged,
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
          onSaveStatusChanged: _handleSaveStatusChanged,
          onPlotStatusErrorsChanged: _handlePlotStatusErrorsChanged,
          onLoadingStateChanged: _handlePlotStatusLoadingStateChanged,
        );
      case NavigationPage.documents:
        return DocumentsPage(
          projectId: _projectId,
          dataVersion: _projectDataVersion,
          isAgentView: _isAgentInviteRole,
        );
      case NavigationPage.settings:
        return SettingsPage(
          projectId: _projectId,
          projectName: _projectName,
          projectOwnerEmail: _projectOwnerEmail,
          isRestrictedViewer: _isPartnerRestricted,
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
      _projectName = null;
      _projectId = null;
      _projectAccessRole = null;
      _projectAccessRoleOptions = <String>[];
      _projectOwnerEmail = null;
      _currentPage = NavigationPage.allProjects;
      _previousPage = null;
    });
    _persistNavState();
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

      setState(() {
        _projectName = projectName;
        _projectId = projectId;
        _projectAccessRole = null;
        _projectAccessRoleOptions = <String>[];
        _projectOwnerEmail = null;
        _saveStatus = ProjectSaveStatusType.saved;
        _savedTimeAgo = 'Just now';
        _previousPage = _currentPage;
        _currentPage = NavigationPage.dataEntry;
      });
      _recordPageVisit(_currentPage);
      _persistNavState();
      _refreshErrorBadgesFromStoredData();
    }
  }

  Future<void> _openProjectFromList(
      String projectId, String projectName) async {
    final prefs = await SharedPreferences.getInstance();
    var resolvedRole =
        await ProjectAccessService.resolveCurrentUserRoleForProject(
      projectId: projectId,
    );
    String ownerEmail = '';
    try {
      final projectRow = await Supabase.instance.client
          .from('projects')
          .select('owner_email')
          .eq('id', projectId)
          .maybeSingle();
      ownerEmail = (projectRow?['owner_email'] ?? '').toString().trim();
    } catch (_) {
      ownerEmail = '';
    }
    if (ownerEmail.isEmpty) {
      ownerEmail = (prefs.getString('nav_project_owner_email_$projectId') ??
              prefs.getString('nav_project_owner_email') ??
              '')
          .trim();
    }
    if (ownerEmail.isEmpty) {
      try {
        final adminInvite = await Supabase.instance.client
            .from('project_access_invites')
            .select('invited_email')
            .eq('project_id', projectId)
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
      await prefs.setString('nav_project_owner_email_$projectId', ownerEmail);
      await prefs.setString('nav_project_owner_email', ownerEmail);
    }
    resolvedRole = (resolvedRole ?? '').trim().toLowerCase();
    final isInviteRestrictedForProject =
        resolvedRole == 'agent' || _isRestrictedInviteRole(resolvedRole);
    final roleForNavState =
        (resolvedRole.isEmpty || resolvedRole == 'owner') ? null : resolvedRole;
    final targetPage = isInviteRestrictedForProject
        ? NavigationPage.dashboard
        : NavigationPage.dataEntry;

    if (!mounted) return;
    _ensureRetainedPageInitialized(targetPage);
    setState(() {
      _projectName = projectName;
      _projectId = projectId;
      _projectAccessRole = roleForNavState;
      _projectAccessRoleOptions = <String>[];
      _projectOwnerEmail = ownerEmail.isEmpty ? null : ownerEmail;
      _previousPage = _currentPage;
      _currentPage = targetPage;
    });
    _recordPageVisit(_currentPage);
    unawaited(
      _refreshProjectRoleOptions(
        projectId: projectId,
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
        status == ProjectSaveStatusType.connectionLost) {
      _projectDataDirty = true;
    }
    if (status == ProjectSaveStatusType.saving ||
        status == ProjectSaveStatusType.notSaved) {
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
                previousStatus == ProjectSaveStatusType.connectionLost;
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
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xCCFFFFFF),
        child: Center(
          child: Container(
            width: 420,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_outline,
                  size: 40,
                  color: Color(0xFFB42318),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Access Denied',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your access to this project is currently paused by the admin.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFF5C5C5C),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 40,
                  child: ElevatedButton(
                    onPressed: () async {
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
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0C8CE9),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Back To Projects',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handlePageChange(NavigationPage page) async {
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
          });
          _recordPageVisit(_currentPage);
        } else {
          // Already in project details context, just switch pages
          setState(() {
            _currentPage = page;
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
    final shouldShowPausedAccessOverlay = _isProjectAccessPaused &&
        isProjectContextPage &&
        (_projectId?.trim().isNotEmpty ?? false);
    final effectiveSaveStatus =
        isContentSkeletonLoading ? ProjectSaveStatusType.loading : _saveStatus;
    final effectiveSavedTimeAgo =
        isContentSkeletonLoading ? null : _savedTimeAgo;

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
              if (!shouldShowPausedAccessOverlay) return layout;
              return Stack(
                children: [
                  layout,
                  _buildPausedAccessOverlay(),
                ],
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
              if (!shouldShowPausedAccessOverlay) return layout;
              return Stack(
                children: [
                  layout,
                  _buildPausedAccessOverlay(),
                ],
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
              if (!shouldShowPausedAccessOverlay) return layout;
              return Stack(
                children: [
                  layout,
                  _buildPausedAccessOverlay(),
                ],
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
