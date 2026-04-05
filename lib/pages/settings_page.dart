import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/project_storage_service.dart';
import '../services/project_access_service.dart';
import '../services/offline_project_sync_service.dart';
import '../services/offline_file_upload_queue_service.dart';
import '../services/area_unit_service.dart';
import '../utils/area_unit_utils.dart';
import '../utils/web_navigation_context.dart' as web_nav;

enum _AccessControlRole { admin, partner, projectManager, agent }

enum _AccessInviteStatus { none, requested, accepted, paused }

class _AccessInviteEntry {
  _AccessInviteEntry({
    String email = '',
    this.status = _AccessInviteStatus.none,
  }) : emailController = TextEditingController(text: email);

  final TextEditingController emailController;
  _AccessInviteStatus status;
  bool isPauseResumeLoading = false;
  bool isSendRequestLoading = false;

  String get email => emailController.text.trim();

  void dispose() {
    emailController.dispose();
  }
}

class _RemoveAccessDialogContent extends StatefulWidget {
  const _RemoveAccessDialogContent({
    required this.roleLabel,
    required this.email,
    this.isSelfAdminRemoval = false,
    required this.onConfirmRemove,
  });

  final String roleLabel;
  final String email;
  final bool isSelfAdminRemoval;
  final Future<void> Function() onConfirmRemove;

  @override
  State<_RemoveAccessDialogContent> createState() =>
      _RemoveAccessDialogContentState();
}

class _RemoveAccessDialogContentState
    extends State<_RemoveAccessDialogContent> {
  late final TextEditingController _confirmController;
  late final FocusNode _confirmFocusNode;

  bool get _removeEnabled =>
      _confirmController.text.trim().toLowerCase() == 'remove';

  @override
  void initState() {
    super.initState();
    _confirmController = TextEditingController();
    _confirmFocusNode = FocusNode();
    _confirmFocusNode.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _confirmController.dispose();
    _confirmFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isSelfAdminRemoval = widget.isSelfAdminRemoval;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 538,
        height: isSelfAdminRemoval ? 338 : 288,
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: Colors.red,
                    ),
                    const SizedBox(width: 16),
                    Text(
                      isSelfAdminRemoval
                          ? 'Removing Self as Admin?'
                          : 'Removing ${widget.roleLabel}?',
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Icon(
                    Icons.close,
                    size: 16,
                    color: Color(0xFF0C8CE9),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              isSelfAdminRemoval
                  ? 'Removing yourself will revoke your access to the project.'
                  : 'Removing this Email ID will revoke their access to the project.',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 8),
            if (isSelfAdminRemoval) ...[
              Text(
                'You will no longer have access to this project. To regain access, your email must be assigned a role (Admin, Partner, Project Manager, or Agent).',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Admin access will remain with other emails assigned the Admin role.',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black.withOpacity(0.8),
                ),
              ),
            ] else
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: '${widget.email} ',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.black.withOpacity(0.8),
                      ),
                    ),
                    TextSpan(
                      text:
                          'will no longer be able to view or access the project.',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black.withOpacity(0.8),
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(height: isSelfAdminRemoval ? 12 : 16),
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: 'Type ',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF323232),
                    ),
                  ),
                  TextSpan(
                    text: 'remove ',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF323232),
                    ),
                  ),
                  TextSpan(
                    text: 'to confirm.',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF323232),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: 150,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xF2FFFFFF),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: _confirmFocusNode.hasFocus
                        ? Colors.red.withOpacity(0.5)
                        : Colors.black.withOpacity(0.25),
                    blurRadius: 2,
                    offset: const Offset(0, 0),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: TextField(
                  controller: _confirmController,
                  focusNode: _confirmFocusNode,
                  cursorHeight: 12,
                  textAlignVertical: TextAlignVertical.center,
                  minLines: 1,
                  maxLines: 1,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
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
                  onTap: _removeEnabled
                      ? () async {
                          await widget.onConfirmRemove();
                          if (!mounted) return;
                          Navigator.of(context).pop();
                        }
                      : null,
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
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        'Remove',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.normal,
                          color: _removeEnabled
                              ? Colors.red
                              : Colors.red.withOpacity(0.5),
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
    );
  }
}

class _AccessControlSyncProgressDialog extends StatefulWidget {
  const _AccessControlSyncProgressDialog({
    required this.projectId,
    required this.onRequestSync,
    required this.onPendingWorkCount,
  });

  final String projectId;
  final Future<bool> Function(String projectId) onRequestSync;
  final Future<int> Function(String projectId) onPendingWorkCount;

  @override
  State<_AccessControlSyncProgressDialog> createState() =>
      _AccessControlSyncProgressDialogState();
}

class _AccessControlSyncProgressDialogState
    extends State<_AccessControlSyncProgressDialog> {
  Timer? _progressTimer;
  bool _isSyncing = true;
  bool _isSynced = false;
  bool _isClosing = false;
  int _initialPendingWork = 1;
  int _pendingWork = 1;
  double _progress = 0.0;

  @override
  void initState() {
    super.initState();
    unawaited(_startSyncFlow());
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshPendingWork() async {
    int pending = 0;
    try {
      pending = await widget.onPendingWorkCount(widget.projectId);
    } catch (_) {
      pending = 0;
    }
    if (!mounted || _isClosing) return;

    final safePending = pending < 0 ? 0 : pending;
    var nextInitial = _initialPendingWork;
    if (safePending > nextInitial) {
      nextInitial = safePending;
    }
    if (nextInitial <= 0) nextInitial = 1;
    final completed = (nextInitial - safePending).clamp(0, nextInitial);
    var nextProgress = nextInitial == 0 ? 0.0 : completed / nextInitial;
    if (_isSyncing) {
      nextProgress = nextProgress.clamp(0.0, 0.98);
    }

    setState(() {
      _initialPendingWork = nextInitial;
      _pendingWork = safePending;
      _progress = nextProgress;
    });
  }

  Future<void> _startSyncFlow() async {
    await _refreshPendingWork();
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 450),
      (_) => unawaited(_refreshPendingWork()),
    );

    bool synced = false;
    try {
      synced = await widget.onRequestSync(widget.projectId);
    } catch (_) {
      synced = false;
    } finally {
      _progressTimer?.cancel();
      _progressTimer = null;
    }

    if (!mounted || _isClosing) return;

    await _refreshPendingWork();
    if (!mounted || _isClosing) return;

    if (!synced) {
      _isClosing = true;
      Navigator.of(context).pop(false);
      return;
    }

    setState(() {
      _isSyncing = false;
      _isSynced = true;
      _pendingWork = 0;
      _progress = 1.0;
    });
  }

  String get _progressCaption {
    if (_isSynced) return 'Your project is live';
    final value = _progress.clamp(0.0, 1.0);
    if (value < 0.10) return 'Connecting to network...';
    if (value < 0.30) return 'Uploading project data...';
    if (value < 0.50) return 'Syncing access permissions...';
    if (value < 0.72) return 'Encrypting and securing your data...';
    if (value < 0.90) return 'Almost there...';
    return 'Your project is live';
  }

  void _close([bool? result]) {
    if (_isClosing || !mounted) return;
    _isClosing = true;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final maxWidth = math.min(
      681.0,
      math.max(320.0, MediaQuery.of(context).size.width - 32),
    );
    final progressWidth = (maxWidth - 32).clamp(0.0, double.infinity);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        width: maxWidth,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF8F9FA),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 2,
              offset: Offset.zero,
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
                Row(
                  children: [
                    const Icon(
                      Icons.sync_rounded,
                      size: 16,
                      color: Color(0xFF0C8CE9),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      _isSynced ? 'All synced!' : 'Syncing project...',
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _close(),
                  child: SizedBox(
                    width: 22.627,
                    height: 22.627,
                    child: Center(
                      child: SvgPicture.asset(
                        'assets/images/cross.svg',
                        width: 13,
                        height: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              _isSynced
                  ? 'Everything is up to date with the cloud.'
                  : 'Getting everything up to date with the cloud.',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: Colors.black,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Your data is end-to-end encrypted and securely stored in the cloud.',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: Colors.black,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: progressWidth,
              height: 17,
              decoration: BoxDecoration(
                color: const Color(0xFFD9D9D9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 240),
                  width: progressWidth * _progress.clamp(0.0, 1.0),
                  height: 17,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0C8CE9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                _progressCaption,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: const Color(0xFF636464),
                  height: 1.3,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: _isSynced
                  ? Container(
                      width: 144,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0C8CE9),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.25),
                            blurRadius: 2,
                            offset: Offset.zero,
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _close(true),
                          child: Center(
                            child: Text(
                              'Done',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w400,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  : Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.25),
                            blurRadius: 2,
                            offset: Offset.zero,
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _close(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SvgPicture.asset(
                                  'assets/images/Dont_sync.svg',
                                  width: 16,
                                  height: 16,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Stop Syncing',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                    color: Colors.red,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final String? projectId;
  final String? projectName;
  final String? projectOwnerEmail;
  final String? viewerRole;
  final bool isNetworkReachable;
  final bool isRestrictedViewer;
  final bool isAccessControlReadOnly;
  final bool allowAgentSectionEditing;
  final bool hideAccessControlSection;
  final VoidCallback? onProjectDeleted;
  final Future<bool> Function(String projectId)? onRequestAccessControlSync;

  const SettingsPage({
    super.key,
    this.projectId,
    this.projectName,
    this.projectOwnerEmail,
    this.viewerRole,
    this.isNetworkReachable = true,
    this.isRestrictedViewer = false,
    this.isAccessControlReadOnly = false,
    this.allowAgentSectionEditing = false,
    this.hideAccessControlSection = false,
    this.onProjectDeleted,
    this.onRequestAccessControlSync,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const String _globalSettingsTabPrefKey = 'nav_settings_active_tab';
  static const String _landingPathEncoded = '/website_8answers%20copy%202/';
  static const String _landingPathDecoded = '/website_8answers copy 2/';
  static const String _defaultInviteBaseUrl = String.fromEnvironment(
    'INVITE_BASE_URL',
    defaultValue: 'https://www.8answers.com/',
  );
  static const String _defaultDownloadUrl = String.fromEnvironment(
    'APP_DOWNLOAD_URL',
    defaultValue: 'https://www.8answers.com/',
  );
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
  final TextEditingController _accessControlEmailController =
      TextEditingController();
  final FocusNode _deleteConfirmFocusNode = FocusNode();
  bool _isAccessControlTabSelected = false;
  bool _isPreparingAccessControlSync = false;
  _AccessControlRole _selectedAccessControlRole = _AccessControlRole.admin;
  final Map<_AccessControlRole, String> _accessControlRoleEmails =
      <_AccessControlRole, String>{
    _AccessControlRole.admin: '',
    _AccessControlRole.partner: '',
    _AccessControlRole.projectManager: '',
    _AccessControlRole.agent: '',
  };
  final Map<_AccessControlRole, _AccessInviteStatus>
      _accessControlInviteStatuses = <_AccessControlRole, _AccessInviteStatus>{
    _AccessControlRole.admin: _AccessInviteStatus.accepted,
    _AccessControlRole.partner: _AccessInviteStatus.none,
    _AccessControlRole.projectManager: _AccessInviteStatus.none,
    _AccessControlRole.agent: _AccessInviteStatus.none,
  };
  final Map<_AccessControlRole, List<_AccessInviteEntry>>
      _additionalAccessRows = <_AccessControlRole, List<_AccessInviteEntry>>{
    _AccessControlRole.admin: <_AccessInviteEntry>[],
    _AccessControlRole.partner: <_AccessInviteEntry>[],
    _AccessControlRole.projectManager: <_AccessInviteEntry>[],
    _AccessControlRole.agent: <_AccessInviteEntry>[],
  };
  final Map<_AccessControlRole, bool> _pauseResumeLoadingByRole =
      <_AccessControlRole, bool>{
    _AccessControlRole.admin: false,
    _AccessControlRole.partner: false,
    _AccessControlRole.projectManager: false,
    _AccessControlRole.agent: false,
  };
  final Map<_AccessControlRole, bool> _sendRequestLoadingByRole =
      <_AccessControlRole, bool>{
    _AccessControlRole.admin: false,
    _AccessControlRole.partner: false,
    _AccessControlRole.projectManager: false,
    _AccessControlRole.agent: false,
  };
  bool _isAccessControlLoading = true;
  bool _isAccessControlSyncReadyForEdits = false;

  void _applyAdminEmailHintIfAvailable({bool overwriteEmptyOnly = true}) {
    final hintedOwnerEmail = (widget.projectOwnerEmail ?? '').trim();
    if (hintedOwnerEmail.isEmpty || !mounted) return;
    final existingAdminEmail =
        (_accessControlRoleEmails[_AccessControlRole.admin] ?? '').trim();
    if (overwriteEmptyOnly && existingAdminEmail.isNotEmpty) return;

    setState(() {
      _accessControlRoleEmails[_AccessControlRole.admin] = hintedOwnerEmail;
      _accessControlInviteStatuses[_AccessControlRole.admin] =
          _AccessInviteStatus.accepted;
      if (_selectedAccessControlRole == _AccessControlRole.admin) {
        _accessControlEmailController.text = hintedOwnerEmail;
        _accessControlEmailController.selection = TextSelection.collapsed(
          offset: _accessControlEmailController.text.length,
        );
      }
    });
  }

  bool _canEditAccessRole(_AccessControlRole role) {
    if (widget.isRestrictedViewer) return false;
    if (!widget.isAccessControlReadOnly) return true;
    return widget.allowAgentSectionEditing && role == _AccessControlRole.agent;
  }

  bool _isRoleReadOnly(_AccessControlRole role) => !_canEditAccessRole(role);

  String get _normalizedViewerRole {
    final explicitRole = (widget.viewerRole ?? '').trim().toLowerCase();
    if (explicitRole.isNotEmpty) return explicitRole;
    if (widget.isRestrictedViewer) return 'partner';
    if (widget.isAccessControlReadOnly) return 'project_manager';
    if (widget.hideAccessControlSection) return 'agent';
    return 'admin';
  }

  bool get _isLimitedDeleteRole {
    final role = _normalizedViewerRole;
    return role == 'partner' ||
        role == 'project_manager' ||
        role == 'agent' ||
        role == 'paused';
  }

  List<String> get _projectBaseUnitAreaOptions => _allProjectBaseUnitAreaOptions
      .where((option) => option == AreaUnitUtils.sqmUnitLabel)
      .toList();

  String _settingsTabPrefKey() {
    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) {
      return _globalSettingsTabPrefKey;
    }
    return '${_globalSettingsTabPrefKey}_$projectId';
  }

  Future<bool> _shouldRestorePersistedSettingsTab() async {
    if (!kIsWeb) return false;
    final prefs = await SharedPreferences.getInstance();
    final persistedCurrentPage =
        (prefs.getString('nav_current_page') ?? '').trim();
    if (persistedCurrentPage != 'settings') return false;
    return web_nav.isReloadNavigation();
  }

  Future<void> _restoreSettingsTabSelection() async {
    final showAccessControlSection = !widget.hideAccessControlSection;
    if (!showAccessControlSection) {
      if (!_isAccessControlTabSelected) return;
      if (!mounted) return;
      setState(() {
        _isAccessControlTabSelected = false;
      });
      return;
    }

    final shouldRestorePersistedSelection =
        await _shouldRestorePersistedSettingsTab();
    final prefs = await SharedPreferences.getInstance();
    var isAccessControlSelected = shouldRestorePersistedSelection
        ? (prefs.getBool(_settingsTabPrefKey()) ?? false)
        : false;
    if (isAccessControlSelected) {
      final projectId = widget.projectId?.trim() ?? '';
      isAccessControlSelected =
          await _isAccessControlSyncReady(projectId: projectId);
    }
    if (!mounted || _isAccessControlTabSelected == isAccessControlSelected) {
      return;
    }
    setState(() {
      _isAccessControlTabSelected = isAccessControlSelected;
    });
  }

  Future<void> _persistSettingsTabSelection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_settingsTabPrefKey(), _isAccessControlTabSelected);
  }

  void _openAccessControlTab() {
    if (_isAccessControlTabSelected) return;
    if (!mounted) return;
    setState(() {
      _isAccessControlTabSelected = true;
    });
    unawaited(_persistSettingsTabSelection());
  }

  Future<bool> _isAccessControlSyncReady({required String projectId}) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return false;
    final cloudSyncEnabled =
        await ProjectStorageService.isCloudSyncEnabledForProject(
      normalizedProjectId,
      defaultValue: false,
    );
    if (!cloudSyncEnabled) return false;
    final hasPendingSyncWork =
        await ProjectStorageService.hasPendingProjectSyncWork(
      normalizedProjectId,
    );
    return !hasPendingSyncWork;
  }

  Future<void> _refreshAccessControlSyncEditState() async {
    final projectId = widget.projectId?.trim() ?? '';
    final isReadyForEdits = projectId.isEmpty
        ? true
        : await _isAccessControlSyncReady(projectId: projectId);
    if (!mounted || _isAccessControlSyncReadyForEdits == isReadyForEdits) {
      return;
    }
    setState(() {
      _isAccessControlSyncReadyForEdits = isReadyForEdits;
    });
  }

  Future<bool> _requestAccessControlSync(String projectId) async {
    final requestSync = widget.onRequestAccessControlSync;
    if (requestSync != null) {
      return requestSync(projectId);
    }
    return ProjectStorageService.enableCloudSyncAndFlushProject(projectId);
  }

  Future<int> _pendingAccessControlSyncWorkCount(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return 0;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final pendingCreates = await OfflineProjectSyncService.pendingCreateCount(
      projectId: normalizedProjectId,
      userId: userId,
    );
    final pendingSaves = await ProjectStorageService.pendingOfflineSaveCount(
      projectId: normalizedProjectId,
    );
    final pendingUploads =
        await OfflineFileUploadQueueService.pendingUploadCount(
      projectId: normalizedProjectId,
    );
    return pendingCreates + pendingSaves + pendingUploads;
  }

  Future<bool?> _showAccessControlSyncProgressDialog({
    required String projectId,
  }) {
    return showDialog<bool?>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _AccessControlSyncProgressDialog(
        projectId: projectId,
        onRequestSync: _requestAccessControlSync,
        onPendingWorkCount: _pendingAccessControlSyncWorkCount,
      ),
    );
  }

  Future<void> _onBlockedAccessControlEditTap() async {
    if (_isPreparingAccessControlSync) return;
    final projectId = widget.projectId?.trim() ?? '';
    if (projectId.isEmpty) return;

    final isReady = await _isAccessControlSyncReady(projectId: projectId);
    if (isReady) {
      await _refreshAccessControlSyncEditState();
      return;
    }

    final shouldStartSync = await _showAccessControlSyncDialog();
    if (!shouldStartSync || !mounted) {
      await _refreshAccessControlSyncEditState();
      return;
    }

    setState(() {
      _isPreparingAccessControlSync = true;
    });
    try {
      final syncResult =
          await _showAccessControlSyncProgressDialog(projectId: projectId);
      if (!mounted || syncResult == null) return;
      if (syncResult != true) {
        final syncPendingMessage = widget.isNetworkReachable
            ? 'Sync started but is not finished yet. Please try again in a moment.'
            : 'Sync is pending without network. Connect to internet and try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(syncPendingMessage),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isPreparingAccessControlSync = false;
        });
      }
      await _refreshAccessControlSyncEditState();
    }
  }

  Future<bool> _showAccessControlSyncDialog() async {
    final decision = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final maxWidth = math.min(
          681.0,
          math.max(
            320.0,
            MediaQuery.of(dialogContext).size.width - 32,
          ),
        );

        Widget buildActionButton({
          required String label,
          required String iconAssetPath,
          required Color backgroundColor,
          required Color foregroundColor,
          required VoidCallback onTap,
        }) {
          return Container(
            height: 44,
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 2,
                  offset: Offset.zero,
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvgPicture.asset(
                        iconAssetPath,
                        width: 16,
                        height: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: foregroundColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          child: Container(
            width: maxWidth,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 2,
                  offset: Offset.zero,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SvgPicture.asset(
                          'assets/images/Warning.svg',
                          width: 16,
                          height: 16,
                        ),
                        const SizedBox(width: 16),
                        Text(
                          'Access Control',
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => Navigator.of(dialogContext).pop(false),
                      child: SizedBox(
                        width: 22.627,
                        height: 22.627,
                        child: Center(
                          child: SvgPicture.asset(
                            'assets/images/cross.svg',
                            width: 13,
                            height: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Connect to a network to grant or revoke user access roles and sync your data to the cloud.',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'To give access control to an email, an internet connection is required.',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'When syncing is on, a network connection is always needed to access the project.',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Your data is end-to-end encrypted and securely stored in the cloud.',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    buildActionButton(
                      label: 'Dont Sync',
                      iconAssetPath: 'assets/images/Dont_sync.svg',
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF0C8CE9),
                      onTap: () => Navigator.of(dialogContext).pop(false),
                    ),
                    buildActionButton(
                      label: 'Sync to cloud',
                      iconAssetPath: 'assets/images/Sync.svg',
                      backgroundColor: const Color(0xFF0C8CE9),
                      foregroundColor: Colors.white,
                      onTap: () => Navigator.of(dialogContext).pop(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    return decision == true;
  }

  Future<void> _handleAccessControlTabTap() async {
    if (_isAccessControlTabSelected || _isPreparingAccessControlSync) return;
    final projectId = widget.projectId?.trim() ?? '';
    if (projectId.isEmpty) {
      _openAccessControlTab();
      await _refreshAccessControlSyncEditState();
      return;
    }

    final isSyncReady = await _isAccessControlSyncReady(projectId: projectId);
    if (isSyncReady) {
      _openAccessControlTab();
      await _refreshAccessControlSyncEditState();
      return;
    }

    final cloudSyncEnabled =
        await ProjectStorageService.isCloudSyncEnabledForProject(
      projectId,
      defaultValue: false,
    );
    if (cloudSyncEnabled) {
      if (!mounted) return;
      final syncPendingMessage = widget.isNetworkReachable
          ? 'Sync is still in progress. Access Control will open after syncing completes.'
          : 'Sync is pending without network. Connect to internet and try Access Control again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(syncPendingMessage),
        ),
      );
      return;
    }

    final shouldStartSync = await _showAccessControlSyncDialog();
    if (!shouldStartSync || !mounted) {
      _openAccessControlTab();
      await _refreshAccessControlSyncEditState();
      return;
    }

    setState(() {
      _isPreparingAccessControlSync = true;
    });
    try {
      final syncResult =
          await _showAccessControlSyncProgressDialog(projectId: projectId);
      if (!mounted || syncResult == null) return;
      if (syncResult == true) {
        _openAccessControlTab();
        await _refreshAccessControlSyncEditState();
        return;
      }
      final syncPendingMessage = widget.isNetworkReachable
          ? 'Sync started but is not finished yet. Please try Access Control again in a moment.'
          : 'Sync is pending without network. Connect to internet and try Access Control again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(syncPendingMessage),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isPreparingAccessControlSync = false;
        });
      }
    }
    await _refreshAccessControlSyncEditState();
  }

  @override
  void initState() {
    super.initState();
    _applyAdminEmailHintIfAvailable();
    _loadProjectBaseUnitArea();
    _loadAccessControlData();
    _restoreSettingsTabSelection();
    unawaited(_refreshAccessControlSyncEditState());
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final projectIdChanged = widget.projectId != oldWidget.projectId;
    final ownerEmailChanged =
        (widget.projectOwnerEmail ?? '').trim().toLowerCase() !=
            (oldWidget.projectOwnerEmail ?? '').trim().toLowerCase();
    final accessVisibilityChanged =
        widget.hideAccessControlSection != oldWidget.hideAccessControlSection;
    if (projectIdChanged) {
      _loadProjectBaseUnitArea();
      _loadAccessControlData();
    }
    if (!projectIdChanged && ownerEmailChanged) {
      _applyAdminEmailHintIfAvailable(overwriteEmptyOnly: true);
    }
    if (projectIdChanged || accessVisibilityChanged) {
      _restoreSettingsTabSelection();
      unawaited(_refreshAccessControlSyncEditState());
    }
  }

  @override
  void dispose() {
    _removeOverlay();
    _removeDeleteDialog();
    _disposeAdditionalAccessRows();
    _deleteConfirmController.dispose();
    _accessControlEmailController.dispose();
    _deleteConfirmFocusNode.dispose();
    super.dispose();
  }

  void _disposeAdditionalAccessRows() {
    for (final entries in _additionalAccessRows.values) {
      for (final entry in entries) {
        entry.dispose();
      }
      entries.clear();
    }
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
                              Icons.warning_amber_rounded,
                              color: Colors.red,
                              size: 16,
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
                          child: const Icon(
                            Icons.close,
                            size: 16,
                            color: Color(0xFF0C8CE9),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    // Warning message
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_isLimitedDeleteRole) ...[
                          Text(
                            'After deleting you will no longer have access to this project.',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.normal,
                              color: Colors.black.withOpacity(0.8),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'To regain access to this project, please contact the admin.',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.normal,
                              color: const Color(0xFF323232),
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
                        ] else ...[
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
                                TextSpan(
                                    text: 'project and all associated data'),
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
                                color: _isLimitedDeleteRole
                                    ? const Color(0xFFFF0000)
                                    : (_deleteConfirmFocusNode.hasFocus
                                        ? const Color(0xFF0C8CE9)
                                        : const Color(0xFFFF0000)),
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
                                  await ProjectAccessService
                                      .deleteProjectForCurrentUser(
                                    projectId: widget.projectId!,
                                  );
                                  _removeDeleteDialog();
                                  if (mounted) {
                                    final message = _isLimitedDeleteRole
                                        ? 'Project removed from your list'
                                        : 'Project deleted';
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(message)),
                                    );
                                  }
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

  String _accessControlRoleLabel(_AccessControlRole role) {
    switch (role) {
      case _AccessControlRole.admin:
        return 'Admin(s)';
      case _AccessControlRole.partner:
        return 'Partner(s)';
      case _AccessControlRole.projectManager:
        return 'Project Manager(s)';
      case _AccessControlRole.agent:
        return 'Agent(s)';
    }
  }

  String _accessControlRoleDescription(_AccessControlRole role) {
    switch (role) {
      case _AccessControlRole.admin:
        return 'Full control over the project, including managing users, roles, permissions, and all project settings.';
      case _AccessControlRole.partner:
        return 'Complete access to all dashboards and project data.';
      case _AccessControlRole.projectManager:
        return 'Full access to manage and update all project-related information.';
      case _AccessControlRole.agent:
        return 'Access limited to only viewing plot availability for sales activities.';
    }
  }

  String _normalizedAccessViewerRole() {
    final explicitRole = (widget.viewerRole ?? '').trim().toLowerCase();
    if (widget.isRestrictedViewer) return 'partner';
    if (widget.isAccessControlReadOnly) return 'project_manager';
    return explicitRole;
  }

  bool _shouldIncludeInviteForViewer(
    _AccessControlRole role,
    _AccessInviteStatus status,
  ) {
    final viewerRole = _normalizedAccessViewerRole();
    if (viewerRole == 'partner') {
      return status == _AccessInviteStatus.accepted;
    }
    if (viewerRole == 'project_manager') {
      if (role == _AccessControlRole.agent) {
        return status == _AccessInviteStatus.accepted ||
            status == _AccessInviteStatus.paused ||
            status == _AccessInviteStatus.requested;
      }
      return status == _AccessInviteStatus.accepted;
    }
    // Admin/owner: show all states.
    return true;
  }

  String get _loggedInUserEmail {
    final email = Supabase.instance.client.auth.currentUser?.email?.trim();
    return (email == null || email.isEmpty) ? '' : email;
  }

  bool _isCurrentUserEmail(String email) {
    final current = _loggedInUserEmail.trim().toLowerCase();
    final target = email.trim().toLowerCase();
    if (current.isEmpty || target.isEmpty) return false;
    return current == target;
  }

  _AccessControlRole? _roleFromDbValue(String rawRole) {
    switch (rawRole.trim().toLowerCase()) {
      case 'admin':
      case 'owner':
        return _AccessControlRole.admin;
      case 'partner':
        return _AccessControlRole.partner;
      case 'project_manager':
        return _AccessControlRole.projectManager;
      case 'agent':
        return _AccessControlRole.agent;
      default:
        return null;
    }
  }

  _AccessInviteStatus _inviteStatusFromDb(String rawStatus) {
    final normalized = rawStatus.trim().toLowerCase();
    if (normalized == 'accepted' || normalized == 'active') {
      return _AccessInviteStatus.accepted;
    }
    if (normalized == 'revoked' || normalized == 'paused') {
      return _AccessInviteStatus.paused;
    }
    if (normalized == 'requested' || normalized == 'pending') {
      return _AccessInviteStatus.requested;
    }
    return _AccessInviteStatus.none;
  }

  void _promoteCurrentUserAccessRowsToTop({
    required String currentUserEmail,
    required Map<_AccessControlRole, String> roleEmails,
    required Map<_AccessControlRole, _AccessInviteStatus> roleStatuses,
    required Map<_AccessControlRole, List<_AccessInviteEntry>>
        roleAdditionalRows,
  }) {
    final normalizedCurrentUserEmail = currentUserEmail.trim().toLowerCase();
    if (normalizedCurrentUserEmail.isEmpty) return;

    for (final role in _AccessControlRole.values) {
      if (role == _AccessControlRole.admin) {
        // Keep owner/admin primary ordering stable for the Admin section.
        continue;
      }
      final primaryEmail = (roleEmails[role] ?? '').trim();
      if (primaryEmail.toLowerCase() == normalizedCurrentUserEmail) continue;

      final rows = roleAdditionalRows[role] ?? <_AccessInviteEntry>[];
      final currentUserIndex = rows.indexWhere(
        (row) => row.email.trim().toLowerCase() == normalizedCurrentUserEmail,
      );
      if (currentUserIndex < 0) continue;

      final currentUserEntry = rows.removeAt(currentUserIndex);
      final previousPrimaryStatus =
          roleStatuses[role] ?? _AccessInviteStatus.none;
      if (primaryEmail.isNotEmpty) {
        rows.insert(
          0,
          _AccessInviteEntry(
            email: primaryEmail,
            status: previousPrimaryStatus,
          ),
        );
      }

      roleEmails[role] = currentUserEntry.email;
      roleStatuses[role] = currentUserEntry.status;
    }
  }

  Future<void> _loadAccessControlData() async {
    if (mounted) {
      setState(() {
        _isAccessControlLoading = true;
      });
    }

    final projectId = widget.projectId?.trim() ?? '';
    if (projectId.isEmpty) {
      if (!mounted) return;
      setState(() {
        _accessControlRoleEmails[_AccessControlRole.admin] = _loggedInUserEmail;
        _accessControlEmailController.text =
            _accessControlRoleEmails[_selectedAccessControlRole] ?? '';
      });
      if (mounted) {
        setState(() {
          _isAccessControlLoading = false;
        });
      }
      return;
    }

    try {
      final roleEmails = <_AccessControlRole, String>{
        _AccessControlRole.admin: '',
        _AccessControlRole.partner: '',
        _AccessControlRole.projectManager: '',
        _AccessControlRole.agent: '',
      };
      final roleStatuses = <_AccessControlRole, _AccessInviteStatus>{
        _AccessControlRole.admin: _AccessInviteStatus.accepted,
        _AccessControlRole.partner: _AccessInviteStatus.none,
        _AccessControlRole.projectManager: _AccessInviteStatus.none,
        _AccessControlRole.agent: _AccessInviteStatus.none,
      };
      final roleAdditionalRows = <_AccessControlRole, List<_AccessInviteEntry>>{
        _AccessControlRole.admin: <_AccessInviteEntry>[],
        _AccessControlRole.partner: <_AccessInviteEntry>[],
        _AccessControlRole.projectManager: <_AccessInviteEntry>[],
        _AccessControlRole.agent: <_AccessInviteEntry>[],
      };
      final activeMemberEmails = <String>{};
      final memberStatusByRoleEmail =
          <_AccessControlRole, Map<String, _AccessInviteStatus>>{
        _AccessControlRole.admin: {},
        _AccessControlRole.partner: {},
        _AccessControlRole.projectManager: {},
        _AccessControlRole.agent: {},
      };
      final roleSeenEmails = <_AccessControlRole, Set<String>>{
        _AccessControlRole.admin: <String>{},
        _AccessControlRole.partner: <String>{},
        _AccessControlRole.projectManager: <String>{},
        _AccessControlRole.agent: <String>{},
      };

      final currentUser = Supabase.instance.client.auth.currentUser;
      final currentUserId = currentUser?.id ?? '';
      final currentUserEmail = currentUser?.email?.trim() ?? '';
      final prefs = await SharedPreferences.getInstance();
      final ownerEmailCacheKey = 'nav_project_owner_email_$projectId';
      String ownerId = '';
      String ownerEmail = '';

      try {
        Map<String, dynamic>? projectRow;
        try {
          projectRow = await Supabase.instance.client
              .from('projects')
              .select('user_id, owner_email')
              .eq('id', projectId)
              .maybeSingle();
        } catch (_) {
          projectRow = await Supabase.instance.client
              .from('projects')
              .select('user_id')
              .eq('id', projectId)
              .maybeSingle();
        }
        ownerId = (projectRow?['user_id'] ?? '').toString().trim();
        ownerEmail = (projectRow?['owner_email'] ?? '').toString().trim();
        if (ownerEmail.isEmpty &&
            ownerId.isNotEmpty &&
            ownerId == currentUserId &&
            currentUserEmail.isNotEmpty) {
          ownerEmail = currentUserEmail;
          try {
            await Supabase.instance.client
                .from('projects')
                .update({'owner_email': ownerEmail})
                .eq('id', projectId)
                .eq('user_id', currentUserId);
          } catch (_) {
            // Ignore owner_email backfill failure.
          }
        }
        roleEmails[_AccessControlRole.admin] = ownerEmail.isNotEmpty
            ? ownerEmail
            : (ownerId == currentUserId ? _loggedInUserEmail : '');
        if (roleEmails[_AccessControlRole.admin]!.isNotEmpty) {
          roleSeenEmails[_AccessControlRole.admin]!
              .add(roleEmails[_AccessControlRole.admin]!.toLowerCase());
          await prefs.setString(
            ownerEmailCacheKey,
            roleEmails[_AccessControlRole.admin]!,
          );
          await prefs.setString(
            'nav_project_owner_email',
            roleEmails[_AccessControlRole.admin]!,
          );
        }
      } catch (_) {
        roleEmails[_AccessControlRole.admin] = '';
      }

      if (roleEmails[_AccessControlRole.admin]!.isEmpty) {
        final cachedOwnerEmail =
            prefs.getString(ownerEmailCacheKey)?.trim() ?? '';
        final globalOwnerEmail =
            prefs.getString('nav_project_owner_email')?.trim() ?? '';
        final widgetOwnerEmail = (widget.projectOwnerEmail ?? '').trim();
        if (widgetOwnerEmail.isNotEmpty) {
          roleEmails[_AccessControlRole.admin] = widgetOwnerEmail;
        } else if (cachedOwnerEmail.isNotEmpty) {
          roleEmails[_AccessControlRole.admin] = cachedOwnerEmail;
        } else if (globalOwnerEmail.isNotEmpty) {
          roleEmails[_AccessControlRole.admin] = globalOwnerEmail;
        }
      }

      if ((roleEmails[_AccessControlRole.admin] ?? '').trim().isNotEmpty) {
        roleStatuses[_AccessControlRole.admin] = _AccessInviteStatus.accepted;
      }

      if (roleEmails[_AccessControlRole.admin]!.isEmpty) {
        try {
          final adminInvite = await Supabase.instance.client
              .from('project_access_invites')
              .select('invited_email')
              .eq('project_id', projectId)
              .eq('role', 'admin')
              .order('requested_at', ascending: false)
              .limit(1)
              .maybeSingle();
          final adminInviteEmail =
              (adminInvite?['invited_email'] ?? '').toString().trim();
          if (adminInviteEmail.isNotEmpty) {
            roleEmails[_AccessControlRole.admin] = adminInviteEmail;
            roleStatuses[_AccessControlRole.admin] =
                _AccessInviteStatus.accepted;
            await prefs.setString(ownerEmailCacheKey, adminInviteEmail);
            await prefs.setString('nav_project_owner_email', adminInviteEmail);
          }
        } catch (_) {
          // Ignore fallback lookup failure.
        }
      }

      if (roleEmails[_AccessControlRole.admin]!.isEmpty) {
        final viewerRole = _normalizedAccessViewerRole();
        final fallbackCurrentUserEmail = _loggedInUserEmail.trim();
        final canTrustCurrentUserAsAdmin = viewerRole.isEmpty ||
            viewerRole == 'admin' ||
            viewerRole == 'owner';
        if (canTrustCurrentUserAsAdmin && fallbackCurrentUserEmail.isNotEmpty) {
          roleEmails[_AccessControlRole.admin] = fallbackCurrentUserEmail;
          roleStatuses[_AccessControlRole.admin] = _AccessInviteStatus.accepted;
          await prefs.setString(ownerEmailCacheKey, fallbackCurrentUserEmail);
          await prefs.setString(
            'nav_project_owner_email',
            fallbackCurrentUserEmail,
          );
        }
      }

      try {
        final members = await Supabase.instance.client
            .from('project_members')
            .select('invited_email, status, role, user_id')
            .eq('project_id', projectId);
        for (final row in members) {
          var email = (row['invited_email'] ?? '').toString().trim();
          final userId = (row['user_id'] ?? '').toString().trim();
          if (email.isEmpty &&
              ownerId.isNotEmpty &&
              ownerEmail.isNotEmpty &&
              userId == ownerId) {
            email = ownerEmail;
          }
          if (email.isEmpty) continue;
          final normalizedEmail = email.toLowerCase();
          final role = _roleFromDbValue((row['role'] ?? '').toString());
          if (role == null) continue;
          final status = _inviteStatusFromDb((row['status'] ?? '').toString());
          memberStatusByRoleEmail[role]![normalizedEmail] = status;
          if (status == _AccessInviteStatus.accepted) {
            activeMemberEmails.add(normalizedEmail);
          }
        }
      } catch (_) {
        // Best-effort lookup used only to filter stale invite rows.
      }

      try {
        final invites = await Supabase.instance.client
            .from('project_access_invites')
            .select(
                'invited_email, role, status, requested_at, accepted_user_id')
            .eq('project_id', projectId)
            .order('requested_at', ascending: false);
        final primaryAdminEmail =
            (roleEmails[_AccessControlRole.admin] ?? '').trim().toLowerCase();
        for (final row in invites) {
          final role = _roleFromDbValue((row['role'] ?? '').toString());
          if (role == null) continue;
          final email = (row['invited_email'] ?? '').toString().trim();
          final normalizedEmail = email.toLowerCase();
          var status = _inviteStatusFromDb((row['status'] ?? '').toString());
          final acceptedUserId =
              (row['accepted_user_id'] ?? '').toString().trim();
          final memberStatus = memberStatusByRoleEmail[role]?[normalizedEmail];
          if (memberStatus != null) {
            status = memberStatus;
          }
          if (status != _AccessInviteStatus.paused &&
              (acceptedUserId.isNotEmpty ||
                  (normalizedEmail.isNotEmpty &&
                      activeMemberEmails.contains(normalizedEmail)) ||
                  (role == _AccessControlRole.admin &&
                      primaryAdminEmail.isNotEmpty &&
                      normalizedEmail == primaryAdminEmail))) {
            // Reconcile stale invite rows where status did not flip to accepted,
            // but membership/accepted_user_id already confirms access.
            status = _AccessInviteStatus.accepted;
          }
          if (!_shouldIncludeInviteForViewer(role, status)) continue;
          if (email.isNotEmpty &&
              roleSeenEmails[role]!.contains(normalizedEmail)) {
            continue;
          }
          if (email.isNotEmpty) {
            roleSeenEmails[role]!.add(normalizedEmail);
          }
          if (roleEmails[role]!.isEmpty && email.isNotEmpty) {
            roleEmails[role] = email;
            roleStatuses[role] = status;
            continue;
          }
          if (email.isNotEmpty) {
            roleAdditionalRows[role]!.add(
              _AccessInviteEntry(
                email: email,
                status: status,
              ),
            );
          }
        }
      } catch (_) {
        // Invite table may not be readable for non-owner roles.
      }

      if (ownerEmail.isNotEmpty) {
        final normalizedOwnerEmail = ownerEmail.toLowerCase();
        roleEmails[_AccessControlRole.admin] = ownerEmail;
        roleStatuses[_AccessControlRole.admin] = _AccessInviteStatus.accepted;
        final adminRows = roleAdditionalRows[_AccessControlRole.admin];
        if (adminRows != null) {
          for (final row in adminRows) {
            if (row.email.trim().toLowerCase() == normalizedOwnerEmail) {
              row.status = _AccessInviteStatus.accepted;
            }
          }
        }
      }

      _promoteCurrentUserAccessRowsToTop(
        currentUserEmail: currentUserEmail,
        roleEmails: roleEmails,
        roleStatuses: roleStatuses,
        roleAdditionalRows: roleAdditionalRows,
      );

      if (!mounted) return;
      setState(() {
        _accessControlRoleEmails
          ..clear()
          ..addAll(roleEmails);
        _accessControlInviteStatuses
          ..clear()
          ..addAll(roleStatuses);
        _disposeAdditionalAccessRows();
        roleAdditionalRows.forEach((role, entries) {
          _additionalAccessRows[role]!.addAll(entries);
        });
        _accessControlEmailController.text =
            _accessControlRoleEmails[_selectedAccessControlRole] ?? '';
        _accessControlEmailController.selection = TextSelection.collapsed(
          offset: _accessControlEmailController.text.length,
        );
        _isAccessControlLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isAccessControlLoading = false;
      });
    }
  }

  void _selectAccessControlRole(_AccessControlRole role) {
    if (_selectedAccessControlRole == role) return;
    setState(() {
      _accessControlRoleEmails[_selectedAccessControlRole] =
          _accessControlEmailController.text.trim();
      _selectedAccessControlRole = role;
      _accessControlEmailController.text =
          _accessControlRoleEmails[_selectedAccessControlRole] ?? '';
      _accessControlEmailController.selection = TextSelection.collapsed(
        offset: _accessControlEmailController.text.length,
      );
    });
  }

  bool _isValidEmail(String value) {
    final email = value.trim();
    if (email.isEmpty) return false;
    final regex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return regex.hasMatch(email);
  }

  bool _isAdminRole(_AccessControlRole role) =>
      role == _AccessControlRole.admin;

  _AccessInviteStatus _inviteStatusForRole(_AccessControlRole role) =>
      _accessControlInviteStatuses[role] ?? _AccessInviteStatus.none;

  String _inviteRoleParam(_AccessControlRole role) {
    switch (role) {
      case _AccessControlRole.partner:
        return 'partner';
      case _AccessControlRole.projectManager:
        return 'project_manager';
      case _AccessControlRole.agent:
        return 'agent';
      case _AccessControlRole.admin:
        return 'admin';
    }
  }

  String _composeGoogleAuthInviteValue({
    required String projectId,
    required String projectRole,
    String? projectName,
    String? ownerEmail,
  }) {
    final normalizedProjectId = projectId.trim();
    final normalizedProjectRole = projectRole.trim().isEmpty
        ? 'partner'
        : projectRole.trim().toLowerCase();
    final payload = <String, String>{
      'projectId': normalizedProjectId,
      'projectRole': normalizedProjectRole,
    };
    final normalizedProjectName = (projectName ?? '').trim();
    if (normalizedProjectName.isNotEmpty) {
      payload['projectName'] = normalizedProjectName;
    }
    final normalizedOwnerEmail = (ownerEmail ?? '').trim().toLowerCase();
    if (normalizedOwnerEmail.isNotEmpty) {
      payload['ownerEmail'] = normalizedOwnerEmail;
    }
    final encodedPayload = base64Url.encode(utf8.encode(jsonEncode(payload)));
    return 'google:$encodedPayload';
  }

  String _composeInviteToken({
    required String projectId,
    required String projectRole,
    String? projectName,
    String? ownerEmail,
  }) {
    final payload = <String, String>{
      'projectId': projectId.trim(),
      'projectRole': projectRole.trim().isEmpty
          ? 'partner'
          : projectRole.trim().toLowerCase(),
    };
    final normalizedProjectName = (projectName ?? '').trim();
    if (normalizedProjectName.isNotEmpty) {
      payload['projectName'] = normalizedProjectName;
    }
    final normalizedOwnerEmail = (ownerEmail ?? '').trim().toLowerCase();
    if (normalizedOwnerEmail.isNotEmpty) {
      payload['ownerEmail'] = normalizedOwnerEmail;
    }
    return base64Url.encode(utf8.encode(jsonEncode(payload)));
  }

  String _resolveAppBasePath(Uri uri) {
    var path = uri.path.isEmpty ? '/' : uri.path;
    final lowerPath = path.toLowerCase();
    final encodedIndex = lowerPath.indexOf(_landingPathEncoded.toLowerCase());
    final decodedIndex = lowerPath.indexOf(_landingPathDecoded.toLowerCase());
    final segmentIndex = encodedIndex >= 0
        ? encodedIndex
        : decodedIndex >= 0
            ? decodedIndex
            : -1;

    if (segmentIndex >= 0) {
      path = path.substring(0, segmentIndex + 1);
    } else if (path.endsWith('/index.html')) {
      path = path.substring(0, path.length - '/index.html'.length);
    } else if (!path.endsWith('/')) {
      final lastSlash = path.lastIndexOf('/');
      path = lastSlash >= 0 ? path.substring(0, lastSlash + 1) : '/';
    }

    if (!path.startsWith('/')) path = '/$path';
    if (!path.endsWith('/')) path = '$path/';
    return path;
  }

  Uri _resolvePublicInviteBaseUri(Uri baseUri) {
    if ((baseUri.scheme == 'https' || baseUri.scheme == 'http') &&
        baseUri.host.trim().isNotEmpty) {
      return Uri(
        scheme: baseUri.scheme,
        host: baseUri.host,
        port: baseUri.hasPort ? baseUri.port : null,
        path: _resolveAppBasePath(baseUri),
      );
    }

    final configured = Uri.tryParse(_defaultInviteBaseUrl.trim());
    if (configured != null &&
        (configured.scheme == 'https' || configured.scheme == 'http') &&
        configured.host.trim().isNotEmpty) {
      var configuredPath = configured.path.isEmpty ? '/' : configured.path;
      if (!configuredPath.endsWith('/')) configuredPath = '$configuredPath/';
      return Uri(
        scheme: configured.scheme,
        host: configured.host,
        port: configured.hasPort ? configured.port : null,
        path: configuredPath,
      );
    }

    return Uri(
      scheme: 'https',
      host: 'www.8answers.com',
      path: '/',
    );
  }

  String _joinUrlPath(String basePath, String childPath) {
    final normalizedBase = basePath.isEmpty ? '/' : basePath;
    final normalizedPrefix =
        normalizedBase.endsWith('/') ? normalizedBase : '$normalizedBase/';
    final normalizedChild =
        childPath.startsWith('/') ? childPath.substring(1) : childPath;
    return '$normalizedPrefix$normalizedChild';
  }

  String _resolveAppDownloadUrl() {
    final configured = Uri.tryParse(_defaultDownloadUrl.trim());
    if (configured != null &&
        (configured.scheme == 'https' || configured.scheme == 'http') &&
        configured.host.trim().isNotEmpty) {
      return configured.toString();
    }
    return 'https://www.8answers.com/';
  }

  Future<bool> _sendAccessInviteEmailForRole(
    String targetEmail,
    _AccessControlRole role,
  ) async {
    final projectId = widget.projectId?.trim() ?? '';
    if (projectId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please select a project before sending request.'),
          ),
        );
      }
      return false;
    }

    final baseUri = Uri.base;
    final inviteBaseUri = _resolvePublicInviteBaseUri(baseUri);
    final inviteRole = _inviteRoleParam(role);
    final inviteProjectName = (widget.projectName ?? '').trim();
    final ownerEmail = (_accessControlRoleEmails[_AccessControlRole.admin] ??
            _loggedInUserEmail)
        .trim()
        .toLowerCase();
    final authValue = _composeGoogleAuthInviteValue(
      projectId: projectId,
      projectRole: inviteRole,
      projectName: inviteProjectName,
      ownerEmail: ownerEmail,
    );
    final inviteToken = _composeInviteToken(
      projectId: projectId,
      projectRole: inviteRole,
      projectName: inviteProjectName,
      ownerEmail: ownerEmail,
    );
    final directAuthUri = inviteBaseUri.replace(
      path: _joinUrlPath(inviteBaseUri.path, 'invite/$inviteToken'),
      queryParameters: <String, String>{
        'auth': authValue,
        'invite': '1',
        'projectId': projectId,
        'projectRole': inviteRole,
        'inv': inviteToken,
        if (inviteProjectName.isNotEmpty) 'projectName': inviteProjectName,
        if (ownerEmail.isNotEmpty) 'ownerEmail': ownerEmail,
      },
    );
    final subject = "You've been invited to access a project on 8Answers";
    var backendFailureReason = '';
    final currentSession = Supabase.instance.client.auth.currentSession;
    final accessToken = currentSession?.accessToken ?? '';
    final googleRefreshToken = currentSession?.providerRefreshToken ?? '';
    if (accessToken.trim().isEmpty) {
      backendFailureReason =
          'Your session has expired. Please sign in again and retry.';
    }
    // One-click path: if a backend mail sender function exists, use it.
    if (backendFailureReason.isEmpty) {
      try {
        final response = await Supabase.instance.client.functions.invoke(
          'send-project-invite-email',
          headers: <String, String>{'Authorization': 'Bearer $accessToken'},
          body: <String, dynamic>{
            'to': targetEmail,
            'subject': subject,
            'projectId': projectId,
            'projectRole': inviteRole,
            'projectName': inviteProjectName,
            'ownerEmail': ownerEmail,
            'inviteToken': inviteToken,
            'directAuthUrl': directAuthUri.toString(),
            'appDownloadUrl': _resolveAppDownloadUrl(),
            'gmailRefreshToken': googleRefreshToken,
          },
        );
        final data = response.data;
        if (response.status == 200 &&
            (data is Map
                ? ((data['success'] == true) || (data['sent'] == true))
                : false)) {
          return true;
        }
        if (response.status == 401) {
          backendFailureReason =
              'Unauthorized (401): Please sign in again. If this continues, ensure your session is valid and the Authorization header is being sent.';
        } else if (data is Map &&
            (data['error'] ?? '').toString().trim().isNotEmpty) {
          final rawBackendError = (data['error'] ?? '').toString().trim();
          if (rawBackendError.contains('No Gmail sender token found')) {
            backendFailureReason =
                'Gmail sender token is not available for this account. Use the same Google account that has invite-send permission (OAuth test user, if app is in testing), then sign out and sign in again.';
          } else {
            backendFailureReason = rawBackendError;
          }
        } else {
          backendFailureReason = 'Function returned status ${response.status}.';
        }
      } catch (error) {
        final rawError = error.toString();
        if (rawError.contains('401')) {
          backendFailureReason =
              'Unauthorized (401): Please sign in again. If this continues, ensure your session is valid and the Authorization header is being sent.';
        } else {
          backendFailureReason =
              'Failed to reach send-project-invite-email: $rawError';
        }
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            backendFailureReason.isEmpty
                ? 'Automatic email send failed. Please verify send-project-invite-email function setup.'
                : backendFailureReason,
          ),
        ),
      );
    }
    return false;
  }

  Future<bool> _sendAccessInviteEmail(String targetEmail) {
    return _sendAccessInviteEmailForRole(
      targetEmail,
      _selectedAccessControlRole,
    );
  }

  Future<void> _enableContinuousSyncAfterAccessShare(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) return;
    await ProjectStorageService.setCloudSyncEnabledForProject(
      normalizedProjectId,
      true,
    );
    await OfflineProjectSyncService.flushPendingCreates(
      supabase: Supabase.instance.client,
      projectId: normalizedProjectId,
      ignoreCloudSyncGate: true,
    );
    await ProjectStorageService.flushPendingSaves(
      projectId: normalizedProjectId,
    );
    await OfflineFileUploadQueueService.flushPendingUploads(
      projectId: normalizedProjectId,
    );
  }

  Future<void> _onSendRequestTap() async {
    final role = _selectedAccessControlRole;
    if (_isRoleReadOnly(role)) return;
    if (_sendRequestLoadingByRole[role] ?? false) return;
    if (!_isValidEmail(_accessControlEmailController.text)) return;
    if (_inviteStatusForRole(role) != _AccessInviteStatus.none) {
      return;
    }
    final targetEmail = _accessControlEmailController.text.trim();
    final projectId = widget.projectId?.trim() ?? '';
    if (projectId.isEmpty) return;

    setState(() {
      _sendRequestLoadingByRole[role] = true;
    });

    try {
      final inviteStored = await ProjectAccessService.createOrUpdateInvite(
        projectId: projectId,
        email: targetEmail,
        role: _inviteRoleParam(role),
      );
      if (!inviteStored) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Access invite was not saved in database. Please check project access policies/permissions.',
            ),
          ),
        );
        return;
      }

      await _enableContinuousSyncAfterAccessShare(projectId);

      await _sendAccessInviteEmail(targetEmail);
      if (!mounted) return;

      setState(() {
        _accessControlInviteStatuses[role] = _AccessInviteStatus.requested;
      });
    } finally {
      if (mounted) {
        setState(() {
          _sendRequestLoadingByRole[role] = false;
        });
      }
    }
  }

  bool _showEmailEndTick(_AccessControlRole role) {
    return _inviteStatusForRole(role) == _AccessInviteStatus.accepted;
  }

  String _sendRequestLabelForStatus(_AccessInviteStatus status) {
    if (status == _AccessInviteStatus.requested ||
        status == _AccessInviteStatus.accepted) {
      return 'Requested';
    }
    return 'Send Request';
  }

  String _sendRequestLabel(_AccessControlRole role) {
    return _sendRequestLabelForStatus(_inviteStatusForRole(role));
  }

  Color _sendRequestColorForStatus(
      _AccessInviteStatus status, String emailValue) {
    if (status == _AccessInviteStatus.requested) {
      return Colors.black.withOpacity(0.5);
    }
    if (status == _AccessInviteStatus.accepted ||
        status == _AccessInviteStatus.paused ||
        _isValidEmail(emailValue)) {
      return const Color(0xFF0C8CE9);
    }
    return Colors.black.withOpacity(0.5);
  }

  Color _sendRequestColor(_AccessControlRole role) {
    return _sendRequestColorForStatus(
      _inviteStatusForRole(role),
      _accessControlEmailController.text,
    );
  }

  bool _shouldShowPauseAccessForEntry({
    required _AccessControlRole role,
    required _AccessInviteStatus status,
    required String emailValue,
  }) {
    if (_isRoleReadOnly(role)) return false;
    if (role != _AccessControlRole.admin &&
        role != _AccessControlRole.partner &&
        role != _AccessControlRole.projectManager &&
        role != _AccessControlRole.agent) {
      return false;
    }
    if (status != _AccessInviteStatus.accepted &&
        status != _AccessInviteStatus.paused) {
      return false;
    }
    return emailValue.trim().isNotEmpty;
  }

  bool _isProjectOwnerEmail(String email) {
    final target = email.trim().toLowerCase();
    if (target.isEmpty) return false;
    final ownerEmail = (widget.projectOwnerEmail ?? '').trim().toLowerCase();
    if (ownerEmail.isEmpty) return false;
    return ownerEmail == target;
  }

  bool _shouldShowPauseAccessAction(_AccessControlRole role) {
    return _shouldShowPauseAccessForEntry(
      role: role,
      status: _inviteStatusForRole(role),
      emailValue: _accessControlRoleEmails[role] ?? '',
    );
  }

  double _emailBlockOpacityForStatus(_AccessInviteStatus status) {
    return status == _AccessInviteStatus.paused ? 0.5 : 1.0;
  }

  Color _pauseResumeLoadingColorForStatus(_AccessInviteStatus status) {
    if (status == _AccessInviteStatus.paused) {
      return const Color(0xFF06AB00);
    }
    return const Color(0xFFCBB42C);
  }

  bool _isPauseResumeLoadingForRole(_AccessControlRole role) {
    return _pauseResumeLoadingByRole[role] ?? false;
  }

  bool _isSendRequestLoadingForRole(_AccessControlRole role) {
    return _sendRequestLoadingByRole[role] ?? false;
  }

  int _accessControlRoleLimit(_AccessControlRole role) {
    switch (role) {
      case _AccessControlRole.admin:
        return 5;
      case _AccessControlRole.partner:
        return 20;
      case _AccessControlRole.projectManager:
        return 5;
      case _AccessControlRole.agent:
        return 20;
    }
  }

  int _roleSlotCount(_AccessControlRole role) {
    final rows = _additionalAccessRows[role] ?? const <_AccessInviteEntry>[];
    // 1 primary row + additional rows
    return 1 + rows.length;
  }

  bool _canAddMoreAccessRows(_AccessControlRole role) {
    return _roleSlotCount(role) < _accessControlRoleLimit(role);
  }

  int _rolePeopleCount(_AccessControlRole role) {
    var count = 0;
    if ((_accessControlRoleEmails[role] ?? '').trim().isNotEmpty) {
      count++;
    }
    final rows = _additionalAccessRows[role] ?? const <_AccessInviteEntry>[];
    for (final row in rows) {
      if (row.email.trim().isNotEmpty) {
        count++;
      }
    }
    return count;
  }

  bool _isRemoveCountConstraintSatisfiedForRole(_AccessControlRole role) {
    if (!_canEditAccessRole(role)) return false;
    // Only Admin requires at least 2 members before allowing removal.
    if (role == _AccessControlRole.admin) {
      return _rolePeopleCount(role) > 1;
    }
    return true;
  }

  bool _isRemoveActionEnabledForEmail(
    _AccessControlRole role,
    String email, {
    bool allowEmpty = false,
  }) {
    if (!_canEditAccessRole(role)) return false;
    final normalizedEmail = email.trim();
    if (normalizedEmail.isEmpty) return allowEmpty;
    if (!_isRemoveCountConstraintSatisfiedForRole(role)) return false;
    return _isValidEmail(normalizedEmail);
  }

  bool _isRemoveActionEnabledForRole(_AccessControlRole role) {
    return _isRemoveActionEnabledForEmail(
      role,
      _accessControlRoleEmails[role] ?? '',
    );
  }

  String _accessControlRoleSingularLabel(_AccessControlRole role) {
    switch (role) {
      case _AccessControlRole.admin:
        return 'Admin';
      case _AccessControlRole.partner:
        return 'Partner';
      case _AccessControlRole.projectManager:
        return 'Project Manager';
      case _AccessControlRole.agent:
        return 'Agent';
    }
  }

  Future<void> _showRemoveAccessDialog({
    required _AccessControlRole role,
    required String email,
    bool isSelfAdminRemoval = false,
    required Future<void> Function() onConfirmRemove,
  }) async {
    if (!mounted) return;

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Remove access',
      barrierColor: Colors.black.withOpacity(0.5),
      pageBuilder: (context, animation, secondaryAnimation) {
        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 24),
              child: _RemoveAccessDialogContent(
                roleLabel: _accessControlRoleSingularLabel(role),
                email: email,
                isSelfAdminRemoval: isSelfAdminRemoval,
                onConfirmRemove: onConfirmRemove,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _onPauseResumeAccessTap(_AccessControlRole role) async {
    if (_isRoleReadOnly(role)) return;
    if (_isPauseResumeLoadingForRole(role)) return;
    final email = (_accessControlRoleEmails[role] ?? '').trim();
    final projectId = widget.projectId?.trim() ?? '';
    if (projectId.isEmpty || email.isEmpty) return;
    if (role == _AccessControlRole.admin && _isProjectOwnerEmail(email)) {
      return;
    }
    final isPaused = _inviteStatusForRole(role) == _AccessInviteStatus.paused;
    setState(() {
      _pauseResumeLoadingByRole[role] = true;
    });
    final ok = await ProjectAccessService.setInvitePaused(
      projectId: projectId,
      email: email,
      role: _inviteRoleParam(role),
      paused: !isPaused,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to update access. Please try again.'),
        ),
      );
      setState(() {
        _pauseResumeLoadingByRole[role] = false;
      });
      return;
    }
    setState(() {
      _accessControlInviteStatuses[role] =
          isPaused ? _AccessInviteStatus.accepted : _AccessInviteStatus.paused;
      _pauseResumeLoadingByRole[role] = false;
    });
  }

  Future<void> _onSendRequestTapForAdditionalRow(
    _AccessControlRole role,
    _AccessInviteEntry entry,
  ) async {
    if (_isRoleReadOnly(role)) return;
    if (entry.isSendRequestLoading) return;
    final email = entry.email;
    if (!_isValidEmail(email)) return;
    if (entry.status != _AccessInviteStatus.none) return;
    final projectId = widget.projectId?.trim() ?? '';
    if (projectId.isEmpty) return;

    setState(() {
      entry.isSendRequestLoading = true;
    });

    try {
      final inviteStored = await ProjectAccessService.createOrUpdateInvite(
        projectId: projectId,
        email: email,
        role: _inviteRoleParam(role),
      );
      if (!inviteStored) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Access invite was not saved in database. Please check project access policies/permissions.',
            ),
          ),
        );
        return;
      }

      await _enableContinuousSyncAfterAccessShare(projectId);

      await _sendAccessInviteEmailForRole(email, role);
      if (!mounted) return;

      setState(() {
        entry.status = _AccessInviteStatus.requested;
      });
    } finally {
      if (mounted) {
        setState(() {
          entry.isSendRequestLoading = false;
        });
      }
    }
  }

  void _addAdditionalAccessRow(_AccessControlRole role) {
    if (_isRoleReadOnly(role)) return;
    if (!_canAddMoreAccessRows(role)) {
      if (mounted) {
        final roleLabel = _accessControlRoleLabel(role);
        final limit = _accessControlRoleLimit(role);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$roleLabel limit reached ($limit).',
            ),
          ),
        );
      }
      return;
    }
    setState(() {
      _additionalAccessRows[role]!.add(_AccessInviteEntry());
    });
  }

  Future<void> _removePrimaryAccessRow(_AccessControlRole role) async {
    if (!_isRemoveActionEnabledForRole(role)) return;

    final rows = _additionalAccessRows[role] ?? <_AccessInviteEntry>[];
    final primaryEmail = (_accessControlRoleEmails[role] ?? '').trim();
    final removeEmail = primaryEmail;
    if (removeEmail.isEmpty) return;
    final hasReplacement = rows.any((row) => row.email.trim().isNotEmpty);
    if (role == _AccessControlRole.admin && !hasReplacement) return;
    final isSelfAdminRemoval =
        role == _AccessControlRole.admin && _isCurrentUserEmail(removeEmail);

    await _showRemoveAccessDialog(
      role: role,
      email: removeEmail,
      isSelfAdminRemoval: isSelfAdminRemoval,
      onConfirmRemove: () async {
        final projectId = widget.projectId?.trim() ?? '';
        if (projectId.isEmpty) return;
        final ok = await ProjectAccessService.removeInviteAccess(
          projectId: projectId,
          email: removeEmail,
          role: _inviteRoleParam(role),
        );
        if (!mounted) return;
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to remove access. Please try again.'),
            ),
          );
          return;
        }

        setState(() {
          final replacementIndex =
              rows.indexWhere((row) => row.email.trim().isNotEmpty);
          if (replacementIndex >= 0 && replacementIndex < rows.length) {
            final replacement = rows.removeAt(replacementIndex);
            _accessControlRoleEmails[role] = replacement.email;
            _accessControlInviteStatuses[role] = replacement.status;
            replacement.dispose();
          } else if (role != _AccessControlRole.admin) {
            _accessControlRoleEmails[role] = '';
            _accessControlInviteStatuses[role] = _AccessInviteStatus.none;
          }
          if (_selectedAccessControlRole == role) {
            _accessControlEmailController.text =
                _accessControlRoleEmails[role] ?? '';
            _accessControlEmailController.selection = TextSelection.collapsed(
              offset: _accessControlEmailController.text.length,
            );
          }
        });
      },
    );
  }

  void _removeAdditionalAccessRow(_AccessControlRole role, int index) {
    if (_isRoleReadOnly(role)) return;
    final rows = _additionalAccessRows[role]!;
    if (index < 0 || index >= rows.length) return;
    final removedEntry = rows[index];
    setState(() {
      removedEntry.dispose();
      rows.removeAt(index);
    });
  }

  Future<void> _removeAdditionalAccessRowWithDialog(
    _AccessControlRole role,
    int index,
  ) async {
    if (_isRoleReadOnly(role)) return;
    final rows = _additionalAccessRows[role] ?? <_AccessInviteEntry>[];
    if (index < 0 || index >= rows.length) return;
    final target = rows[index];
    final email = target.email.trim();

    if (email.isEmpty) {
      _removeAdditionalAccessRow(role, index);
      return;
    }
    if (!_isRemoveActionEnabledForEmail(role, email)) return;
    final isSelfAdminRemoval =
        role == _AccessControlRole.admin && _isCurrentUserEmail(email);

    await _showRemoveAccessDialog(
      role: role,
      email: email,
      isSelfAdminRemoval: isSelfAdminRemoval,
      onConfirmRemove: () async {
        final projectId = widget.projectId?.trim() ?? '';
        if (projectId.isEmpty) return;
        final ok = await ProjectAccessService.removeInviteAccess(
          projectId: projectId,
          email: email,
          role: _inviteRoleParam(role),
        );
        if (!mounted) return;
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to remove access. Please try again.'),
            ),
          );
          return;
        }
        _removeAdditionalAccessRow(role, index);
      },
    );
  }

  Future<void> _onPauseResumeAdditionalRowTap(
    _AccessControlRole role,
    _AccessInviteEntry entry,
  ) async {
    if (_isRoleReadOnly(role)) return;
    if (entry.isPauseResumeLoading) return;
    final email = entry.email;
    final projectId = widget.projectId?.trim() ?? '';
    if (projectId.isEmpty || email.isEmpty) return;
    if (role == _AccessControlRole.admin && _isProjectOwnerEmail(email)) {
      return;
    }
    final isPaused = entry.status == _AccessInviteStatus.paused;
    setState(() {
      entry.isPauseResumeLoading = true;
    });
    final ok = await ProjectAccessService.setInvitePaused(
      projectId: projectId,
      email: email,
      role: _inviteRoleParam(role),
      paused: !isPaused,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to update access. Please try again.'),
        ),
      );
      setState(() {
        entry.isPauseResumeLoading = false;
      });
      return;
    }
    setState(() {
      entry.status =
          isPaused ? _AccessInviteStatus.accepted : _AccessInviteStatus.paused;
      entry.isPauseResumeLoading = false;
    });
  }

  Widget _buildAdditionalAccessRow(
    _AccessControlRole role,
    _AccessInviteEntry entry,
    int index,
  ) {
    return Padding(
      padding: EdgeInsets.only(
        top: index == 0 ? 12 : 8,
      ),
      child: Row(
        children: [
          Opacity(
            opacity: _emailBlockOpacityForStatus(entry.status),
            child: Container(
              width: 400,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xF2FFFFFF),
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
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: TextField(
                      controller: entry.emailController,
                      readOnly: _isRoleReadOnly(role) ||
                          !_isAccessControlSyncReadyForEdits,
                      onTap: () {
                        if (_isRoleReadOnly(role) ||
                            _isAccessControlSyncReadyForEdits) {
                          return;
                        }
                        unawaited(_onBlockedAccessControlEditTap());
                      },
                      onChanged: (value) {
                        if (_isRoleReadOnly(role)) return;
                        setState(() {
                          entry.status = _AccessInviteStatus.none;
                        });
                      },
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintText: 'Enter email ID',
                        hintStyle: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: Colors.black.withOpacity(0.45),
                        ),
                      ),
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (entry.status == _AccessInviteStatus.accepted)
                    SvgPicture.asset(
                      'assets/images/Admin.svg',
                      width: 16,
                      height: 12,
                      colorFilter: const ColorFilter.mode(
                        Color(0xFF0C8CE9),
                        BlendMode.srcIn,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_isRoleReadOnly(role)) ...[
            const SizedBox(width: 12),
            if (entry.email.isNotEmpty)
              _isCurrentUserEmail(entry.email)
                  ? Container(
                      width: role == _AccessControlRole.admin ? 147 : 53,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xF2FFFFFF),
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
                          '(You)',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Colors.black.withOpacity(0.5),
                          ),
                        ),
                      ),
                    )
                  : Container(
                      width: 53,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xF2FFFFFF),
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
                        child: SvgPicture.asset(
                          'assets/images/Partner_email.svg',
                          width: 53,
                          height: 40,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
          ] else ...[
            const SizedBox(width: 24),
            role == _AccessControlRole.admin && _isCurrentUserEmail(entry.email)
                ? Container(
                    width: 147,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xF2FFFFFF),
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
                        '(You)',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.black.withOpacity(0.5),
                        ),
                      ),
                    ),
                  )
                : _shouldShowPauseAccessForEntry(
                    role: role,
                    status: entry.status,
                    emailValue: entry.emailController.text,
                  )
                    ? MouseRegion(
                        cursor: entry.isPauseResumeLoading
                            ? SystemMouseCursors.basic
                            : SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: entry.isPauseResumeLoading
                              ? null
                              : () {
                                  _onPauseResumeAdditionalRowTap(role, entry);
                                },
                          child: Container(
                            width: 147,
                            height: 40,
                            decoration: BoxDecoration(
                              color: const Color(0xF2FFFFFF),
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
                              child: entry.isPauseResumeLoading
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          _pauseResumeLoadingColorForStatus(
                                            entry.status,
                                          ),
                                        ),
                                      ),
                                    )
                                  : SvgPicture.asset(
                                      entry.status == _AccessInviteStatus.paused
                                          ? 'assets/images/Resume_access.svg'
                                          : 'assets/images/Pause_access.svg',
                                      width: 147,
                                      height: 40,
                                      fit: BoxFit.contain,
                                    ),
                            ),
                          ),
                        ),
                      )
                    : Container(
                        width: 147,
                        height: 40,
                        decoration: BoxDecoration(
                          color: const Color(0xF2FFFFFF),
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
                          child: MouseRegion(
                            cursor:
                                (_isValidEmail(entry.emailController.text) &&
                                        !entry.isSendRequestLoading)
                                    ? SystemMouseCursors.click
                                    : SystemMouseCursors.basic,
                            child: GestureDetector(
                              onTap: entry.isSendRequestLoading
                                  ? null
                                  : () {
                                      _onSendRequestTapForAdditionalRow(
                                        role,
                                        entry,
                                      );
                                    },
                              child: Builder(
                                builder: (context) {
                                  final actionColor =
                                      _sendRequestColorForStatus(
                                    entry.status,
                                    entry.emailController.text,
                                  );
                                  if (entry.isSendRequestLoading) {
                                    return SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                          actionColor,
                                        ),
                                      ),
                                    );
                                  }
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _sendRequestLabelForStatus(
                                            entry.status),
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: actionColor,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Transform.rotate(
                                        angle: entry.status ==
                                                _AccessInviteStatus.requested
                                            ? -math.pi / 4
                                            : 0,
                                        child: SvgPicture.asset(
                                          'assets/images/Send_request.svg',
                                          width: 14,
                                          height: 14,
                                          colorFilter: ColorFilter.mode(
                                            actionColor,
                                            BlendMode.srcIn,
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
            if (_canEditAccessRole(role)) ...[
              const SizedBox(width: 20),
              Builder(
                builder: (context) {
                  final removeEnabled = _isRemoveActionEnabledForEmail(
                    role,
                    entry.email,
                    allowEmpty: true,
                  );
                  return MouseRegion(
                    cursor: removeEnabled
                        ? SystemMouseCursors.click
                        : SystemMouseCursors.basic,
                    child: GestureDetector(
                      onTap: removeEnabled
                          ? () => _removeAdditionalAccessRowWithDialog(
                                role,
                                index,
                              )
                          : null,
                      child: Container(
                        height: 40,
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
                            ),
                          ],
                        ),
                        child: Center(
                          child: Text(
                            'Remove',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.normal,
                              color: removeEnabled
                                  ? Colors.red
                                  : Colors.red.withOpacity(0.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildAccessRoleChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 160,
          height: 40,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFC2E2F9) : const Color(0xF2FFFFFF),
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
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black,
                height: 1.29,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGeneralTabContent() {
    const deleteSummaryText =
        'Permanently remove this project and all associated data. This action cannot be undone.';
    final deleteSummaryStyle = GoogleFonts.inter(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: Colors.black.withOpacity(0.8),
    );
    final textPainter = TextPainter(
      text: TextSpan(text: deleteSummaryText, style: deleteSummaryStyle),
      maxLines: 1,
      textDirection: Directionality.of(context),
    )..layout();
    final maxAllowedWidth = MediaQuery.of(context).size.width - 48;
    final generalCardWidth =
        (textPainter.width + 32 + 18).clamp(617.0, maxAllowedWidth).toDouble();
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: generalCardWidth,
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
                  'The operational status of this project.',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black.withOpacity(0.8),
                  ),
                ),
                const SizedBox(height: 24),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'Project Base Unit Area ',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.black,
                            ),
                          ),
                          TextSpan(
                            text: '*',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.red,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 186,
                      height: 40,
                      padding: const EdgeInsets.only(left: 4, right: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xF2FFFFFF),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.25),
                            blurRadius: 2,
                            offset: const Offset(0, 0),
                          ),
                        ],
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          AreaUnitUtils.sqmUnitLabel,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),
          Container(
            width: generalCardWidth,
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
                  deleteSummaryText,
                  maxLines: 1,
                  softWrap: false,
                  style: deleteSummaryStyle,
                ),
                const SizedBox(height: 24),
                GestureDetector(
                  onTap: _showDeleteDialog,
                  child: Container(
                    height: 44,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
    );
  }

  Widget _buildAccessControlTabContent() {
    if (_isAccessControlLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 744),
          child: Container(
            width: double.infinity,
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
                _skeletonBlock(width: 180, height: 24),
                const SizedBox(height: 8),
                _skeletonBlock(width: 360, height: 16),
                const SizedBox(height: 24),
                Row(
                  children: [
                    _skeletonBlock(width: 90, height: 32),
                    const SizedBox(width: 24),
                    _skeletonBlock(width: 90, height: 32),
                    const SizedBox(width: 24),
                    _skeletonBlock(width: 130, height: 32),
                    const SizedBox(width: 24),
                    _skeletonBlock(width: 80, height: 32),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  width: double.infinity,
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
                      _skeletonBlock(width: 190, height: 24),
                      const SizedBox(height: 8),
                      _skeletonBlock(width: 420, height: 16),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          _skeletonBlock(width: 400, height: 40),
                          const SizedBox(width: 24),
                          _skeletonBlock(width: 147, height: 40),
                          const SizedBox(width: 20),
                          _skeletonBlock(width: 88, height: 40),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _skeletonBlock(width: 120, height: 36),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 744),
        child: Container(
          width: double.infinity,
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
                'Select Role',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Choose the role for which you want to grant access',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  _buildAccessRoleChip(
                    label: _accessControlRoleLabel(_AccessControlRole.admin),
                    selected:
                        _selectedAccessControlRole == _AccessControlRole.admin,
                    onTap: () => _selectAccessControlRole(
                      _AccessControlRole.admin,
                    ),
                  ),
                  const SizedBox(width: 24),
                  _buildAccessRoleChip(
                    label: _accessControlRoleLabel(_AccessControlRole.partner),
                    selected: _selectedAccessControlRole ==
                        _AccessControlRole.partner,
                    onTap: () => _selectAccessControlRole(
                      _AccessControlRole.partner,
                    ),
                  ),
                  const SizedBox(width: 24),
                  _buildAccessRoleChip(
                    label: _accessControlRoleLabel(
                      _AccessControlRole.projectManager,
                    ),
                    selected: _selectedAccessControlRole ==
                        _AccessControlRole.projectManager,
                    onTap: () => _selectAccessControlRole(
                      _AccessControlRole.projectManager,
                    ),
                  ),
                  const SizedBox(width: 24),
                  _buildAccessRoleChip(
                    label: _accessControlRoleLabel(_AccessControlRole.agent),
                    selected:
                        _selectedAccessControlRole == _AccessControlRole.agent,
                    onTap: () => _selectAccessControlRole(
                      _AccessControlRole.agent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                width: double.infinity,
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
                      _accessControlRoleLabel(_selectedAccessControlRole),
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _accessControlRoleDescription(_selectedAccessControlRole),
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black.withOpacity(0.8),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Opacity(
                          opacity: _emailBlockOpacityForStatus(
                            _inviteStatusForRole(_selectedAccessControlRole),
                          ),
                          child: Container(
                            width: 400,
                            height: 40,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xF2FFFFFF),
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
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _accessControlEmailController,
                                    readOnly: _isAdminRole(
                                          _selectedAccessControlRole,
                                        ) ||
                                        _isRoleReadOnly(
                                          _selectedAccessControlRole,
                                        ) ||
                                        !_isAccessControlSyncReadyForEdits,
                                    onTap: () {
                                      final isReadOnlyRole = _isAdminRole(
                                            _selectedAccessControlRole,
                                          ) ||
                                          _isRoleReadOnly(
                                            _selectedAccessControlRole,
                                          );
                                      if (isReadOnlyRole ||
                                          _isAccessControlSyncReadyForEdits) {
                                        return;
                                      }
                                      unawaited(
                                        _onBlockedAccessControlEditTap(),
                                      );
                                    },
                                    onChanged: (value) {
                                      final role = _selectedAccessControlRole;
                                      setState(() {
                                        _accessControlRoleEmails[role] =
                                            value.trim();
                                        if (!_isAdminRole(
                                          role,
                                        )) {
                                          _accessControlInviteStatuses[role] =
                                              _AccessInviteStatus.none;
                                        }
                                      });
                                    },
                                    decoration: InputDecoration(
                                      border: InputBorder.none,
                                      isDense: true,
                                      contentPadding: EdgeInsets.zero,
                                      hintText: _selectedAccessControlRole ==
                                              _AccessControlRole.admin
                                          ? null
                                          : 'Enter email ID',
                                      hintStyle: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w400,
                                        color: Colors.black.withOpacity(0.45),
                                      ),
                                    ),
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.black,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (_showEmailEndTick(
                                    _selectedAccessControlRole))
                                  SvgPicture.asset(
                                    'assets/images/Admin.svg',
                                    width: 16,
                                    height: 12,
                                    colorFilter: const ColorFilter.mode(
                                      Color(0xFF0C8CE9),
                                      BlendMode.srcIn,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (_isRoleReadOnly(_selectedAccessControlRole)) ...[
                          const SizedBox(width: 12),
                          if (_accessControlEmailController.text
                              .trim()
                              .isNotEmpty)
                            _isCurrentUserEmail(
                              _accessControlEmailController.text.trim(),
                            )
                                ? Container(
                                    width: _selectedAccessControlRole ==
                                            _AccessControlRole.admin
                                        ? 147
                                        : 53,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: const Color(0xF2FFFFFF),
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
                                        '(You)',
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.black.withOpacity(0.5),
                                        ),
                                      ),
                                    ),
                                  )
                                : Container(
                                    width: 53,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: const Color(0xF2FFFFFF),
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
                                      child: SvgPicture.asset(
                                        'assets/images/Partner_email.svg',
                                        width: 53,
                                        height: 40,
                                        fit: BoxFit.contain,
                                      ),
                                    ),
                                  ),
                        ] else ...[
                          const SizedBox(width: 24),
                          _selectedAccessControlRole ==
                                      _AccessControlRole.admin &&
                                  _isCurrentUserEmail(
                                    _accessControlEmailController.text.trim(),
                                  )
                              ? Container(
                                  width: 147,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: const Color(0xF2FFFFFF),
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
                                      '(You)',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black.withOpacity(0.5),
                                      ),
                                    ),
                                  ),
                                )
                              : _shouldShowPauseAccessAction(
                                  _selectedAccessControlRole,
                                )
                                  ? MouseRegion(
                                      cursor: _isPauseResumeLoadingForRole(
                                        _selectedAccessControlRole,
                                      )
                                          ? SystemMouseCursors.basic
                                          : SystemMouseCursors.click,
                                      child: GestureDetector(
                                        onTap: _isPauseResumeLoadingForRole(
                                          _selectedAccessControlRole,
                                        )
                                            ? null
                                            : () {
                                                _onPauseResumeAccessTap(
                                                  _selectedAccessControlRole,
                                                );
                                              },
                                        child: Container(
                                          width: 147,
                                          height: 40,
                                          decoration: BoxDecoration(
                                            color: const Color(0xF2FFFFFF),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black
                                                    .withOpacity(0.25),
                                                blurRadius: 2,
                                                offset: const Offset(0, 0),
                                              ),
                                            ],
                                          ),
                                          child: Center(
                                            child: _isPauseResumeLoadingForRole(
                                              _selectedAccessControlRole,
                                            )
                                                ? SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                              Color>(
                                                        _pauseResumeLoadingColorForStatus(
                                                          _inviteStatusForRole(
                                                            _selectedAccessControlRole,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  )
                                                : SvgPicture.asset(
                                                    _inviteStatusForRole(
                                                                _selectedAccessControlRole) ==
                                                            _AccessInviteStatus
                                                                .paused
                                                        ? 'assets/images/Resume_access.svg'
                                                        : 'assets/images/Pause_access.svg',
                                                    width: 147,
                                                    height: 40,
                                                    fit: BoxFit.contain,
                                                  ),
                                          ),
                                        ),
                                      ),
                                    )
                                  : Container(
                                      width: 147,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: const Color(0xF2FFFFFF),
                                        borderRadius: BorderRadius.circular(8),
                                        boxShadow: [
                                          BoxShadow(
                                            color:
                                                Colors.black.withOpacity(0.25),
                                            blurRadius: 2,
                                            offset: const Offset(0, 0),
                                          ),
                                        ],
                                      ),
                                      child: Center(
                                        child: MouseRegion(
                                          cursor: (_isValidEmail(
                                                    _accessControlEmailController
                                                        .text,
                                                  ) &&
                                                  !_isSendRequestLoadingForRole(
                                                    _selectedAccessControlRole,
                                                  ))
                                              ? SystemMouseCursors.click
                                              : SystemMouseCursors.basic,
                                          child: GestureDetector(
                                            onTap: _isSendRequestLoadingForRole(
                                              _selectedAccessControlRole,
                                            )
                                                ? null
                                                : () {
                                                    _onSendRequestTap();
                                                  },
                                            child: Builder(
                                              builder: (context) {
                                                final actionColor =
                                                    _sendRequestColor(
                                                  _selectedAccessControlRole,
                                                );
                                                if (_isSendRequestLoadingForRole(
                                                  _selectedAccessControlRole,
                                                )) {
                                                  return SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child:
                                                        CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                      valueColor:
                                                          AlwaysStoppedAnimation<
                                                              Color>(
                                                        actionColor,
                                                      ),
                                                    ),
                                                  );
                                                }
                                                return Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      _sendRequestLabel(
                                                        _selectedAccessControlRole,
                                                      ),
                                                      style: GoogleFonts.inter(
                                                        fontSize: 14,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                        color: actionColor,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Transform.rotate(
                                                      angle:
                                                          _inviteStatusForRole(
                                                                    _selectedAccessControlRole,
                                                                  ) ==
                                                                  _AccessInviteStatus
                                                                      .requested
                                                              ? -math.pi / 4
                                                              : 0,
                                                      child: SvgPicture.asset(
                                                        'assets/images/Send_request.svg',
                                                        width: 14,
                                                        height: 14,
                                                        colorFilter:
                                                            ColorFilter.mode(
                                                          actionColor,
                                                          BlendMode.srcIn,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                          const SizedBox(width: 20),
                          Builder(
                            builder: (context) {
                              final removeEnabled =
                                  _isRemoveActionEnabledForRole(
                                _selectedAccessControlRole,
                              );
                              return MouseRegion(
                                cursor: removeEnabled
                                    ? SystemMouseCursors.click
                                    : SystemMouseCursors.basic,
                                child: GestureDetector(
                                  onTap: removeEnabled
                                      ? () => _removePrimaryAccessRow(
                                            _selectedAccessControlRole,
                                          )
                                      : null,
                                  child: Container(
                                    height: 40,
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
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: Text(
                                        'Remove',
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.normal,
                                          color: removeEnabled
                                              ? Colors.red
                                              : Colors.red.withOpacity(0.5),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                    ...(_additionalAccessRows[_selectedAccessControlRole] ??
                            const <_AccessInviteEntry>[])
                        .asMap()
                        .entries
                        .map(
                          (entry) => _buildAdditionalAccessRow(
                            _selectedAccessControlRole,
                            entry.value,
                            entry.key,
                          ),
                        ),
                    if (_canEditAccessRole(_selectedAccessControlRole)) ...[
                      const SizedBox(height: 16),
                      Builder(
                        builder: (context) {
                          final canAddMore =
                              _canAddMoreAccessRows(_selectedAccessControlRole);
                          final addDisabled =
                              !canAddMore || _isPreparingAccessControlSync;
                          return MouseRegion(
                            cursor: addDisabled
                                ? SystemMouseCursors.basic
                                : SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: addDisabled
                                  ? null
                                  : () async {
                                      if (!_isAccessControlSyncReadyForEdits) {
                                        await _onBlockedAccessControlEditTap();
                                        if (!mounted ||
                                            !_isAccessControlSyncReadyForEdits) {
                                          return;
                                        }
                                      }
                                      _addAdditionalAccessRow(
                                        _selectedAccessControlRole,
                                      );
                                    },
                              child: Opacity(
                                opacity: addDisabled ? 0.5 : 1.0,
                                child: Container(
                                  height: 36,
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
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
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Add Email IDs',
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.normal,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      const Icon(
                                        Icons.add,
                                        size: 12,
                                        color: Colors.white,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showAccessControlSection = !widget.hideAccessControlSection;
    final isGeneralTabSelected =
        !showAccessControlSection || !_isAccessControlTabSelected;
    final isAccessControlTabSelected =
        showAccessControlSection && _isAccessControlTabSelected;

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
          height: 32,
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
              // General tab (inactive)
              GestureDetector(
                onTap: () {
                  if (showAccessControlSection && _isAccessControlTabSelected) {
                    setState(() {
                      _isAccessControlTabSelected = false;
                    });
                    _persistSettingsTabSelection();
                  }
                },
                child: SizedBox(
                  height: 32,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: isGeneralTabSelected
                              ? const Color(0xFF0C8CE9)
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Center(
                        child: Text(
                          'General',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: isGeneralTabSelected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: isGeneralTabSelected
                                ? const Color(0xFF0C8CE9)
                                : const Color(0xFF858585),
                            height: 1.43,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (showAccessControlSection) ...[
                const SizedBox(width: 36),
                // Access Control tab (active)
                GestureDetector(
                  onTap: _handleAccessControlTabTap,
                  child: SizedBox(
                    height: 32,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: isAccessControlTabSelected
                                ? const Color(0xFF0C8CE9)
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Access Control',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: isAccessControlTabSelected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: isAccessControlTabSelected
                                      ? const Color(0xFF0C8CE9)
                                      : const Color(0xFF858585),
                                  height: 1.43,
                                ),
                              ),
                              if (_isPreparingAccessControlSync) ...[
                                const SizedBox(width: 8),
                                const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.8,
                                    color: Color(0xFF0C8CE9),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 40),
        isAccessControlTabSelected
            ? _buildAccessControlTabContent()
            : _buildGeneralTabContent(),
      ],
    );
  }
}
