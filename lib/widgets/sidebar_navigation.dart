import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'nav_link.dart';
import '../models/navigation_page.dart';
import 'project_save_status.dart';
import '../config/app_release_info.dart';
import '../services/app_update_service.dart';
import '../services/desktop_installer_update_service.dart';

class SidebarNavigation extends StatefulWidget {
  final NavigationPage currentPage;
  final Function(NavigationPage) onPageChanged;
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
  final bool? hasProjectManagerWarningsOnly;
  final bool? hasAgentWarningsOnly;
  final bool? hasAboutErrors;
  final bool? hasAboutWarningsOnly;
  final bool? hasAccountErrors;
  final bool isLoading;
  final bool isPartnerRestricted;
  final bool isAgentRestricted;
  final bool isReadOnlyProject;
  final bool hasActiveProject;

  const SidebarNavigation({
    super.key,
    required this.currentPage,
    required this.onPageChanged,
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
    this.hasProjectManagerWarningsOnly,
    this.hasAgentWarningsOnly,
    this.hasAboutErrors,
    this.hasAboutWarningsOnly,
    this.hasAccountErrors,
    this.isLoading = false,
    this.isPartnerRestricted = false,
    this.isAgentRestricted = false,
    this.isReadOnlyProject = false,
    this.hasActiveProject = false,
  });

  @override
  State<SidebarNavigation> createState() => _SidebarNavigationState();
}

class _SidebarNavigationState extends State<SidebarNavigation> {
  bool _isHomeHovered = false;
  bool _isDataEntryHovered = false;
  AppUpdateInfo? _availableUpdate;
  bool _isCheckingForUpdate = false;
  bool _isLaunchingUpdate = false;

  String _platformKeyForUpdateFeed() {
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

  bool get _supportsInAppUpdateLink {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  void initState() {
    super.initState();
    _checkForSidebarUpdateAction();
  }

  Future<void> _checkForSidebarUpdateAction() async {
    if (!_supportsInAppUpdateLink || _isCheckingForUpdate) return;
    _isCheckingForUpdate = true;
    try {
      final updateInfo = await AppUpdateService.checkForUpdate(
        platform: _platformKeyForUpdateFeed(),
      );
      if (!mounted) return;
      setState(() {
        _availableUpdate = updateInfo;
      });
    } catch (_) {
      // Silent failure: the update CTA is optional and should not block UX.
    } finally {
      _isCheckingForUpdate = false;
    }
  }

  Future<void> _openUpdatePage() async {
    final updateInfo = _availableUpdate;
    if (updateInfo == null || _isLaunchingUpdate) return;

    setState(() {
      _isLaunchingUpdate = true;
    });

    try {
      final launchedInstaller =
          await DesktopInstallerUpdateService.tryRunInstaller(updateInfo);
      if (launchedInstaller) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (!kIsWeb && mounted) {
          await SystemNavigator.pop();
        }
        return;
      }

      final releaseUrl = updateInfo.releaseUrl.trim();
      if (releaseUrl.isEmpty) return;
      final uri = Uri.tryParse(releaseUrl);
      if (uri == null) return;
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } finally {
      if (mounted) {
        setState(() {
          _isLaunchingUpdate = false;
        });
      }
    }
  }

  Widget _buildUpdateButton() {
    return GestureDetector(
      onTap: _isLaunchingUpdate ? null : _openUpdatePage,
      child: Container(
        width: double.infinity,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLaunchingUpdate) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              _isLaunchingUpdate ? 'Updating...' : 'Update',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.normal,
                color: Colors.white,
              ),
            ),
            if (!_isLaunchingUpdate) ...[
              const SizedBox(width: 8),
              SvgPicture.asset(
                'assets/images/Update.svg',
                width: 12,
                height: 12,
                fit: BoxFit.contain,
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
                placeholderBuilder: (context) => const SizedBox(
                  width: 12,
                  height: 12,
                ),
              ),
            ],
          ],
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

  Widget _buildProjectDetailsSidebarSkeleton() {
    return Container(
      width: 252,
      height: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFF4F4F4),
        border: const Border(
          right: BorderSide(
            color: Color(0xFF5C5C5C),
            width: 0.5,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _skeletonBlock(width: 174, height: 35),
            const SizedBox(height: 24),
            _skeletonBlock(width: 52, height: 14),
            const SizedBox(height: 8),
            _skeletonBlock(width: 140, height: 16),
            const SizedBox(height: 8),
            _skeletonBlock(width: 96, height: 14),
            const SizedBox(height: 40),
            _skeletonBlock(width: 84, height: 24),
            const SizedBox(height: 40),
            _skeletonBlock(width: 120, height: 14),
            const SizedBox(height: 16),
            ...List.generate(
              6,
              (index) => Padding(
                padding: EdgeInsets.only(bottom: index == 5 ? 0 : 16),
                child: _skeletonBlock(width: 160, height: 24),
              ),
            ),
            const Spacer(),
            _skeletonBlock(width: 90, height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildOriginalSidebarSkeleton() {
    return Container(
      width: 252,
      height: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        border: const Border(
          right: BorderSide(
            color: Color(0xFF5C5C5C),
            width: 0.5,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _skeletonBlock(width: 174, height: 35),
            const SizedBox(height: 24),
            _skeletonBlock(width: 120, height: 24),
            const SizedBox(height: 40),
            _skeletonBlock(width: 70, height: 14),
            const SizedBox(height: 16),
            _skeletonBlock(width: 150, height: 24),
            const SizedBox(height: 16),
            _skeletonBlock(width: 130, height: 24),
            const SizedBox(height: 16),
            _skeletonBlock(width: 90, height: 24),
            const SizedBox(height: 40),
            _skeletonBlock(width: 40, height: 14),
            const SizedBox(height: 16),
            _skeletonBlock(width: 120, height: 24),
            const SizedBox(height: 40),
            _skeletonBlock(width: 64, height: 14),
            const SizedBox(height: 16),
            _skeletonBlock(width: 80, height: 24),
            const Spacer(),
            _skeletonBlock(width: 80, height: 24),
            const SizedBox(height: 16),
            _skeletonBlock(width: 100, height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildProjectDetailsSidebar() {
    return Container(
      width: 252,
      height: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFF4F4F4),
        border: const Border(
          right: BorderSide(
            color: Color(0xFF5C5C5C),
            width: 0.5,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 8answers logo
                SizedBox(
                  width: 174,
                  height: 35,
                  child: SvgPicture.asset(
                    'assets/images/8answers.svg',
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                  ),
                ),
                const SizedBox(height: 24),
                // Project section
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Project label
                    Text(
                      'Project',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: const Color(0xFF5D5D5D),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Project name
                    Text(
                      (widget.projectName ?? '').trim().isEmpty
                          ? 'Loading project...'
                          : widget.projectName!,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    // Project save status
                    if (widget.saveStatus != null && widget.hasActiveProject)
                      ProjectSaveStatus(
                        status: widget.saveStatus!,
                        visualOverride: widget.saveStatusVisualOverride ??
                            ProjectSaveStatusVisualOverride.none,
                        savedTimeAgo: widget.savedTimeAgo,
                      ),
                  ],
                ),
                const SizedBox(height: 40),
                // Home link
                MouseRegion(
                  onEnter: (_) => setState(() => _isHomeHovered = true),
                  onExit: (_) => setState(() => _isHomeHovered = false),
                  child: GestureDetector(
                    onTap: () => widget.onPageChanged(NavigationPage.home),
                    child: Container(
                      width: double.infinity,
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: widget.currentPage == NavigationPage.home
                            ? const Color(0xFFDDDEDE)
                            : (_isHomeHovered
                                ? const Color(0xFFF0F0F0)
                                : Colors.transparent),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Back arrow icon
                          SizedBox(
                            width: 7,
                            height: 14,
                            child: Icon(
                              Icons.arrow_back_ios,
                              size: 14,
                              color: const Color(0xFF5C5C5C),
                            ),
                          ),
                          const SizedBox(width: 24),
                          // Home icon
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: SvgPicture.asset(
                              _isHomeHovered
                                  ? 'assets/images/Home_hover.svg'
                                  : (widget.currentPage == NavigationPage.home
                                      ? 'assets/images/Home_active.svg'
                                      : 'assets/images/Home_inactive.svg'),
                              width: 16,
                              height: 16,
                              fit: BoxFit.contain,
                              placeholderBuilder: (context) => const SizedBox(
                                width: 16,
                                height: 16,
                              ),
                              errorBuilder: (context, error, stackTrace) {
                                print('Error loading Home icon: $error');
                                return const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: Icon(Icons.home,
                                      size: 16, color: Color(0xFF5C5C5C)),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Home text
                          Text(
                            'Home',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight:
                                  widget.currentPage == NavigationPage.home
                                      ? FontWeight.w500
                                      : FontWeight.normal,
                              color: widget.currentPage == NavigationPage.home
                                  ? const Color(0xFF000000)
                                  : (_isHomeHovered
                                      ? const Color(0xCC000000)
                                      : const Color(0xA3000000)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                // Data Visualization section
                Text(
                  'Data Visualization',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF5D5D5D),
                  ),
                ),
                const SizedBox(height: 16),
                NavLink(
                  inactiveIconPath: 'assets/images/Dashboard_inactive.svg',
                  hoverIconPath: 'assets/images/Dashboard_hover.svg',
                  activeIconPath: 'assets/images/Dashboard_active.svg',
                  label: 'Dashboard',
                  isActive: widget.currentPage == NavigationPage.dashboard,
                  onTap: () => widget.onPageChanged(NavigationPage.dashboard),
                ),
                if (widget.isReadOnlyProject ||
                    (!widget.isPartnerRestricted &&
                        !widget.isAgentRestricted)) ...[
                  const SizedBox(height: 40),
                  // Project Details section
                  Text(
                    'Project Details',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF5D5D5D),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (widget.isReadOnlyProject ||
                      (!widget.isPartnerRestricted &&
                          !widget.isAgentRestricted)) ...[
                    MouseRegion(
                      onEnter: (_) =>
                          setState(() => _isDataEntryHovered = true),
                      onExit: (_) =>
                          setState(() => _isDataEntryHovered = false),
                      child: GestureDetector(
                        onTap: () =>
                            widget.onPageChanged(NavigationPage.dataEntry),
                        child: Container(
                          width: double.infinity,
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color:
                                widget.currentPage == NavigationPage.dataEntry
                                    ? const Color(0xFFDDDEDE)
                                    : (_isDataEntryHovered
                                        ? const Color(0xFFF0F0F0)
                                        : Colors.transparent),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: SvgPicture.asset(
                                  widget.currentPage == NavigationPage.dataEntry
                                      ? 'assets/images/Account_active.svg'
                                      : (_isDataEntryHovered
                                          ? 'assets/images/Account_.hoversvg.svg'
                                          : 'assets/images/Account_inactive.svg'),
                                  width: 16,
                                  height: 16,
                                  fit: BoxFit.contain,
                                  placeholderBuilder: (context) =>
                                      const SizedBox(
                                    width: 16,
                                    height: 16,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Data Entry',
                                style: GoogleFonts.inter(
                                  fontSize: 16,
                                  fontWeight: widget.currentPage ==
                                          NavigationPage.dataEntry
                                      ? FontWeight.w500
                                      : FontWeight.w400,
                                  color: widget.currentPage ==
                                          NavigationPage.dataEntry
                                      ? Colors.black
                                      : (_isDataEntryHovered
                                          ? const Color(0xCC000000)
                                          : const Color(0xA3000000)),
                                  letterSpacing: 0,
                                ),
                              ),
                              if (() {
                                final hasGlobalHardError =
                                    widget.hasDataEntryErrors == true;
                                final hasProjectManagerHardErrors =
                                    (widget.hasProjectManagerErrors == true) &&
                                        (widget.hasProjectManagerWarningsOnly !=
                                            true);
                                final hasAgentHardErrors =
                                    (widget.hasAgentErrors == true) &&
                                        (widget.hasAgentWarningsOnly != true);
                                final hasSectionError = hasGlobalHardError ||
                                    widget.hasAreaErrors == true ||
                                    widget.hasPartnerErrors == true ||
                                    widget.hasExpenseErrors == true ||
                                    widget.hasSiteErrors == true ||
                                    hasProjectManagerHardErrors ||
                                    hasAgentHardErrors ||
                                    widget.hasAboutErrors == true;
                                final hasAnyWarningOnly = !hasSectionError &&
                                    (widget.hasProjectManagerWarningsOnly ==
                                            true ||
                                        widget.hasAgentWarningsOnly == true ||
                                        widget.hasAboutWarningsOnly == true);
                                return hasSectionError || hasAnyWarningOnly;
                              }()) ...[
                                const SizedBox(width: 8),
                                SvgPicture.asset(
                                  (() {
                                    final hasGlobalHardError =
                                        widget.hasDataEntryErrors == true;
                                    final hasProjectManagerHardErrors = (widget
                                                .hasProjectManagerErrors ==
                                            true) &&
                                        (widget.hasProjectManagerWarningsOnly !=
                                            true);
                                    final hasAgentHardErrors =
                                        (widget.hasAgentErrors == true) &&
                                            (widget.hasAgentWarningsOnly !=
                                                true);
                                    final hasAnyError = hasGlobalHardError ||
                                        widget.hasAreaErrors == true ||
                                        widget.hasPartnerErrors == true ||
                                        widget.hasExpenseErrors == true ||
                                        widget.hasSiteErrors == true ||
                                        hasProjectManagerHardErrors ||
                                        hasAgentHardErrors ||
                                        widget.hasAboutErrors == true;
                                    return hasAnyError
                                        ? 'assets/images/Error_msg.svg'
                                        : 'assets/images/Warning.svg';
                                  })(),
                                  width: 17,
                                  height: 15,
                                  fit: BoxFit.contain,
                                  errorBuilder: (context, error, stackTrace) {
                                    print(
                                        'Error loading Error_msg.svg: $error');
                                    return const SizedBox(
                                      width: 17,
                                      height: 15,
                                    );
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    NavLink(
                      inactiveIconPath:
                          'assets/images/Plot_status_inactive.svg',
                      hoverIconPath: 'assets/images/Plot_status_hover.svg',
                      activeIconPath: 'assets/images/Plot_status_active.svg',
                      label: 'Plot Status',
                      isActive: widget.currentPage == NavigationPage.plotStatus,
                      hasError: widget.hasPlotStatusErrors ?? false,
                      onTap: () =>
                          widget.onPageChanged(NavigationPage.plotStatus),
                    ),
                    const SizedBox(height: 16),
                  ],
                  NavLink(
                    inactiveIconPath: 'assets/images/Document_inactive.svg',
                    hoverIconPath: 'assets/images/Document_inactive.svg',
                    activeIconPath: 'assets/images/Document_active.svg',
                    label: 'Documents',
                    isActive: widget.currentPage == NavigationPage.documents,
                    onTap: () => widget.onPageChanged(NavigationPage.documents),
                  ),
                ],
                if (!widget.isReadOnlyProject &&
                    (widget.isPartnerRestricted ||
                        widget.isAgentRestricted)) ...[
                  const SizedBox(height: 40),
                  Text(
                    'Documents',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF5D5D5D),
                    ),
                  ),
                  const SizedBox(height: 16),
                  NavLink(
                    inactiveIconPath: 'assets/images/Document_inactive.svg',
                    hoverIconPath: 'assets/images/Document_inactive.svg',
                    activeIconPath: 'assets/images/Document_active.svg',
                    label: 'Documents',
                    isActive: widget.currentPage == NavigationPage.documents,
                    onTap: () => widget.onPageChanged(NavigationPage.documents),
                  ),
                ],
                if (widget.isReadOnlyProject ||
                    (!widget.isPartnerRestricted &&
                        !widget.isAgentRestricted)) ...[
                  const SizedBox(height: 40),
                  Text(
                    'Report Generator',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF5D5D5D),
                    ),
                  ),
                  const SizedBox(height: 16),
                  NavLink(
                    inactiveIconPath: 'assets/images/Report_inactive.svg',
                    hoverIconPath: 'assets/images/Report_hover.svg',
                    activeIconPath: 'assets/images/Report_active.svg',
                    label: 'Reports',
                    isActive: widget.currentPage == NavigationPage.report,
                    onTap: () => widget.onPageChanged(NavigationPage.report),
                  ),
                ],
              ],
            ),
            // Settings at bottom
            if (widget.isReadOnlyProject)
              const SizedBox.shrink()
            else
              NavLink(
                inactiveIconPath: 'assets/images/settings_inactive.svg',
                hoverIconPath: 'assets/images/settings_hover.svg',
                activeIconPath: 'assets/images/settings_active.svg',
                label: 'Settings',
                isActive: widget.currentPage == NavigationPage.settings,
                onTap: () => widget.onPageChanged(NavigationPage.settings),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildOriginalSidebar() {
    return Container(
      width: 252,
      height: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        border: const Border(
          right: BorderSide(
            color: Color(0xFF5C5C5C),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 174,
                height: 35,
                child: SvgPicture.asset(
                  'assets/images/8answers.svg',
                  fit: BoxFit.contain,
                  alignment: Alignment.centerLeft,
                ),
              ),
            ),
          ),
          // Navigation items
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.saveStatus != null &&
                          widget.hasActiveProject) ...[
                        SizedBox(
                          width: 213,
                          height: 84,
                          child: ProjectSaveStatus(
                            status: widget.saveStatus!,
                            visualOverride: widget.saveStatusVisualOverride ??
                                ProjectSaveStatusVisualOverride.none,
                            savedTimeAgo: widget.savedTimeAgo,
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      // Account (Active)
                      NavLink(
                        key: ValueKey(
                            'account_${widget.currentPage == NavigationPage.account}'),
                        inactiveIconPath: 'assets/images/Account_inactive.svg',
                        hoverIconPath: 'assets/images/Account_.hoversvg.svg',
                        activeIconPath: 'assets/images/Account_active.svg',
                        label: 'Account',
                        isActive: widget.currentPage == NavigationPage.account,
                        hasError: widget.hasAccountErrors ?? false,
                        errorIconPath: 'assets/images/Warning.svg',
                        onTap: () =>
                            widget.onPageChanged(NavigationPage.account),
                      ),
                      const SizedBox(height: 40),
                      // Projects section
                      Text(
                        'Projects',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.normal,
                          color: Colors.black.withOpacity(0.4),
                        ),
                      ),
                      const SizedBox(height: 16),
                      NavLink(
                        inactiveIconPath:
                            'assets/images/Recent projects_inactive.svg',
                        hoverIconPath:
                            'assets/images/Recent projects_hover.svg',
                        activeIconPath:
                            'assets/images/Recent projects_active.svg',
                        label: 'Recent Projects',
                        isActive:
                            widget.currentPage == NavigationPage.recentProjects,
                        onTap: () =>
                            widget.onPageChanged(NavigationPage.recentProjects),
                      ),
                      const SizedBox(height: 16),
                      NavLink(
                        inactiveIconPath:
                            'assets/images/All projects_inactive.svg',
                        hoverIconPath: 'assets/images/All_projects_hover.svg',
                        activeIconPath: 'assets/images/All projects_active.svg',
                        label: 'All Projects',
                        isActive:
                            widget.currentPage == NavigationPage.allProjects,
                        onTap: () =>
                            widget.onPageChanged(NavigationPage.allProjects),
                      ),
                      const SizedBox(height: 16),
                      NavLink(
                        inactiveIconPath: 'assets/images/Trash_inactive.svg',
                        hoverIconPath: 'assets/images/Trash_hover.svg',
                        activeIconPath: 'assets/images/Trash_active.svg',
                        label: 'Trash',
                        isActive: widget.currentPage == NavigationPage.trash,
                        onTap: () => widget.onPageChanged(NavigationPage.trash),
                      ),
                      const SizedBox(height: 40),
                      // Support section
                      Text(
                        'Support',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.normal,
                          color: Colors.black.withOpacity(0.4),
                        ),
                      ),
                      const SizedBox(height: 16),
                      NavLink(
                        inactiveIconPath: 'assets/images/Help_inactive.svg',
                        hoverIconPath: 'assets/images/Help_hover.svg',
                        activeIconPath: 'assets/images/Help_active.svg',
                        label: 'Help',
                        isActive: widget.currentPage == NavigationPage.help,
                        onTap: () => widget.onPageChanged(NavigationPage.help),
                      ),
                    ],
                  ),
                  // Footer
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_availableUpdate != null) ...[
                        _buildUpdateButton(),
                        const SizedBox(height: 16),
                      ],
                      NavLink(
                        inactiveIconPath: 'assets/images/Loggout_inactive.svg',
                        hoverIconPath: 'assets/images/Logout_hver.svg',
                        activeIconPath: 'assets/images/Logout_active.svg',
                        label: 'Sign Out',
                        iconRotation: 0,
                        isActive: widget.currentPage == NavigationPage.logout,
                        onTap: () =>
                            widget.onPageChanged(NavigationPage.logout),
                      ),
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: Text(
                          'Version ${AppReleaseInfo.displayVersion}',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.normal,
                            color: const Color(0xFF666666),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading) {
      if (widget.currentPage == NavigationPage.projectDetails ||
          widget.currentPage == NavigationPage.dashboard ||
          widget.currentPage == NavigationPage.dataEntry ||
          widget.currentPage == NavigationPage.plotStatus ||
          widget.currentPage == NavigationPage.documents ||
          widget.currentPage == NavigationPage.settings ||
          widget.currentPage == NavigationPage.report) {
        return _buildProjectDetailsSidebarSkeleton();
      }
      return _buildOriginalSidebarSkeleton();
    }

    // Show new sidebar design when on project details, dashboard, data entry, plot status, documents, or settings pages
    if (widget.currentPage == NavigationPage.projectDetails ||
        widget.currentPage == NavigationPage.dashboard ||
        widget.currentPage == NavigationPage.dataEntry ||
        widget.currentPage == NavigationPage.plotStatus ||
        widget.currentPage == NavigationPage.documents ||
        widget.currentPage == NavigationPage.settings ||
        widget.currentPage == NavigationPage.report) {
      return _buildProjectDetailsSidebar();
    }
    return _buildOriginalSidebar();
  }
}
