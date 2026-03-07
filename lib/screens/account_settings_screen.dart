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
import '../services/project_storage_service.dart';
import '../utils/web_navigation_context.dart' as web_nav;
import '../widgets/unauthenticated_page.dart';

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends State<AccountSettingsScreen>
    with WidgetsBindingObserver {
  static const String _accountErrorsPrefKey = 'nav_has_account_errors';

  NavigationPage _currentPage = NavigationPage.recentProjects;
  NavigationPage? _previousPage;
  final List<NavigationPage> _pageHistory = <NavigationPage>[];
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
  bool _hasProjectManagerWarningOnly = false;
  bool _hasAgentWarningOnly = false;
  bool _hasAccountErrors = false;
  bool _isRestoringNavState = true;
  bool _isDashboardPageLoading = false;
  bool _isPlotStatusPageLoading = false;
  int _errorBadgeRefreshGeneration = 0;

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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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

  Future<void> _handleBrowserBackNavigation() async {
    if (_currentPage == NavigationPage.recentProjects) {
      return;
    }
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
    final isReload = await web_nav.isReloadNavigation();
    final forceRecentOnNextOpen =
        prefs.getBool('nav_force_recent_on_next_open') ?? false;
    final pageName = prefs.getString('nav_current_page');
    final prevPageName = prefs.getString('nav_previous_page');
    final projectId = prefs.getString('nav_project_id');
    final projectName = prefs.getString('nav_project_name');
    final hasAccountErrors = prefs.getBool(_accountErrorsPrefKey) ?? false;

    final shouldForceRecent = forceRecentOnNextOpen || !isReload;

    if (shouldForceRecent) {
      await prefs.remove('nav_force_recent_on_next_open');
      await prefs.setString(
          'nav_current_page', NavigationPage.recentProjects.name);
      await prefs.remove('nav_previous_page');
      setState(() {
        _currentPage = NavigationPage.recentProjects;
        _previousPage = null;
        _projectId = projectId;
        _projectName = projectName;
        _hasAccountErrors = hasAccountErrors;
        _isRestoringNavState = false;
      });
      _initializeHistory(NavigationPage.recentProjects);
      _refreshAccountErrorBadgeFromStoredData();
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

      // Don't restore logout
      if (page != NavigationPage.logout) {
        setState(() {
          _currentPage = page;
          _previousPage = prevPage;
          _projectId = projectId;
          _projectName = projectName;
          _hasAccountErrors = hasAccountErrors;
          _isRestoringNavState = false;
        });
        _initializeHistory(page);
        _refreshErrorBadgesFromStoredData();
        _refreshAccountErrorBadgeFromStoredData();
        return;
      }
    }

    setState(() {
      _currentPage = NavigationPage.recentProjects;
      _previousPage = null;
      _projectId = projectId;
      _projectName = projectName;
      _hasAccountErrors = hasAccountErrors;
      _isRestoringNavState = false;
    });
    _initializeHistory(NavigationPage.recentProjects);
    _refreshAccountErrorBadgeFromStoredData();
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
  }

  Future<void> _clearPersistedNavState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('nav_current_page');
    await prefs.remove('nav_previous_page');
    await prefs.remove('nav_project_id');
    await prefs.remove('nav_project_name');
    await prefs.remove(_accountErrorsPrefKey);
  }

  Future<void> _persistAccountErrorsState(bool hasErrors) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_accountErrorsPrefKey, hasErrors);
  }

  Future<void> _refreshAccountErrorBadgeFromStoredData() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.trim().isEmpty) return;

    try {
      final row = await Supabase.instance.client
          .from('account_report_identity_settings')
          .select(
              'full_name, organization, role, logo_storage_path, logo_svg, logo_base64')
          .eq('user_id', userId)
          .maybeSingle();

      final hasErrors = row == null
          ? true
          : (row['full_name'] ?? '').toString().trim().isEmpty ||
              (row['organization'] ?? '').toString().trim().isEmpty ||
              (row['role'] ?? '').toString().trim().isEmpty ||
              (((row['logo_storage_path'] ?? '').toString().trim().isEmpty) &&
                  ((row['logo_svg'] ?? '').toString().trim().isEmpty) &&
                  ((row['logo_base64'] ?? '').toString().trim().isEmpty));

      _setStateSafely(() {
        _hasAccountErrors = hasErrors;
      });
      _persistAccountErrorsState(hasErrors);
    } catch (e) {
      print('Error refreshing account sidebar error badge: $e');
    }
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

  Future<void> _refreshErrorBadgesFromStoredData() async {
    final projectId = _projectId;
    if (projectId == null || projectId.trim().isEmpty) return;
    final generation = ++_errorBadgeRefreshGeneration;

    try {
      final data = await ProjectStorageService.fetchProjectDataById(projectId);
      if (!mounted || generation != _errorBadgeRefreshGeneration) return;
      if (data == null) return;

      final totalAreaValue = _parseNumeric(data['totalArea']);
      final sellingAreaValue = _parseNumeric(data['sellingArea']);

      final nonSellableAreas =
          (data['nonSellableAreas'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[];
      final amenityAreas =
          (data['amenityAreas'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[];
      final partners =
          (data['partners'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[];
      final expenses =
          (data['expenses'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[];
      final layouts =
          (data['layouts'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[];
      final plots = (data['plots'] as List?)?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];
      final plotPartners =
          (data['plot_partners'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[];
      final projectManagers =
          (data['project_managers'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[];
      final agents = (data['agents'] as List?)?.cast<Map<String, dynamic>>() ??
          const <Map<String, dynamic>>[];

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
          if (plotNumber.isEmpty || areaMissing || selectedPartners.isEmpty) {
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

      final hasAboutErrors =
          (data['projectName'] ?? '').toString().trim().isEmpty;
      final hasProjectManagerHardErrors =
          hasProjectManagerErrors && !hasProjectManagerWarningOnly;
      final hasAgentHardErrors = hasAgentErrors && !hasAgentWarningOnly;
      final effectiveAreaErrors = hasAreaErrors || _hasAreaErrors;

      _setStateSafely(() {
        // Keep live data-entry validation (including amenity-tab-only checks)
        // from being overwritten by backend refresh snapshots.
        _hasAreaErrors = effectiveAreaErrors;
        _hasPartnerErrors = hasPartnerErrors;
        _hasExpenseErrors = hasExpenseErrors;
        _hasSiteErrors = hasSiteErrors;
        _hasProjectManagerErrors = hasProjectManagerErrors;
        _hasAgentErrors = hasAgentErrors;
        _hasProjectManagerWarningOnly = hasProjectManagerWarningOnly;
        _hasAgentWarningOnly = hasAgentWarningOnly;
        _hasAboutErrors = hasAboutErrors;
        _hasDataEntryErrors = effectiveAreaErrors ||
            hasPartnerErrors ||
            hasExpenseErrors ||
            hasSiteErrors ||
            hasProjectManagerHardErrors ||
            hasAgentHardErrors ||
            hasAboutErrors;
        _hasPlotStatusErrors = hasPlotStatusErrors;
      });
    } catch (e) {
      print('Error refreshing sidebar error badges: $e');
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
        return ReportPage(projectId: _projectId);
      case NavigationPage.recentProjects:
        return RecentProjectsPage(
          onCreateProject: () => _showCreateProjectDialog(),
          onProjectSelected: (projectId, projectName) {
            setState(() {
              _projectName = projectName;
              _projectId = projectId;
              _previousPage = _currentPage;
              _currentPage = NavigationPage.dataEntry;
            });
            _recordPageVisit(_currentPage);
            _persistNavState();
            _refreshErrorBadgesFromStoredData();
          },
        );
      case NavigationPage.allProjects:
        return AllProjectsPage(
          onCreateProject: () => _showCreateProjectDialog(),
          onProjectSelected: (projectId, projectName) {
            setState(() {
              _projectName = projectName;
              _projectId = projectId;
              _previousPage = _currentPage;
              _currentPage = NavigationPage.dataEntry;
            });
            _recordPageVisit(_currentPage);
            _persistNavState();
            _refreshErrorBadgesFromStoredData();
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
        ); // Data Entry shows Project Details page
      case NavigationPage.plotStatus:
        return PlotStatusPage(
          projectId: _projectId,
          onSaveStatusChanged: _handleSaveStatusChanged,
          onPlotStatusErrorsChanged: _handlePlotStatusErrorsChanged,
          onLoadingStateChanged: _handlePlotStatusLoadingStateChanged,
        );
      case NavigationPage.documents:
        return DocumentsPage(projectId: _projectId);
      case NavigationPage.settings:
        return SettingsPage(
          projectId: _projectId,
          onProjectDeleted: _handleProjectDeleted,
        );
    }
  }

  Widget _getPageContent() {
    switch (_currentPage) {
      case NavigationPage.account:
        return AccountSettingsContent(
          onReportIdentityErrorsChanged: _handleAccountErrorsChanged,
        );
      case NavigationPage.notifications:
        return const NotificationsPage();
      case NavigationPage.toDoList:
        return const ToDoListPage();
      case NavigationPage.report:
        return ReportPage(projectId: _projectId);
      case NavigationPage.recentProjects:
        return RecentProjectsPage(
          onCreateProject: () => _showCreateProjectDialog(),
          onProjectSelected: (projectId, projectName) {
            setState(() {
              _projectName = projectName;
              _projectId = projectId;
              _previousPage = _currentPage;
              _currentPage = NavigationPage.dataEntry;
            });
            _recordPageVisit(_currentPage);
            _persistNavState();
            _refreshErrorBadgesFromStoredData();
          },
        );
      case NavigationPage.allProjects:
        return AllProjectsPage(
          onCreateProject: () => _showCreateProjectDialog(),
          onProjectSelected: (projectId, projectName) {
            setState(() {
              _projectName = projectName;
              _projectId = projectId;
              _previousPage = _currentPage;
              _currentPage = NavigationPage.dataEntry;
            });
            _recordPageVisit(_currentPage);
            _persistNavState();
            _refreshErrorBadgesFromStoredData();
          },
        );
      case NavigationPage.trash:
        return const TrashPage();
      case NavigationPage.help:
        return const HelpPage();
      case NavigationPage.logout:
        // For logout, you might want to show a dialog or navigate to login
        return AccountSettingsContent(
          onReportIdentityErrorsChanged: _handleAccountErrorsChanged,
        );
      case NavigationPage.projectDetails:
        return ProjectDetailsPage(
          initialProjectName: _projectName,
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
        );
      case NavigationPage.home:
        // This should not be reached as Home navigates back
        return _previousPage != null
            ? _getPageContentForPage(_previousPage!)
            : AccountSettingsContent(
                onReportIdentityErrorsChanged: _handleAccountErrorsChanged,
              );
      case NavigationPage.dashboard:
        return DashboardPage(
          projectId: _projectId,
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
        ); // Data Entry shows Project Details page
      case NavigationPage.plotStatus:
        return PlotStatusPage(
          projectId: _projectId,
          onSaveStatusChanged: _handleSaveStatusChanged,
          onPlotStatusErrorsChanged: _handlePlotStatusErrorsChanged,
          onLoadingStateChanged: _handlePlotStatusLoadingStateChanged,
        );
      case NavigationPage.documents:
        return DocumentsPage(projectId: _projectId);
      case NavigationPage.settings:
        return SettingsPage(
          projectId: _projectId,
          onProjectDeleted: _handleProjectDeleted,
        );
    }
  }

  void _handleProjectDeleted() {
    setState(() {
      _projectName = null;
      _projectId = null;
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
      final projectName = result['projectName'] as String;
      final projectId = result['projectId'] as String?;

      setState(() {
        _projectName = projectName;
        _projectId = projectId;
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

  void _handleErrorStateChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasDataEntryErrors = hasErrors;
    });
  }

  void _handleAreaErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasAreaErrors = hasErrors;
    });
  }

  void _handlePartnerErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasPartnerErrors = hasErrors;
    });
  }

  void _handleExpenseErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasExpenseErrors = hasErrors;
    });
  }

  void _handleSiteErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasSiteErrors = hasErrors;
    });
  }

  void _handleProjectManagerErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasProjectManagerErrors = hasErrors;
    });
  }

  void _handleProjectManagerWarningOnlyChanged(bool hasWarningOnly) {
    _setStateSafely(() {
      _hasProjectManagerWarningOnly = hasWarningOnly;
    });
  }

  void _handleAgentErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasAgentErrors = hasErrors;
    });
  }

  void _handleAgentWarningOnlyChanged(bool hasWarningOnly) {
    _setStateSafely(() {
      _hasAgentWarningOnly = hasWarningOnly;
    });
  }

  void _handleAboutErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasAboutErrors = hasErrors;
    });
  }

  void _handleAccountErrorsChanged(bool hasErrors) {
    _setStateSafely(() {
      _hasAccountErrors = hasErrors;
    });
    _persistAccountErrorsState(hasErrors);
  }

  void _handlePlotStatusErrorsChanged(bool hasErrors) {
    print(
        '🔴 AccountSettingsScreen._handlePlotStatusErrorsChanged: hasErrors=$hasErrors');
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
    _setStateSafely(() {
      _saveStatus = status;
      if (status == ProjectSaveStatusType.saved) {
        // Update saved time when status changes to saved
        _savedTimeAgo = 'Just now';
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
        MaterialPageRoute(builder: (context) => const UnauthenticatedPage()),
        (route) => false,
      );
    }
  }

  Future<void> _handlePageChange(NavigationPage page) async {
    // Handle logout separately
    if (page == NavigationPage.logout) {
      _handleLogout();
      return;
    }

    final isOnDataEntryContext = _currentPage == NavigationPage.dataEntry ||
        _currentPage == NavigationPage.projectDetails;
    final isLeavingDataEntryContext = isOnDataEntryContext &&
        page != NavigationPage.dataEntry &&
        page != NavigationPage.projectDetails;

    if (isLeavingDataEntryContext) {
      // Commit any focused text edit so ProjectDetails autosave can run.
      FocusManager.instance.primaryFocus?.unfocus();
      // Brief delay so the autosave debounce can fire; the dashboard will
      // show skeleton loading until the Supabase save finishes.
      await Future.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
    }

    if (page == NavigationPage.home) {
      setState(() {
        _currentPage = NavigationPage.recentProjects;
        _previousPage = null;
      });
      _recordPageVisit(_currentPage);
      _persistNavState();
      _refreshErrorBadgesFromStoredData();
      _refreshAccountErrorBadgeFromStoredData();
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
      _persistNavState();
      _refreshErrorBadgesFromStoredData();
      _refreshAccountErrorBadgeFromStoredData();
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
    final isSidebarLoading =
        isProjectContextPage && (_projectId == null || _projectName == null);
    final isContentSkeletonLoading =
        (_currentPage == NavigationPage.dashboard && _isDashboardPageLoading) ||
            (_currentPage == NavigationPage.plotStatus &&
                _isPlotStatusPageLoading);
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
              return MobileLayout(
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
                hasAccountErrors: _hasAccountErrors,
                isSidebarLoading: isSidebarLoading,
                onPageChanged: _handlePageChange,
                pageContent: _getPageContent(),
              );
            } else if (constraints.maxWidth < 1024) {
              // Tablet: Sidebar and content side by side
              return TabletLayout(
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
                hasAccountErrors: _hasAccountErrors,
                isSidebarLoading: isSidebarLoading,
                onPageChanged: _handlePageChange,
                pageContent: _getPageContent(),
              );
            } else {
              // Desktop: Full layout with fixed sidebar
              return DesktopLayout(
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
                hasAccountErrors: _hasAccountErrors,
                isSidebarLoading: isSidebarLoading,
                onPageChanged: _handlePageChange,
                pageContent: _getPageContent(),
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
  final bool? hasAccountErrors;
  final bool isSidebarLoading;

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
    this.hasAccountErrors,
    this.isSidebarLoading = false,
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
          hasAccountErrors: hasAccountErrors,
          isLoading: isSidebarLoading,
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
  final bool? hasAccountErrors;
  final bool isSidebarLoading;

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
    this.hasAccountErrors,
    this.isSidebarLoading = false,
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
          hasAccountErrors: hasAccountErrors,
          isLoading: isSidebarLoading,
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
  final bool? hasAccountErrors;
  final bool isSidebarLoading;

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
    this.hasAccountErrors,
    this.isSidebarLoading = false,
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
                      hasAccountErrors: widget.hasAccountErrors,
                      isLoading: widget.isSidebarLoading,
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
