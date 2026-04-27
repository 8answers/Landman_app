import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui show AppExitResponse, ImageFilter;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/sidebar_navigation.dart';
import '../widgets/account_settings_content.dart';
import '../widgets/create_project_dialog.dart';
import '../widgets/no_internet_dialogs.dart';
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
import '../widgets/unauthenticated_page.dart';
import '../widgets/app_scale_metrics.dart';
import '../services/project_storage_service.dart';
import '../services/offline_project_sync_service.dart';
import '../services/offline_file_upload_queue_service.dart';
import '../services/projects_list_cache_service.dart';
import '../services/project_access_service.dart';
import '../services/default_sample_project_service.dart';
import '../services/app_update_service.dart';
import '../services/desktop_installer_update_service.dart';
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
  static const String _inviteLaunchPopupPendingPrefKey =
      'nav_invite_launch_popup_pending';
  static const String _appUpdatePromptedVersionPrefKey =
      'app_update_prompted_version';

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
  ProjectSaveStatusVisualOverride _saveStatusVisualOverride =
      ProjectSaveStatusVisualOverride.none;
  String? _savedTimeAgo;
  bool _projectHasSharedAccessBeyondAdmin = false;
  bool _forceCloudSyncStatusVisual = false;
  bool _isNetworkReachableForSync = false;
  DateTime? _plotStatusSyncVisualSuppressUntil;
  bool _isNetworkProbeRunning = false;
  DateTime? _lastNetworkProbeAt;
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
  bool _isPlotStatusEditDialogOpen = false;
  bool _dashboardLoadingSignalActive = false;
  bool _plotStatusLoadingSignalActive = false;
  int _errorBadgeRefreshGeneration = 0;
  int _projectDataVersion = 0;
  int _projectsListVersion = 0;
  bool _projectDataDirty = false;
  bool _backgroundDataEntrySavePendingRefresh = false;
  bool _documentsPagePendingRefresh = false;
  bool _pendingDataEntryBadgeRecalc = false;
  static const Duration _pageLoadingIndicatorShowDelay = Duration(
    milliseconds: 220,
  );
  Timer? _dashboardLoadingIndicatorDelayTimer;
  Timer? _plotStatusLoadingIndicatorDelayTimer;
  Timer? _savingStatusReconcileTimer;
  Timer? _projectSyncTimer;
  Timer? _sharedAccessSyncVisualTimer;
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
  bool _didProcessInviteLaunchPopup = false;
  bool _hasDocumentsActiveUploads = false;
  bool _isHandlingExitRequest = false;
  bool _hasShownSyncRiskOfflineDialogForCurrentOutage = false;
  bool _isSyncRiskOfflineDialogVisible = false;
  bool _isCheckingForAppUpdate = false;

  bool _isLowNetworkSyncInProgressForExitWarning() {
    return _saveStatusVisualOverride ==
            ProjectSaveStatusVisualOverride.savingPoorConnection ||
        _saveStatusVisualOverride ==
            ProjectSaveStatusVisualOverride.saveFailedPoorConnection ||
        _saveStatusVisualOverride ==
            ProjectSaveStatusVisualOverride.syncingInProgressShared;
  }

  bool _hasActiveSaveStateForExitWarning() {
    return _saveStatus == ProjectSaveStatusType.saving ||
        _saveStatus == ProjectSaveStatusType.uploadingFile ||
        _saveStatus == ProjectSaveStatusType.notSaved ||
        _saveStatus == ProjectSaveStatusType.connectionLost;
  }

  Future<bool> _showExitSyncWarningDialog({
    required bool uploadInProgressVariant,
  }) async {
    if (!mounted) return false;
    final media = MediaQuery.of(context);
    final maxWidth = math.min(560.0, media.size.width - 24);
    final leaveLabel = 'Leave anyway';
    final stayLabel = uploadInProgressVariant ? 'Stay and finish sync' : 'Stay';
    final bodyLineOne = uploadInProgressVariant
        ? 'Files are still uploading...'
        : 'Changes are saved locally. Syncing to cloud...';
    final bodyLineTwo = uploadInProgressVariant
        ? 'Leaving now may cancel the upload and they won\'t be saved.'
        : 'Leaving now may delay syncing to the cloud.';

    final shouldLeave = await showGeneralDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.12),
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (dialogContext, _, __) {
        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: maxWidth,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F9FA),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 2,
                        offset: Offset(0, 0),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.cloud_upload_outlined,
                            size: 20,
                            color: Colors.black,
                          ),
                          const SizedBox(width: 16),
                          Text(
                            'Sync in progress',
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: Colors.black,
                            ),
                          ),
                          const Spacer(),
                          InkWell(
                            borderRadius: BorderRadius.circular(999),
                            onTap: () => Navigator.of(dialogContext).pop(false),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.close,
                                size: 18,
                                color: Color(0xFF0C8CE9),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        bodyLineOne,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xCC000000),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        bodyLineTwo,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xCC000000),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          _buildExitWarningActionButton(
                            label: uploadInProgressVariant
                                ? leaveLabel
                                : stayLabel,
                            textColor: uploadInProgressVariant
                                ? const Color(0x80FF0000)
                                : const Color(0xFF0C8CE9),
                            fillColor: Colors.white,
                            onTap: () => Navigator.of(dialogContext).pop(
                              uploadInProgressVariant,
                            ),
                          ),
                          const Spacer(),
                          _buildExitWarningActionButton(
                            label: uploadInProgressVariant
                                ? stayLabel
                                : leaveLabel,
                            textColor: uploadInProgressVariant
                                ? Colors.white
                                : const Color(0x80FF0000),
                            fillColor: uploadInProgressVariant
                                ? const Color(0xFF0C8CE9)
                                : Colors.white,
                            onTap: () => Navigator.of(dialogContext).pop(
                              !uploadInProgressVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (_, animation, __, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.08),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
    return shouldLeave == true;
  }

  Widget _buildExitWarningActionButton({
    required String label,
    required Color textColor,
    required Color fillColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 2,
                offset: Offset(0, 0),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }

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

  bool get _isDefaultSampleProject =>
      DefaultSampleProjectService.isDefaultSampleProjectId(_projectId);

  bool _isDefaultSampleViewerRole(String? role) {
    return (role ?? '').trim().toLowerCase() ==
        DefaultSampleProjectService.viewerRole;
  }

  bool get _isReadOnlyDefaultSampleProject => _isDefaultSampleProject;

  bool get _isPartnerRestricted => _isRestrictedInviteRole(_projectAccessRole);
  bool get _isAgentInviteRole =>
      (_projectAccessRole ?? '').trim().toLowerCase() == 'agent';
  bool get _isInviteNavigationRestricted =>
      _isPartnerRestricted ||
      _isAgentInviteRole ||
      _isReadOnlyDefaultSampleProject;

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
      case DefaultSampleProjectService.viewerRole:
        return 'Sample';
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
      case DefaultSampleProjectService.viewerRole:
        return 'Sample';
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
    required bool blurRoleBadge,
    String? roleBadgeLabel,
    required String selectedRole,
    required List<String> roleOptions,
  }) {
    final scaleMetrics = AppScaleMetrics.of(context);
    final extraRightWidth = scaleMetrics?.rightOverflowWidth ?? 0.0;
    final children = <Widget>[layout];
    if (showPausedAccessOverlay) {
      children.add(_buildPausedAccessOverlay());
    }
    if (showRoleBadge && roleBadgeLabel != null) {
      children.add(
        Positioned(
          top: 24,
          right: 24,
          child: Transform.translate(
            offset: Offset(extraRightWidth, 0),
            child: ImageFiltered(
              imageFilter: blurRoleBadge
                  ? ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4)
                  : ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0),
              child: IgnorePointer(
                ignoring: blurRoleBadge,
                child: _buildGlobalRoleBadge(
                  roleLabel: roleBadgeLabel,
                  selectedRole: selectedRole,
                  roleOptions: roleOptions,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: children,
      ),
    );
  }

  bool _isPageAllowedForInviteRole(
    NavigationPage page, {
    String? roleOverride,
  }) {
    final normalizedRole =
        (roleOverride ?? _projectAccessRole ?? '').trim().toLowerCase();
    if (normalizedRole == DefaultSampleProjectService.viewerRole) {
      return page == NavigationPage.home ||
          page == NavigationPage.recentProjects ||
          page == NavigationPage.allProjects ||
          page == NavigationPage.projectDetails ||
          page == NavigationPage.dashboard ||
          page == NavigationPage.dataEntry ||
          page == NavigationPage.plotStatus ||
          page == NavigationPage.documents ||
          page == NavigationPage.report;
    }
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
        normalized == 'agent' ||
        normalized == DefaultSampleProjectService.viewerRole) {
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
        normalized == 'agent' ||
        normalized == DefaultSampleProjectService.viewerRole) {
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
    if (DefaultSampleProjectService.isDefaultSampleProjectId(
      normalizedProjectId,
    )) {
      return DefaultSampleProjectService.viewerRole;
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
    if (DefaultSampleProjectService.isDefaultSampleProjectId(
      normalizedProjectId,
    )) {
      if (!mounted) return;
      _setStateSafely(() {
        _projectAccessRoleOptions = <String>[
          DefaultSampleProjectService.viewerRole,
        ];
        _activeProjectRoles = <String>{DefaultSampleProjectService.viewerRole};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = true;
        _projectAccessRole = DefaultSampleProjectService.viewerRole;
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

  void _resetProjectScopedTransientStateForProjectSwitch() {
    _dashboardLoadingIndicatorDelayTimer?.cancel();
    _plotStatusLoadingIndicatorDelayTimer?.cancel();
    _dashboardLoadingSignalActive = false;
    _plotStatusLoadingSignalActive = false;
    _isDashboardPageLoading = false;
    _isPlotStatusPageLoading = false;
    _isPlotStatusEditDialogOpen = false;
    _hasDataEntryErrors = false;
    _hasPlotStatusErrors = false;
    _hasAreaErrors = false;
    _hasPartnerErrors = false;
    _hasExpenseErrors = false;
    _hasSiteErrors = false;
    _hasProjectManagerErrors = false;
    _hasAgentErrors = false;
    _hasAboutErrors = false;
    _hasAboutWarningOnly = false;
    _hasProjectManagerWarningOnly = false;
    _hasAgentWarningOnly = false;
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

  bool _isNonAdminSharedRole(String role) {
    final normalized = role.trim().toLowerCase();
    return normalized == 'partner' ||
        normalized == 'project_manager' ||
        normalized == 'agent';
  }

  bool _isInviteStatusGrantingSharedAccess(String status) {
    final normalized = status.trim().toLowerCase();
    return normalized == 'requested' ||
        normalized == 'accepted' ||
        normalized == 'active';
  }

  bool _isMemberStatusGrantingSharedAccess(String status) {
    final normalized = status.trim().toLowerCase();
    return normalized.isEmpty || normalized == 'active';
  }

  bool _isLikelyNetworkError(Object error) {
    final message = error.toString().toLowerCase();
    const markers = <String>[
      'socketexception',
      'failed host lookup',
      'xmlhttprequest error',
      'networkerror',
      'network request failed',
      'failed to fetch',
      'clientexception',
      'connection closed',
      'connection refused',
      'connection reset',
      'connection aborted',
      'software caused connection abort',
      'network is unreachable',
      'network connection was lost',
      'the network connection was lost',
      'the internet connection appears to be offline',
      'not connected to the internet',
      'could not connect to the server',
      'err_internet_disconnected',
      'nsurlerrordomain',
      'code=-1009',
      'code=-1005',
      'error -1009',
      'error -1005',
      'timeout',
      'timed out',
      'status code: 0',
      'statuscode: null',
      'temporary failure in name resolution',
      'no address associated with hostname',
      'name or service not known',
    ];
    return markers.any(message.contains);
  }

  String _currentUserEmailLower() {
    return (Supabase.instance.client.auth.currentUser?.email ?? '')
        .trim()
        .toLowerCase();
  }

  bool _isCurrentUserOwnerEmail(String ownerEmail) {
    final normalizedOwnerEmail = ownerEmail.trim().toLowerCase();
    final normalizedCurrentUserEmail = _currentUserEmailLower();
    if (normalizedOwnerEmail.isEmpty || normalizedCurrentUserEmail.isEmpty) {
      return false;
    }
    return normalizedOwnerEmail == normalizedCurrentUserEmail;
  }

  Future<String> _resolveProjectOwnerEmail({
    required String projectId,
    required SharedPreferences prefs,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return '';

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
        'nav_project_owner_email_$normalizedProjectId',
        ownerEmail,
      );
      await prefs.setString('nav_project_owner_email', ownerEmail);
    }
    return ownerEmail;
  }

  Future<void> _navigateToRecentProjectsFromOfflineDialog() async {
    if (!mounted) return;
    _ensureRetainedPageInitialized(NavigationPage.recentProjects);
    _setStateSafely(() {
      _currentPage = NavigationPage.recentProjects;
      _previousPage = null;
    });
    _initializeHistory(NavigationPage.recentProjects);
    await _persistNavState();
  }

  Future<void> _showSharedProjectOfflineOpenDialog({
    required String projectId,
    required String projectName,
  }) async {
    if (!mounted) return;
    await showSharedProjectOfflineDialog(
      context: context,
      onRecentProjects: _navigateToRecentProjectsFromOfflineDialog,
      onRetry: () async {
        await _refreshNetworkReachability(
          projectId: projectId,
          force: true,
        );
        if (!mounted || !_isNetworkReachableForSync) return;
        unawaited(_openProjectFromList(projectId, projectName));
      },
    );
  }

  Future<bool> _hasLocalProjectDataOnThisDevice({
    required String projectId,
    String? userId,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return false;

    final normalizedUserId = (userId ?? '').trim();
    final isPendingLocalProject =
        await OfflineProjectSyncService.isPendingLocalProject(
      projectId: normalizedProjectId,
      userId: normalizedUserId.isEmpty ? null : normalizedUserId,
    );
    if (isPendingLocalProject) return true;

    final hasPendingOfflineSaves =
        await ProjectStorageService.hasPendingOfflineSaves(
      projectId: normalizedProjectId,
    );
    if (hasPendingOfflineSaves) return true;

    final localSnapshot =
        await ProjectStorageService.getLocalSnapshotForProject(
      normalizedProjectId,
    );
    return localSnapshot != null;
  }

  Future<bool> _hasSyncedRemoteProjectData({
    required String projectId,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return false;

    Future<bool> hasRelatedRows(String tableName) async {
      try {
        final rows = await Supabase.instance.client
            .from(tableName)
            .select('id')
            .eq('project_id', normalizedProjectId)
            .limit(1);
        return rows.isNotEmpty;
      } catch (_) {
        return false;
      }
    }

    try {
      final projectRow = await Supabase.instance.client
          .from('projects')
          .select(
              'project_address,google_maps_link,total_area,selling_area,estimated_development_cost')
          .eq('id', normalizedProjectId)
          .maybeSingle();

      if (projectRow == null) return false;

      final projectAddress =
          (projectRow['project_address'] ?? '').toString().trim();
      final googleMapsLink =
          (projectRow['google_maps_link'] ?? '').toString().trim();
      final totalArea = double.tryParse(
            (projectRow['total_area'] ?? '').toString().trim(),
          ) ??
          0.0;
      final sellingArea = double.tryParse(
            (projectRow['selling_area'] ?? '').toString().trim(),
          ) ??
          0.0;
      final estimatedDevelopmentCost = double.tryParse(
            (projectRow['estimated_development_cost'] ?? '').toString().trim(),
          ) ??
          0.0;

      if (projectAddress.isNotEmpty ||
          googleMapsLink.isNotEmpty ||
          totalArea > 0 ||
          sellingArea > 0 ||
          estimatedDevelopmentCost > 0) {
        return true;
      }

      final relatedRowsPresence = await Future.wait<bool>([
        hasRelatedRows('layouts'),
        hasRelatedRows('partners'),
        hasRelatedRows('expenses'),
        hasRelatedRows('amenity_areas'),
        hasRelatedRows('non_sellable_areas'),
        hasRelatedRows('project_managers'),
        hasRelatedRows('agents'),
      ]);
      return relatedRowsPresence.any((hasRows) => hasRows);
    } catch (_) {
      // Fail open on lookup errors so we do not block valid projects.
      return true;
    }
  }

  Future<void> _showSyncRiskOfflineDialog({
    required String projectId,
  }) async {
    if (!mounted || _isSyncRiskOfflineDialogVisible) return;
    _isSyncRiskOfflineDialogVisible = true;
    try {
      await showProjectSyncRiskOfflineDialog(
        context: context,
        onRecentProjects: _navigateToRecentProjectsFromOfflineDialog,
        onRetry: () async {
          await _refreshNetworkReachability(
            projectId: projectId,
            force: true,
          );
        },
      );
    } finally {
      _isSyncRiskOfflineDialogVisible = false;
    }
  }

  Future<void> _handleNetworkReachabilityTransition({
    required String projectId,
    required bool previousReachable,
    required bool currentReachable,
  }) async {
    if (currentReachable) {
      _hasShownSyncRiskOfflineDialogForCurrentOutage = false;
      return;
    }
    if (!previousReachable) return;
    if (_hasShownSyncRiskOfflineDialogForCurrentOutage) return;
    if (!_isProjectScopedPage(_currentPage)) return;
    if ((_projectId ?? '').trim() != projectId.trim()) return;
    if (!(_forceCloudSyncStatusVisual || _projectHasSharedAccessBeyondAdmin)) {
      return;
    }

    final hasPendingCloudSync = await _hasPendingCloudSyncWorkForProject(
      projectId,
    );
    if (!_hasActiveSaveStateForExitWarning() && !hasPendingCloudSync) return;

    _hasShownSyncRiskOfflineDialogForCurrentOutage = true;
    await _showSyncRiskOfflineDialog(projectId: projectId);
  }

  Future<void> _refreshNetworkReachability({
    required String projectId,
    bool force = false,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    if (_isNetworkProbeRunning) return;
    final now = DateTime.now().toUtc();
    final lastProbe = _lastNetworkProbeAt;
    if (!force &&
        lastProbe != null &&
        now.difference(lastProbe) < const Duration(seconds: 3)) {
      return;
    }

    _isNetworkProbeRunning = true;
    try {
      final previousReachable = _isNetworkReachableForSync;
      var reachable = true;
      try {
        await Supabase.instance.client
            .from('projects')
            .select('id')
            .eq('id', normalizedProjectId)
            .limit(1)
            .maybeSingle()
            .timeout(const Duration(milliseconds: 1800));
      } catch (error) {
        reachable = !_isLikelyNetworkError(error);
      }

      _setStateSafely(() {
        _isNetworkReachableForSync = reachable;
        _syncSaveStatusVisualOverrideForSharedAccess();
      });
      if (previousReachable != reachable) {
        await _handleNetworkReachabilityTransition(
          projectId: normalizedProjectId,
          previousReachable: previousReachable,
          currentReachable: reachable,
        );
      }
    } finally {
      _lastNetworkProbeAt = DateTime.now().toUtc();
      _isNetworkProbeRunning = false;
    }
  }

  String _projectSharedAccessCacheKey(String projectId) {
    return 'project_${projectId}_has_shared_access_beyond_admin';
  }

  ProjectSaveStatusVisualOverride _queuedOfflineVisualOverride() {
    if (_plotStatusSyncVisualSuppressUntil != null &&
        DateTime.now().isBefore(_plotStatusSyncVisualSuppressUntil!)) {
      return ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
    }
    if (_forceCloudSyncStatusVisual) {
      return _isNetworkReachableForSync
          ? ProjectSaveStatusVisualOverride.syncingInProgressShared
          : ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
    }
    if (_projectHasSharedAccessBeyondAdmin) {
      return _isNetworkReachableForSync
          ? ProjectSaveStatusVisualOverride.syncingInProgressShared
          : ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
    }
    return _isNetworkReachableForSync
        ? ProjectSaveStatusVisualOverride.savedLocallyOnlineNoShare
        : ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
  }

  ProjectSaveStatusVisualOverride _syncedAfterOfflineVisualOverride() {
    final hasSharedCloudSyncContext =
        _forceCloudSyncStatusVisual || _projectHasSharedAccessBeyondAdmin;
    if (hasSharedCloudSyncContext) {
      return ProjectSaveStatusVisualOverride.savedAndSyncedShared;
    }
    return _isNetworkReachableForSync
        ? ProjectSaveStatusVisualOverride.savedLocallyOnlineNoShare
        : ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
  }

  ProjectSaveStatusVisualOverride _savingVisualOverride() {
    final hasSharedCloudSyncContext =
        _forceCloudSyncStatusVisual || _projectHasSharedAccessBeyondAdmin;
    if (!hasSharedCloudSyncContext) {
      return _isNetworkReachableForSync
          ? ProjectSaveStatusVisualOverride.savedLocallyOnlineNoShare
          : ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
    }
    if (_plotStatusSyncVisualSuppressUntil != null &&
        DateTime.now().isBefore(_plotStatusSyncVisualSuppressUntil!)) {
      return ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
    }
    if (_isNetworkReachableForSync) {
      return ProjectSaveStatusVisualOverride.syncingInProgressShared;
    }
    return ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
  }

  ProjectSaveStatusVisualOverride _connectionLostVisualOverride() {
    if (_forceCloudSyncStatusVisual || _projectHasSharedAccessBeyondAdmin) {
      if (_isNetworkReachableForSync) {
        return ProjectSaveStatusVisualOverride.saveFailedPoorConnection;
      }
      return ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
    }
    return _isNetworkReachableForSync
        ? ProjectSaveStatusVisualOverride.saveFailedPoorConnection
        : ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
  }

  void _syncSaveStatusVisualOverrideForSharedAccess() {
    if (_saveStatus != ProjectSaveStatusType.saved) {
      _sharedAccessSyncVisualTimer?.cancel();
      _sharedAccessSyncVisualTimer = null;
    }
    if (_saveStatus == ProjectSaveStatusType.queuedOffline) {
      _saveStatusVisualOverride = _queuedOfflineVisualOverride();
      return;
    }
    if (_saveStatus == ProjectSaveStatusType.saved) {
      _saveStatusVisualOverride = _syncedAfterOfflineVisualOverride();
      return;
    }
    if (_saveStatus == ProjectSaveStatusType.uploadingFile) {
      _saveStatusVisualOverride = ProjectSaveStatusVisualOverride.none;
      return;
    }
    if (_saveStatus == ProjectSaveStatusType.saving ||
        _saveStatus == ProjectSaveStatusType.notSaved) {
      _saveStatusVisualOverride = _savingVisualOverride();
      return;
    }
    if (_saveStatus == ProjectSaveStatusType.connectionLost) {
      _saveStatusVisualOverride = _connectionLostVisualOverride();
      return;
    }
    if (_saveStatus != ProjectSaveStatusType.saved) {
      _saveStatusVisualOverride = ProjectSaveStatusVisualOverride.none;
    }
  }

  Future<void> _refreshProjectSharedAccessState({
    String? projectId,
    bool hydrateFromCacheFirst = true,
  }) async {
    final normalizedProjectId = (projectId ?? _projectId ?? '').trim();
    if (normalizedProjectId.isEmpty) {
      _setStateSafely(() {
        if (!_projectHasSharedAccessBeyondAdmin &&
            _saveStatusVisualOverride == ProjectSaveStatusVisualOverride.none) {
          return;
        }
        _projectHasSharedAccessBeyondAdmin = false;
        _forceCloudSyncStatusVisual = false;
        _syncSaveStatusVisualOverrideForSharedAccess();
      });
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final cacheKey = _projectSharedAccessCacheKey(normalizedProjectId);
    final cached = prefs.getBool(cacheKey);

    if (hydrateFromCacheFirst && cached != null) {
      _setStateSafely(() {
        _projectHasSharedAccessBeyondAdmin = cached;
        _syncSaveStatusVisualOverrideForSharedAccess();
      });
    }

    try {
      if (!await ProjectAccessService.hasAccessControlTables()) {
        if (cached == null) {
          _setStateSafely(() {
            _projectHasSharedAccessBeyondAdmin = false;
            _forceCloudSyncStatusVisual = false;
            _syncSaveStatusVisualOverrideForSharedAccess();
          });
        }
        return;
      }

      bool hasSharedAccess = false;

      try {
        final inviteRows = await Supabase.instance.client
            .from('project_access_invites')
            .select('role,status')
            .eq('project_id', normalizedProjectId);
        for (final row in inviteRows) {
          final role =
              ProjectAccessService.normalizeRoleStrict(row['role']?.toString());
          if (!_isNonAdminSharedRole(role)) continue;
          final status = (row['status'] ?? '').toString();
          if (_isInviteStatusGrantingSharedAccess(status)) {
            hasSharedAccess = true;
            break;
          }
        }
      } catch (_) {
        // Fall back to project_members lookup below.
      }

      if (!hasSharedAccess) {
        try {
          final memberRows = await Supabase.instance.client
              .from('project_members')
              .select('role,status')
              .eq('project_id', normalizedProjectId);
          for (final row in memberRows) {
            final role = ProjectAccessService.normalizeRoleStrict(
              row['role']?.toString(),
            );
            if (!_isNonAdminSharedRole(role)) continue;
            final status = (row['status'] ?? '').toString();
            if (_isMemberStatusGrantingSharedAccess(status)) {
              hasSharedAccess = true;
              break;
            }
          }
        } catch (_) {
          // Keep invite-derived value.
        }
      }

      if (hasSharedAccess) {
        unawaited(_ensureSharedProjectKeepsSyncing(normalizedProjectId));
      }

      await prefs.setBool(cacheKey, hasSharedAccess);
      _setStateSafely(() {
        _projectHasSharedAccessBeyondAdmin = hasSharedAccess;
        _syncSaveStatusVisualOverrideForSharedAccess();
      });
    } catch (_) {
      if (cached == null) return;
      _setStateSafely(() {
        _projectHasSharedAccessBeyondAdmin = cached;
        _syncSaveStatusVisualOverrideForSharedAccess();
      });
    }
  }

  Future<void> _refreshCloudSyncStatusVisualState({
    String? projectId,
  }) async {
    final normalizedProjectId = (projectId ?? _projectId ?? '').trim();
    if (normalizedProjectId.isEmpty) {
      _setStateSafely(() {
        if (!_forceCloudSyncStatusVisual) return;
        _forceCloudSyncStatusVisual = false;
        _syncSaveStatusVisualOverrideForSharedAccess();
      });
      return;
    }

    bool cloudSyncEnabled = false;
    try {
      cloudSyncEnabled =
          await ProjectStorageService.isCloudSyncEnabledForProject(
        normalizedProjectId,
        defaultValue: false,
      );
    } catch (_) {
      cloudSyncEnabled = false;
    }

    _setStateSafely(() {
      if (_forceCloudSyncStatusVisual == cloudSyncEnabled) return;
      _forceCloudSyncStatusVisual = cloudSyncEnabled;
      _syncSaveStatusVisualOverrideForSharedAccess();
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
    unawaited(_checkForAppUpdateAndPrompt());
  }

  @override
  void dispose() {
    _removeGlobalRoleDropdown();
    _dashboardLoadingIndicatorDelayTimer?.cancel();
    _plotStatusLoadingIndicatorDelayTimer?.cancel();
    _savingStatusReconcileTimer?.cancel();
    _projectSyncTimer?.cancel();
    _sharedAccessSyncVisualTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    final shouldWarnForSharedUploadExit =
        _currentPage == NavigationPage.documents &&
            _projectHasSharedAccessBeyondAdmin &&
            _hasDocumentsActiveUploads;
    final isProjectWorkspacePage =
        _currentPage == NavigationPage.projectDetails ||
            _currentPage == NavigationPage.dataEntry ||
            _currentPage == NavigationPage.dashboard ||
            _currentPage == NavigationPage.plotStatus ||
            _currentPage == NavigationPage.documents ||
            _currentPage == NavigationPage.settings ||
            _currentPage == NavigationPage.report;
    final shouldWarnForSyncInProgressExit = isProjectWorkspacePage
        ? await _shouldWarnBeforeLeavingProjectWorkspace()
        : false;

    if (!shouldWarnForSharedUploadExit && !shouldWarnForSyncInProgressExit) {
      return ui.AppExitResponse.exit;
    }
    if (_isHandlingExitRequest) {
      return ui.AppExitResponse.cancel;
    }

    _isHandlingExitRequest = true;
    try {
      final shouldLeave = await _showExitSyncWarningDialog(
        uploadInProgressVariant: shouldWarnForSharedUploadExit,
      );
      return shouldLeave ? ui.AppExitResponse.exit : ui.AppExitResponse.cancel;
    } finally {
      _isHandlingExitRequest = false;
    }
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

  Future<void> _checkForAppUpdateAndPrompt() async {
    if (_isCheckingForAppUpdate) return;
    _isCheckingForAppUpdate = true;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted) return;

      String platformKey() {
        if (kIsWeb) return 'web';
        switch (defaultTargetPlatform) {
          case TargetPlatform.windows:
            return 'windows';
          case TargetPlatform.macOS:
            return 'macos';
          case TargetPlatform.linux:
            return 'linux';
          case TargetPlatform.android:
            return 'android';
          case TargetPlatform.iOS:
            return 'ios';
          default:
            return '';
        }
      }

      final updateInfo =
          await AppUpdateService.checkForUpdate(platform: platformKey());
      if (!mounted || updateInfo == null) return;

      final prefs = await SharedPreferences.getInstance();
      final alreadyPromptedVersion =
          (prefs.getString(_appUpdatePromptedVersionPrefKey) ?? '').trim();
      if (alreadyPromptedVersion == updateInfo.latestVersion) return;
      if (!mounted) return;

      final shouldUpdate = await showDialog<bool>(
            context: context,
            barrierDismissible: true,
            barrierColor: Colors.black.withValues(alpha: 0.5),
            builder: (dialogContext) {
              final notes = (updateInfo.releaseNotes ?? '').trim();
              final preview = notes.isEmpty
                  ? ''
                  : notes
                      .split('\n')
                      .where((line) => line.trim().isNotEmpty)
                      .take(3)
                      .join('\n');
              return Material(
                color: Colors.transparent,
                child: SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Container(
                        width: 538,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Update Available',
                                  style: GoogleFonts.inter(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black,
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () =>
                                      Navigator.of(dialogContext).pop(null),
                                  child: const Icon(
                                    Icons.close,
                                    size: 22,
                                    color: Color(0xFF0C8CE9),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'A new version (${updateInfo.latestVersion}) is available.\\nCurrent version: ${updateInfo.currentVersion}',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.normal,
                                color: Colors.black.withValues(alpha: 0.8),
                              ),
                            ),
                            if (preview.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                preview,
                                maxLines: 5,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.normal,
                                  color: Colors.black.withValues(alpha: 0.8),
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                GestureDetector(
                                  onTap: () =>
                                      Navigator.of(dialogContext).pop(false),
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
                                          color: Colors.black
                                              .withValues(alpha: 0.25),
                                          blurRadius: 2,
                                          offset: const Offset(0, 0),
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: Text(
                                        'Later',
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
                                  onTap: () =>
                                      Navigator.of(dialogContext).pop(true),
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
                                          color: Colors.black
                                              .withValues(alpha: 0.25),
                                          blurRadius: 2,
                                          offset: const Offset(0, 0),
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: Text(
                                        'Update',
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.normal,
                                          color: const Color(0xFF0C8CE9),
                                        ),
                                      ),
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
                ),
              );
            },
          ) ??
          false;

      if (!shouldUpdate) return;
      await prefs.setString(
        _appUpdatePromptedVersionPrefKey,
        updateInfo.latestVersion,
      );
      var loadingDialogShown = false;
      if (mounted) {
        loadingDialogShown = true;
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) {
              return AlertDialog(
                content: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Updating app...',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final launchedInstaller =
          await DesktopInstallerUpdateService.tryRunInstaller(updateInfo);
      if (loadingDialogShown && mounted) {
        final navigator = Navigator.of(context, rootNavigator: true);
        if (navigator.canPop()) {
          navigator.pop();
        }
      }
      if (launchedInstaller) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (!kIsWeb && mounted) {
          await SystemNavigator.pop();
        }
        return;
      }

      final uri = Uri.tryParse(updateInfo.releaseUrl);
      if (uri == null) return;
      await launchUrl(
        uri,
        mode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
      );
    } catch (_) {
      // Silent failure: update checks should never block app usage.
    } finally {
      _isCheckingForAppUpdate = false;
    }
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
      _isNetworkReachableForSync = false;
      return;
    }

    // Keep data-reload stable while inside project pages, but still keep
    // network/sync indicators live so status icons react without refresh.
    if (_isProjectScopedPage(_currentPage)) {
      if (_lastSeenProjectIdForSync != projectId) {
        _lastSeenProjectIdForSync = projectId;
        _lastSeenProjectUpdatedAt = null;
        unawaited(_refreshProjectSharedAccessState(projectId: projectId));
      }
      await _refreshNetworkReachability(projectId: projectId);
      return;
    }

    if (_lastSeenProjectIdForSync != projectId) {
      _lastSeenProjectIdForSync = projectId;
      _lastSeenProjectUpdatedAt = null;
      unawaited(_refreshProjectSharedAccessState(projectId: projectId));
      unawaited(_refreshNetworkReachability(projectId: projectId, force: true));
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
      if (!_isNetworkReachableForSync) {
        const previousReachable = false;
        _setStateSafely(() {
          _isNetworkReachableForSync = true;
          _syncSaveStatusVisualOverrideForSharedAccess();
        });
        await _handleNetworkReachabilityTransition(
          projectId: projectId,
          previousReachable: previousReachable,
          currentReachable: true,
        );
      }

      final previous = _lastSeenProjectUpdatedAt;
      if (previous == null) {
        _lastSeenProjectUpdatedAt = updatedAt;
        return;
      }

      if (updatedAt.isAfter(previous)) {
        _lastSeenProjectUpdatedAt = updatedAt;
        _setStateSafely(() {
          _projectDataVersion++;
        });
        _refreshErrorBadgesFromStoredData();
      }
    } catch (error) {
      final previousReachable = _isNetworkReachableForSync;
      if (_isLikelyNetworkError(error) && previousReachable) {
        _setStateSafely(() {
          _isNetworkReachableForSync = false;
          _syncSaveStatusVisualOverrideForSharedAccess();
        });
        await _handleNetworkReachabilityTransition(
          projectId: projectId,
          previousReachable: previousReachable,
          currentReachable: false,
        );
      }
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
          final hasPendingUpload =
              await OfflineFileUploadQueueService.hasPendingUploads(
            projectId: projectId,
          );
          final hasPendingSyncWork =
              hasPendingCreate || hasPendingSave || hasPendingUpload;
          if (_saveStatus == ProjectSaveStatusType.queuedOffline) {
            final cloudSyncEnabled =
                await ProjectStorageService.isCloudSyncEnabledForProject(
              projectId,
              defaultValue: false,
            );
            if (!cloudSyncEnabled) {
              _setStateSafely(() {
                if (_saveStatus == ProjectSaveStatusType.queuedOffline) {
                  _saveStatusVisualOverride = _queuedOfflineVisualOverride();
                }
              });
              timer.cancel();
              return;
            }
            await _refreshNetworkReachability(projectId: projectId);
            await _refreshProjectSharedAccessState(
              projectId: projectId,
              hydrateFromCacheFirst: true,
            );
            if (hasPendingCreate || hasPendingSave || hasPendingUpload) {
              _setStateSafely(() {
                if (_saveStatus == ProjectSaveStatusType.queuedOffline) {
                  _saveStatusVisualOverride = _queuedOfflineVisualOverride();
                }
              });
              return;
            }

            // No queued sync work remains for this project; clear stale
            // queuedOffline immediately instead of waiting on timestamps.
            _setStateSafely(() {
              if (_saveStatus == ProjectSaveStatusType.queuedOffline) {
                _saveStatus = ProjectSaveStatusType.saved;
                _savedTimeAgo = 'Just now';
                _projectDataDirty = false;
                _saveStatusVisualOverride = _syncedAfterOfflineVisualOverride();
              }
            });
            timer.cancel();
            return;
          }

          // If remote save caught up with the latest local edit,
          // resolve stale "Saving..." / "Not saved" UI to Saved.
          final isSynced = (localEditMs == 0 && remoteSaveMs == 0) ||
              (localEditMs > 0 && remoteSaveMs >= localEditMs);
          if (isSynced || !hasPendingSyncWork) {
            _setStateSafely(() {
              if (_saveStatus == ProjectSaveStatusType.saving ||
                  _saveStatus == ProjectSaveStatusType.notSaved ||
                  _saveStatus == ProjectSaveStatusType.queuedOffline) {
                _saveStatus = ProjectSaveStatusType.saved;
                _savedTimeAgo = 'Just now';
                _projectDataDirty = false;
                _saveStatusVisualOverride = _syncedAfterOfflineVisualOverride();
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

  Future<bool> _hasPendingCloudSyncWorkForProject(
    String projectId, {
    bool attemptFlush = false,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return false;
    final cloudSyncEnabled =
        await ProjectStorageService.isCloudSyncEnabledForProject(
      normalizedProjectId,
      defaultValue: false,
    );
    if (!cloudSyncEnabled) return false;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (attemptFlush) {
      try {
        await OfflineProjectSyncService.flushPendingCreates(
          supabase: Supabase.instance.client,
          userId: userId,
          projectId: normalizedProjectId,
        );
      } catch (_) {}
      try {
        await ProjectStorageService.flushPendingSaves(
          projectId: normalizedProjectId,
        );
      } catch (_) {}
      try {
        await OfflineFileUploadQueueService.flushPendingUploads(
          projectId: normalizedProjectId,
        );
      } catch (_) {}
    }

    final hasPendingProjectSync =
        await ProjectStorageService.hasPendingProjectSyncWork(
      normalizedProjectId,
      userId: userId,
    );
    final hasPendingUploads =
        await OfflineFileUploadQueueService.hasPendingUploads(
      projectId: normalizedProjectId,
    );
    return hasPendingProjectSync || hasPendingUploads;
  }

  Future<bool> _shouldWarnBeforeLeavingProjectWorkspace() async {
    final currentProjectId = (_projectId ?? '').trim();
    bool hasPendingCloudSync = false;

    if (currentProjectId.isNotEmpty) {
      final shouldAttemptFlush =
          _saveStatus == ProjectSaveStatusType.queuedOffline ||
              _saveStatusVisualOverride ==
                  ProjectSaveStatusVisualOverride.syncingInProgressShared;
      hasPendingCloudSync = await _hasPendingCloudSyncWorkForProject(
        currentProjectId,
        attemptFlush: shouldAttemptFlush,
      );
      if (!hasPendingCloudSync &&
          (_saveStatus == ProjectSaveStatusType.queuedOffline ||
              _saveStatusVisualOverride ==
                  ProjectSaveStatusVisualOverride.syncingInProgressShared)) {
        _handleSaveStatusChanged(ProjectSaveStatusType.saved);
      }
    }

    return _hasActiveSaveStateForExitWarning() || hasPendingCloudSync;
  }

  Future<void> _ensureSharedProjectKeepsSyncing(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    try {
      await ProjectStorageService.setCloudSyncEnabledForProject(
        normalizedProjectId,
        true,
      );
      await OfflineProjectSyncService.flushPendingCreates(
        supabase: Supabase.instance.client,
      );
      await ProjectStorageService.flushPendingSaves(
        projectId: normalizedProjectId,
      );
      await OfflineFileUploadQueueService.flushPendingUploads(
        projectId: normalizedProjectId,
      );
    } catch (_) {
      // Best effort: keep UI responsive and retry on next refresh/save cycle.
    }
  }

  Future<bool> _handleAccessControlSyncRequest(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return false;

    await ProjectStorageService.setCloudSyncEnabledForProject(
      normalizedProjectId,
      true,
    );
    await _refreshNetworkReachability(
      projectId: normalizedProjectId,
      force: true,
    );

    _setStateSafely(() {
      _forceCloudSyncStatusVisual = true;
      _saveStatus = ProjectSaveStatusType.queuedOffline;
      _saveStatusVisualOverride = _isNetworkReachableForSync
          ? ProjectSaveStatusVisualOverride.syncingInProgressShared
          : ProjectSaveStatusVisualOverride.savedLocallyOfflineSharedNotSynced;
    });

    if (!_isNetworkReachableForSync) {
      _startSavingStatusReconcile();
      return false;
    }

    bool synced = false;
    try {
      synced = await ProjectStorageService.enableCloudSyncAndFlushProject(
        normalizedProjectId,
        timeout: const Duration(seconds: 90),
        pollInterval: const Duration(milliseconds: 600),
      ).timeout(
        const Duration(seconds: 95),
        onTimeout: () => false,
      );
    } catch (_) {
      synced = false;
    }
    if (!synced) {
      final hasPendingSyncWork =
          await ProjectStorageService.hasPendingProjectSyncWork(
        normalizedProjectId,
        userId: Supabase.instance.client.auth.currentUser?.id,
      );
      if (!hasPendingSyncWork) {
        synced = true;
      } else {
        final pendingDebug = await ProjectStorageService.pendingSyncDebugInfo(
          normalizedProjectId,
          userId: Supabase.instance.client.auth.currentUser?.id,
        );
        debugPrint(
          '[AccessControlSync] pending debug for $normalizedProjectId: $pendingDebug',
        );
      }
    }
    await _refreshNetworkReachability(
      projectId: normalizedProjectId,
      force: true,
    );
    await _refreshProjectSharedAccessState(
      projectId: normalizedProjectId,
      hydrateFromCacheFirst: false,
    );

    _setStateSafely(() {
      if (synced) {
        _saveStatus = ProjectSaveStatusType.saved;
        _savedTimeAgo = 'Just now';
        _projectDataDirty = false;
        _saveStatusVisualOverride =
            ProjectSaveStatusVisualOverride.savedAndSyncedShared;
      } else {
        _saveStatus = ProjectSaveStatusType.queuedOffline;
        _saveStatusVisualOverride = _isNetworkReachableForSync
            ? ProjectSaveStatusVisualOverride.saveFailedPoorConnection
            : ProjectSaveStatusVisualOverride
                .savedLocallyOfflineSharedNotSynced;
      }
    });
    if (synced) {
      unawaited(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        await _refreshCloudSyncStatusVisualState(
          projectId: normalizedProjectId,
        );
        _setStateSafely(() {
          _saveStatusVisualOverride = _syncedAfterOfflineVisualOverride();
        });
      }());
    }
    if (!synced) {
      _startSavingStatusReconcile();
    }
    return synced;
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
    final isProjectWorkspacePage =
        _currentPage == NavigationPage.projectDetails ||
            _currentPage == NavigationPage.dataEntry ||
            _currentPage == NavigationPage.dashboard ||
            _currentPage == NavigationPage.plotStatus ||
            _currentPage == NavigationPage.documents ||
            _currentPage == NavigationPage.settings ||
            _currentPage == NavigationPage.report;
    if (isProjectWorkspacePage) {
      final shouldWarn = await _shouldWarnBeforeLeavingProjectWorkspace();
      if (shouldWarn) {
        final shouldLeave = await _showExitSyncWarningDialog(
          uploadInProgressVariant: false,
        );
        if (!mounted || !shouldLeave) {
          return;
        }
      }
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
      final isDefaultSampleProject =
          DefaultSampleProjectService.isDefaultSampleProjectId(
        validatedProjectId,
      );
      var isPendingLocalProject = false;
      if (!isDefaultSampleProject) {
        try {
          isPendingLocalProject =
              await OfflineProjectSyncService.isPendingLocalProject(
            projectId: validatedProjectId,
            userId: Supabase.instance.client.auth.currentUser?.id,
          );
        } catch (_) {
          isPendingLocalProject = false;
        }
      }
      String? validatedRole;
      if (isDefaultSampleProject) {
        validatedRole = DefaultSampleProjectService.viewerRole;
        projectName ??= DefaultSampleProjectService.projectName;
        if (projectOwnerEmail.isEmpty) {
          projectOwnerEmail = DefaultSampleProjectService.ownerEmail;
        }
      } else if (isPendingLocalProject) {
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
      unawaited(
        _refreshProjectSharedAccessState(projectId: validatedProjectId),
      );
      unawaited(
        _refreshNetworkReachability(
          projectId: validatedProjectId,
          force: true,
        ),
      );
      unawaited(
        _refreshCloudSyncStatusVisualState(projectId: validatedProjectId),
      );
      _refreshErrorBadgesFromStoredData(force: true);
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
      _refreshErrorBadgesFromStoredData(force: true);
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
              _isRestrictedInviteRole(resolvedInviteRole) ||
              _isDefaultSampleViewerRole(resolvedInviteRole));
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
        if (validatedProjectId.isNotEmpty) {
          unawaited(
            _refreshProjectSharedAccessState(projectId: validatedProjectId),
          );
          unawaited(
            _refreshNetworkReachability(
              projectId: validatedProjectId,
              force: true,
            ),
          );
          unawaited(
            _refreshCloudSyncStatusVisualState(projectId: validatedProjectId),
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

  Future<void> _showPendingInviteLaunchPopup() async {
    if (_didProcessInviteLaunchPopup) return;
    _didProcessInviteLaunchPopup = true;

    final prefs = await SharedPreferences.getInstance();
    final shouldShow = prefs.getBool(_inviteLaunchPopupPendingPrefKey) ?? false;
    if (!shouldShow) return;
    await prefs.remove(_inviteLaunchPopupPendingPrefKey);
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Invite Opened'),
            content: const Text(
              'If the invite tab opened briefly and closed, open the 8Answers app and refresh/relaunch once. The invited project dashboard will appear.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
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

  Future<void> _refreshErrorBadgesFromStoredData({bool force = false}) async {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (isDataEntryContext) {
      // Data Entry already drives badge state from live section callbacks.
      // Avoid DB-snapshot recalcs here; they can transiently show false red badges.
      _scheduleDataEntryBadgeRecalc();
      return;
    }
    if (!force && _isProjectScopedPage(_currentPage)) {
      return;
    }
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
              _isMissingNumeric(a['area']));

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
      String normalizeSoldLikeStatus(dynamic value) {
        var status = (value ?? '').toString().trim().toLowerCase();
        if (status.contains('.')) {
          status = status.split('.').last;
        }
        if (status == 'pending' || status == 'blocked') return 'reserved';
        return status;
      }

      bool hasPaymentMethodInPlot(dynamic paymentsRaw) {
        List<dynamic> payments = const [];
        if (paymentsRaw is List<dynamic>) {
          payments = paymentsRaw;
        } else if (paymentsRaw is String && paymentsRaw.trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(paymentsRaw);
            if (decoded is List) {
              payments = decoded;
            }
          } catch (_) {
            payments = const [];
          }
        }
        return payments.any((payment) {
          if (payment is Map<String, dynamic>) {
            final method =
                (payment['paymentMethod'] ?? payment['payment_method'] ?? '')
                    .toString()
                    .trim();
            return method.isNotEmpty;
          }
          if (payment is Map) {
            final method =
                (payment['paymentMethod'] ?? payment['payment_method'] ?? '')
                    .toString()
                    .trim();
            return method.isNotEmpty;
          }
          return false;
        });
      }

      bool hasPaymentMethodInAmenity(Map<String, dynamic> area) {
        final paymentRaw =
            (area['payment'] ?? area['payment_method'] ?? '').toString().trim();
        if (paymentRaw.isEmpty) return false;
        try {
          final decoded = jsonDecode(paymentRaw);
          if (decoded is Map) {
            final methods = (decoded['methods'] ?? decoded['method'] ?? '')
                .toString()
                .trim();
            return methods.isNotEmpty;
          }
          if (decoded is List) {
            return decoded.isNotEmpty;
          }
        } catch (_) {
          // Treat non-JSON non-empty text as a provided payment method.
        }
        return paymentRaw.isNotEmpty;
      }

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

          final status = normalizeSoldLikeStatus(plot['status']);
          if (status == 'sold' || status == 'reserved') {
            final salePriceMissing =
                _isMissingNumeric(plot['sale_price'] ?? plot['salePrice']);
            final buyerMissing = (plot['buyer_name'] ?? plot['buyerName'] ?? '')
                .toString()
                .trim()
                .isEmpty;
            final agentMissing =
                (plot['agent_name'] ?? plot['agentName'] ?? plot['agent'] ?? '')
                    .toString()
                    .trim()
                    .isEmpty;
            final dateMissing = (plot['sale_date'] ?? plot['saleDate'] ?? '')
                .toString()
                .trim()
                .isEmpty;
            final hasPaymentMethod = hasPaymentMethodInPlot(plot['payments']);
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

      for (final area in amenityAreas) {
        final status = normalizeSoldLikeStatus(area['status']);
        if (status != 'sold' && status != 'reserved') continue;

        final salePriceMissing = _isMissingNumeric(
          area['sale_price'] ?? area['salePrice'],
        );
        final buyerMissing = (area['buyer_name'] ?? area['buyerName'] ?? '')
            .toString()
            .trim()
            .isEmpty;
        final agentMissing =
            (area['agent_name'] ?? area['agentName'] ?? area['agent'] ?? '')
                .toString()
                .trim()
                .isEmpty;
        final dateMissing = (area['sale_date'] ?? area['saleDate'] ?? '')
            .toString()
            .trim()
            .isEmpty;
        final hasPaymentMethod = hasPaymentMethodInAmenity(area);

        if (salePriceMissing ||
            buyerMissing ||
            agentMissing ||
            dateMissing ||
            !hasPaymentMethod) {
          hasPlotStatusErrors = true;
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
      final nextDataEntryErrors = mergedAreaErrors ||
          hasPartnerErrors ||
          hasExpenseErrors ||
          hasSiteErrors ||
          hasProjectManagerHardErrors ||
          hasAgentHardErrors ||
          hasAboutErrors;

      final hasBadgeStateChanges =
          _hasPlotStatusErrors != hasPlotStatusErrors ||
              _hasAreaErrors != mergedAreaErrors ||
              _hasPartnerErrors != hasPartnerErrors ||
              _hasExpenseErrors != hasExpenseErrors ||
              _hasSiteErrors != hasSiteErrors ||
              _hasProjectManagerErrors != hasProjectManagerErrors ||
              _hasAgentErrors != hasAgentErrors ||
              _hasProjectManagerWarningOnly != hasProjectManagerWarningOnly ||
              _hasAgentWarningOnly != hasAgentWarningOnly ||
              _hasAboutErrors != hasAboutErrors ||
              _hasAboutWarningOnly != hasAboutWarningOnly ||
              _hasDataEntryErrors != nextDataEntryErrors;
      if (!hasBadgeStateChanges) return;

      _setStateSafely(() {
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
        _hasDataEntryErrors = nextDataEntryErrors;
        _hasPlotStatusErrors = hasPlotStatusErrors;
      });
    } catch (e) {
      print('Error refreshing sidebar error badges: $e');
    }
  }

  Future<void> _refreshAccountWarningBadge() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) {
      if (_hasAccountErrors) {
        _setStateSafely(() {
          _hasAccountErrors = false;
        });
      }
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

      if (_hasAccountErrors != hasWarnings) {
        _setStateSafely(() {
          _hasAccountErrors = hasWarnings;
        });
      }
    } catch (e) {
      print('Error refreshing account warning badge: $e');
    }
  }

  Widget _getPageContentForPage(NavigationPage page) {
    final shouldShowReadOnlyDashboard =
        _isReadOnlyDefaultSampleProject && page == NavigationPage.settings;
    if (shouldShowReadOnlyDashboard) {
      return DashboardPage(
        projectId: _projectId,
        dataVersion: _projectDataVersion,
        isActive: _currentPage == page,
        isAgentView: false,
        viewerRole: _projectAccessRole,
        availableRoles: _projectAccessRoleOptions,
        onRoleChanged: _handleDashboardRoleChanged,
        onLoadingStateChanged: _handleDashboardLoadingStateChanged,
        onNavigateToDataEntrySite: _openDataEntrySiteSection,
      );
    }

    switch (page) {
      case NavigationPage.account:
        return AccountSettingsContent(
          onReportIdentityErrorsChanged: _handleAccountErrorsChanged,
          isNetworkReachable: _isNetworkReachableForSync,
        );
      case NavigationPage.notifications:
        return const NotificationsPage();
      case NavigationPage.toDoList:
        return const ToDoListPage();
      case NavigationPage.report:
        return ReportPage(
          projectId: _projectId,
          dataVersion: _projectDataVersion,
          isActive: _currentPage == NavigationPage.report,
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
        return TrashPage(
          key: ValueKey<String>('trash_$_projectsListVersion'),
          onProjectsMutated: _handleProjectsListMutation,
        );
      case NavigationPage.help:
        return const HelpPage();
      case NavigationPage.logout:
        return AccountSettingsContent(
          onReportIdentityErrorsChanged: _handleAccountErrorsChanged,
          isNetworkReachable: _isNetworkReachableForSync,
        );
      case NavigationPage.projectDetails:
        return ProjectDetailsPage(
          key: ValueKey<String>(
            'project_details_${(_projectId ?? '').trim()}',
          ),
          initialProjectName: _projectName,
          projectId: _projectId,
          dataVersion: _projectDataVersion,
          isActive: _currentPage == NavigationPage.projectDetails ||
              _currentPage == NavigationPage.dataEntry,
          isReadOnly: _isReadOnlyDefaultSampleProject,
          isNetworkReachable: _isNetworkReachableForSync,
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
          onPlotStatusErrorsChanged: (status) =>
              _handlePlotStatusErrorsChangedFromPage(
                  NavigationPage.projectDetails, status),
          onAboutErrorsChanged: _handleAboutErrorsChanged,
          onAboutWarningOnlyChanged: _handleAboutWarningOnlyChanged,
        );
      case NavigationPage.home:
        return _previousPage != null
            ? _getPageContentForPage(_previousPage!)
            : AccountSettingsContent(
                onReportIdentityErrorsChanged: _handleAccountErrorsChanged,
                isNetworkReachable: _isNetworkReachableForSync,
              );
      case NavigationPage.dashboard:
        return DashboardPage(
          projectId: _projectId,
          dataVersion: _projectDataVersion,
          isActive: _currentPage == NavigationPage.dashboard,
          isAgentView: _isAgentInviteRole,
          viewerRole: _projectAccessRole,
          availableRoles: _projectAccessRoleOptions,
          onRoleChanged: _handleDashboardRoleChanged,
          onLoadingStateChanged: _handleDashboardLoadingStateChanged,
          onNavigateToDataEntrySite: _openDataEntrySiteSection,
        );
      case NavigationPage.dataEntry:
        return ProjectDetailsPage(
          key: ValueKey<String>(
            'data_entry_${(_projectId ?? '').trim()}',
          ),
          initialProjectName: _projectName,
          projectId: _projectId,
          dataVersion: _projectDataVersion,
          isActive: _currentPage == NavigationPage.dataEntry ||
              _currentPage == NavigationPage.projectDetails,
          isReadOnly: _isReadOnlyDefaultSampleProject,
          requestedTab: _requestedDataEntryTab,
          requestedTabRequestId: _requestedDataEntryTabRequestId,
          isNetworkReachable: _isNetworkReachableForSync,
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
          onPlotStatusErrorsChanged: (status) =>
              _handlePlotStatusErrorsChangedFromPage(
                  NavigationPage.dataEntry, status),
          onAboutErrorsChanged: _handleAboutErrorsChanged,
          onAboutWarningOnlyChanged: _handleAboutWarningOnlyChanged,
        ); // Data Entry shows Project Details page
      case NavigationPage.plotStatus:
        return PlotStatusPage(
          projectId: _projectId,
          dataVersion: _projectDataVersion,
          isActive: _currentPage == NavigationPage.plotStatus,
          isReadOnly: _isReadOnlyDefaultSampleProject,
          isNetworkReachable: _isNetworkReachableForSync,
          onNavigateToDataEntrySite: _openDataEntrySiteSection,
          onSaveStatusChanged: (status) => _handleSaveStatusChangedFromPage(
              NavigationPage.plotStatus, status),
          onPlotStatusErrorsChanged: (status) =>
              _handlePlotStatusErrorsChangedFromPage(
                  NavigationPage.plotStatus, status),
          onLoadingStateChanged: _handlePlotStatusLoadingStateChanged,
          onEditDialogVisibilityChanged:
              _handlePlotStatusEditDialogVisibilityChanged,
        );
      case NavigationPage.documents:
        return DocumentsPage(
          projectId: _projectId,
          dataVersion: _projectDataVersion,
          isActive: _currentPage == NavigationPage.documents,
          isAgentView: _isAgentInviteRole,
          isPartnerView: _isPartnerRestricted,
          isReadOnly: _isReadOnlyDefaultSampleProject,
          isNetworkReachable: _isNetworkReachableForSync,
          onSaveStatusChanged: (status) => _handleSaveStatusChangedFromPage(
              NavigationPage.documents, status),
          onUploadActivityChanged: _handleDocumentsUploadActivityChanged,
        );
      case NavigationPage.settings:
        return SettingsPage(
          projectId: _projectId,
          projectName: _projectName,
          projectOwnerEmail: _projectOwnerEmail,
          viewerRole: _projectAccessRole,
          isNetworkReachable: _isNetworkReachableForSync,
          isRestrictedViewer: _isInviteNavigationRestricted,
          isAccessControlReadOnly: _isProjectManagerInviteRole,
          allowAgentSectionEditing: _isProjectManagerInviteRole,
          hideAccessControlSection: _isAgentInviteRole,
          onProjectDeleted: _handleProjectDeleted,
          onRequestAccessControlSync: _handleAccessControlSyncRequest,
        );
    }
  }

  Widget _getPageContent() {
    final normalizedCurrent = _normalizePageForRetention(_currentPage);
    final currentIndex = _retainedPageOrder.indexOf(normalizedCurrent);
    final safeIndex = currentIndex >= 0
        ? currentIndex
        : _retainedPageOrder.indexOf(NavigationPage.recentProjects);
    final retainedChildren = _retainedPageOrder.map((page) {
      final shouldBuildPage =
          _initializedRetainedPages.contains(page) || page == normalizedCurrent;
      return KeyedSubtree(
        key: ValueKey<String>('retained_slot_${page.name}'),
        child: shouldBuildPage
            ? _getPageContentForPage(page)
            : const SizedBox.shrink(),
      );
    }).toList(growable: false);

    return IndexedStack(
      index: safeIndex,
      children: retainedChildren,
    );
  }

  void _handleProjectDeleted() {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId != null && userId.isNotEmpty) {
      ProjectsListCacheService.invalidateUser(userId);
    }
    _ensureRetainedPageInitialized(NavigationPage.allProjects);
    setState(() {
      _resetProjectScopedTransientStateForProjectSwitch();
      _projectsListVersion++;
      _projectName = null;
      _projectId = null;
      _hasDocumentsActiveUploads = false;
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

  Future<void> _removeDeletedProjectFromVisibleLists({
    required String projectId,
    String? projectName,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;

    final currentUserId =
        (Supabase.instance.client.auth.currentUser?.id ?? '').trim();
    if (currentUserId.isNotEmpty) {
      await OfflineProjectSyncService.removePendingProject(
        projectId: normalizedProjectId,
        userId: currentUserId,
      );
      ProjectsListCacheService.invalidateUser(currentUserId);
    }
    await ProjectStorageService.removePendingOfflineSavesForProject(
      normalizedProjectId,
    );
    ProjectStorageService.invalidateProjectCache(normalizedProjectId);

    if (!mounted) return;
    _setStateSafely(() {
      _projectsListVersion++;
      if ((_projectId ?? '').trim() == normalizedProjectId) {
        _resetProjectScopedTransientStateForProjectSwitch();
        _projectName = null;
        _projectId = null;
        _hasDocumentsActiveUploads = false;
        _projectAccessRole = null;
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = false;
        _projectOwnerEmail = null;
        _projectHasSharedAccessBeyondAdmin = false;
        _forceCloudSyncStatusVisual = false;
        _previousPage = _currentPage;
        _currentPage = NavigationPage.recentProjects;
      }
    });
    await _persistNavState();
    if (!mounted) return;
    final safeProjectName = (projectName ?? '').trim();
    final message = safeProjectName.isEmpty
        ? 'This project was deleted and removed from your list.'
        : '"$safeProjectName" was deleted and removed from your list.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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
        _resetProjectScopedTransientStateForProjectSwitch();
        _projectName = projectName;
        _projectId = projectId;
        _hasDocumentsActiveUploads = false;
        _requestedDataEntryTab = ProjectTab.about;
        _requestedDataEntryTabRequestId++;
        _projectsListVersion++;
        _projectAccessRole = null;
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = false;
        _projectOwnerEmail = null;
        _projectHasSharedAccessBeyondAdmin = false;
        _forceCloudSyncStatusVisual = false;
        _isNetworkReachableForSync = !savedLocally;
        _hasShownSyncRiskOfflineDialogForCurrentOutage = false;
        _saveStatus = savedLocally
            ? ProjectSaveStatusType.queuedOffline
            : ProjectSaveStatusType.saved;
        _saveStatusVisualOverride = savedLocally
            ? _queuedOfflineVisualOverride()
            : _syncedAfterOfflineVisualOverride();
        _savedTimeAgo = savedLocally ? null : 'Just now';
        _previousPage = _currentPage;
        _currentPage = NavigationPage.dataEntry;
      });
      if (projectId != null && projectId.trim().isNotEmpty) {
        unawaited(_refreshProjectSharedAccessState(projectId: projectId));
        unawaited(
          _refreshNetworkReachability(projectId: projectId, force: true),
        );
      }
      if (savedLocally) {
        _startSavingStatusReconcile();
      }
      _recordPageVisit(_currentPage);
      _persistNavState();
      _refreshErrorBadgesFromStoredData(force: true);
      if (savedLocally && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Project saved in your system. Enable sync from Access Control when you want to share it.',
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
        _resetProjectScopedTransientStateForProjectSwitch();
        _projectName = projectName;
        _projectId = normalizedProjectId;
        _hasDocumentsActiveUploads = false;
        _requestedDataEntryTab = ProjectTab.about;
        _requestedDataEntryTabRequestId++;
        _projectAccessRole = null;
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = false;
        _projectOwnerEmail = null;
        _projectHasSharedAccessBeyondAdmin = false;
        _forceCloudSyncStatusVisual = false;
        _isNetworkReachableForSync = false;
        _hasShownSyncRiskOfflineDialogForCurrentOutage = false;
        _saveStatus = ProjectSaveStatusType.queuedOffline;
        _saveStatusVisualOverride = _queuedOfflineVisualOverride();
        _savedTimeAgo = null;
        _previousPage = _currentPage;
        _currentPage = NavigationPage.dataEntry;
      });
      unawaited(
        _refreshProjectSharedAccessState(projectId: normalizedProjectId),
      );
      unawaited(
        _refreshNetworkReachability(
          projectId: normalizedProjectId,
          force: true,
        ),
      );
      _startSavingStatusReconcile();
      _recordPageVisit(_currentPage);
      await _persistNavState();
      _refreshErrorBadgesFromStoredData();
      return;
    }

    if (DefaultSampleProjectService.isDefaultSampleProjectId(
      normalizedProjectId,
    )) {
      if (!mounted) return;
      _ensureRetainedPageInitialized(NavigationPage.dashboard);
      setState(() {
        _resetProjectScopedTransientStateForProjectSwitch();
        _projectName = DefaultSampleProjectService.projectName;
        _projectId = normalizedProjectId;
        _hasDocumentsActiveUploads = false;
        _requestedDataEntryTab = ProjectTab.about;
        _requestedDataEntryTabRequestId++;
        _projectAccessRole = DefaultSampleProjectService.viewerRole;
        _projectAccessRoleOptions = <String>[
          DefaultSampleProjectService.viewerRole,
        ];
        _activeProjectRoles = <String>{DefaultSampleProjectService.viewerRole};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = true;
        _projectOwnerEmail = DefaultSampleProjectService.ownerEmail;
        _projectHasSharedAccessBeyondAdmin = false;
        _forceCloudSyncStatusVisual = false;
        _isNetworkReachableForSync = true;
        _hasShownSyncRiskOfflineDialogForCurrentOutage = false;
        _saveStatus = ProjectSaveStatusType.saved;
        _saveStatusVisualOverride = ProjectSaveStatusVisualOverride.none;
        _savedTimeAgo = 'Just now';
        _projectDataDirty = false;
        _previousPage = _currentPage;
        _currentPage = NavigationPage.dashboard;
      });
      _recordPageVisit(_currentPage);
      await _persistNavState();
      _refreshErrorBadgesFromStoredData(force: true);
      return;
    }

    final cloudSyncEnabled =
        await ProjectStorageService.isCloudSyncEnabledForProject(
      normalizedProjectId,
      defaultValue: false,
    );
    final ownerEmail = await _resolveProjectOwnerEmail(
      projectId: normalizedProjectId,
      prefs: prefs,
    );
    final isCurrentUserOwnerByEmail = _isCurrentUserOwnerEmail(ownerEmail);
    final canConfirmOwnerByEmail = ownerEmail.isNotEmpty;
    if (cloudSyncEnabled) {
      final hasPendingLocalSave =
          await ProjectStorageService.hasPendingOfflineSaves(
        projectId: normalizedProjectId,
      );
      if (!hasPendingLocalSave) {
        await _refreshNetworkReachability(
          projectId: normalizedProjectId,
          force: true,
        );
        final shouldBlockOfflineOpen = canConfirmOwnerByEmail &&
            !isCurrentUserOwnerByEmail &&
            !_isNetworkReachableForSync;
        if (shouldBlockOfflineOpen) {
          if (!mounted) return;
          await _showSharedProjectOfflineOpenDialog(
            projectId: normalizedProjectId,
            projectName: projectName,
          );
          return;
        }
      }
    }

    bool projectLookupSucceeded = false;
    bool isDeletedFromDatabase = false;
    String projectOwnerUserId = '';
    try {
      final projectRow = await Supabase.instance.client
          .from('projects')
          .select('id,user_id')
          .eq('id', normalizedProjectId)
          .maybeSingle();
      projectLookupSucceeded = true;
      isDeletedFromDatabase = projectRow == null;
      projectOwnerUserId = (projectRow?['user_id'] ?? '').toString().trim();
    } catch (_) {
      // If lookup fails (e.g. transient network issue), keep previous behavior:
      // allow opening cached/local data path instead of force-removing.
    }
    if (projectLookupSucceeded && isDeletedFromDatabase) {
      if (cloudSyncEnabled) {
        await _removeDeletedProjectFromVisibleLists(
          projectId: normalizedProjectId,
          projectName: projectName,
        );
        return;
      }

      // For local-only projects (cloud sync disabled), keep the project even
      // if a document-sync bootstrap row was removed from the remote DB.
      if (!mounted) return;
      _ensureRetainedPageInitialized(NavigationPage.dataEntry);
      setState(() {
        _resetProjectScopedTransientStateForProjectSwitch();
        _projectName = projectName;
        _projectId = normalizedProjectId;
        _hasDocumentsActiveUploads = false;
        _requestedDataEntryTab = ProjectTab.about;
        _requestedDataEntryTabRequestId++;
        _projectAccessRole = null;
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = <String>{};
        _hasResolvedProjectRoles = false;
        _projectOwnerEmail = ownerEmail.isEmpty ? null : ownerEmail;
        _projectHasSharedAccessBeyondAdmin = false;
        _forceCloudSyncStatusVisual = false;
        _isNetworkReachableForSync = false;
        _hasShownSyncRiskOfflineDialogForCurrentOutage = false;
        _saveStatus = ProjectSaveStatusType.queuedOffline;
        _saveStatusVisualOverride = _queuedOfflineVisualOverride();
        _savedTimeAgo = null;
        _previousPage = _currentPage;
        _currentPage = NavigationPage.dataEntry;
      });
      unawaited(
        _refreshProjectSharedAccessState(projectId: normalizedProjectId),
      );
      unawaited(
        _refreshNetworkReachability(
          projectId: normalizedProjectId,
          force: true,
        ),
      );
      _startSavingStatusReconcile();
      _recordPageVisit(_currentPage);
      await _persistNavState();
      _refreshErrorBadgesFromStoredData();
      return;
    }

    if (!cloudSyncEnabled && projectLookupSucceeded && !isDeletedFromDatabase) {
      final normalizedCurrentUserId = (currentUserId ?? '').trim();
      final isOwnedByCurrentUser = (normalizedCurrentUserId.isNotEmpty &&
              projectOwnerUserId.isNotEmpty &&
              normalizedCurrentUserId == projectOwnerUserId) ||
          (canConfirmOwnerByEmail && isCurrentUserOwnerByEmail);
      if (isOwnedByCurrentUser) {
        final hasLocalProjectData = await _hasLocalProjectDataOnThisDevice(
          projectId: normalizedProjectId,
          userId:
              normalizedCurrentUserId.isEmpty ? null : normalizedCurrentUserId,
        );
        if (!hasLocalProjectData) {
          final hasSyncedRemoteData = await _hasSyncedRemoteProjectData(
            projectId: normalizedProjectId,
          );
          if (!hasSyncedRemoteData) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'This project is not on this system. Enable sync in Access Control to see it across devices in your account.',
                ),
              ),
            );
            return;
          }
        }
      }
    }

    final isNetworkReachableAtOpen = _isNetworkReachableForSync;

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
    resolvedRole = (resolvedRole ?? '').trim().toLowerCase();
    if (resolvedRole.isEmpty &&
        !_isNetworkReachableForSync &&
        (!canConfirmOwnerByEmail || isCurrentUserOwnerByEmail)) {
      resolvedRole = 'owner';
    }
    if (resolvedRole.isEmpty &&
        cloudSyncEnabled &&
        !_isNetworkReachableForSync &&
        canConfirmOwnerByEmail &&
        !isCurrentUserOwnerByEmail) {
      if (!mounted) return;
      await _showSharedProjectOfflineOpenDialog(
        projectId: normalizedProjectId,
        projectName: projectName,
      );
      return;
    }
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
        _resetProjectScopedTransientStateForProjectSwitch();
        _projectName = projectName;
        _projectId = normalizedProjectId;
        _hasDocumentsActiveUploads = false;
        _projectAccessRole = pausedViewerRole;
        _projectAccessRoleOptions = <String>[];
        _activeProjectRoles = <String>{};
        _deniedProjectRoles = deniedRoles;
        _hasResolvedProjectRoles = true;
        _projectOwnerEmail = ownerEmail.isEmpty ? null : ownerEmail;
        _projectHasSharedAccessBeyondAdmin = false;
        _forceCloudSyncStatusVisual = cloudSyncEnabled;
        _isNetworkReachableForSync = isNetworkReachableAtOpen;
        _hasShownSyncRiskOfflineDialogForCurrentOutage = false;
        _saveStatus = ProjectSaveStatusType.saved;
        _saveStatusVisualOverride = _syncedAfterOfflineVisualOverride();
        _savedTimeAgo = 'Just now';
        _projectDataDirty = false;
        _previousPage = _currentPage;
        _currentPage = NavigationPage.dashboard;
      });
      unawaited(
        _refreshProjectSharedAccessState(projectId: normalizedProjectId),
      );
      unawaited(
        _refreshNetworkReachability(
          projectId: normalizedProjectId,
          force: true,
        ),
      );
      unawaited(
        _refreshCloudSyncStatusVisualState(projectId: normalizedProjectId),
      );
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
      _resetProjectScopedTransientStateForProjectSwitch();
      _projectName = projectName;
      _projectId = normalizedProjectId;
      _hasDocumentsActiveUploads = false;
      _projectAccessRole = roleForNavState;
      _projectAccessRoleOptions = <String>[];
      _activeProjectRoles = <String>{};
      _deniedProjectRoles = <String>{};
      _hasResolvedProjectRoles = false;
      _projectOwnerEmail = ownerEmail.isEmpty ? null : ownerEmail;
      _projectHasSharedAccessBeyondAdmin = false;
      _forceCloudSyncStatusVisual = cloudSyncEnabled;
      _isNetworkReachableForSync = isNetworkReachableAtOpen;
      _hasShownSyncRiskOfflineDialogForCurrentOutage = false;
      _saveStatus = ProjectSaveStatusType.saved;
      _saveStatusVisualOverride = _syncedAfterOfflineVisualOverride();
      _savedTimeAgo = 'Just now';
      _projectDataDirty = false;
      _previousPage = _currentPage;
      _currentPage = targetPage;
    });
    unawaited(
      _refreshProjectSharedAccessState(projectId: normalizedProjectId),
    );
    unawaited(
      _refreshNetworkReachability(
        projectId: normalizedProjectId,
        force: true,
      ),
    );
    unawaited(
      _refreshCloudSyncStatusVisualState(projectId: normalizedProjectId),
    );
    _recordPageVisit(_currentPage);
    unawaited(
      _refreshProjectRoleOptions(
        projectId: normalizedProjectId,
        selectedRole: roleForNavState,
      ),
    );
    _persistNavState();
    _refreshErrorBadgesFromStoredData(force: true);
  }

  void _handleErrorStateChanged(bool hasErrors) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    // Accept explicit hard-error signals (e.g. amenity data-entry checks)
    // immediately so sidebar icon stays red while editing.
    if (hasErrors) {
      if (_hasDataEntryErrors) return;
      _setStateSafely(() {
        _hasDataEntryErrors = true;
      });
      return;
    }
    // Keep Data Entry badge stable and based on full section state.
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAreaErrorsChanged(bool hasErrors) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    if (_hasAreaErrors == hasErrors) return;
    _setStateSafely(() {
      _hasAreaErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handlePartnerErrorsChanged(bool hasErrors) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    if (_hasPartnerErrors == hasErrors) return;
    _setStateSafely(() {
      _hasPartnerErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleExpenseErrorsChanged(bool hasErrors) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    if (_hasExpenseErrors == hasErrors) return;
    _setStateSafely(() {
      _hasExpenseErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleSiteErrorsChanged(bool hasErrors) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    if (_hasSiteErrors == hasErrors) return;
    _setStateSafely(() {
      _hasSiteErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleProjectManagerErrorsChanged(bool hasErrors) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    if (_hasProjectManagerErrors == hasErrors) return;
    _setStateSafely(() {
      _hasProjectManagerErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleProjectManagerWarningOnlyChanged(bool hasWarningOnly) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    if (_hasProjectManagerWarningOnly == hasWarningOnly) return;
    _setStateSafely(() {
      _hasProjectManagerWarningOnly = hasWarningOnly;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAgentErrorsChanged(bool hasErrors) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    if (_hasAgentErrors == hasErrors) return;
    _setStateSafely(() {
      _hasAgentErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAgentWarningOnlyChanged(bool hasWarningOnly) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    if (_hasAgentWarningOnly == hasWarningOnly) return;
    _setStateSafely(() {
      _hasAgentWarningOnly = hasWarningOnly;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAboutErrorsChanged(bool hasErrors) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    if (_hasAboutErrors == hasErrors) return;
    _setStateSafely(() {
      _hasAboutErrors = hasErrors;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAboutWarningOnlyChanged(bool hasWarningOnly) {
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    if (!isDataEntryContext) return;
    if (_hasAboutWarningOnly == hasWarningOnly) return;
    _setStateSafely(() {
      _hasAboutWarningOnly = hasWarningOnly;
    });
    _scheduleDataEntryBadgeRecalc();
  }

  void _handleAccountErrorsChanged(bool hasErrors) {
    if (_hasAccountErrors == hasErrors) return;
    _setStateSafely(() {
      _hasAccountErrors = hasErrors;
    });
  }

  void _handlePlotStatusErrorsChangedFromPage(
    NavigationPage sourcePage,
    bool hasErrors,
  ) {
    final isDataEntrySource = sourcePage == NavigationPage.dataEntry ||
        sourcePage == NavigationPage.projectDetails;
    final isDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    // Ignore hidden page callbacks; only accept updates from visible page.
    // Exception: Data Entry is allowed to update Plot Status badge while
    // Data Entry is visible because site edits can affect that badge.
    final shouldAccept =
        sourcePage == _currentPage || (isDataEntrySource && isDataEntryContext);
    if (!shouldAccept) return;
    if (_hasPlotStatusErrors == hasErrors) return;
    _setStateSafely(() {
      _hasPlotStatusErrors = hasErrors;
    });
  }

  void _handleDashboardLoadingStateChanged(bool isLoading) {
    if (!isLoading) {
      _dashboardLoadingSignalActive = false;
      _dashboardLoadingIndicatorDelayTimer?.cancel();
      if (!_isDashboardPageLoading) return;
      _setStateSafely(() {
        _isDashboardPageLoading = false;
      });
      return;
    }

    if (_currentPage != NavigationPage.dashboard) return;
    if (_dashboardLoadingSignalActive) return;
    _dashboardLoadingSignalActive = true;
    if (_isDashboardPageLoading) return;
    _dashboardLoadingIndicatorDelayTimer?.cancel();
    _dashboardLoadingIndicatorDelayTimer = Timer(
      _pageLoadingIndicatorShowDelay,
      () {
        if (!mounted ||
            !_dashboardLoadingSignalActive ||
            _isDashboardPageLoading) {
          return;
        }
        _setStateSafely(() {
          _isDashboardPageLoading = true;
        });
      },
    );
  }

  void _handlePlotStatusLoadingStateChanged(bool isLoading) {
    if (!isLoading) {
      _plotStatusLoadingSignalActive = false;
      _plotStatusLoadingIndicatorDelayTimer?.cancel();
      if (!_isPlotStatusPageLoading) return;
      _setStateSafely(() {
        _isPlotStatusPageLoading = false;
      });
      return;
    }

    if (_currentPage != NavigationPage.plotStatus) return;
    if (_plotStatusLoadingSignalActive) return;
    _plotStatusLoadingSignalActive = true;
    if (_isPlotStatusPageLoading) return;
    _plotStatusLoadingIndicatorDelayTimer?.cancel();
    _plotStatusLoadingIndicatorDelayTimer = Timer(
      _pageLoadingIndicatorShowDelay,
      () {
        if (!mounted ||
            !_plotStatusLoadingSignalActive ||
            _isPlotStatusPageLoading) {
          return;
        }
        _setStateSafely(() {
          _isPlotStatusPageLoading = true;
        });
      },
    );
  }

  void _handlePlotStatusEditDialogVisibilityChanged(bool isOpen) {
    if (_isPlotStatusEditDialogOpen == isOpen) return;
    _setStateSafely(() {
      _isPlotStatusEditDialogOpen = isOpen;
    });
  }

  void _handleDocumentsUploadActivityChanged(bool hasActiveUploads) {
    if (_hasDocumentsActiveUploads == hasActiveUploads) return;
    _setStateSafely(() {
      _hasDocumentsActiveUploads = hasActiveUploads;
    });
  }

  void _handleSaveStatusChanged(ProjectSaveStatusType status) {
    final previousStatus = _saveStatus;
    final previousOverride = _saveStatusVisualOverride;
    final wasDirty = _projectDataDirty;
    if (status == ProjectSaveStatusType.saving ||
        status == ProjectSaveStatusType.notSaved) {
      _projectDataDirty = true;
    }
    if (status == ProjectSaveStatusType.saving ||
        status == ProjectSaveStatusType.notSaved ||
        status == ProjectSaveStatusType.queuedOffline) {
      _startSavingStatusReconcile();
    } else {
      _savingStatusReconcileTimer?.cancel();
    }
    if (status == ProjectSaveStatusType.queuedOffline) {
      final projectId = (_projectId ?? '').trim();
      if (projectId.isNotEmpty) {
        unawaited(
          _refreshProjectSharedAccessState(projectId: projectId),
        );
        unawaited(
          _refreshNetworkReachability(projectId: projectId, force: true),
        );
      }
    }
    if (status == ProjectSaveStatusType.connectionLost) {
      final projectId = (_projectId ?? '').trim();
      if (projectId.isNotEmpty) {
        unawaited(
          _refreshNetworkReachability(projectId: projectId, force: true),
        );
      }
    }
    ProjectSaveStatusVisualOverride nextOverride = previousOverride;
    if (status == ProjectSaveStatusType.queuedOffline) {
      nextOverride = _queuedOfflineVisualOverride();
    } else if (status == ProjectSaveStatusType.saved) {
      nextOverride = _syncedAfterOfflineVisualOverride();
    } else if (status == ProjectSaveStatusType.uploadingFile) {
      nextOverride = ProjectSaveStatusVisualOverride.none;
    } else if (status == ProjectSaveStatusType.saving ||
        status == ProjectSaveStatusType.notSaved) {
      nextOverride = _savingVisualOverride();
    } else if (status == ProjectSaveStatusType.connectionLost) {
      nextOverride = _connectionLostVisualOverride();
    } else {
      final keepOfflineVisual = previousStatus ==
              ProjectSaveStatusType.queuedOffline &&
          (previousOverride ==
                  ProjectSaveStatusVisualOverride.savedLocallyOnlineNoShare ||
              previousOverride ==
                  ProjectSaveStatusVisualOverride
                      .savedLocallyOfflineSharedNotSynced ||
              previousOverride ==
                  ProjectSaveStatusVisualOverride.syncingInProgressShared);
      nextOverride = keepOfflineVisual
          ? previousOverride
          : ProjectSaveStatusVisualOverride.none;
    }

    if (status == previousStatus &&
        wasDirty == _projectDataDirty &&
        nextOverride == previousOverride) {
      return;
    }
    _setStateSafely(() {
      _saveStatus = status;
      _saveStatusVisualOverride = nextOverride;
      if (status == ProjectSaveStatusType.saved) {
        // Update saved time when status changes to saved
        _savedTimeAgo = 'Just now';
        if (wasDirty || _projectDataDirty) {
          final isOnDataEntryContext =
              _currentPage == NavigationPage.dataEntry ||
                  _currentPage == NavigationPage.projectDetails;
          // Keep Data Entry badge stable while editing; avoid cross-page
          // auto-refresh and reload cascades while navigating.
          if (isOnDataEntryContext) {
            _scheduleDataEntryBadgeRecalc();
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
    if (sourcePage == NavigationPage.plotStatus &&
        (status == ProjectSaveStatusType.notSaved ||
            status == ProjectSaveStatusType.saving ||
            status == ProjectSaveStatusType.queuedOffline)) {
      _plotStatusSyncVisualSuppressUntil =
          DateTime.now().add(const Duration(seconds: 3));
    }
    final isDataEntryContextSource = sourcePage == NavigationPage.dataEntry ||
        sourcePage == NavigationPage.projectDetails;
    final normalizedStatus =
        (isDataEntryContextSource && status == ProjectSaveStatusType.notSaved)
            ? ProjectSaveStatusType.saving
            : status;
    final isIncomingDirtySignal =
        normalizedStatus == ProjectSaveStatusType.saving ||
            normalizedStatus == ProjectSaveStatusType.notSaved ||
            normalizedStatus == ProjectSaveStatusType.queuedOffline;
    final isDocumentsContextSource = sourcePage == NavigationPage.documents;
    final isDocumentsDirtySignal = isIncomingDirtySignal;
    if (isDocumentsContextSource && isDocumentsDirtySignal) {
      _documentsPagePendingRefresh = true;
    }
    if (isDocumentsContextSource &&
        normalizedStatus == ProjectSaveStatusType.saved &&
        _documentsPagePendingRefresh) {
      _documentsPagePendingRefresh = false;
      _setStateSafely(() {
        _projectDataVersion++;
      });
      _refreshErrorBadgesFromStoredData();
    }

    final isDataEntryDirtySignal = isIncomingDirtySignal;
    if (isDataEntryContextSource && isDataEntryDirtySignal) {
      _backgroundDataEntrySavePendingRefresh = true;
    }
    final keepQueuedOfflineSticky = isDataEntryContextSource &&
        _saveStatus == ProjectSaveStatusType.queuedOffline &&
        normalizedStatus == ProjectSaveStatusType.saving;
    if (keepQueuedOfflineSticky) {
      return;
    }
    // Pages are retained in an IndexedStack; hidden pages can still emit
    // callbacks. Ignore save-status events from non-visible pages so the
    // sidebar status reflects the active screen only.
    if (_currentPage != sourcePage) {
      final saveStatusCanBeClearedFromBackground =
          _saveStatus == ProjectSaveStatusType.loading ||
              _saveStatus == ProjectSaveStatusType.saving ||
              _saveStatus == ProjectSaveStatusType.notSaved ||
              _saveStatus == ProjectSaveStatusType.queuedOffline;
      final shouldRefreshFromBackgroundDataEntrySave =
          isDataEntryContextSource &&
              normalizedStatus == ProjectSaveStatusType.saved &&
              (_backgroundDataEntrySavePendingRefresh || _projectDataDirty);
      final shouldClearBackgroundSyncing =
          normalizedStatus == ProjectSaveStatusType.saved &&
              saveStatusCanBeClearedFromBackground &&
              (shouldRefreshFromBackgroundDataEntrySave ||
                  _projectDataDirty ||
                  isDocumentsContextSource ||
                  sourcePage == NavigationPage.plotStatus);
      if (shouldRefreshFromBackgroundDataEntrySave) {
        _projectDataDirty = false;
      }
      if (isDataEntryContextSource &&
          normalizedStatus == ProjectSaveStatusType.saved) {
        _backgroundDataEntrySavePendingRefresh = false;
      }
      if (shouldClearBackgroundSyncing) {
        _handleSaveStatusChanged(ProjectSaveStatusType.saved);
      }
      return;
    }
    if (isDataEntryContextSource &&
        normalizedStatus == ProjectSaveStatusType.saved) {
      _backgroundDataEntrySavePendingRefresh = false;
    }
    _handleSaveStatusChanged(normalizedStatus);
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
        MaterialPageRoute(
          builder: (context) => const UnauthenticatedPage(
            openSignInDirectly: true,
          ),
        ),
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

    bool isProjectWorkspacePage(NavigationPage candidate) {
      return candidate == NavigationPage.projectDetails ||
          candidate == NavigationPage.dataEntry ||
          candidate == NavigationPage.dashboard ||
          candidate == NavigationPage.plotStatus ||
          candidate == NavigationPage.documents ||
          candidate == NavigationPage.settings ||
          candidate == NavigationPage.report;
    }

    Future<bool> shouldWarnBeforeLeavingProjectWorkspace() async =>
        _shouldWarnBeforeLeavingProjectWorkspace();

    final isLeavingProjectWorkspaceToHomeOrRecent =
        (page == NavigationPage.home ||
                page == NavigationPage.recentProjects) &&
            isProjectWorkspacePage(_currentPage);
    if (isLeavingProjectWorkspaceToHomeOrRecent) {
      final shouldWarn = await shouldWarnBeforeLeavingProjectWorkspace();
      if (!mounted) return;
      if (shouldWarn) {
        final shouldLeave = await _showExitSyncWarningDialog(
          uploadInProgressVariant: false,
        );
        if (!mounted || !shouldLeave) return;
      }
    }

    final isOnDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    final isLeavingDataEntryContext = isOnDataEntryContext &&
        page != NavigationPage.dataEntry &&
        page != NavigationPage.projectDetails;

    if (isLeavingDataEntryContext) {
      // Commit any focused text edit so ProjectDetails autosave can run.
      FocusManager.instance.primaryFocus?.unfocus();
      // Local-first navigation: don't block page switches on remote saves.
      // Let sync continue in the background.
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

    unawaited(_showPendingInviteLaunchPopup());

    final isProjectContextPage =
        _currentPage == NavigationPage.projectDetails ||
            _currentPage == NavigationPage.dashboard ||
            _currentPage == NavigationPage.dataEntry ||
            _currentPage == NavigationPage.plotStatus ||
            _currentPage == NavigationPage.documents ||
            _currentPage == NavigationPage.settings ||
            _currentPage == NavigationPage.report;
    final hasActiveProject =
        isProjectContextPage && (_projectId?.trim().isNotEmpty ?? false);
    final isSidebarLoading = isProjectContextPage && _projectId == null;
    final isContentSkeletonLoading =
        (_currentPage == NavigationPage.dashboard && _isDashboardPageLoading) ||
            (_currentPage == NavigationPage.plotStatus &&
                _isPlotStatusPageLoading);
    final hasActiveSaveState = _saveStatus == ProjectSaveStatusType.saving ||
        _saveStatus == ProjectSaveStatusType.uploadingFile ||
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
    var effectiveSaveStatusVisualOverride =
        (isContentSkeletonLoading && !hasActiveSaveState)
            ? ProjectSaveStatusVisualOverride.none
            : _saveStatusVisualOverride;
    if (!isContentSkeletonLoading &&
        _currentPage == NavigationPage.documents &&
        !_isNetworkReachableForSync) {
      effectiveSaveStatusVisualOverride =
          ProjectSaveStatusVisualOverride.documentsOfflineNoNetwork;
    }
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
    final shouldBlurGlobalRoleBadge =
        _currentPage == NavigationPage.plotStatus &&
            _isPlotStatusEditDialogOpen;

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
                saveStatusVisualOverride: effectiveSaveStatusVisualOverride,
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
                isReadOnlyProject: _isReadOnlyDefaultSampleProject,
                hasActiveProject: hasActiveProject,
                onPageChanged: _handlePageChange,
                pageContent: _getPageContent(),
              );
              return _buildScreenWithOverlays(
                layout: layout,
                showPausedAccessOverlay: shouldShowPausedAccessOverlay,
                showRoleBadge: showGlobalRoleBadge,
                blurRoleBadge: shouldBlurGlobalRoleBadge,
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
                saveStatusVisualOverride: effectiveSaveStatusVisualOverride,
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
                isReadOnlyProject: _isReadOnlyDefaultSampleProject,
                hasActiveProject: hasActiveProject,
                onPageChanged: _handlePageChange,
                pageContent: _getPageContent(),
              );
              return _buildScreenWithOverlays(
                layout: layout,
                showPausedAccessOverlay: shouldShowPausedAccessOverlay,
                showRoleBadge: showGlobalRoleBadge,
                blurRoleBadge: shouldBlurGlobalRoleBadge,
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
                saveStatusVisualOverride: effectiveSaveStatusVisualOverride,
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
                isReadOnlyProject: _isReadOnlyDefaultSampleProject,
                hasActiveProject: hasActiveProject,
                onPageChanged: _handlePageChange,
                pageContent: _getPageContent(),
              );
              return _buildScreenWithOverlays(
                layout: layout,
                showPausedAccessOverlay: shouldShowPausedAccessOverlay,
                showRoleBadge: showGlobalRoleBadge,
                blurRoleBadge: shouldBlurGlobalRoleBadge,
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
  final ProjectSaveStatusVisualOverride? saveStatusVisualOverride;
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
  final bool isReadOnlyProject;
  final bool hasActiveProject;

  const DesktopLayout({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    required this.pageContent,
    this.projectName,
    this.saveStatus,
    this.saveStatusVisualOverride,
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
    this.isReadOnlyProject = false,
    this.hasActiveProject = false,
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
          saveStatusVisualOverride: saveStatusVisualOverride,
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
          isReadOnlyProject: isReadOnlyProject,
          hasActiveProject: hasActiveProject,
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
  final ProjectSaveStatusVisualOverride? saveStatusVisualOverride;
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
  final bool isReadOnlyProject;
  final bool hasActiveProject;

  const TabletLayout({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    required this.pageContent,
    this.projectName,
    this.saveStatus,
    this.saveStatusVisualOverride,
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
    this.isReadOnlyProject = false,
    this.hasActiveProject = false,
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
          saveStatusVisualOverride: saveStatusVisualOverride,
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
          isReadOnlyProject: isReadOnlyProject,
          hasActiveProject: hasActiveProject,
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
  final ProjectSaveStatusVisualOverride? saveStatusVisualOverride;
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
  final bool isReadOnlyProject;
  final bool hasActiveProject;

  const MobileLayout({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
    required this.pageContent,
    this.projectName,
    this.saveStatus,
    this.saveStatusVisualOverride,
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
    this.isReadOnlyProject = false,
    this.hasActiveProject = false,
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
                      saveStatusVisualOverride: widget.saveStatusVisualOverride,
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
                      isReadOnlyProject: widget.isReadOnlyProject,
                      hasActiveProject: widget.hasActiveProject,
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
