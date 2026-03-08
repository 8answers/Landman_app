import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:math' as math;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/area_unit_service.dart';
import '../utils/area_unit_utils.dart';
import '../widgets/area_unit_selector.dart';
import '../widgets/app_scale_metrics.dart';
import 'project_details_page.dart';

enum DashboardTab {
  overview,
  sales,
  profitRoi,
  site,
  amenityArea,
  partners,
  projectManagers,
  agents,
}

class DashboardPage extends StatefulWidget {
  final String? projectId;
  final ValueChanged<bool>? onLoadingStateChanged;

  const DashboardPage({super.key, this.projectId, this.onLoadingStateChanged});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  void _notifyLoadingState(bool isLoading) {
    widget.onLoadingStateChanged?.call(isLoading);
  }

  // Dashboard table for plots with custom columns
  Widget _buildDashboardPlotsTable(List<dynamic> plots, double allInCost) {
    const tableBaseWidth = 1500.0;
    final baseHeaderHeight = 48.0;
    final baseRowHeight = 48.0;
    final baseHeight = baseHeaderHeight + (plots.length * baseRowHeight);
    final scaledHeight = (baseHeight * _tableZoomLevel)
        .clamp(baseHeaderHeight * _tableZoomLevel, double.infinity);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: _layoutPlotsTableScrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _layoutPlotsTableScrollController,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            height: scaledHeight,
            child: Padding(
              padding: EdgeInsets.only(
                left: ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0),
                right: ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0) +
                    ((_tableZoomLevel - 1.0) * tableBaseWidth)
                        .clamp(0.0, tableBaseWidth),
                top: ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0),
                bottom: ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0) +
                    ((_tableZoomLevel - 1.0) * 100.0).clamp(0.0, 100.0),
              ),
              child: Transform.scale(
                scale: _tableZoomLevel,
                alignment: Alignment.topLeft,
                child: Table(
                  border: TableBorder(
                    horizontalInside: BorderSide(color: Colors.black, width: 1),
                    verticalInside: BorderSide(color: Colors.black, width: 1),
                  ),
                  columnWidths: const {
                    0: FixedColumnWidth(60), // Sl. No.
                    1: FixedColumnWidth(186), // Plot Number
                    2: FixedColumnWidth(215), // Area
                    3: FixedColumnWidth(215), // All-in Cost
                    4: FixedColumnWidth(215), // Total Plot Cost
                    5: FixedColumnWidth(215), // Sale Price
                    6: FixedColumnWidth(215), // Sale Value
                    7: FixedColumnWidth(167), // Sale date
                  },
                  children: [
                    // Header row
                    TableRow(
                      decoration: const BoxDecoration(
                        color: Color(0xFFE2E2E2),
                      ),
                      children: [
                        _buildTableHeaderCell('Sl. No.',
                            isFirst: true, centerAlign: true),
                        _buildTableHeaderCell('Plot Number'),
                        _buildTableHeaderCell('Area ($_areaUnitSuffix)'),
                        _buildTableHeaderCell(
                            'All-in Cost (₹/$_areaUnitSuffix)'),
                        _buildTableHeaderCell('Total Plot Cost (₹)'),
                        _buildTableHeaderCell(
                            'Sale Price (₹/$_areaUnitSuffix)'),
                        _buildTableHeaderCell('Sale Value (₹)'),
                        _buildTableHeaderCell('Sale date', isLast: true),
                      ],
                    ),
                    // Data rows
                    ...plots.asMap().entries.map((entry) {
                      final index = entry.key;
                      final plot = entry.value;
                      final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
                      final salePrice =
                          ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
                      final plotNumber =
                          (plot['plot_number'] as String? ?? '').toString();
                      final totalPlotCost = area * allInCost;
                      final saleValue = salePrice * area;
                      final saleDate =
                          (plot['sale_date'] as String? ?? '').toString();
                      final isLastRow = index == plots.length - 1;
                      return TableRow(
                        children: [
                          _buildTableDataCell('${index + 1}',
                              isFirst: true,
                              isLastRow: isLastRow,
                              centerAlign: true),
                          _buildTableDataCell(plotNumber,
                              isFirst: false, isLastRow: isLastRow),
                          _buildAreaCell(
                              AreaUnitUtils.areaFromSqftToDisplay(area, _isSqm),
                              isLastRow),
                          _buildCostCell(
                              '₹/$_areaUnitSuffix',
                              _formatCurrencyNumber(
                                  AreaUnitUtils.rateFromSqftToDisplay(
                                      allInCost, _isSqm)),
                              isLastRow),
                          _buildCostCell('₹',
                              _formatCurrencyNumber(totalPlotCost), isLastRow),
                          _buildTableDataCell(
                              '₹/$_areaUnitSuffix ${_formatCurrencyNumber(AreaUnitUtils.rateFromSqftToDisplay(salePrice, _isSqm))}',
                              isFirst: false,
                              isLastRow: isLastRow),
                          _buildTableDataCell(
                              '₹ ${_formatCurrencyNumber(saleValue)}',
                              isFirst: false,
                              isLastRow: isLastRow),
                          _buildSaleDateCell(saleDate, true, isLastRow,
                              isLast: true),
                        ],
                      );
                    }).toList(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  final SupabaseClient _supabase = Supabase.instance.client;
  String _areaUnit = AreaUnitService.defaultUnit;
  bool get _isSqm => AreaUnitUtils.isSqm(_areaUnit);
  String get _areaUnitSuffix => AreaUnitUtils.unitSuffix(_isSqm);
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = true;
  int _dashboardLoadGeneration = 0;
  Map<String, dynamic>? _dashboardData;
  List<Map<String, dynamic>> _siteLayouts = [];
  double _projectManagersCompensation = 0.0;
  double _agentsCompensation = 0.0;
  List<Map<String, dynamic>> _partners = [];
  List<Map<String, dynamic>> _projectManagers = [];
  List<Map<String, dynamic>> _agents = [];
  List<Map<String, dynamic>> _compensationLayouts = [];
  List<Map<String, dynamic>> _amenityAreaRows = [];
  double _totalCompensation = 0.0;

  // Loading state flags for individual data sections
  bool _isPartnersLoading = false;
  bool _isProjectManagersLoading = false;
  bool _isAgentsLoading = false;
  bool _isSiteDataLoading = false;

  // Scroll controllers for tables
  final ScrollController _partnersTableScrollController = ScrollController();
  final ScrollController _projectManagersTableScrollController =
      ScrollController();
  final ScrollController _layoutPlotsTableScrollController = ScrollController();
  final ScrollController _agentsTableScrollController = ScrollController();
  final ScrollController _compensationTableScrollController =
      ScrollController();
  final ScrollController _amenityAgentTableScrollController =
      ScrollController();
  final ScrollController _amenityAreaTableScrollController = ScrollController();
  final Map<int, ScrollController> _siteLayoutTableScrollControllers = {};

  // Tab state
  DashboardTab _activeTab = DashboardTab.overview;

  // Sales Activity filter state
  String _selectedTimeFilter = '1D';

  // Layouts toolbar state (Site tab)
  final Set<int> _collapsedLayouts = {};
  double _tableZoomLevel = 1.0;
  String _selectedLayoutFilter = 'All';
  bool _isAmenityAreaSectionCollapsed = false;
  String _selectedAmenityFilter = 'All';

  // Compensation Layouts toolbar state (Agents tab)
  final Set<int> _collapsedCompensationLayouts = {};
  double _compensationTableZoomLevel = 1.0;
  String _selectedCompensationLayoutFilter = 'All';

  String get _perAreaFeeLabel => AreaUnitUtils.perAreaFeeLabel(_isSqm);

  double _parsePlotNumeric(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value.toDouble();
    final normalized = value
        .toString()
        .replaceAll(',', '')
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .trim();
    return double.tryParse(normalized) ?? 0.0;
  }

  bool _hasPaymentMethod(Map<String, dynamic> plot) {
    final payments = plot['payments'] as List<dynamic>? ?? const [];
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

  bool _isSoldPlotCompleteForDashboard(Map<String, dynamic> plot) {
    final salePrice = _parsePlotNumeric(plot['sale_price']);
    final buyerName =
        (plot['buyer_name'] ?? plot['buyerName'] ?? '').toString().trim();
    final agentName =
        (plot['agent_name'] ?? plot['agent'] ?? '').toString().trim();
    final saleDate =
        (plot['sale_date'] ?? plot['saleDate'] ?? '').toString().trim();

    return salePrice > 0 &&
        buyerName.isNotEmpty &&
        agentName.isNotEmpty &&
        saleDate.isNotEmpty &&
        _hasPaymentMethod(plot);
  }

  bool _shouldIncludePlotInDashboard(Map<String, dynamic> plot) {
    // Show every persisted plot row in dashboard even when partially filled
    // in Plot Status. Missing fields can render as empty values, but the row
    // (including status) remains visible.
    return true;
  }

  @override
  void initState() {
    super.initState();
    _notifyLoadingState(true);
    if (widget.projectId != null) {
      _loadDashboardData();
    } else {
      setState(() {
        _isLoading = false;
      });
      _notifyLoadingState(false);
    }
  }

  @override
  void didUpdateWidget(DashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.projectId != oldWidget.projectId) {
      if (widget.projectId != null) {
        _loadDashboardData();
      } else {
        setState(() {
          _dashboardData = null;
          _amenityAreaRows = [];
          _isLoading = false;
        });
        _notifyLoadingState(false);
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _partnersTableScrollController.dispose();
    _projectManagersTableScrollController.dispose();
    _layoutPlotsTableScrollController.dispose();
    _agentsTableScrollController.dispose();
    _compensationTableScrollController.dispose();
    _amenityAgentTableScrollController.dispose();
    _amenityAreaTableScrollController.dispose();
    for (final controller in _siteLayoutTableScrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  ScrollController _getSiteLayoutTableScrollController(int layoutIndex) {
    return _siteLayoutTableScrollControllers.putIfAbsent(
      layoutIndex,
      () => ScrollController(),
    );
  }

  bool _isDashboardLoadCurrent(int generation) =>
      mounted && generation == _dashboardLoadGeneration;

  String _normalizeNumericString(dynamic value) {
    final raw = (value ?? '').toString().trim();
    if (raw.isEmpty) return '';
    final parsed = double.tryParse(raw.replaceAll(',', ''));
    if (parsed == null) return raw;
    return parsed.toString();
  }

  bool _draftMatchesRow(
    Map<String, dynamic> draft,
    Map<String, dynamic>? row,
  ) {
    if (row == null) return false;

    final draftComp = (draft['compensation'] ?? '').toString().trim();
    final draftEarn = (draft['earningType'] ?? '').toString().trim();
    final rowComp = (row['compensation_type'] ?? '').toString().trim();
    final rowEarn = (row['earning_type'] ?? '').toString().trim();

    if (draftComp.isNotEmpty && rowComp != draftComp) return false;
    if (draftComp == 'Percentage Bonus' &&
        draftEarn.isNotEmpty &&
        rowEarn != draftEarn &&
        rowEarn != 'Selling Price Per Plot' &&
        rowEarn != 'Profit Per Plot') {
      return false;
    }

    final pairs = <List<dynamic>>[
      [draft['percentage'], row['percentage']],
      [draft['fixedFee'], row['fixed_fee']],
      [draft['monthlyFee'], row['monthly_fee']],
      [draft['months'], row['months']],
      [draft['perSqftFee'], row['per_sqft_fee']],
    ];
    for (final pair in pairs) {
      final left = _normalizeNumericString(pair[0]);
      final right = _normalizeNumericString(pair[1]);
      if (left.isNotEmpty && left != right) return false;
    }

    return true;
  }

  Future<bool> _hasPendingCompensationDraftMismatch() async {
    if (widget.projectId == null || widget.projectId!.trim().isEmpty) {
      return false;
    }
    final key = 'project_${widget.projectId}_pending_compensation_draft';
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return false;

    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }

    final savedAt = DateTime.tryParse((parsed['savedAt'] ?? '').toString());
    if (savedAt == null) return false;
    final age = DateTime.now().difference(savedAt);
    if (age > const Duration(seconds: 20)) return false;

    final managerDrafts = (parsed['managers'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        const <Map<String, dynamic>>[];
    final agentDrafts = (parsed['agents'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        const <Map<String, dynamic>>[];

    Map<String, dynamic>? findByIdOrName(
      List<Map<String, dynamic>> rows,
      String id,
      String name,
    ) {
      if (id.isNotEmpty) {
        for (final row in rows) {
          if ((row['id'] ?? '').toString() == id) return row;
        }
      }
      final lowered = name.trim().toLowerCase();
      if (lowered.isEmpty) return null;
      for (final row in rows) {
        if ((row['name'] ?? '').toString().trim().toLowerCase() == lowered) {
          return row;
        }
      }
      return null;
    }

    for (final draft in managerDrafts) {
      final id = (draft['id'] ?? '').toString();
      final name = (draft['name'] ?? '').toString();
      final row = findByIdOrName(_projectManagers, id, name);
      if (!_draftMatchesRow(draft, row)) {
        return true;
      }
    }

    for (final draft in agentDrafts) {
      final id = (draft['id'] ?? '').toString();
      final name = (draft['name'] ?? '').toString();
      final row = findByIdOrName(_agents, id, name);
      if (!_draftMatchesRow(draft, row)) {
        return true;
      }
    }

    return false;
  }

  Future<bool> _hasUnsyncedLocalEdits() async {
    if (widget.projectId == null || widget.projectId!.trim().isEmpty) {
      return false;
    }
    final prefs = await SharedPreferences.getInstance();
    final localEditMs =
        prefs.getInt('project_${widget.projectId}_last_local_edit_ms') ?? 0;
    final remoteSaveMs =
        prefs.getInt('project_${widget.projectId}_last_remote_save_ms') ?? 0;
    return localEditMs > remoteSaveMs;
  }

  double _toDouble(dynamic value) {
    if (value == null) return 0.0;
    final raw = value.toString().replaceAll(',', '').trim();
    return double.tryParse(raw) ?? 0.0;
  }

  String _normalizePartnerName(dynamic value) {
    return (value ?? '').toString().trim().toLowerCase();
  }

  Future<void> _applyUnsyncedLocalDraftsIfAny({int? loadGeneration}) async {
    if (widget.projectId == null || widget.projectId!.trim().isEmpty) return;
    if (!await _hasUnsyncedLocalEdits()) return;

    final prefs = await SharedPreferences.getInstance();
    final compRaw = prefs
        .getString('project_${widget.projectId}_pending_compensation_draft');
    final partnerExpenseRaw = prefs
        .getString('project_${widget.projectId}_pending_partner_expense_draft');
    // Preserve plot assignment visibility when overlaying local drafts.
    // Use already-loaded persisted site/partner data as assignment source.
    final assignedPlotsByPartner = <String, List<String>>{};
    final assignedPlotsSeen = <String, Set<String>>{};

    void addAssignedPlot(String partnerName, String plotNumber) {
      final normalized = _normalizePartnerName(partnerName);
      final normalizedPlot = plotNumber.trim();
      if (normalized.isEmpty || normalizedPlot.isEmpty) return;
      assignedPlotsByPartner.putIfAbsent(normalized, () => <String>[]);
      assignedPlotsSeen.putIfAbsent(normalized, () => <String>{});
      if (assignedPlotsSeen[normalized]!.add(normalizedPlot)) {
        assignedPlotsByPartner[normalized]!.add(normalizedPlot);
      }
    }

    for (final layout in _siteLayouts) {
      final plots = (layout['plots'] as List?) ?? const [];
      for (final plot in plots) {
        final plotMap = Map<String, dynamic>.from(plot as Map);
        final plotNumber =
            (plotMap['plot_number'] ?? plotMap['plotNumber'] ?? '')
                .toString()
                .trim();
        final plotPartners = ((plotMap['partners'] as List?) ?? const [])
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty);
        for (final partnerName in plotPartners) {
          addAssignedPlot(partnerName, plotNumber);
        }
      }
    }

    for (final partner in _partners) {
      final partnerName = (partner['name'] ?? '').toString().trim();
      final assignedPlots = (partner['assignedPlots'] as List?) ?? const [];
      for (final plot in assignedPlots) {
        addAssignedPlot(partnerName, plot.toString());
      }
    }

    final localPartners = <Map<String, dynamic>>[];
    if (partnerExpenseRaw != null && partnerExpenseRaw.trim().isNotEmpty) {
      try {
        final parsed = jsonDecode(partnerExpenseRaw) as Map<String, dynamic>;
        final partnersRaw = (parsed['partners'] as List?) ?? const [];

        for (int i = 0; i < partnersRaw.length; i++) {
          final p = Map<String, dynamic>.from(partnersRaw[i] as Map);
          final name = (p['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          final assignedPlots = assignedPlotsByPartner[_normalizePartnerName(
                name,
              )] ??
              const <String>[];
          localPartners.add({
            'name': name,
            'amount': _toDouble(p['amount']),
            'assignedPlots': List<String>.from(assignedPlots),
            'plotCount': assignedPlots.length,
          });
        }
      } catch (_) {}
    }

    final localProjectManagers = <Map<String, dynamic>>[];
    final localAgents = <Map<String, dynamic>>[];
    if (compRaw != null && compRaw.trim().isNotEmpty) {
      try {
        final parsed = jsonDecode(compRaw) as Map<String, dynamic>;
        final managersRaw = (parsed['managers'] as List?) ?? const [];
        final agentsRaw = (parsed['agents'] as List?) ?? const [];

        for (final row in managersRaw) {
          final m = Map<String, dynamic>.from(row as Map);
          final name = (m['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          localProjectManagers.add({
            'id': m['id'],
            'name': name,
            'compensation_type': (m['compensation'] ?? '').toString(),
            'earning_type': (m['earningType'] ?? '').toString(),
            'percentage': _toDouble(m['percentage']),
            'fixed_fee': _toDouble(m['fixedFee']),
            'monthly_fee': _toDouble(m['monthlyFee']),
            'months': int.tryParse((m['months'] ?? '').toString()),
          });
        }

        for (final row in agentsRaw) {
          final a = Map<String, dynamic>.from(row as Map);
          final name = (a['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          localAgents.add({
            'id': a['id'],
            'name': name,
            'compensation_type': (a['compensation'] ?? '').toString(),
            'earning_type': (a['earningType'] ?? '').toString(),
            'percentage': _toDouble(a['percentage']),
            'fixed_fee': _toDouble(a['fixedFee']),
            'monthly_fee': _toDouble(a['monthlyFee']),
            'months': int.tryParse((a['months'] ?? '').toString()),
            'per_sqft_fee': _toDouble(a['perSqftFee']),
            'per_sqm_fee': null,
          });
        }
      } catch (_) {}
    }

    if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
      return;
    }

    if (localPartners.isEmpty &&
        localProjectManagers.isEmpty &&
        localAgents.isEmpty) {
      return;
    }

    setState(() {
      if (localPartners.isNotEmpty) {
        _partners = localPartners;
      }
      if (localProjectManagers.isNotEmpty) {
        _projectManagers = localProjectManagers;
      }
      if (localAgents.isNotEmpty) {
        _agents = localAgents;
      }
    });
  }

  Future<void> _loadDashboardData({int retryAttempt = 0}) async {
    if (widget.projectId == null) return;
    final loadGeneration = ++_dashboardLoadGeneration;
    if (mounted) {
      setState(() {
        _isLoading = true;
        _dashboardData = null;
        _siteLayouts = [];
        _partners = [];
        _projectManagers = [];
        _agents = [];
        _compensationLayouts = [];
        _isPartnersLoading = true;
        _isProjectManagersLoading = true;
        _isAgentsLoading = true;
        _isSiteDataLoading = true;
      });
    }
    _notifyLoadingState(true);

    try {
      await ProjectDetailsPage.pendingSave.timeout(const Duration(seconds: 8));
    } catch (_) {
      // Continue with latest DB read even if pending save could not complete in time.
    }
    if (!_isDashboardLoadCurrent(loadGeneration)) return;

    // Hard sync gate:
    // Do not reload dashboard sections while there are unsynced local edits.
    // This prevents showing stale DB snapshots while Data Entry changes are
    // still pending remote persistence.
    const maxSyncRetries = 6;
    final hasUnsyncedBeforeLoad = await _hasUnsyncedLocalEdits();
    if (hasUnsyncedBeforeLoad) {
      if (retryAttempt >= maxSyncRetries) {
        // Stop blocking forever. Continue with DB load and local draft overlay.
        print(
            'Dashboard sync gate: max retries reached, continuing with local draft fallback');
      } else {
        final delay = const Duration(milliseconds: 700);
        await Future.delayed(delay);
        if (!_isDashboardLoadCurrent(loadGeneration)) return;
        return _loadDashboardData(retryAttempt: retryAttempt + 1);
      }
    }

    final projectId = widget.projectId!;
    _areaUnit = await AreaUnitService.getAreaUnit(widget.projectId);
    if (!_isDashboardLoadCurrent(loadGeneration)) return;

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) {
        if (!_isDashboardLoadCurrent(loadGeneration)) return;
        setState(() {
          _isLoading = false;
          _isSiteDataLoading = false;
        });
        _notifyLoadingState(false);
        return;
      }

      // Fetch project data
      final projectData = await _supabase
          .from('projects')
          .select()
          .eq('id', projectId)
          .eq('user_id', userId)
          .single();

      // Fetch expenses with category
      final expenses = await _supabase
          .from('expenses')
          .select('amount, category')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);

      // Fetch non-sellable areas
      final nonSellableAreas = await _supabase
          .from('non_sellable_areas')
          .select('area')
          .eq('project_id', projectId);

      // Fetch amenity areas
      List<dynamic> amenityAreas;
      try {
        amenityAreas = await _supabase
            .from('amenity_areas')
            .select(
                'id, name, area, all_in_cost, status, sale_price, sale_value, buyer_name, payment, agent_name, sale_date')
            .eq('project_id', projectId)
            .order('sort_order', ascending: true)
            .order('created_at', ascending: true)
            .order('id', ascending: true);
      } catch (_) {
        // Fallback for older schemas where sales/status columns may be missing.
        amenityAreas = await _supabase
            .from('amenity_areas')
            .select('id, name, area, all_in_cost')
            .eq('project_id', projectId)
            .order('sort_order', ascending: true)
            .order('created_at', ascending: true)
            .order('id', ascending: true);
      }

      // Fetch layouts
      final layouts = await _supabase
          .from('layouts')
          .select('id, name')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);

      final layoutIds = layouts.map((l) => l['id'] as String).toList();

      // Fetch plots - optimized: single query for all plots
      List<Map<String, dynamic>> allPlots = [];
      if (layoutIds.isNotEmpty) {
        // Use 'in' filter to get all plots in one query instead of multiple
        final plots = await _supabase
            .from('plots')
            .select(
                'id, layout_id, area, status, sale_price, buyer_name, agent_name, sale_date, payments')
            .inFilter('layout_id', layoutIds)
            .order('created_at', ascending: true);
        allPlots = List<Map<String, dynamic>>.from(plots);
      }
      final dashboardPlots =
          allPlots.where(_shouldIncludePlotInDashboard).toList();

      // Calculate metrics
      final estimatedDevelopmentCost =
          (projectData['estimated_development_cost'] as num?)?.toDouble() ??
              0.0;

      final totalExpenses = expenses.fold<double>(
        0.0,
        (sum, expense) =>
            sum + ((expense['amount'] as num?)?.toDouble() ?? 0.0),
      );

      final totalArea = (projectData['total_area'] as num?)?.toDouble() ?? 0.0;
      final approvedSellingArea =
          (projectData['selling_area'] as num?)?.toDouble() ?? 0.0;

      final nonSellableArea = nonSellableAreas.fold<double>(
        0.0,
        (sum, area) => sum + ((area['area'] as num?)?.toDouble() ?? 0.0),
      );

      final amenityAreaRows = amenityAreas
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      final validAmenityAreas = amenityAreaRows.where((row) {
        final name = (row['name'] ?? '').toString().trim();
        final areaSqft = (row['area'] as num?)?.toDouble() ?? 0.0;
        final allInCostPerSqft =
            (row['all_in_cost'] as num?)?.toDouble() ?? 0.0;
        return name.isNotEmpty || areaSqft > 0 || allInCostPerSqft > 0;
      }).toList();

      final totalAmenityAreaSqft = validAmenityAreas.fold<double>(
        0.0,
        (sum, row) => sum + ((row['area'] as num?)?.toDouble() ?? 0.0),
      );
      final totalAmenityAreaValue = validAmenityAreas.fold<double>(
        0.0,
        (sum, row) {
          final areaSqft = (row['area'] as num?)?.toDouble() ?? 0.0;
          final allInCostPerSqft =
              (row['all_in_cost'] as num?)?.toDouble() ?? 0.0;
          return sum + (areaSqft * allInCostPerSqft);
        },
      );
      final amenityAllInCostPerSqft = totalAmenityAreaSqft > 0
          ? (totalAmenityAreaValue / totalAmenityAreaSqft)
          : 0.0;

      final sellingArea = approvedSellingArea;
      final allInCost = sellingArea > 0 ? totalExpenses / sellingArea : 0.0;

      final totalLayouts = layouts.length;
      final totalPlots = dashboardPlots.length;
      final availablePlots =
          dashboardPlots.where((p) => p['status'] == 'available').length;
      final soldPlots =
          dashboardPlots.where((p) => p['status'] == 'sold').length;
      final pendingPlots = dashboardPlots.where((p) {
        final status = (p['status'] ?? '').toString().toLowerCase();
        return status == 'reserved' || status == 'pending';
      }).length;
      final saleProgress =
          totalPlots > 0 ? (soldPlots / totalPlots) * 100 : 0.0;

      // Calculate total sales value = sum of (sale_price * area) for all sold plots
      final totalSalesValue =
          dashboardPlots.where((p) => p['status'] == 'sold').fold<double>(
        0.0,
        (sum, plot) {
          final salePrice = ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
          final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
          return sum + (salePrice * area);
        },
      );

      // Calculate sum of sale prices (per sqft) for all sold plots across all layouts
      final totalSalePriceSum =
          dashboardPlots.where((p) => p['status'] == 'sold').fold<double>(
        0.0,
        (sum, plot) {
          final salePrice = ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
          return sum + salePrice;
        },
      );

      // Average Sale Price = Sum of sale prices of all layouts / Number of plots sold
      final avgSalePricePerSqft =
          soldPlots > 0 ? totalSalePriceSum / soldPlots : 0.0;

      // Calculate sales by layout
      final salesByLayout = <Map<String, dynamic>>[];
      for (var layout in layouts) {
        final layoutId = layout['id'] as String;
        final layoutPlots =
            dashboardPlots.where((p) => p['layout_id'] == layoutId).toList();
        final layoutSoldPlots =
            layoutPlots.where((p) => p['status'] == 'sold').toList();
        // Calculate layout sales value = sum of (sale_price * area) for all sold plots in this layout
        final layoutSalesValue = layoutSoldPlots.fold<double>(
          0.0,
          (sum, plot) {
            final salePrice = ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
            final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
            return sum + (salePrice * area);
          },
        );
        final layoutSalePercentage = layoutPlots.isNotEmpty
            ? (layoutSoldPlots.length / layoutPlots.length) * 100
            : 0.0;

        salesByLayout.add({
          'name': layout['name'] as String,
          'totalPlots': layoutPlots.length,
          'soldPlots': layoutSoldPlots.length,
          'salesValue': layoutSalesValue,
          'salePercentage': layoutSalePercentage,
        });
      }

      // Set loading flags for data sections and store dashboard data
      if (!_isDashboardLoadCurrent(loadGeneration)) return;
      setState(() {
        _amenityAreaRows = amenityAreaRows;
        _dashboardData = {
          'estimatedDevelopmentCost': estimatedDevelopmentCost,
          'totalExpenses': totalExpenses,
          'expenses': expenses,
          'allInCost': allInCost,
          'totalArea': totalArea,
          'sellingArea': sellingArea,
          'nonSellableArea': nonSellableArea,
          'amenityAreaRowCount': amenityAreaRows.length,
          'amenityAreaCount': validAmenityAreas.length,
          'totalAmenityAreaSqft': totalAmenityAreaSqft,
          'amenityAllInCostPerSqft': amenityAllInCostPerSqft,
          'totalAmenityAreaValue': totalAmenityAreaValue,
          'totalLayouts': totalLayouts,
          'totalPlots': totalPlots,
          'availablePlots': availablePlots,
          'soldPlots': soldPlots,
          'pendingPlots': pendingPlots,
          'saleProgress': saleProgress,
          'totalSalesValue': totalSalesValue,
          'avgSalePricePerSqft': avgSalePricePerSqft,
          'salesByLayout': salesByLayout,
        };
        _isPartnersLoading = true;
        _isProjectManagersLoading = true;
        _isAgentsLoading = true;
        if (_activeTab == DashboardTab.site) {
          _isSiteDataLoading = true;
        }
      });

      // Load all required data in parallel for better performance
      // Note: Always load compensation data (partners, project managers, agents) for net profit calculation
      // regardless of the active tab
      try {
        await Future.wait([
          _loadPartnersData(loadGeneration: loadGeneration),
          _loadProjectManagersData(loadGeneration: loadGeneration),
          _loadAgentsData(loadGeneration: loadGeneration),
          _loadCompensationData(loadGeneration: loadGeneration),
          _loadSiteData(
              loadGeneration:
                  loadGeneration), // Always load site data to support agent sold plot checking
        ]).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            print('Warning: Data loading timeout after 30 seconds');
            return [];
          },
        );
      } catch (e) {
        print('Error during parallel data loading: $e');
      }

      if (!_isDashboardLoadCurrent(loadGeneration)) return;

      // Gate again after section loads to avoid rendering partially stale data
      // if new unsynced edits appeared during async fetches.
      final hasUnsyncedAfterSections = await _hasUnsyncedLocalEdits();
      if (hasUnsyncedAfterSections) {
        if (retryAttempt < maxSyncRetries) {
          await Future.delayed(const Duration(milliseconds: 700));
          if (!_isDashboardLoadCurrent(loadGeneration)) return;
          return _loadDashboardData(retryAttempt: retryAttempt + 1);
        } else {
          print(
              'Dashboard post-load sync gate: max retries reached, using local draft fallback');
        }
      }

      await _applyUnsyncedLocalDraftsIfAny(loadGeneration: loadGeneration);
      if (!_isDashboardLoadCurrent(loadGeneration)) return;

      final hasDraftMismatch = await _hasPendingCompensationDraftMismatch();
      const maxConsistencyRetries = 8;
      if (hasDraftMismatch && retryAttempt < maxConsistencyRetries) {
        await Future.delayed(const Duration(milliseconds: 700));
        if (!_isDashboardLoadCurrent(loadGeneration)) return;
        return _loadDashboardData(retryAttempt: retryAttempt + 1);
      }

      // Calculate and store all profit metrics after all compensation data is loaded
      if (!_isDashboardLoadCurrent(loadGeneration)) return;
      // Gross Profit = _calculateTotalGrossProfit() (same logic as _buildProfitAndROISection - only counts cost of SOLD plots)
      final grossProfit = _calculateTotalGrossProfit();

      // Total Compensation = Project Managers + Agents (same calculation as in _buildProfitAndROISection)
      final totalPMCompensation = _calculateTotalProjectManagersCompensation();
      final totalAgentCompensation = _calculateTotalAgentsCompensation();
      final totalCompensation = totalPMCompensation + totalAgentCompensation;

      // Net Profit = Gross Profit - Total Compensation (same as overview section)
      final netProfit = grossProfit - totalCompensation;

      // Calculate Profit Margin (%) = (Net Profit / Total Sales Value) * 100
      final profitMargin =
          totalSalesValue > 0 ? (netProfit / totalSalesValue) * 100 : 0.0;

      // Calculate ROI (%) = (Net Profit / Total Expenses) * 100
      final roi = totalExpenses > 0 ? (netProfit / totalExpenses) * 100 : 0.0;

      print(
          'DEBUG Dashboard: Calculating metrics - grossProfit: $grossProfit, netProfit: $netProfit, profitMargin: $profitMargin, roi: $roi');
      print(
          'DEBUG Dashboard: Compensation - PM: $totalPMCompensation, Agent: $totalAgentCompensation, Total: $totalCompensation');

      // Update _dashboardData with all profit/ROI/compensation metrics and mark loading as complete
      if (!_isDashboardLoadCurrent(loadGeneration)) return;
      setState(() {
        _dashboardData = {
          ..._dashboardData!,
          'grossProfit': grossProfit,
          'netProfit': netProfit,
          'profitMargin': profitMargin,
          'roi': roi,
          'totalProjectManagerCompensation': totalPMCompensation,
          'totalAgentCompensation': totalAgentCompensation,
          'totalCompensation': totalCompensation,
        };
        _isLoading = false;
      });
      _notifyLoadingState(false);

      // Store dashboard data in SharedPreferences for use by ReportPage (only scalar values, not lists/objects)
      try {
        final prefs = await SharedPreferences.getInstance();
        if (!_isDashboardLoadCurrent(loadGeneration)) return;
        final dataToSave = {
          'totalArea': _dashboardData!['totalArea'],
          'sellingArea': _dashboardData!['sellingArea'],
          'nonSellableArea': _dashboardData!['nonSellableArea'],
          'totalLayouts': _dashboardData!['totalLayouts'],
          'totalPlots': _dashboardData!['totalPlots'],
          'availablePlots': _dashboardData!['availablePlots'],
          'soldPlots': _dashboardData!['soldPlots'],
          'pendingPlots': _dashboardData!['pendingPlots'],
          'totalSalesValue': _dashboardData!['totalSalesValue'],
          'avgSalePricePerSqft': _dashboardData!['avgSalePricePerSqft'],
          'avgSalesPrice':
              _dashboardData!['avgSalePricePerSqft'], // For compatibility
          'totalExpenses': _dashboardData!['totalExpenses'],
          'allInCost': _dashboardData!['allInCost'],
          'amenityAreaCount': _dashboardData!['amenityAreaCount'] ?? 0,
          'totalAmenityAreaSqft': _dashboardData!['totalAmenityAreaSqft'] ?? 0,
          'amenityAllInCostPerSqft':
              _dashboardData!['amenityAllInCostPerSqft'] ?? 0,
          'totalAmenityAreaValue':
              _dashboardData!['totalAmenityAreaValue'] ?? 0,
          'estimatedDevelopmentCost':
              _dashboardData!['estimatedDevelopmentCost'] ?? 0,
          'grossProfit': grossProfit,
          'netProfit': netProfit,
          'profitMargin': profitMargin,
          'roi': roi,
          'totalProjectManagerCompensation': totalPMCompensation,
          'totalAgentCompensation': totalAgentCompensation,
          'totalCompensation': totalCompensation,
        };
        print(
            'DEBUG Dashboard: Saving to SharedPreferences with key: dashboard_data_${widget.projectId}');
        print('DEBUG Dashboard: Data being saved: $dataToSave');
        await prefs.setString(
            'dashboard_data_${widget.projectId}', jsonEncode(dataToSave));
        print(
            'DEBUG Dashboard: Successfully saved dashboard data to SharedPreferences');
      } catch (e) {
        print(
            'Warning: Could not save dashboard data to SharedPreferences: $e');
      }
    } catch (e) {
      print('Error loading dashboard data: $e');
      if (!_isDashboardLoadCurrent(loadGeneration)) return;
      setState(() {
        _amenityAreaRows = [];
        _isLoading = false;
        _isPartnersLoading = false;
        _isProjectManagersLoading = false;
        _isAgentsLoading = false;
        _isSiteDataLoading = false;
      });
      _notifyLoadingState(false);
    }
  }

  Future<void> _loadSiteData({int? loadGeneration}) async {
    if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
      return;
    }
    if (widget.projectId == null || _dashboardData == null) return;
    final projectId = widget.projectId!;

    // Set loading flag at the start if not already set
    if (!_isSiteDataLoading &&
        (loadGeneration == null || _isDashboardLoadCurrent(loadGeneration))) {
      setState(() {
        _isSiteDataLoading = true;
      });
    }

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      // Fetch layouts with full plot details
      final layouts = await _supabase
          .from('layouts')
          .select('id, name')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);

      final layoutIds = layouts.map((l) => l['id'] as String).toList();
      if (layoutIds.isEmpty) {
        if (loadGeneration != null &&
            !_isDashboardLoadCurrent(loadGeneration)) {
          return;
        }
        setState(() {
          _siteLayouts = [];
          _isSiteDataLoading = false;
        });
        return;
      }

      // Optimize: Fetch all plots in one query, ordered by creation time to maintain consistent order
      final allPlots = await _supabase
          .from('plots')
          .select('*')
          .inFilter('layout_id', layoutIds)
          .order('created_at', ascending: true);

      // Get all plot IDs to fetch partners in one query
      final plotIds = allPlots.map((p) => p['id'] as String).toList();

      // Fetch all plot partners in one query
      final allPlotPartners = plotIds.isNotEmpty
          ? await _supabase
              .from('plot_partners')
              .select('plot_id, partner_name')
              .inFilter('plot_id', plotIds)
          : <Map<String, dynamic>>[];

      // Group partners by plot_id
      final partnersByPlotId = <String, List<String>>{};
      for (var partner in allPlotPartners) {
        final plotId = partner['plot_id'] as String;
        final partnerName = partner['partner_name'] as String;
        if (!partnersByPlotId.containsKey(plotId)) {
          partnersByPlotId[plotId] = [];
        }
        partnersByPlotId[plotId]!.add(partnerName);
      }

      // Build site layouts with plots
      final siteLayouts = <Map<String, dynamic>>[];
      for (var layout in layouts) {
        final layoutId = layout['id'] as String;
        final layoutPlots = allPlots
            .where((p) => p['layout_id'] == layoutId)
            .where(_shouldIncludePlotInDashboard)
            .map((plot) => {
                  ...plot,
                  'partners': partnersByPlotId[plot['id'] as String] ?? [],
                })
            .toList();

        siteLayouts.add({
          'id': layoutId,
          'name': layout['name'] as String,
          'plots': layoutPlots,
        });
      }

      // Fetch project managers and calculate compensation
      final projectManagers = await _supabase
          .from('project_managers')
          .select('*')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);

      double projectManagersCompensation = 0.0;
      // Calculate compensation based on type (simplified - you may need to adjust based on your compensation logic)
      for (var manager in projectManagers) {
        final compensationType = manager['compensation_type'] as String? ?? '';
        final compensation =
            (manager['compensation'] as num?)?.toDouble() ?? 0.0;
        // Add logic here to calculate based on compensation type
        projectManagersCompensation += compensation;
      }

      // Fetch agents and calculate compensation
      final agents = await _supabase
          .from('agents')
          .select('*')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);

      double agentsCompensation = 0.0;
      // Calculate compensation based on type (simplified - you may need to adjust based on your compensation logic)
      for (var agent in agents) {
        final compensationType = agent['compensation_type'] as String? ?? '';
        final compensation = (agent['compensation'] as num?)?.toDouble() ?? 0.0;
        // Add logic here to calculate based on compensation type
        agentsCompensation += compensation;
      }

      if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
        return;
      }
      setState(() {
        _siteLayouts = siteLayouts;
        _projectManagersCompensation = projectManagersCompensation;
        _agentsCompensation = agentsCompensation;
        _isSiteDataLoading = false;
      });
      await _applyUnsyncedLocalDraftsIfAny(loadGeneration: loadGeneration);
    } catch (e) {
      print('Error loading site data: $e');
      if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
        return;
      }
      setState(() {
        _isSiteDataLoading = false;
      });
    }
  }

  Future<void> _loadPartnersData({int? loadGeneration}) async {
    if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
      return;
    }
    if (widget.projectId == null) return;
    final projectId = widget.projectId!;

    try {
      final partners = await _supabase
          .from('partners')
          .select('*')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);

      // Fetch all layouts and plots for this project to get plot assignments
      final layouts = await _supabase
          .from('layouts')
          .select('id, name')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);

      final layoutIds = layouts.map((l) => l['id'] as String).toList();

      final plots = layoutIds.isNotEmpty
          ? await _supabase
              .from('plots')
              .select('id, plot_number, layout_id')
              .inFilter('layout_id', layoutIds)
              .order('created_at', ascending: true)
          : <Map<String, dynamic>>[];

      final plotIds = plots.map((p) => p['id'] as String).toList();

      // Fetch plot-partner assignments
      final plotPartners = plotIds.isNotEmpty
          ? await _supabase
              .from('plot_partners')
              .select('plot_id, partner_name')
              .inFilter('plot_id', plotIds)
          : <Map<String, dynamic>>[];

      // Build a map of plot_id to plot_number
      final plotIdToNumber = <String, String>{};
      for (var plot in plots) {
        plotIdToNumber[plot['id'] as String] = plot['plot_number'] as String;
      }

      // Group plots by partner name
      final plotsByPartner = <String, List<String>>{};
      for (var assignment in plotPartners) {
        final partnerName = _normalizePartnerName(assignment['partner_name']);
        final plotId = assignment['plot_id'] as String;
        final plotNumber = plotIdToNumber[plotId] ?? '';

        if (!plotsByPartner.containsKey(partnerName)) {
          plotsByPartner[partnerName] = [];
        }
        if (plotNumber.isNotEmpty) {
          plotsByPartner[partnerName]!.add(plotNumber);
        }
      }

      if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
        return;
      }
      setState(() {
        _partners = partners.asMap().entries.map((entry) {
          final index = entry.key;
          final p = entry.value;
          final rawPartnerName = (p['name'] ?? '').toString();
          final assignedPlots =
              plotsByPartner[_normalizePartnerName(rawPartnerName)] ?? [];
          final displayName = rawPartnerName.trim().isEmpty
              ? 'Unnamed Partner ${index + 1}'
              : rawPartnerName;
          return {
            'name': displayName,
            'amount': (p['amount'] as num?)?.toDouble() ?? 0.0,
            'assignedPlots': assignedPlots,
            'plotCount': assignedPlots.length,
          };
        }).toList();
        _isPartnersLoading = false;
      });
      await _applyUnsyncedLocalDraftsIfAny(loadGeneration: loadGeneration);
    } catch (e) {
      print('Error loading partners data: $e');
      if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
        return;
      }
      setState(() {
        _isPartnersLoading = false;
      });
    }
  }

  Future<void> _loadProjectManagersData({int? loadGeneration}) async {
    if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
      return;
    }
    if (widget.projectId == null) return;
    final projectId = widget.projectId!;

    try {
      final projectManagers = await _supabase
          .from('project_managers')
          .select('*')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);

      if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
        return;
      }
      setState(() {
        _projectManagers = projectManagers
            .map((pm) => {
                  'id': pm['id'],
                  'name': (pm['name'] ?? '').toString(),
                  'compensation_type':
                      (pm['compensation_type'] ?? '').toString(),
                  'earning_type': (pm['earning_type'] ?? '').toString(),
                  'percentage': (pm['percentage'] as num?)?.toDouble(),
                  'fixed_fee': (pm['fixed_fee'] as num?)?.toDouble(),
                  'monthly_fee': (pm['monthly_fee'] as num?)?.toDouble(),
                  'months': (pm['months'] as num?)?.toInt(),
                })
            .toList();
        _isProjectManagersLoading = false;
      });
      await _applyUnsyncedLocalDraftsIfAny(loadGeneration: loadGeneration);
    } catch (e) {
      print('Error loading project managers data: $e');
      if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
        return;
      }
      setState(() {
        _isProjectManagersLoading = false;
      });
    }
  }

  Future<void> _loadAgentsData({int? loadGeneration}) async {
    if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
      return;
    }
    if (widget.projectId == null) return;
    final projectId = widget.projectId!;

    try {
      final agents = await _supabase
          .from('agents')
          .select('*')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);

      if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
        return;
      }
      setState(() {
        _agents = agents
            .map((agent) => {
                  'id': agent['id'],
                  'name': (agent['name'] ?? '').toString(),
                  'compensation_type':
                      (agent['compensation_type'] ?? '').toString(),
                  'earning_type': (agent['earning_type'] ?? '').toString(),
                  'percentage': (agent['percentage'] as num?)?.toDouble(),
                  'fixed_fee': (agent['fixed_fee'] as num?)?.toDouble(),
                  'monthly_fee': (agent['monthly_fee'] as num?)?.toDouble(),
                  'months': (agent['months'] as num?)?.toInt(),
                  'per_sqft_fee': (agent['per_sqft_fee'] as num?)?.toDouble(),
                  'per_sqm_fee': (agent['per_sqm_fee'] as num?)?.toDouble(),
                })
            .toList();
        _isAgentsLoading = false;
      });
      await _applyUnsyncedLocalDraftsIfAny(loadGeneration: loadGeneration);
    } catch (e) {
      print('Error loading agents data: $e');
      if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
        return;
      }
      setState(() {
        _isAgentsLoading = false;
      });
    }
  }

  Future<void> _loadCompensationData({int? loadGeneration}) async {
    if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
      return;
    }
    if (widget.projectId == null || _dashboardData == null) return;
    final projectId = widget.projectId!;

    try {
      final userId = _supabase.auth.currentUser?.id;
      if (userId == null) return;

      // Fetch layouts
      final layouts = await _supabase
          .from('layouts')
          .select('id, name')
          .eq('project_id', projectId)
          .order('created_at', ascending: true);

      final layoutIds = layouts.map((l) => l['id'] as String).toList();
      final compensationLayouts = <Map<String, dynamic>>[];
      double totalCompensation = 0.0;

      for (var layout in layouts) {
        final layoutId = layout['id'] as String;
        final plots = await _supabase
            .from('plots')
            .select('*')
            .eq('layout_id', layoutId)
            .order('created_at', ascending: true);
        final dashboardPlots =
            plots.where(_shouldIncludePlotInDashboard).toList();

        // Load agent information for each plot
        final plotsWithCompensation = <Map<String, dynamic>>[];
        for (var plot in dashboardPlots) {
          final plotId = plot['id'] as String;

          // Get agent for this plot from agent_blocks
          final agentBlocks = await _supabase
              .from('agent_blocks')
              .select('agent_id')
              .eq('plot_id', plotId)
              .limit(1);

          String? agentName;
          double plotCompensation = 0.0;

          if (agentBlocks.isNotEmpty) {
            final agentId = agentBlocks[0]['agent_id'] as String;
            final agent = await _supabase
                .from('agents')
                .select(
                    'name, compensation_type, earning_type, percentage, fixed_fee, monthly_fee, months, per_sqft_fee')
                .eq('id', agentId)
                .single();

            agentName = agent['name'] as String?;

            // Calculate compensation using same logic as table
            final area = (plot['area'] as num?)?.toDouble() ?? 0.0;
            final plotStatus =
                (plot['status'] as String? ?? 'available').toLowerCase();
            final compensationType =
                agent['compensation_type'] as String? ?? '';

            if (plotStatus == 'sold') {
              if (compensationType == 'Fixed Fee') {
                plotCompensation = agent['fixed_fee'] as double? ?? 0.0;
              } else if (compensationType == 'Monthly Fee') {
                final monthlyFee = agent['monthly_fee'] as double? ?? 0.0;
                final months = agent['months'] as int? ?? 0;
                plotCompensation = monthlyFee * months;
              } else if (compensationType == 'Per Sqft Fee' ||
                  compensationType == 'Per Sqm Fee') {
                if (_isSqm) {
                  final perSqmFee = agent['per_sqm_fee'] as double? ?? 0.0;
                  final areaSqm =
                      AreaUnitUtils.areaFromSqftToDisplay(area, true);
                  plotCompensation = perSqmFee * areaSqm;
                } else {
                  final perSqftFee = agent['per_sqft_fee'] as double? ?? 0.0;
                  plotCompensation = perSqftFee * area;
                }
              } else if (compensationType == 'Percentage Bonus') {
                final percentage = agent['percentage'] as double? ?? 0.0;
                final earningType = agent['earning_type'] as String? ?? '';
                final salePrice =
                    ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
                final saleValue = salePrice * area;
                final allInCost = _dashboardData!['allInCost'] as double;
                final plotCost = area * allInCost;
                final plotProfit = saleValue - plotCost;

                // Check for "Selling Price Per Plot"
                final isSellingPriceBased =
                    earningType == 'Selling Price Per Plot' ||
                        earningType == '% of Selling Price per Plot' ||
                        (earningType.toLowerCase().contains('selling price') &&
                            earningType.toLowerCase().contains('plot'));

                if (isSellingPriceBased) {
                  plotCompensation = (saleValue * percentage) / 100;
                } else {
                  // Apply percentage to plot profit
                  plotCompensation = (plotProfit * percentage) / 100;
                }
              }
            }
          } else {
            // Check if plot has agent_name directly
            agentName = plot['agent_name'] as String?;
          }

          // Only add compensation for sold plots
          final plotStatus =
              (plot['status'] as String? ?? 'available').toLowerCase();
          if (plotStatus == 'sold') {
            totalCompensation += plotCompensation;
          }

          plotsWithCompensation.add({
            ...plot,
            'agent_name': agentName,
            'compensation': plotCompensation,
          });
        }

        // Calculate layout totals
        final allInCost = _dashboardData!['allInCost'] as double;
        double totalArea = 0.0;
        double totalPlotCost = 0.0;
        double totalSaleValue = 0.0;
        int availablePlots = 0;
        int soldPlots = 0;

        for (var plot in plotsWithCompensation) {
          final area = (plot['area'] as num?)?.toDouble() ?? 0.0;
          final status =
              (plot['status'] as String? ?? 'available').toLowerCase();
          final salePrice = (plot['sale_price'] as num?)?.toDouble() ?? 0.0;

          totalArea += area;
          totalPlotCost += area * allInCost;

          if (status == 'sold') {
            soldPlots++;
            totalSaleValue += salePrice * area;
          } else {
            availablePlots++;
          }
        }

        final grossProfit = totalSaleValue - totalPlotCost;
        final layoutCompensation = plotsWithCompensation.fold<double>(
          0.0,
          (sum, plot) {
            final status =
                (plot['status'] as String? ?? 'available').toLowerCase();
            if (status == 'sold') {
              return sum + (plot['compensation'] as double? ?? 0.0);
            }
            return sum;
          },
        );

        compensationLayouts.add({
          'id': layoutId,
          'name': layout['name'] as String,
          'plots': plotsWithCompensation,
          'totalPlots': plotsWithCompensation.length,
          'availablePlots': availablePlots,
          'soldPlots': soldPlots,
          'grossProfit': grossProfit,
          'totalCompensation': layoutCompensation,
        });
      }

      if (loadGeneration != null && !_isDashboardLoadCurrent(loadGeneration)) {
        return;
      }
      setState(() {
        _compensationLayouts = compensationLayouts;
        _totalCompensation = totalCompensation;
      });
    } catch (e) {
      print('Error loading compensation data: $e');
    }
  }

  String _formatCurrency(double value) {
    if (value == 0) return '₹ 0.00';
    final isNegative = value < 0;
    final absValue = value.abs();

    // Format with Indian numbering system
    final parts = absValue.toStringAsFixed(2).split('.');
    final integerPart = parts[0];
    final decimalPart = parts[1];

    String formatted = '';
    final length = integerPart.length;

    if (length <= 3) {
      formatted = integerPart;
    } else {
      final lastThree = integerPart.substring(length - 3);
      final remaining = integerPart.substring(0, length - 3);

      // Add commas every 2 digits from right
      String formattedRemaining = '';
      for (int i = remaining.length - 1; i >= 0; i--) {
        if ((remaining.length - 1 - i) > 0 &&
            (remaining.length - 1 - i) % 2 == 0) {
          formattedRemaining = ',' + formattedRemaining;
        }
        formattedRemaining = remaining[i] + formattedRemaining;
      }

      formatted = formattedRemaining.isEmpty
          ? lastThree
          : '$formattedRemaining,$lastThree';
    }

    final sign = isNegative ? '-' : '';
    return '₹ $sign$formatted.$decimalPart';
  }

  String _formatCurrencyNumber(double value) {
    if (value == 0) return '0.00';
    final isNegative = value < 0;
    final absValue = value.abs();

    // Format with Indian numbering system (without rupee symbol)
    final parts = absValue.toStringAsFixed(2).split('.');
    final integerPart = parts[0];
    final decimalPart = parts[1];

    String formatted = '';
    final length = integerPart.length;

    if (length <= 3) {
      formatted = integerPart;
    } else {
      final lastThree = integerPart.substring(length - 3);
      final remaining = integerPart.substring(0, length - 3);

      // Add commas every 2 digits from right
      String formattedRemaining = '';
      for (int i = remaining.length - 1; i >= 0; i--) {
        if ((remaining.length - 1 - i) > 0 &&
            (remaining.length - 1 - i) % 2 == 0) {
          formattedRemaining = ',' + formattedRemaining;
        }
        formattedRemaining = remaining[i] + formattedRemaining;
      }

      formatted = formattedRemaining.isEmpty
          ? lastThree
          : '$formattedRemaining,$lastThree';
    }

    final sign = isNegative ? '-' : '';
    return '$sign$formatted.$decimalPart';
  }

  String _formatPercentageDisplay(double? value) {
    if (value == null) return '0';
    final formatted = value.toStringAsFixed(2);
    return formatted.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String _formatNumberNoDecimals(double value) {
    if (value == 0) return '0';
    final isNegative = value < 0;
    final roundedValue = value.abs().round();
    final formatted = _formatIndianInteger(roundedValue);
    return isNegative ? '-$formatted' : formatted;
  }

  // Format number with specified decimal places and Indian numbering
  String _formatNumberWithDecimals(double value, int decimals) {
    if (value == 0) return '0.${'0' * decimals}';
    final isNegative = value < 0;
    final absValue = value.abs();
    final formatted = absValue.toStringAsFixed(decimals);
    final parts = formatted.split('.');
    final integerPart = _formatIndianInteger(int.parse(parts[0]));
    final decimalPart = decimals > 0 ? '.${parts[1]}' : '';
    return isNegative
        ? '-$integerPart$decimalPart'
        : '$integerPart$decimalPart';
  }

  String _formatIndianInteger(int value) {
    final integerPart = value.toString();
    final length = integerPart.length;

    if (length <= 3) {
      return integerPart;
    }

    final lastThree = integerPart.substring(length - 3);
    final remaining = integerPart.substring(0, length - 3);

    String formattedRemaining = '';
    for (int i = remaining.length - 1; i >= 0; i--) {
      if ((remaining.length - 1 - i) > 0 &&
          (remaining.length - 1 - i) % 2 == 0) {
        formattedRemaining = ',' + formattedRemaining;
      }
      formattedRemaining = remaining[i] + formattedRemaining;
    }

    return formattedRemaining.isEmpty
        ? lastThree
        : '$formattedRemaining,$lastThree';
  }

  String _formatArea(double value) {
    if (value == 0) return '0.00';
    final isNegative = value < 0;
    final absValue = value.abs();

    // Format with Indian numbering system
    final parts = absValue.toStringAsFixed(2).split('.');
    final integerPart = parts[0];
    final decimalPart = parts[1];

    String formatted = '';
    final length = integerPart.length;

    if (length <= 3) {
      formatted = integerPart;
    } else {
      final lastThree = integerPart.substring(length - 3);
      final remaining = integerPart.substring(0, length - 3);

      // Add commas every 2 digits from right
      String formattedRemaining = '';
      for (int i = remaining.length - 1; i >= 0; i--) {
        if ((remaining.length - 1 - i) > 0 &&
            (remaining.length - 1 - i) % 2 == 0) {
          formattedRemaining = ',' + formattedRemaining;
        }
        formattedRemaining = remaining[i] + formattedRemaining;
      }

      formatted = formattedRemaining.isEmpty
          ? lastThree
          : '$formattedRemaining,$lastThree';
    }

    final sign = isNegative ? '-' : '';
    return '$sign$formatted.$decimalPart';
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

  Widget _buildDashboardSkeletonCard({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Container(
      padding: padding,
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
      child: child,
    );
  }

  Widget _buildDashboardOverviewLoadingSkeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDashboardSkeletonCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _skeletonBlock(width: 360, height: 24),
              const SizedBox(height: 16),
              Row(
                children: [
                  _skeletonBlock(width: 265, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 265, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 265, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 72, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 72, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 72, height: 101),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _skeletonBlock(width: 265, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 265, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 265, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 265, height: 101),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _buildDashboardSkeletonCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _skeletonBlock(width: 180, height: 24),
              const SizedBox(height: 16),
              Row(
                children: [
                  _skeletonBlock(width: 265, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 265, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 265, height: 101),
                  const SizedBox(width: 16),
                  _skeletonBlock(width: 265, height: 101),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDashboardSkeletonCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _skeletonBlock(width: 170, height: 24),
                  const SizedBox(height: 16),
                  _skeletonBlock(width: 257, height: 141),
                  const SizedBox(height: 16),
                  _skeletonBlock(width: 257, height: 141),
                ],
              ),
            ),
            const SizedBox(width: 16),
            _buildDashboardSkeletonCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _skeletonBlock(width: 150, height: 24),
                  const SizedBox(height: 16),
                  _skeletonBlock(width: 257, height: 68),
                  const SizedBox(height: 16),
                  _skeletonBlock(width: 257, height: 68),
                  const SizedBox(height: 16),
                  _skeletonBlock(width: 257, height: 68),
                  const SizedBox(height: 16),
                  _skeletonBlock(width: 257, height: 68),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _buildDashboardSkeletonCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _skeletonBlock(width: 330, height: 24),
              const SizedBox(height: 16),
              _skeletonBlock(width: 580, height: 220),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _buildDashboardSkeletonCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _skeletonBlock(width: 260, height: 24),
              const SizedBox(height: 16),
              _skeletonBlock(width: 860, height: 280),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDashboardSectionLoadingSkeleton({
    int rows = 5,
    double rowHeight = 52,
  }) {
    return _buildDashboardSkeletonCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _skeletonBlock(width: 260, height: 22),
          const SizedBox(height: 12),
          ...List.generate(
            rows,
            (index) => Padding(
              padding: EdgeInsets.only(bottom: index == rows - 1 ? 0 : 10),
              child: _skeletonBlock(width: double.infinity, height: rowHeight),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSalesTabLoadingSkeleton() =>
      _buildDashboardSectionLoadingSkeleton(
        rows: 6,
        rowHeight: 56,
      );

  Widget _buildSiteTabLoadingSkeleton() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildDashboardSkeletonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _skeletonBlock(width: 250, height: 24),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _skeletonBlock(width: 300, height: 101),
                    const SizedBox(width: 16),
                    _skeletonBlock(width: 300, height: 101),
                    const SizedBox(width: 16),
                    _skeletonBlock(width: 130, height: 101),
                    const SizedBox(width: 16),
                    _skeletonBlock(width: 130, height: 101),
                    const SizedBox(width: 16),
                    _skeletonBlock(width: 180, height: 101),
                  ],
                ),
                const SizedBox(height: 16),
                _skeletonBlock(width: double.infinity, height: 32),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _buildDashboardSectionLoadingSkeleton(rows: 4, rowHeight: 110),
        ],
      );

  Widget _buildPartnersLoadingSkeleton() =>
      _buildDashboardSectionLoadingSkeleton(rows: 5, rowHeight: 56);

  Widget _buildProjectManagersLoadingSkeleton() =>
      _buildDashboardSectionLoadingSkeleton(rows: 4, rowHeight: 56);

  Widget _buildAgentsLoadingSkeleton() =>
      _buildDashboardSectionLoadingSkeleton(rows: 4, rowHeight: 56);

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final scaleMetrics = AppScaleMetrics.of(context);
    final tabLineWidth = (scaleMetrics?.designViewportWidth ?? screenWidth) +
        (scaleMetrics?.rightOverflowWidth ?? 0.0);
    final extraTabLineWidth =
        tabLineWidth > screenWidth ? tabLineWidth - screenWidth : 0.0;
    final hasAmenityArea =
        ((_dashboardData?['amenityAreaRowCount'] as num?)?.toInt() ?? 0) > 0 ||
            ((_dashboardData?['amenityAreaCount'] as num?)?.toInt() ?? 0) > 0 ||
            ((_dashboardData?['totalAmenityAreaSqft'] as num?)?.toDouble() ??
                    0) >
                0 ||
            _amenityAreaRows.isNotEmpty;
    if (!hasAmenityArea && _activeTab == DashboardTab.amenityArea) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _activeTab = DashboardTab.overview;
        });
      });
    }
    final hasPendingPlots =
        !_isLoading && (((_dashboardData?['pendingPlots'] as int?) ?? 0) > 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header section - Fixed at top
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
                    Text(
                      'Project Overview',
                      style: GoogleFonts.inter(
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'A high-level snapshot of project cost, area, layouts, and sales progress.',
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
              Transform.translate(
                offset: Offset(extraTabLineWidth, 0),
                child: const AreaUnitDisplay(
                  unitLabel: AreaUnitUtils.sqmUnitLabel,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        // Full-width TabBar
        SizedBox(
          height: 32,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: -extraTabLineWidth,
                bottom: 0,
                child: Container(
                  height: 0.5,
                  color: const Color(0xFF5C5C5C),
                ),
              ),
              Row(
                children: [
                  const SizedBox(width: 24),
                  // Overview tab
                  GestureDetector(
                    onTap: () =>
                        setState(() => _activeTab = DashboardTab.overview),
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: _activeTab == DashboardTab.overview
                          ? BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: const Color(0xFF0C8CE9),
                                  width: 2,
                                ),
                              ),
                            )
                          : null,
                      child: Center(
                        child: Text(
                          'Overview',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: _activeTab == DashboardTab.overview
                                ? FontWeight.w500
                                : FontWeight.normal,
                            color: _activeTab == DashboardTab.overview
                                ? const Color(0xFF0C8CE9)
                                : const Color(0xFF5C5C5C),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 36),
                  // Sales tab
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _activeTab = DashboardTab.sales;
                        if (_dashboardData != null && _siteLayouts.isEmpty) {
                          _isSiteDataLoading = true;
                          _loadSiteData();
                        }
                      });
                    },
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: _activeTab == DashboardTab.sales
                          ? BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: const Color(0xFF0C8CE9),
                                  width: 2,
                                ),
                              ),
                            )
                          : null,
                      child: Center(
                        child: Text(
                          'Sales',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: _activeTab == DashboardTab.sales
                                ? FontWeight.w500
                                : FontWeight.normal,
                            color: _activeTab == DashboardTab.sales
                                ? const Color(0xFF0C8CE9)
                                : const Color(0xFF5C5C5C),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 36),
                  if (hasPendingPlots) ...[
                    // Profit & ROI tab (shown only when pending plots exist)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _activeTab = DashboardTab.profitRoi;
                          if (_dashboardData != null && _siteLayouts.isEmpty) {
                            _isSiteDataLoading = true;
                            _loadSiteData();
                          }
                        });
                      },
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: _activeTab == DashboardTab.profitRoi
                            ? BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: const Color(0xFF0C8CE9),
                                    width: 2,
                                  ),
                                ),
                              )
                            : null,
                        child: Center(
                          child: Text(
                            'Profit & ROI',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: _activeTab == DashboardTab.profitRoi
                                  ? FontWeight.w500
                                  : FontWeight.normal,
                              color: _activeTab == DashboardTab.profitRoi
                                  ? const Color(0xFF0C8CE9)
                                  : const Color(0xFF5C5C5C),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 36),
                  ],
                  // Site tab
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _activeTab = DashboardTab.site;
                        if (_dashboardData != null && _siteLayouts.isEmpty) {
                          _isSiteDataLoading = true;
                          _loadSiteData();
                        }
                      });
                    },
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: _activeTab == DashboardTab.site
                          ? BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: const Color(0xFF0C8CE9),
                                  width: 2,
                                ),
                              ),
                            )
                          : null,
                      child: Center(
                        child: Text(
                          'Site',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: _activeTab == DashboardTab.site
                                ? FontWeight.w500
                                : FontWeight.normal,
                            color: _activeTab == DashboardTab.site
                                ? const Color(0xFF0C8CE9)
                                : const Color(0xFF5C5C5C),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 36),
                  if (hasAmenityArea) ...[
                    // Amenity Area tab
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _activeTab = DashboardTab.amenityArea;
                        });
                      },
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: _activeTab == DashboardTab.amenityArea
                            ? BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: const Color(0xFF0C8CE9),
                                    width: 2,
                                  ),
                                ),
                              )
                            : null,
                        child: Center(
                          child: Text(
                            'Amenity Area',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: _activeTab == DashboardTab.amenityArea
                                  ? FontWeight.w500
                                  : FontWeight.normal,
                              color: _activeTab == DashboardTab.amenityArea
                                  ? const Color(0xFF0C8CE9)
                                  : const Color(0xFF5C5C5C),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 36),
                  ],
                  // Partner(s) tab
                  GestureDetector(
                    onTap: () =>
                        setState(() => _activeTab = DashboardTab.partners),
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: _activeTab == DashboardTab.partners
                          ? BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: const Color(0xFF0C8CE9),
                                  width: 2,
                                ),
                              ),
                            )
                          : null,
                      child: Center(
                        child: Text(
                          'Partner(s)',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: _activeTab == DashboardTab.partners
                                ? FontWeight.w500
                                : FontWeight.normal,
                            color: _activeTab == DashboardTab.partners
                                ? const Color(0xFF0C8CE9)
                                : const Color(0xFF5C5C5C),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 36),
                  // Project Manager(s) tab
                  GestureDetector(
                    onTap: () {
                      setState(() => _activeTab = DashboardTab.projectManagers);
                      _loadProjectManagersData();
                    },
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: _activeTab == DashboardTab.projectManagers
                          ? BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: const Color(0xFF0C8CE9),
                                  width: 2,
                                ),
                              ),
                            )
                          : null,
                      child: Center(
                        child: Text(
                          'Project Manager(s)',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight:
                                _activeTab == DashboardTab.projectManagers
                                    ? FontWeight.w500
                                    : FontWeight.normal,
                            color: _activeTab == DashboardTab.projectManagers
                                ? const Color(0xFF0C8CE9)
                                : const Color(0xFF5C5C5C),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 36),
                  // Agent(s) tab
                  GestureDetector(
                    onTap: () {
                      setState(() => _activeTab = DashboardTab.agents);
                      _loadAgentsData();
                      if (_dashboardData != null) {
                        _loadCompensationData();
                      }
                    },
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: _activeTab == DashboardTab.agents
                          ? BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: const Color(0xFF0C8CE9),
                                  width: 2,
                                ),
                              ),
                            )
                          : null,
                      child: Center(
                        child: Text(
                          'Agent(s)',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: _activeTab == DashboardTab.agents
                                ? FontWeight.w500
                                : FontWeight.normal,
                            color: _activeTab == DashboardTab.agents
                                ? const Color(0xFF0C8CE9)
                                : const Color(0xFF5C5C5C),
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
        // Content - Scrollable
        Expanded(
          child: ScrollbarTheme(
            data: ScrollbarThemeData(
              thickness: MaterialStateProperty.all(7),
              thumbVisibility: MaterialStateProperty.all(true),
              radius: const Radius.circular(4),
              minThumbLength: 233,
            ),
            child: Scrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
                controller: _scrollController,
                clipBehavior: Clip.hardEdge,
                padding: const EdgeInsets.only(
                  top: 24,
                  left: 24,
                  right: 24,
                  bottom: 24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Tab content - Conditional based on data availability
                    if (widget.projectId == null) ...[
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'No project selected',
                                style: GoogleFonts.inter(
                                  fontSize: 18,
                                  color: Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Please select a project to view the dashboard',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  color: Colors.black54,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ] else if (_isLoading || _dashboardData == null) ...[
                      if (_isLoading) ...[
                        if (_activeTab == DashboardTab.overview) ...[
                          _buildDashboardOverviewLoadingSkeleton(),
                        ] else if (_activeTab == DashboardTab.sales) ...[
                          _buildSalesTabLoadingSkeleton(),
                        ] else if (_activeTab == DashboardTab.profitRoi) ...[
                          _buildSalesTabLoadingSkeleton(),
                        ] else if (_activeTab == DashboardTab.site) ...[
                          _buildSiteTabLoadingSkeleton(),
                        ] else if (_activeTab == DashboardTab.amenityArea) ...[
                          _buildSiteTabLoadingSkeleton(),
                        ] else if (_activeTab == DashboardTab.partners) ...[
                          _buildPartnersLoadingSkeleton(),
                        ] else if (_activeTab ==
                            DashboardTab.projectManagers) ...[
                          _buildProjectManagersLoadingSkeleton(),
                        ] else if (_activeTab == DashboardTab.agents) ...[
                          _buildAgentsLoadingSkeleton(),
                        ],
                      ] else ...[
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No data available',
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                color: const Color(0xFF5C5C5C),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ] else if (_activeTab == DashboardTab.overview) ...[
                      // Project Cost & Area Summary
                      _buildCostAndAreaSummary(),
                      const SizedBox(height: 24),

                      // Amenity Area Summary
                      if (((_dashboardData!['amenityAreaCount'] as int?) ?? 0) >
                          0) ...[
                        _buildAmenityAreaSummaryCard(),
                        const SizedBox(height: 24),
                      ],

                      // Profit and ROI section
                      _buildProfitAndROISection(),
                      const SizedBox(height: 24),

                      // Sales Highlights + Site Overview
                      if (((_dashboardData!['pendingPlots'] as int?) ?? 0) > 0)
                        _buildSalesHighlightsAndSiteOverviewFigma()
                      else
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IntrinsicWidth(
                            child: IntrinsicHeight(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildSalesHighlights(),
                                  const SizedBox(width: 16),
                                  _buildSiteOverview(),
                                ],
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),

                      // Sales, Expenses & Profit Overview (Waterfall)
                      _buildSalesExpensesProfitOverview(),
                      const SizedBox(height: 24),

                      // Total Expenses Breakdown
                      _buildTotalExpensesBreakdown(),
                      const SizedBox(height: 24),
                    ] else if (_activeTab == DashboardTab.sales) ...[
                      _buildSalesTabContent(),
                    ] else if (_activeTab == DashboardTab.profitRoi &&
                        hasPendingPlots) ...[
                      _buildProfitRoiPendingTabContent(),
                    ] else if (_activeTab == DashboardTab.profitRoi &&
                        !hasPendingPlots) ...[
                      _buildSalesTabContent(),
                    ] else if (_activeTab == DashboardTab.site) ...[
                      _buildSiteTabContent(),
                    ] else if (_activeTab == DashboardTab.amenityArea &&
                        hasAmenityArea) ...[
                      _buildAmenityAreaTabContent(),
                    ] else if (_activeTab == DashboardTab.partners) ...[
                      // Partners tab content
                      _buildPartnersSection(),
                      const SizedBox(height: 24),
                      _buildPartnerPlotDistribution(),
                    ] else if (_activeTab == DashboardTab.projectManagers) ...[
                      // Project Managers tab content
                      _buildProjectManagersSection(),
                    ] else if (_activeTab == DashboardTab.agents) ...[
                      // Agents tab content
                      _buildAgentsSection(),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCostAndAreaSummary() {
    final estimatedProjectCost =
        _dashboardData!['estimatedDevelopmentCost'] as double;
    final totalExpenses = _dashboardData!['totalExpenses'] as double;
    final budgetVariance = estimatedProjectCost - totalExpenses;
    final totalArea = _dashboardData!['totalArea'] as double;
    final totalAmenityAreaSqft =
        (_dashboardData!['totalAmenityAreaSqft'] as num?)?.toDouble() ?? 0.0;
    final totalProjectAreaWithAmenity = totalArea + totalAmenityAreaSqft;
    final sellingArea = _dashboardData!['sellingArea'] as double;
    final nonSellableArea = _dashboardData!['nonSellableArea'] as double;
    final allInCost = _dashboardData!['allInCost'] as double;

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1109),
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
              Text(
                'Project Cost & Area Summary',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 16),
              // First row
              Align(
                alignment: Alignment.centerLeft,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const baseCurrencyCardWidth = 265.0;
                    const minCurrencyCardWidth = 245.0;
                    const compactCardWidth = 78.0;
                    const interCardGap = 16.0;
                    const totalBaseWidth = (baseCurrencyCardWidth * 3) +
                        (compactCardWidth * 3) +
                        (interCardGap * 5); // 1109
                    const areaRowTotalBaseWidth = (baseCurrencyCardWidth * 4) +
                        (interCardGap * 3); // 1108

                    final availableWidth = constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : totalBaseWidth;
                    // Match first-row main card width with second-row area card width.
                    final areaRowOverflowPx =
                        (areaRowTotalBaseWidth - availableWidth).ceil();
                    final reductionPerCurrencyCard = areaRowOverflowPx > 0
                        ? (areaRowOverflowPx / 4).ceilToDouble()
                        : 0.0;
                    final currencyCardWidth =
                        (baseCurrencyCardWidth - reductionPerCurrencyCard)
                            .clamp(minCurrencyCardWidth, baseCurrencyCardWidth);
                    // Keep compact cards readable; shrink only spacing to avoid overflow.
                    final minGap = 8.0;
                    final fixedCardsWidth =
                        (currencyCardWidth * 3) + (compactCardWidth * 3);
                    final computedGap = (availableWidth - fixedCardsWidth) / 5;
                    final effectiveInterCardGap =
                        computedGap.clamp(minGap, interCardGap).toDouble();
                    final budgetVarianceStartGap = effectiveInterCardGap + 3;
                    final compactCardsGap =
                        (effectiveInterCardGap - 3).clamp(4.0, interCardGap);
                    final compactCardsStartGap =
                        (effectiveInterCardGap + 2).clamp(minGap, interCardGap);

                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildSummaryCurrencyCard(
                          'Estimated Project Cost',
                          estimatedProjectCost,
                          width: currencyCardWidth,
                        ),
                        SizedBox(width: effectiveInterCardGap),
                        _buildSummaryCurrencyCard(
                          'Total Expenses',
                          totalExpenses,
                          width: currencyCardWidth,
                        ),
                        SizedBox(width: budgetVarianceStartGap),
                        _buildSummaryCurrencyCard(
                          'Budget Variance (Under Budget)',
                          budgetVariance,
                          width: currencyCardWidth,
                        ),
                        SizedBox(width: compactCardsStartGap),
                        _buildSummaryCompactCard(
                          'Partners',
                          _partners.length.toString(),
                          width: compactCardWidth,
                        ),
                        SizedBox(width: compactCardsGap),
                        _buildSummaryCompactCard(
                          'PM(s)',
                          _projectManagers.length.toString(),
                          width: compactCardWidth,
                        ),
                        SizedBox(width: compactCardsGap),
                        _buildSummaryCompactCard(
                          'Agents',
                          _agents.length.toString(),
                          width: compactCardWidth,
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Second row
              Align(
                alignment: Alignment.centerLeft,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const baseCardWidth = 265.0;
                    const interCardGap = 16.0;
                    const totalBaseWidth =
                        (baseCardWidth * 4) + (interCardGap * 3); // 1108

                    final availableWidth = constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : totalBaseWidth;
                    final overflowPx = (totalBaseWidth - availableWidth).ceil();
                    final reductionPerCard =
                        overflowPx > 0 ? (overflowPx / 4).ceilToDouble() : 0.0;
                    final cardWidth =
                        (baseCardWidth - reductionPerCard).clamp(245.0, 265.0);

                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildSummaryAreaCard(
                          'Total Project Area',
                          AreaUnitUtils.areaFromSqftToDisplay(
                              totalProjectAreaWithAmenity, _isSqm),
                          width: cardWidth,
                        ),
                        const SizedBox(width: interCardGap),
                        _buildSummaryAreaCard(
                          'Approved Selling Area ',
                          AreaUnitUtils.areaFromSqftToDisplay(
                              sellingArea, _isSqm),
                          width: cardWidth,
                        ),
                        const SizedBox(width: interCardGap),
                        _buildSummaryAreaCard(
                          'Non-Sellable Area',
                          AreaUnitUtils.areaFromSqftToDisplay(
                              nonSellableArea, _isSqm),
                          width: cardWidth,
                        ),
                        const SizedBox(width: interCardGap),
                        _buildSummaryCurrencyCard(
                          'All-in Cost (₹ / $_areaUnitSuffix)',
                          AreaUnitUtils.rateFromSqftToDisplay(
                              allInCost, _isSqm),
                          width: cardWidth,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAmenityAreaSummaryCard() {
    final totalAmenityAreaSqft =
        (_dashboardData!['totalAmenityAreaSqft'] as num?)?.toDouble() ?? 0.0;
    final amenityAllInCostPerSqft =
        (_dashboardData!['amenityAllInCostPerSqft'] as num?)?.toDouble() ?? 0.0;
    final totalAmenityAreaValue =
        (_dashboardData!['totalAmenityAreaValue'] as num?)?.toDouble() ?? 0.0;

    final totalAmenityAreaDisplay =
        AreaUnitUtils.areaFromSqftToDisplay(totalAmenityAreaSqft, _isSqm);
    final amenityAllInCostDisplay = AreaUnitUtils.rateFromSqftToDisplay(
      amenityAllInCostPerSqft,
      _isSqm,
    );

    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: 860,
        height: 162,
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
              Text(
                'Amenity Area Summary',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _buildAmenitySummaryMetricCard(
                    width: 265,
                    label: 'Total Amenity Area',
                    value: _formatNumberNoDecimals(totalAmenityAreaDisplay),
                    suffix: _areaUnitSuffix,
                  ),
                  const SizedBox(width: 16),
                  _buildAmenitySummaryMetricCard(
                    width: 266,
                    label: 'Amenity Area All-in Cost (₹ / $_areaUnitSuffix)',
                    prefix: '₹',
                    value: _formatNumberNoDecimals(amenityAllInCostDisplay),
                  ),
                  const SizedBox(width: 16),
                  _buildAmenitySummaryMetricCard(
                    width: 265,
                    label: 'Amenity Area Total Value',
                    prefix: '₹',
                    value: _formatNumberNoDecimals(totalAmenityAreaValue),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAmenitySummaryMetricCard({
    required double width,
    required String label,
    required String value,
    String? prefix,
    String? suffix,
  }) {
    return Container(
      width: width,
      height: 88,
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (prefix != null) ...[
                Text(
                  prefix,
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
                    height: 1.0,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  value,
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
                    height: 1.0,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (suffix != null) ...[
                const SizedBox(width: 8),
                Text(
                  suffix,
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
                    height: 1.0,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProfitAndROISection() {
    final totalExpenses = _dashboardData!['totalExpenses'] as double;
    final salesTillDate = _dashboardData!['totalSalesValue'] as double;

    // Calculate Gross Profit using the same logic as _calculateTotalGrossProfit()
    // This only counts cost of sold plots, not all plots
    final grossProfit = _calculateTotalGrossProfit();

    // Calculate Total Compensation (Project Managers + Agents)
    final totalCompensation = _calculateTotalProjectManagersCompensation() +
        _calculateTotalAgentsCompensation();

    // Net Profit = Gross Profit - Total Compensation
    final netProfit = grossProfit - totalCompensation;

    // Calculate Profit Margin (%) = (Net Profit / Total Sales Value) * 100
    final profitMargin =
        salesTillDate > 0 ? (netProfit / salesTillDate) * 100 : 0.0;

    // Calculate ROI (%) = (Net Profit / Total Expenses) * 100
    final roi = totalExpenses > 0 ? (netProfit / totalExpenses) * 100 : 0.0;

    return Align(
      alignment: Alignment.centerLeft,
      child: IntrinsicWidth(
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
                spreadRadius: 0,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Profit and ROI',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: IntrinsicWidth(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildSummaryCurrencyCard(
                        'Gross Profit',
                        grossProfit,
                        width: 265,
                      ),
                      const SizedBox(width: 16),
                      _buildSummaryCurrencyCard(
                        'Net Profit',
                        netProfit,
                        width: 265,
                      ),
                      const SizedBox(width: 16),
                      _buildSummaryPercentCard(
                        'Profit Margin (%)',
                        profitMargin,
                        width: 265,
                      ),
                      const SizedBox(width: 16),
                      _buildSummaryPercentCard(
                        'ROI (%)',
                        roi,
                        width: 265,
                        valueColor: roi < 0 ? Colors.red : Colors.black,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSiteOverview() {
    return Align(
      alignment: Alignment.centerLeft,
      child: IntrinsicWidth(
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
              Text(
                'Site Overview',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Column(
                    children: [
                      _buildSiteOverviewItem(
                        'Total Layouts',
                        _formatNumberNoDecimals(
                          (_dashboardData!['totalLayouts'] as int).toDouble(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildSiteOverviewItem(
                        'Total Plots',
                        _formatNumber(_dashboardData!['totalPlots'] as int),
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Column(
                    children: [
                      _buildSiteOverviewItem(
                        'Available Plots',
                        _formatNumber(_dashboardData!['availablePlots'] as int),
                      ),
                      const SizedBox(height: 16),
                      _buildSiteOverviewItem(
                        'Sold Plots',
                        _formatNumber(_dashboardData!['soldPlots'] as int),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSalesHighlightsAndSiteOverviewFigma() {
    const double cardVerticalGap = 24.0;
    final totalSalesValue =
        _dashboardData!['totalSalesValue'] as double? ?? 0.0;
    final soldPlots = _dashboardData!['soldPlots'] as int? ?? 0;
    final totalLayouts = _dashboardData!['totalLayouts'] as int? ?? 0;
    final totalPlots = _dashboardData!['totalPlots'] as int? ?? 0;
    final availablePlots = _dashboardData!['availablePlots'] as int? ?? 0;
    final inferredPendingPlots = totalPlots - availablePlots - soldPlots;
    final pendingPlots = (_dashboardData!['pendingPlots'] as int?) ??
        (inferredPendingPlots > 0 ? inferredPendingPlots : 0);

    return Container(
      width: 1138,
      height: 202,
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
            'Sales Highlights & Site Overview',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildFigmaSalesValueCard(
                  totalSalesValue: totalSalesValue,
                  soldPlots: soldPlots,
                ),
                const SizedBox(width: 16),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildFigmaOverviewCountCard(
                      label: 'Total Layouts',
                      value: _formatNumber(totalLayouts),
                    ),
                    const SizedBox(height: cardVerticalGap),
                    _buildFigmaOverviewCountCard(
                      label: 'Total Plots',
                      value: _formatNumber(totalPlots),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildFigmaOverviewCountCard(
                      label: 'Available Plots',
                      value: _formatNumber(availablePlots),
                      backgroundColor: const Color(0xFFE8F4EA),
                    ),
                    const SizedBox(height: cardVerticalGap),
                    _buildFigmaOverviewCountCard(
                      label: 'Sold Plots',
                      value: _formatNumber(soldPlots),
                      backgroundColor: const Color(0xFFF8F1F2),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                _buildFigmaOverviewCountCard(
                  label: 'Pending Plots',
                  value: _formatNumber(pendingPlots),
                  backgroundColor: const Color(0xFFF9F2E6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFigmaSalesValueCard({
    required double totalSalesValue,
    required int soldPlots,
  }) {
    return Container(
      width: 265,
      height: 130,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Total Sales Value',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                '₹',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w400,
                  color: Colors.black,
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _formatNumberNoDecimals(totalSalesValue),
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
                    height: 1.0,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '${_formatNumber(soldPlots)} plots sold',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFigmaOverviewCountCard({
    required String label,
    required String value,
    Color backgroundColor = Colors.white,
  }) {
    return Container(
      width: 245,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: backgroundColor,
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
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF5C5C5C),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.normal,
                color: Colors.black,
                height: 1.0,
              ),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(double soldPercentage, double remainingPercentage) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final remainingWidth = totalWidth * (remainingPercentage / 100);
        final soldWidth = totalWidth * (soldPercentage / 100);

        return SizedBox(
          height: 32,
          child: Row(
            children: [
              // Remaining (green) - left side
              if (remainingPercentage > 0)
                Container(
                  width: remainingWidth,
                  height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFF22C55E),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(100),
                      bottomLeft: Radius.circular(100),
                    ),
                    border: Border.all(
                      color: const Color(0xFF707070).withOpacity(0.2),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(
                    '${remainingPercentage.toStringAsFixed(0)}% Remaining',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              // Sold (red) - right side
              if (soldPercentage > 0)
                Container(
                  width: soldWidth,
                  height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444),
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(100),
                      bottomRight: Radius.circular(100),
                    ),
                    border: Border.all(
                      color: const Color(0xFF707070).withOpacity(0.2),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 2,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  child: Text(
                    '${soldPercentage.toStringAsFixed(0)}% Sold',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSalesHighlights() {
    return Align(
      alignment: Alignment.centerLeft,
      child: IntrinsicWidth(
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
              Text(
                'Sales Highlights',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _buildSalesHighlightCard(
                    title: 'Total Sales Value',
                    value: _dashboardData!['totalSalesValue'] as double,
                    footerText: '${_dashboardData!['soldPlots']} plots sold',
                  ),
                  const SizedBox(width: 16),
                  _buildSalesHighlightCard(
                    title: 'Average Sales Price (₹ / $_areaUnitSuffix)',
                    value: AreaUnitUtils.rateFromSqftToDisplay(
                        _dashboardData!['avgSalePricePerSqft'] as double,
                        _isSqm),
                    footerText: 'Based on sold plots',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSalesHighlightCard({
    required String title,
    required double value,
    required String footerText,
  }) {
    final valueStyle = GoogleFonts.inter(
      fontSize: 20,
      fontWeight: FontWeight.normal,
      color: Colors.black,
    );

    return Container(
      width: 257,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('₹', style: valueStyle),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _formatNumberNoDecimals(value),
                  style: valueStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            footerText,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSiteOverviewItem(String label, String value) {
    return Container(
      width: 257,
      padding: const EdgeInsets.all(16),
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
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF5C5C5C),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSalesExpensesProfitOverview() {
    final totalSalesValue = _dashboardData!['totalSalesValue'] as double;
    final totalExpenses = _dashboardData!['totalExpenses'] as double;
    final grossProfit = _calculateTotalGrossProfit();
    final totalCompensation = _calculateTotalProjectManagersCompensation() +
        _calculateTotalAgentsCompensation();
    final netProfit = grossProfit - totalCompensation;

    const chartWidth = 549.0;
    const rowHeight = 32.0;
    const dividerGap = 12.0;
    const dividerHeight = 1.0;
    const axisGap = 8.0;
    const axisLineHeight = 1.0;
    const axisTopExtension = 20.0;
    // Waterfall anchors (as requested):
    // Gross + Compensation start where Expenses ends.
    // Net Profit starts where Compensation ends.
    final expensesEndValue = totalExpenses;
    final grossStartValue = expensesEndValue;
    final compensationStartValue = grossStartValue;
    final compensationEndValue = compensationStartValue + totalCompensation;
    final netProfitStartValue = compensationEndValue;

    // X-axis range is based on total sales value:
    // round up to the nearest nice 5/10-like multiple, then split into 5 intervals.
    final axisScale = _buildSalesWaterfallAxisScale(totalSalesValue);
    final axisRange = axisScale.axisMax - axisScale.axisMin;
    final zeroX = axisRange <= 0
        ? 0.0
        : ((0 - axisScale.axisMin) / axisRange) * chartWidth;

    final hasNegative = axisScale.axisMin < 0;
    final hasPositive = axisScale.axisMax > 0;

    double barWidth(double value) {
      if (axisRange <= 0) return 0;
      return (value.abs().clamp(0.0, axisRange) / axisRange) * chartWidth;
    }

    double valueToX(double value) {
      if (axisRange <= 0) return 0.0;
      return ((value - axisScale.axisMin) / axisRange) * chartWidth;
    }

    // Waterfall steps (pixel positions from value anchors above).
    final grossAndCompensationStartX = valueToX(grossStartValue);
    final compensationStartX = grossAndCompensationStartX;
    final netProfitStartX = valueToX(netProfitStartValue);

    final tickXs = List<double>.generate(6, (index) {
      if (axisRange <= 0) return 0.0;
      final value = axisScale.axisMin + (axisScale.step * index);
      return ((value - axisScale.axisMin) / axisRange) * chartWidth;
    });

    // Keep bar geometry fixed, but provide 8px extra canvas width on the right
    // so the x-axis arrow appears 8px after the last black tick/extension.
    final totalChartWidth = chartWidth + 24;

    final chartHeight = (rowHeight * 5) +
        (dividerHeight * 4) +
        (dividerGap * 8) +
        axisGap +
        axisLineHeight +
        axisTopExtension;
    // Extend the grey vertical grid lines down to where the x-axis is drawn
    // so that they visually "touch" the axis, just like the y-axis does.
    final plotHeight = chartHeight - (axisLineHeight / 2);

    return Align(
      alignment: Alignment.centerLeft,
      child: IntrinsicWidth(
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
              Text(
                'Sales, Expenses & Profit Overview',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _buildChartLabel('Net Profit', height: rowHeight),
                            const SizedBox(height: 24),
                            _buildChartLabel('Compensation', height: rowHeight),
                            const SizedBox(height: 24),
                            _buildChartLabel('Gross Profit', height: rowHeight),
                            const SizedBox(height: 24),
                            _buildChartLabel('Total Expenses',
                                height: rowHeight),
                            const SizedBox(height: 24),
                            _buildChartLabel('Total Sales Value',
                                height: rowHeight),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: totalChartWidth,
                            height: chartHeight,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _VerticalGridPainter(
                                      tickXs: tickXs,
                                      plotHeight: plotHeight,
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(
                                      top: axisTopExtension),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _buildChartRow(
                                        barWidth(netProfit),
                                        const Color(0xFF76CF68),
                                        rowHeight,
                                        zeroX: zeroX,
                                        startX: netProfitStartX,
                                        isNegative: netProfit < 0,
                                        tooltipText:
                                            _formatCurrencyWithSign(netProfit),
                                      ),
                                      _buildChartDivider(chartWidth, dividerGap,
                                          dividerHeight),
                                      _buildChartRow(
                                        barWidth(totalCompensation),
                                        const Color(0xFFE1A157),
                                        rowHeight,
                                        zeroX: zeroX,
                                        startX: compensationStartX,
                                        isNegative: totalCompensation < 0,
                                        tooltipText: _formatCurrencyWithSign(
                                            totalCompensation),
                                      ),
                                      _buildChartDivider(chartWidth, dividerGap,
                                          dividerHeight),
                                      _buildChartRow(
                                        barWidth(grossProfit),
                                        const Color(0xFF7CD7EC),
                                        rowHeight,
                                        zeroX: zeroX,
                                        startX: grossAndCompensationStartX,
                                        isNegative: grossProfit < 0,
                                        tooltipText: _formatCurrencyWithSign(
                                            grossProfit),
                                      ),
                                      _buildChartDivider(chartWidth, dividerGap,
                                          dividerHeight),
                                      _buildChartRow(
                                        barWidth(totalExpenses),
                                        const Color(0xFFFB7D7D),
                                        rowHeight,
                                        zeroX: zeroX,
                                        isNegative: totalExpenses < 0,
                                        tooltipText: _formatCurrencyWithSign(
                                            totalExpenses),
                                      ),
                                      _buildChartDivider(chartWidth, dividerGap,
                                          dividerHeight),
                                      _buildChartRow(
                                        barWidth(totalSalesValue),
                                        const Color(0xFF0C8CE9),
                                        rowHeight,
                                        zeroX: zeroX,
                                        isNegative: totalSalesValue < 0,
                                        tooltipText: _formatCurrencyWithSign(
                                            totalSalesValue),
                                      ),
                                      const SizedBox(height: axisGap),
                                    ],
                                  ),
                                ),
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _AxisPainter(
                                      zeroX: zeroX,
                                      hasNegative: hasNegative,
                                      hasPositive: hasPositive,
                                      axisLineHeight: axisLineHeight,
                                      tickXs: tickXs,
                                      verticalAxisEndY:
                                          plotHeight + axisTopExtension,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: totalChartWidth,
                            height: 24,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: List.generate(6, (index) {
                                final value = axisScale.axisMin +
                                    (axisScale.step * index);
                                final tickX =
                                    tickXs[index].clamp(0.0, totalChartWidth);
                                return CustomSingleChildLayout(
                                  delegate:
                                      _AxisLabelLayoutDelegate(tickX: tickX),
                                  child: _buildAxisLabel(
                                    _formatAxisLabelValue(value, axisScale),
                                  ),
                                );
                              }),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(width: 11),
                  SizedBox(
                    width: 405,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 192,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLegendItem(
                                color: const Color(0xFF76CF68),
                                label: 'Net Profit',
                                value: netProfit,
                              ),
                              const SizedBox(height: 40),
                              _buildLegendItem(
                                color: const Color(0xFFE1A157),
                                label: 'Compensation',
                                value: totalCompensation,
                              ),
                              const SizedBox(height: 40),
                              _buildLegendItem(
                                color: const Color(0xFF0C8CE9),
                                label: 'Total Sales Value',
                                value: totalSalesValue,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 21),
                        SizedBox(
                          width: 192,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLegendItem(
                                color: const Color(0xFF7CD7EC),
                                label: 'Gross Profit',
                                value: grossProfit,
                              ),
                              const SizedBox(height: 40),
                              _buildLegendItem(
                                color: const Color(0xFFFB7D7D),
                                label: 'Total Expenses',
                                value: totalExpenses,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTotalExpensesBreakdown() {
    final totalExpenses = _dashboardData!['totalExpenses'] as double;
    final expenses = _dashboardData!['expenses'] as List<dynamic>? ?? [];

    // Group expenses by category
    final expensesByCategory = <String, double>{};
    for (var expense in expenses) {
      final category = expense['category'] as String? ?? 'Others';
      final amount = (expense['amount'] as num?)?.toDouble() ?? 0.0;
      expensesByCategory[category] =
          (expensesByCategory[category] ?? 0.0) + amount;
    }

    final donutItems = [
      _ExpenseBreakdownItem(
        label: 'Land Purchase Cost',
        color: const Color(0xFFE8F6DA),
        amount: expensesByCategory['Land Purchase Cost'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Statutory & Registration',
        color: const Color(0xFFC8C0DC),
        amount: expensesByCategory['Statutory & Registration'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Legal & Professional Fees',
        color: const Color(0xFFDCD4C0),
        amount: expensesByCategory['Legal & Professional Fees'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Survey, Approvals & Conversion',
        color: const Color(0xFFC0DCDC),
        amount: expensesByCategory['Survey, Approvals & Conversion'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Construction & Development',
        color: const Color(0xFFDCC0CF),
        amount: expensesByCategory['Construction & Development'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Amenities & Infrastructure',
        color: const Color(0xFFE7B7B8),
        amount: expensesByCategory['Amenities & Infrastructure'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Others',
        color: const Color(0xFFD0D0D0),
        amount: expensesByCategory['Others'] ?? 0,
      ),
    ];

    final legendItems = [
      _ExpenseBreakdownItem(
        label: 'Land Purchase Cost',
        color: const Color(0xFFE8F6DA),
        amount: expensesByCategory['Land Purchase Cost'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Survey, Approvals & Conversion',
        color: const Color(0xFFC0DCDC),
        amount: expensesByCategory['Survey, Approvals & Conversion'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Others',
        color: const Color(0xFFD0D0D0),
        amount: expensesByCategory['Others'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Statutory & Registration',
        color: const Color(0xFFC8C0DC),
        amount: expensesByCategory['Statutory & Registration'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Construction & Development',
        color: const Color(0xFFDCC0CF),
        amount: expensesByCategory['Construction & Development'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Legal & Professional Fees',
        color: const Color(0xFFDCD4C0),
        amount: expensesByCategory['Legal & Professional Fees'] ?? 0,
      ),
      _ExpenseBreakdownItem(
        label: 'Amenities & Infrastructure',
        color: const Color(0xFFE7B7B8),
        amount: expensesByCategory['Amenities & Infrastructure'] ?? 0,
      ),
    ];

    return Align(
      alignment: Alignment.centerLeft,
      child: IntrinsicWidth(
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
              Text(
                'Total Expenses Breakdown',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildExpensesDonut(totalExpenses, donutItems),
                  const SizedBox(width: 40),
                  SizedBox(
                    width: 806,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildExpenseLegendItem(
                                legendItems[0], totalExpenses),
                            const SizedBox(height: 40),
                            _buildExpenseLegendItem(
                                legendItems[1], totalExpenses),
                            const SizedBox(height: 40),
                            _buildExpenseLegendItem(
                                legendItems[2], totalExpenses),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildExpenseLegendItem(
                                legendItems[3], totalExpenses),
                            const SizedBox(height: 40),
                            _buildExpenseLegendItem(
                                legendItems[4], totalExpenses),
                            const SizedBox(height: 49),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildExpenseLegendItem(
                                legendItems[5], totalExpenses),
                            const SizedBox(height: 40),
                            _buildExpenseLegendItem(
                                legendItems[6], totalExpenses),
                            const SizedBox(height: 49),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpensesDonut(
      double totalExpenses, List<_ExpenseBreakdownItem> items) {
    return SizedBox(
      width: 262,
      height: 262,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(262, 262),
            painter: _DonutPainter(items: items, totalExpenses: totalExpenses),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Total Expenses',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFBCBCBC),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '₹',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF5C5C5C),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatCurrencyNumber(totalExpenses),
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF5C5C5C),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildExpenseLegendItem(
    _ExpenseBreakdownItem item,
    double totalExpenses,
  ) {
    final percentage =
        totalExpenses == 0 ? 0 : (item.amount / totalExpenses) * 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: item.color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 2,
                    offset: const Offset(0, 0),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              item.label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF5C5C5C),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 32),
          child: Row(
            children: [
              Text(
                '₹',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatCurrencyNumber(item.amount),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '(${percentage.toStringAsFixed(0)}%)',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF5C5C5C),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChartLabel(String text, {double height = 32}) {
    return SizedBox(
      height: height,
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF5C5C5C),
          ),
          textAlign: TextAlign.right,
        ),
      ),
    );
  }

  Widget _buildChartRow(
    double width,
    Color color,
    double height, {
    required double zeroX,
    double? startX,
    required bool isNegative,
    required String tooltipText,
  }) {
    final baselineX = startX ?? zeroX;
    final left = isNegative ? (baselineX - width) : baselineX;

    return SizedBox(
      width: 549,
      height: height,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned(
            left: left,
            top: 0,
            bottom: 0,
            child: Tooltip(
              message: tooltipText,
              child: Container(
                width: width,
                height: height,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartDivider(double width, double gap, double height) {
    return Column(
      children: [
        SizedBox(height: gap),
        Container(
          width: width,
          height: height,
          color: const Color(0xFFE0E0E0), // Light grey separator line
        ),
        SizedBox(height: gap),
      ],
    );
  }

  Widget _buildAxisLabel(String text) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.normal,
        color: Colors.black,
      ),
      textAlign: TextAlign.center,
    );
  }

  _AxisScale _buildAxisScale(double minValue, double maxValue, double maxAbs) {
    if (minValue >= 0) {
      final axisMax = _roundUpNice(maxValue <= 0 ? 1.0 : maxValue);
      final step = axisMax / 5;
      final unit = _axisUnit(axisMax);
      final suffix = _axisSuffix(unit);
      return _AxisScale(
        axisMin: 0,
        axisMax: axisMax,
        step: step,
        unit: unit,
        suffix: suffix,
      );
    }

    if (maxValue <= 0) {
      final axisMin = -_roundUpNice(minValue.abs());
      final step = (0 - axisMin) / 5;
      final unit = _axisUnit(axisMin.abs());
      final suffix = _axisSuffix(unit);
      return _AxisScale(
        axisMin: axisMin,
        axisMax: 0,
        step: step,
        unit: unit,
        suffix: suffix,
      );
    }

    double step = _roundUpNice((maxValue - minValue) / 5);
    double axisMin = (minValue / step).floor() * step;
    double axisMax = axisMin + (step * 5);

    if (axisMax < maxValue) {
      axisMax = (maxValue / step).ceil() * step;
      axisMin = axisMax - (step * 5);
    }

    if (axisMin > minValue) {
      axisMin = (minValue / step).floor() * step;
      axisMax = axisMin + (step * 5);
    }

    final magnitude = math.max(axisMax.abs(), axisMin.abs());
    final unit = _axisUnit(magnitude);
    final suffix = _axisSuffix(unit);

    return _AxisScale(
      axisMin: axisMin,
      axisMax: axisMax,
      step: step,
      unit: unit,
      suffix: suffix,
    );
  }

  _AxisScale _buildSalesWaterfallAxisScale(double totalSalesValue) {
    final sanitizedSales =
        totalSalesValue.isFinite ? totalSalesValue.abs() : 0.0;
    final axisMax = _roundUpNice(sanitizedSales <= 0 ? 5.0 : sanitizedSales);
    return _buildAxisScale(0, axisMax, axisMax);
  }

  double _roundUpNice(double value) {
    if (value <= 0) return 1;
    final exponent =
        math.pow(10, (math.log(value) / math.ln10).floor()).toDouble();
    final fraction = value / exponent;
    double nice;
    if (fraction <= 1) {
      nice = 1;
    } else if (fraction <= 2) {
      nice = 2;
    } else if (fraction <= 5) {
      nice = 5;
    } else {
      nice = 10;
    }
    return nice * exponent;
  }

  double _axisUnit(double axisMax) {
    if (axisMax >= 10000000) return 10000000;
    if (axisMax >= 100000) return 100000;
    if (axisMax >= 1000) return 1000;
    return 1;
  }

  String _axisSuffix(double unit) {
    if (unit == 10000000) return 'Cr';
    if (unit == 100000) return 'L';
    if (unit == 1000) return 'K';
    return '';
  }

  String _formatAxisLabelValue(double value, _AxisScale scale) {
    final scaled = value / scale.unit;
    final needsDecimal = (scale.step / scale.unit) < 1;
    final formatted =
        needsDecimal ? scaled.toStringAsFixed(1) : scaled.toStringAsFixed(0);
    final trimmed = formatted.replaceAll(RegExp(r'\.0$'), '');
    if (scale.suffix.isEmpty) {
      return trimmed;
    }
    return '$trimmed ${scale.suffix}';
  }

  String _formatCurrencyWithSign(double value) {
    if (value < 0) {
      return '-${_formatCurrency(value.abs())}';
    }
    return _formatCurrency(value);
  }

  Widget _buildLegendItem({
    required Color color,
    required String label,
    required double value,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 2,
                    offset: const Offset(0, 0),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF5C5C5C),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 32),
          child: Row(
            children: [
              Text(
                '₹',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 144,
                child: Text(
                  _formatNumberNoDecimals(value),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF5C5C5C),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard(String label, String value) {
    return Container(
      height: 101,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 24,
              fontWeight: FontWeight.normal,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCardWithUnit(String label, String value, String unit) {
    return Container(
      height: 101,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                unit,
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard({
    required double width,
    required String label,
    required Widget value,
    EdgeInsets padding =
        const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    CrossAxisAlignment crossAxisAlignment = CrossAxisAlignment.start,
    TextAlign labelAlign = TextAlign.left,
  }) {
    return Container(
      width: width,
      padding: padding,
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
      child: Column(
        crossAxisAlignment: crossAxisAlignment,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: labelAlign,
          ),
          const SizedBox(height: 16),
          value,
        ],
      ),
    );
  }

  Widget _buildSummaryCurrencyCard(String label, double value,
      {double width = 265}) {
    final valueStyle = GoogleFonts.inter(
      fontSize: 20,
      fontWeight: FontWeight.normal,
      color: Colors.black,
    );

    return _buildSummaryCard(
      width: width,
      label: label,
      value: Row(
        children: [
          Text('₹', style: valueStyle),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _formatNumberWithDecimals(value, 2),
              style: valueStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryAreaCard(String label, double value,
      {double width = 265}) {
    final valueStyle = GoogleFonts.inter(
      fontSize: 20,
      fontWeight: FontWeight.normal,
      color: Colors.black,
    );

    return _buildSummaryCard(
      width: width,
      label: label,
      value: Row(
        children: [
          Expanded(
            child: Text(
              '${_formatNumberNoDecimals(value)} $_areaUnitSuffix',
              style: valueStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCompactCard(String label, String value,
      {double width = 78}) {
    final valueStyle = GoogleFonts.inter(
      fontSize: 20,
      fontWeight: FontWeight.normal,
      color: Colors.black,
    );

    return _buildSummaryCard(
      width: width,
      label: label,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      crossAxisAlignment: CrossAxisAlignment.center,
      labelAlign: TextAlign.center,
      value: Text(
        value,
        style: valueStyle,
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildSummaryPercentCard(
    String label,
    double value, {
    double width = 265,
    Color valueColor = Colors.black,
  }) {
    final valueStyle = GoogleFonts.inter(
      fontSize: 20,
      fontWeight: FontWeight.normal,
      color: valueColor,
    );

    return _buildSummaryCard(
      width: width,
      label: label,
      value: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _formatNumberWithDecimals(value, 2),
            style: valueStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(width: 4),
          Text('%', style: valueStyle),
        ],
      ),
    );
  }

  Widget _buildProfitCard(String label, String value, {Color? valueColor}) {
    return Container(
      width: 320,
      height: 101,
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 24,
              fontWeight: FontWeight.normal,
              color: valueColor ?? Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSmallMetricCard(String label, String value,
      {Color? valueColor}) {
    return Container(
      height: 101,
      width: 150,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 24,
              fontWeight: FontWeight.normal,
              color: valueColor ?? Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSalesCard(String label, String value, String subtitle) {
    return Container(
      width: 300,
      height: 141,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 24,
              fontWeight: FontWeight.normal,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            subtitle,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
        ],
      ),
    );
  }

  String _formatNumber(int value) {
    if (value < 1000) return value.toString();

    final parts = value.toString().split('');
    String formatted = '';
    final length = parts.length;

    if (length <= 3) {
      formatted = value.toString();
    } else {
      final lastThree = parts.sublist(length - 3).join();
      final remaining = parts.sublist(0, length - 3).join();

      // Add commas every 2 digits from right
      String formattedRemaining = '';
      for (int i = remaining.length - 1; i >= 0; i--) {
        if ((remaining.length - 1 - i) > 0 &&
            (remaining.length - 1 - i) % 2 == 0) {
          formattedRemaining = ',' + formattedRemaining;
        }
        formattedRemaining = remaining[i] + formattedRemaining;
      }

      formatted = formattedRemaining.isEmpty
          ? lastThree
          : '$formattedRemaining,$lastThree';
    }

    return formatted;
  }

  Widget _buildSalesTabContent() {
    if (_dashboardData == null) {
      return _buildSalesTabLoadingSkeleton();
    }

    final totalSalesValue = _dashboardData!['totalSalesValue'] as double;
    final soldPlots = _dashboardData!['soldPlots'] as int;
    final totalPlots = _dashboardData!['totalPlots'] as int;
    final availablePlots = _dashboardData!['availablePlots'] as int;
    final pendingPlots = _dashboardData!['pendingPlots'] as int? ?? 0;
    final allInCost = _dashboardData!['allInCost'] as double;
    final amenityAreaRowCount =
        (_dashboardData!['amenityAreaRowCount'] as num?)?.toInt() ?? 0;
    final amenityAreaCount =
        (_dashboardData!['amenityAreaCount'] as num?)?.toInt() ?? 0;
    final totalAmenityAreaSqft =
        (_dashboardData!['totalAmenityAreaSqft'] as num?)?.toDouble() ?? 0.0;
    final totalAmenityAreaValue =
        (_dashboardData!['totalAmenityAreaValue'] as num?)?.toDouble() ?? 0.0;
    final hasAmenityArea = amenityAreaRowCount > 0 ||
        amenityAreaCount > 0 ||
        totalAmenityAreaSqft > 0 ||
        totalAmenityAreaValue > 0;

    // Calculate sales by date (for chart) based on selected time filter
    int todaysSales = 0; // For backward compatibility
    Map<String, int> dailySalesMap = {};

    final today = DateTime.now();
    final todayStr =
        '${today.day.toString().padLeft(2, '0')}/${today.month.toString().padLeft(2, '0')}/${today.year}';
    final todayStrISO =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    // Determine the number of days to look back
    int daysToLookBack = 1; // Default to 1D
    if (_selectedTimeFilter == '7D') {
      daysToLookBack = 7;
    } else if (_selectedTimeFilter == '28D') {
      daysToLookBack = 29;
    }

    print(
        'DEBUG: Selected time filter: $_selectedTimeFilter, looking back $daysToLookBack days');
    print('DEBUG: Today ISO: $todayStrISO');

    // Initialize sales map for all days in the period (using ISO format as key)
    for (int i = 0; i < daysToLookBack; i++) {
      final date = today.subtract(Duration(days: i));
      final dateStrISO =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      dailySalesMap[dateStrISO] = 0;
      print('DEBUG: Initialized date: $dateStrISO');
    }

    // Count sales for each day
    for (var layout in _siteLayouts) {
      final plots = layout['plots'] as List<dynamic>;
      for (var plot in plots) {
        final status = (plot['status'] as String? ?? 'available').toLowerCase();
        if (status == 'sold') {
          final saleDate =
              (plot['sale_date'] as String? ?? '').toString().trim();
          print('DEBUG: Found sold plot with saleDate: "$saleDate"');
          if (dailySalesMap.containsKey(saleDate)) {
            dailySalesMap[saleDate] = dailySalesMap[saleDate]! + 1;
            print(
                'DEBUG: Matched! Updated count for $saleDate to ${dailySalesMap[saleDate]}');
            if (saleDate == todayStrISO) {
              todaysSales++;
            }
          } else {
            print(
                'DEBUG: Date "$saleDate" not found in map. Available keys: ${dailySalesMap.keys.toList()}');
          }
        }
      }
    }

    // Build list of sales data for the selected period (in chronological order: oldest to newest)
    List<int> salesData = [];
    for (int i = daysToLookBack - 1; i >= 0; i--) {
      final date = today.subtract(Duration(days: i));
      final dateStrISO =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final sales = dailySalesMap[dateStrISO] ?? 0;
      salesData.add(sales);
      print('DEBUG: Built data for $dateStrISO: $sales sales');
    }

    print('DEBUG: Total todaysSales = $todaysSales, salesData = $salesData');

    // Calculate maxY once using all data to ensure consistent positioning across all time filters
    int maxY = todaysSales;
    if (salesData.isNotEmpty) {
      final dataMax = salesData.reduce((a, b) => a > b ? a : b);
      maxY = maxY > dataMax ? maxY : dataMax;
    }
    maxY = ((maxY + 4) ~/ 5) * 5; // Round up to nearest multiple of 5
    if (maxY == 0) maxY = 5; // Minimum scale

    // Calculate average sales price per sqft from sold plots
    double averageSalesPrice = 0.0;
    double soldArea = 0.0;

    for (var layout in _siteLayouts) {
      final plots = layout['plots'] as List<dynamic>;
      for (var plot in plots) {
        final status = (plot['status'] as String? ?? 'available').toLowerCase();
        if (status == 'sold') {
          final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
          final salePrice = ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
          soldArea += area;
          averageSalesPrice += salePrice * area;
        }
      }
    }

    averageSalesPrice = soldArea > 0 ? averageSalesPrice / soldArea : 0.0;

    // Calculate monthly sales run rate (assuming sales data is available)
    // For now, using a simple calculation: total sales / months since project start
    // This would need actual date data for proper calculation
    final monthlySalesRunRate = soldPlots > 0 ? totalSalesValue : 0.0;
    final totalRevenueWithAmenity = totalSalesValue + totalAmenityAreaValue;
    final monthlySalesRunRateWithAmenity = totalRevenueWithAmenity;

    if (pendingPlots > 0) {
      final pendingSalesMetrics = _calculatePendingSalesMetrics();
      final expectedSalesValue = pendingSalesMetrics['expectedSalesValue'] ?? 0;
      final collectionsReceived =
          pendingSalesMetrics['collectionsReceived'] ?? 0;
      final totalPendingAmount = pendingSalesMetrics['totalPendingAmount'] ?? 0;
      final averagePendingAndSoldPricePerSqft =
          pendingSalesMetrics['averagePendingAndSoldPricePerSqft'] ?? 0;

      return _buildSalesTabContentWithPending(
        totalSalesValue: totalSalesValue,
        soldPlots: soldPlots,
        totalLayouts: _dashboardData!['totalLayouts'] as int? ?? 0,
        totalPlots: totalPlots,
        availablePlots: availablePlots,
        pendingPlots: pendingPlots,
        monthlySalesRunRate: monthlySalesRunRate,
        hasAmenityArea: hasAmenityArea,
        totalRevenueWithAmenity: totalRevenueWithAmenity,
        allInCost: allInCost,
        averageSalesPricePerSqft: averageSalesPrice,
        averagePendingAndSoldPricePerSqft: averagePendingAndSoldPricePerSqft,
        collectionsReceived: collectionsReceived,
        expectedSalesValue: expectedSalesValue,
        totalPendingAmount: totalPendingAmount,
        todaysSales: todaysSales,
        salesData: salesData,
        maxY: maxY,
      );
    }

    final soldPercentage =
        totalPlots > 0 ? (soldPlots / totalPlots) * 100 : 0.0;
    final availablePercentage =
        totalPlots > 0 ? (availablePlots / totalPlots) * 100 : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Last updated text
        Text(
          'Last updated: 1 sec ago',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF5C5C5C),
          ),
        ),
        const SizedBox(height: 24),

        // Sales metrics cards
        if (hasAmenityArea) ...[
          _buildSalesRevenueCardsForAmenity(
            totalRevenue: totalRevenueWithAmenity,
            monthlyRunRate: monthlySalesRunRateWithAmenity,
          ),
          const SizedBox(height: 24),
          _buildSalesCardsForAmenity(
            totalSalesValue: totalSalesValue,
            soldPlots: soldPlots,
            averageSalesPrice: averageSalesPrice,
            allInCost: allInCost,
            monthlySalesRunRate: monthlySalesRunRate,
          ),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: IntrinsicWidth(
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
                    Text(
                      'Sales',
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        _buildSalesMetricCard(
                          'Total Sales Value',
                          totalSalesValue,
                          '$soldPlots plots sold',
                        ),
                        const SizedBox(width: 16),
                        _buildSalesMetricCard(
                          'Average Sales Price (₹ / $_areaUnitSuffix)',
                          AreaUnitUtils.rateFromSqftToDisplay(
                              averageSalesPrice, _isSqm),
                          'Based on sold plots',
                        ),
                        const SizedBox(width: 16),
                        _buildSalesMetricCard(
                          'All-in Cost (₹ / $_areaUnitSuffix)',
                          AreaUnitUtils.rateFromSqftToDisplay(
                              allInCost, _isSqm),
                          'Total cost per $_areaUnitSuffix',
                        ),
                        const SizedBox(width: 16),
                        _buildSalesMetricCard(
                          'Monthly Sales Run Rate',
                          monthlySalesRunRate,
                          '$soldPlots Plots sold this month',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: 24),

        // Sales Activity and Site sections
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Sales Activity chart
            Container(
              width: 784,
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
                      Text(
                        'Sales Activity',
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                      Row(
                        children: [
                          _buildTimeFilterButton(
                              '1D', _selectedTimeFilter == '1D', () {
                            setState(() {
                              _selectedTimeFilter = '1D';
                            });
                          }),
                          const SizedBox(width: 16),
                          _buildTimeFilterButton(
                              '7D', _selectedTimeFilter == '7D', () {
                            setState(() {
                              _selectedTimeFilter = '7D';
                            });
                          }),
                          const SizedBox(width: 16),
                          _buildTimeFilterButton(
                              '28D', _selectedTimeFilter == '28D', () {
                            setState(() {
                              _selectedTimeFilter = '28D';
                            });
                          }),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Sales Activity Chart
                  SizedBox(
                    height: 358,
                    child: _buildSalesActivityChart(
                      totalPlots,
                      todaysSales,
                      _selectedTimeFilter,
                      salesData,
                      maxY,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),

            // Site info section
            SizedBox(
              width: 340,
              child: Column(
                children: [
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
                          'Site',
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _buildSiteInfoCard(
                                'Total Layouts',
                                _siteLayouts.length.toString(),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: _buildSiteInfoCard(
                                'Total Plots',
                                totalPlots.toString(),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
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
                          'Site Sales Progress',
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _buildSiteProgressCard(
                                'Sold Plots',
                                soldPlots.toString(),
                                const Color(0xFF06AB00),
                                width: double.infinity,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: _buildSiteProgressCard(
                                'Available Plots',
                                availablePlots.toString(),
                                const Color(0xFFCF9B00),
                                width: double.infinity,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Container(
                          height: 24,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.25),
                                blurRadius: 2,
                                offset: const Offset(0, 0),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final soldFraction = totalPlots > 0
                                    ? (soldPlots / totalPlots).clamp(0.0, 1.0)
                                    : 0.0;
                                final fillRadius = soldFraction >= 1.0
                                    ? BorderRadius.circular(8)
                                    : const BorderRadius.only(
                                        topLeft: Radius.circular(8),
                                        bottomLeft: Radius.circular(8),
                                      );
                                final availableFraction =
                                    (1.0 - soldFraction).clamp(0.0, 1.0);
                                final availableRadius = availableFraction >= 1.0
                                    ? BorderRadius.circular(8)
                                    : const BorderRadius.only(
                                        topRight: Radius.circular(8),
                                        bottomRight: Radius.circular(8),
                                      );
                                final soldWidth =
                                    constraints.maxWidth * soldFraction;
                                final availableWidth =
                                    constraints.maxWidth * availableFraction;

                                return Stack(
                                  children: [
                                    Container(color: Colors.white),
                                    if (availableWidth > 0)
                                      Positioned(
                                        right: 0,
                                        top: 0,
                                        bottom: 0,
                                        width: availableWidth,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFCF9B00),
                                            borderRadius: availableRadius,
                                          ),
                                        ),
                                      ),
                                    if (soldWidth > 0)
                                      Positioned(
                                        left: 0,
                                        top: 0,
                                        bottom: 0,
                                        width: soldWidth,
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF06AB00),
                                            borderRadius: fillRadius,
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black
                                                    .withOpacity(0.25),
                                                blurRadius: 4,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Sold (${soldPercentage.toStringAsFixed(0)}%)',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFF06AB00),
                              ),
                            ),
                            Text(
                              'Available (${availablePercentage.toStringAsFixed(0)}%)',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: const Color(0xFFCF9B00),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSalesRevenueCardsForAmenity({
    required double totalRevenue,
    required double monthlyRunRate,
  }) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: 578,
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
              'Sales Revenue',
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _buildSalesMetricCard(
                  'Total Revenue',
                  totalRevenue,
                  'Based on sold plots & Amenity Area',
                  width: 265,
                  height: 130,
                  titleMaxLines: 1,
                  footerMaxLines: 2,
                ),
                const SizedBox(width: 16),
                _buildSalesMetricCard(
                  'Monthly Sales Run Rate',
                  monthlyRunRate,
                  'Based on sold plots & Amenity Area',
                  width: 265,
                  height: 130,
                  titleMaxLines: 1,
                  footerMaxLines: 2,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSalesCardsForAmenity({
    required double totalSalesValue,
    required int soldPlots,
    required double averageSalesPrice,
    required double allInCost,
    required double monthlySalesRunRate,
  }) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 1140,
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
              Text(
                'Sales',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _buildSalesMetricCard(
                    'Total Sales Value',
                    totalSalesValue,
                    '$soldPlots plots sold',
                    width: 265,
                    height: 130,
                    titleMaxLines: 1,
                    footerMaxLines: 1,
                  ),
                  const SizedBox(width: 16),
                  _buildSalesMetricCard(
                    'Average Sales Price (₹ / $_areaUnitSuffix)',
                    AreaUnitUtils.rateFromSqftToDisplay(
                        averageSalesPrice, _isSqm),
                    'Based on sold plots',
                    width: 265,
                    height: 130,
                    titleMaxLines: 1,
                    footerMaxLines: 1,
                  ),
                  const SizedBox(width: 16),
                  _buildSalesMetricCard(
                    'All-in Cost (₹ / $_areaUnitSuffix)',
                    AreaUnitUtils.rateFromSqftToDisplay(allInCost, _isSqm),
                    'Total cost per $_areaUnitSuffix',
                    width: 265,
                    height: 130,
                    titleMaxLines: 1,
                    footerMaxLines: 1,
                  ),
                  const SizedBox(width: 16),
                  _buildSalesMetricCard(
                    'Monthly Sales Run Rate',
                    monthlySalesRunRate,
                    '$soldPlots plots',
                    width: 265,
                    height: 130,
                    titleMaxLines: 1,
                    footerMaxLines: 1,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSalesTabContentWithPending({
    required double totalSalesValue,
    required int soldPlots,
    required int totalLayouts,
    required int totalPlots,
    required int availablePlots,
    required int pendingPlots,
    required double monthlySalesRunRate,
    required bool hasAmenityArea,
    required double totalRevenueWithAmenity,
    required double allInCost,
    required double averageSalesPricePerSqft,
    required double averagePendingAndSoldPricePerSqft,
    required double collectionsReceived,
    required double expectedSalesValue,
    required double totalPendingAmount,
    required int todaysSales,
    required List<int> salesData,
    required int maxY,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Last updated: 1 sec ago',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF5C5C5C),
          ),
        ),
        const SizedBox(height: 24),
        if (hasAmenityArea) ...[
          _buildSalesRevenueCardsForAmenity(
            totalRevenue: totalRevenueWithAmenity,
            monthlyRunRate: totalRevenueWithAmenity,
          ),
          const SizedBox(height: 24),
          _buildSalesCardsForAmenity(
            totalSalesValue: totalSalesValue,
            soldPlots: soldPlots,
            averageSalesPrice: averageSalesPricePerSqft,
            allInCost: allInCost,
            monthlySalesRunRate: monthlySalesRunRate,
          ),
          const SizedBox(height: 24),
        ],
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            width: 1140,
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
                  'Sales Overview',
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _buildSalesMetricCard(
                      'Sold Plots Revenue',
                      totalSalesValue,
                      '${_formatNumber(soldPlots)} plots sold',
                    ),
                    const SizedBox(width: 16),
                    _buildSalesMetricCard(
                      'Monthly Sales Run Rate',
                      monthlySalesRunRate,
                      'Based on ${_formatNumber(soldPlots)} sold plots',
                    ),
                    const SizedBox(width: 16),
                    _buildSalesMetricCard(
                      'Average Sales Price (₹ / $_areaUnitSuffix)',
                      AreaUnitUtils.rateFromSqftToDisplay(
                          averageSalesPricePerSqft, _isSqm),
                      'Based on only sold plots',
                    ),
                    const SizedBox(width: 16),
                    _buildSalesMetricCard(
                      'Average Sales Price (₹ / $_areaUnitSuffix)',
                      AreaUnitUtils.rateFromSqftToDisplay(
                          averagePendingAndSoldPricePerSqft, _isSqm),
                      'Based on pending & sold plots',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 1140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPendingSalesSummaryCard(
                  width: 431,
                  title: 'Received Payments',
                  subtitle:
                      'Based on partial payments from pending & sold plots',
                  metricTitle: 'Collections Received',
                  metricValue: collectionsReceived,
                  metricFooter:
                      '${_formatNumber(soldPlots)} plots sold & ${_formatNumber(pendingPlots)} Pending',
                  metricCardWidth: 256,
                ),
                const SizedBox(width: 24),
                _buildPendingSalesSummaryCard(
                  width: 353,
                  title: 'Expected Revenue',
                  subtitle: 'Based on full value of pending & sold plots',
                  metricTitle: 'Expected Sales Value',
                  metricValue: expectedSalesValue,
                  metricFooter:
                      '${_formatNumber(soldPlots)} plots sold & ${_formatNumber(pendingPlots)} Pending',
                ),
                const SizedBox(width: 24),
                _buildPendingSalesSummaryCard(
                  width: 308,
                  title: 'Pending Payments',
                  subtitle: 'Amount to be received from buyers',
                  metricTitle: 'Total Pending Amount',
                  metricValue: totalPendingAmount,
                  metricFooter: '${_formatNumber(pendingPlots)} Pending Plots',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 1140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 808,
                  height: 422,
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
                          Text(
                            'Sales Activity',
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              color: Colors.black,
                            ),
                          ),
                          Row(
                            children: [
                              _buildTimeFilterButton(
                                  '1D', _selectedTimeFilter == '1D', () {
                                setState(() {
                                  _selectedTimeFilter = '1D';
                                });
                              }),
                              const SizedBox(width: 16),
                              _buildTimeFilterButton(
                                  '7D', _selectedTimeFilter == '7D', () {
                                setState(() {
                                  _selectedTimeFilter = '7D';
                                });
                              }),
                              const SizedBox(width: 16),
                              _buildTimeFilterButton(
                                  '28D', _selectedTimeFilter == '28D', () {
                                setState(() {
                                  _selectedTimeFilter = '28D';
                                });
                              }),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 338,
                        child: _buildSalesActivityChart(
                          totalPlots,
                          todaysSales,
                          _selectedTimeFilter,
                          salesData,
                          maxY,
                          topLabelTopPadding: 0,
                          labelToChartGap: 0,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                _buildPendingSiteSalesProgressCard(
                  totalLayouts: totalLayouts,
                  totalPlots: totalPlots,
                  availablePlots: availablePlots,
                  soldPlots: soldPlots,
                  pendingPlots: pendingPlots,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPendingSalesSummaryCard({
    required double width,
    required String title,
    required String subtitle,
    required String metricTitle,
    required double metricValue,
    required String metricFooter,
    double metricCardWidth = 265,
    double height = 229,
  }) {
    return Container(
      width: width,
      height: height,
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
            title,
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w400,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 16),
          _buildSalesMetricCard(
            metricTitle,
            metricValue,
            metricFooter,
            width: metricCardWidth,
            height: 120,
            titleMaxLines: 1,
            footerMaxLines: 1,
          ),
        ],
      ),
    );
  }

  Widget _buildPendingSiteSalesProgressCard({
    required int totalLayouts,
    required int totalPlots,
    required int availablePlots,
    required int soldPlots,
    required int pendingPlots,
  }) {
    const double rowGap = 15.9;
    return Container(
      width: 308,
      height: 422,
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
            'Site Sales Progress',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: rowGap),
          _buildPendingSiteSalesProgressRow(
            'Total Layouts',
            _formatNumber(totalLayouts),
          ),
          const SizedBox(height: rowGap),
          _buildPendingSiteSalesProgressRow(
            'Total Plots',
            _formatNumber(totalPlots),
          ),
          const SizedBox(height: rowGap),
          _buildPendingSiteSalesProgressRow(
            'Available Plots',
            _formatNumber(availablePlots),
            backgroundColor: const Color(0xFFE8F4EA),
          ),
          const SizedBox(height: rowGap),
          _buildPendingSiteSalesProgressRow(
            'Sold Plots',
            _formatNumber(soldPlots),
            backgroundColor: const Color(0xFFF8F1F2),
          ),
          const SizedBox(height: rowGap),
          _buildPendingSiteSalesProgressRow(
            'Pending Plots',
            _formatNumber(pendingPlots),
            backgroundColor: const Color(0xFFF9F2E6),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingSiteSalesProgressRow(
    String label,
    String value, {
    Color backgroundColor = Colors.white,
  }) {
    return Container(
      width: 276,
      height: 56,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: backgroundColor,
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
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF5C5C5C),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w400,
                color: Colors.black,
                height: 1.0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfitRoiPendingTabContent() {
    final totalExpenses = _dashboardData!['totalExpenses'] as double? ?? 0.0;
    final bookedRevenue = _dashboardData!['totalSalesValue'] as double? ?? 0.0;
    final totalCompensation = _dashboardData!['totalCompensation'] as double? ??
        (_calculateTotalProjectManagersCompensation() +
            _calculateTotalAgentsCompensation());

    final pendingSalesMetrics = _calculatePendingSalesMetrics();
    final collectionsReceived =
        pendingSalesMetrics['collectionsReceived'] ?? 0.0;
    final expectedRevenue = pendingSalesMetrics['expectedSalesValue'] ?? 0.0;
    final bookedGrossProfit = bookedRevenue - totalExpenses;
    final expectedGrossProfit = expectedRevenue - totalExpenses;
    final actualGrossProfit = collectionsReceived - totalExpenses;
    final actualNetProfit = actualGrossProfit - totalCompensation;
    final bookedNetProfit = bookedGrossProfit - totalCompensation;
    final expectedNetProfit = expectedGrossProfit - totalCompensation;

    // ROI (%) = (Net Profit / Total Expenses) * 100
    final actualRoi = _safePercent(actualNetProfit, totalExpenses);
    final bookedRoi = _safePercent(bookedNetProfit, totalExpenses);
    final expectedRoi = _safePercent(expectedNetProfit, totalExpenses);

    // Profit Margin (%) = (Net Profit / Total Sales Value) * 100
    final actualTotalSalesValue = collectionsReceived;
    final bookedTotalSalesValue = bookedRevenue;
    final expectedTotalSalesValue = expectedRevenue;
    final actualProfitMargin =
        _safePercent(actualNetProfit, actualTotalSalesValue);
    final bookedProfitMargin =
        _safePercent(bookedNetProfit, bookedTotalSalesValue);
    final expectedProfitMargin =
        _safePercent(expectedNetProfit, expectedTotalSalesValue);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Last updated: 1 sec ago',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF5C5C5C),
          ),
        ),
        const SizedBox(height: 24),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 1164,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 760,
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
                        'Profit & ROI Comparison',
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Compare actual, booked, and expected profitability for this project.',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Table(
                            columnWidths: const {
                              0: FixedColumnWidth(140),
                              1: FixedColumnWidth(196),
                              2: FixedColumnWidth(196),
                              3: FixedColumnWidth(196),
                            },
                            border: const TableBorder(
                              horizontalInside:
                                  BorderSide(color: Colors.black, width: 1),
                              verticalInside:
                                  BorderSide(color: Colors.black, width: 1),
                            ),
                            defaultVerticalAlignment:
                                TableCellVerticalAlignment.middle,
                            children: [
                              TableRow(
                                children: [
                                  _buildPendingTableHeaderCell('Metric'),
                                  _buildPendingTableHeaderCell(
                                      'Actual (Payments Receive)'),
                                  _buildPendingTableHeaderCell(
                                      'Booked (Only Sold Plots)'),
                                  _buildPendingTableHeaderCell(
                                      'Expected (Pipeline)'),
                                ],
                              ),
                              TableRow(
                                children: [
                                  _buildPendingTableMetricCell('Gross Profit'),
                                  _buildPendingCurrencyCell(actualGrossProfit),
                                  _buildPendingCurrencyCell(bookedGrossProfit),
                                  _buildPendingCurrencyCell(
                                      expectedGrossProfit),
                                ],
                              ),
                              TableRow(
                                children: [
                                  _buildPendingTableMetricCell('Net Profit'),
                                  _buildPendingCurrencyCell(actualNetProfit),
                                  _buildPendingCurrencyCell(bookedNetProfit),
                                  _buildPendingCurrencyCell(expectedNetProfit),
                                ],
                              ),
                              TableRow(
                                children: [
                                  _buildPendingTableMetricCell('ROI'),
                                  _buildPendingPercentCell(actualRoi),
                                  _buildPendingPercentCell(bookedRoi),
                                  _buildPendingPercentCell(expectedRoi),
                                ],
                              ),
                              TableRow(
                                children: [
                                  _buildPendingTableMetricCell('Profit Margin'),
                                  _buildPendingPercentCell(actualProfitMargin),
                                  _buildPendingPercentCell(bookedProfitMargin),
                                  _buildPendingPercentCell(
                                      expectedProfitMargin),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Container(
                  width: 592,
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
                        'Revenue Overview',
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Overview of booked sales, collections received, and expected revenue for this project.',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black, width: 1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Table(
                            columnWidths: const {
                              0: FixedColumnWidth(176),
                              1: FixedColumnWidth(196),
                            },
                            border: const TableBorder(
                              horizontalInside:
                                  BorderSide(color: Colors.black, width: 1),
                              verticalInside:
                                  BorderSide(color: Colors.black, width: 1),
                            ),
                            defaultVerticalAlignment:
                                TableCellVerticalAlignment.middle,
                            children: [
                              TableRow(
                                children: [
                                  _buildPendingTableHeaderCell('Metric'),
                                  _buildPendingTableHeaderCell('Amount'),
                                ],
                              ),
                              TableRow(
                                children: [
                                  _buildPendingTableMetricCell(
                                      'Sold Plots Revenue'),
                                  _buildPendingCurrencyCell(bookedRevenue),
                                ],
                              ),
                              TableRow(
                                children: [
                                  _buildPendingTableMetricCell(
                                      'Collections Received'),
                                  _buildPendingCurrencyCell(
                                      collectionsReceived),
                                ],
                              ),
                              TableRow(
                                children: [
                                  _buildPendingTableMetricCell(
                                      'Expected Revenue'),
                                  _buildPendingCurrencyCell(expectedRevenue),
                                ],
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
          ),
        ),
      ],
    );
  }

  double _safePercent(double numerator, double denominator) {
    if (denominator == 0 || !denominator.isFinite) {
      return 0.0;
    }
    final value = (numerator / denominator) * 100;
    if (value.isNaN || value.isInfinite) {
      return 0.0;
    }
    return value;
  }

  Widget _buildPendingTableHeaderCell(String text) {
    return Container(
      height: 48,
      color: const Color(0x33707070),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.black,
        ),
      ),
    );
  }

  Widget _buildPendingTableMetricCell(String text) {
    return Container(
      height: 48,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.black,
        ),
      ),
    );
  }

  Widget _buildPendingCurrencyCell(double value) {
    return Container(
      height: 48,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerRight,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color.fromRGBO(255, 255, 255, 0.95),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '₹',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: const Color(0xFF5C5C5C),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatNumberNoDecimals(value),
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingPercentCell(double value) {
    return Container(
      height: 48,
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerRight,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color.fromRGBO(255, 255, 255, 0.95),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.centerRight,
        child: Text(
          '${_formatPercentageDisplay(value)}%',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
        ),
      ),
    );
  }

  Map<String, double> _calculatePendingSalesMetrics() {
    double expectedSalesValue = 0.0;
    double collectionsReceived = 0.0;
    double pendingAndSoldArea = 0.0;

    for (final layout in _siteLayouts) {
      final plots = layout['plots'] as List<dynamic>? ?? const [];
      for (final rawPlot in plots) {
        if (rawPlot is! Map) {
          continue;
        }

        final plot = Map<String, dynamic>.from(rawPlot);
        final status = (plot['status'] ?? '').toString().toLowerCase().trim();
        final isSold = status == 'sold';
        final isPending = status == 'pending' || status == 'reserved';
        if (!isSold && !isPending) {
          continue;
        }

        final area = _parsePlotNumeric(plot['area']);
        final salePrice = _parsePlotNumeric(plot['sale_price']);
        if (area > 0 && salePrice > 0) {
          final value = area * salePrice;
          expectedSalesValue += value;
          pendingAndSoldArea += area;
        }

        collectionsReceived += _sumPlotPaymentAmount(plot);
      }
    }

    final averagePendingAndSoldPricePerSqft =
        pendingAndSoldArea > 0 ? expectedSalesValue / pendingAndSoldArea : 0.0;
    final totalPendingAmount =
        math.max(0.0, expectedSalesValue - collectionsReceived);

    return {
      'expectedSalesValue': expectedSalesValue,
      'collectionsReceived': collectionsReceived,
      'totalPendingAmount': totalPendingAmount,
      'averagePendingAndSoldPricePerSqft': averagePendingAndSoldPricePerSqft,
      'pendingAndSoldArea': pendingAndSoldArea,
    };
  }

  double _sumPlotPaymentAmount(Map<String, dynamic> plot) {
    final rawPayments = plot['payments'];
    if (rawPayments == null) return 0.0;

    List<dynamic> payments;
    if (rawPayments is List) {
      payments = rawPayments;
    } else if (rawPayments is String && rawPayments.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawPayments);
        payments = decoded is List ? decoded : const [];
      } catch (_) {
        payments = const [];
      }
    } else {
      payments = const [];
    }

    double total = 0.0;
    for (final rawPayment in payments) {
      if (rawPayment is! Map) {
        continue;
      }
      final amount = rawPayment['paymentAmount'] ??
          rawPayment['payment_amount'] ??
          rawPayment['amount'];
      total += _parsePlotNumeric(amount);
    }

    return total;
  }

  Widget _buildSalesMetricCard(
    String title,
    double value,
    String footer, {
    double width = 265,
    double? height,
    int? titleMaxLines,
    int? footerMaxLines,
  }) {
    final isFixedHeightCard = height != null;
    final valueStyle = GoogleFonts.inter(
      fontSize: 20,
      fontWeight: FontWeight.normal,
      color: Colors.black,
      height: 1.0,
    );

    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: isFixedHeightCard ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: isFixedHeightCard
            ? MainAxisAlignment.spaceBetween
            : MainAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: titleMaxLines,
            overflow: titleMaxLines != null
                ? TextOverflow.ellipsis
                : TextOverflow.clip,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
          if (!isFixedHeightCard) const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('₹', style: valueStyle),
              const SizedBox(width: 8),
              Text(_formatNumberNoDecimals(value), style: valueStyle),
            ],
          ),
          if (!isFixedHeightCard) const SizedBox(height: 16),
          Text(
            footer,
            maxLines: footerMaxLines,
            overflow: footerMaxLines != null
                ? TextOverflow.ellipsis
                : TextOverflow.clip,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeFilterButton(
      String label, bool isActive, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.97),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: isActive
                  ? const Color(0xFF0C8CE9)
                  : Colors.black.withOpacity(0.25),
              blurRadius: 2,
              offset: const Offset(0, 0),
            ),
          ],
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMultiDateXAxisRow(
      String timeFilter, List<int> salesData, List<int>? labelIndices) {
    final today = DateTime.now();
    int daysToLookBack = timeFilter == '7D' ? 7 : 29;
    List<DateTime> dates = [];

    for (int i = daysToLookBack - 1; i >= 0; i--) {
      dates.add(today.subtract(Duration(days: i)));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final chartWidth = constraints.maxWidth;
        // First data point starts at a smaller offset for left alignment
        final xOffset = timeFilter == '28D' ? 14.0 : 18.0;
        final rightInset = timeFilter == '28D' ? 48.0 : 40.0;
        final availableWidth = chartWidth - xOffset - rightInset;
        final xSpacing = dates.length > 1
            ? availableWidth / (dates.length - 1)
            : availableWidth;
        final resolvedLabelIndices = labelIndices ??
            (timeFilter == '28D'
                ? _buildFixedIntervalLabelIndices(dates.length, 4,
                    includeLast: true)
                : List<int>.generate(dates.length, (index) => index));
        final majorLabelIndexSet = resolvedLabelIndices.toSet();
        final minorTickIndices = timeFilter == '28D'
            ? List<int>.generate(dates.length, (index) => index)
                .where((index) => !majorLabelIndexSet.contains(index))
                .toList()
            : const <int>[];
        final minorTickXShift = timeFilter == '28D' ? 11.0 : 0.0;
        final labelXShift = timeFilter == '28D' ? -18.0 : -29.0;

        return SizedBox(
          width: chartWidth,
          height: 64,
          child: Stack(
            children: [
              ...minorTickIndices.map((dateIndex) {
                final xPos = xOffset + (dateIndex * xSpacing) + minorTickXShift;
                return Positioned(
                  left: xPos,
                  child: Container(
                    height: 3,
                    width: 1,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                );
              }),
              ...List.generate(
                resolvedLabelIndices.length,
                (index) {
                  final dateIndex = resolvedLabelIndices[index];
                  final date = dates[dateIndex];
                  final dateStr = '${date.day} ${_getMonthAbbr(date.month)}';
                  final xPos = xOffset + (dateIndex * xSpacing);

                  return Positioned(
                    left: xPos,
                    child: Transform.translate(
                      offset: Offset(
                          labelXShift, 0), // Center the label horizontally
                      child: Column(
                        children: [
                          Container(
                            height: 4,
                            width: 2,
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            width: 56,
                            child: Text(
                              dateStr,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.normal,
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  List<int> _buildFixedIntervalLabelIndices(
    int length,
    int dayInterval, {
    bool includeLast = true,
  }) {
    if (length <= 1 || dayInterval <= 0) {
      return List<int>.generate(length, (index) => index);
    }

    final indices = <int>[
      for (int i = 0; i < length; i += dayInterval) i,
    ];
    if (includeLast && (indices.isEmpty || indices.last != length - 1)) {
      indices.add(length - 1);
    }

    return indices;
  }

  String _getMonthAbbr(int month) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return months[month - 1];
  }

  Widget _buildSalesActivityChart(
    int totalPlots,
    int todaysSales,
    String timeFilter,
    List<int> salesData,
    int fixedMaxY, {
    double topLabelTopPadding = 12,
    double labelToChartGap = 8,
  }) {
    // Use the fixed maxY calculated at the tab level for consistent positioning
    final int maxY = fixedMaxY;

    // Calculate x-axis intervals
    int xInterval = maxY ~/ 5;
    final labelIndices = timeFilter == '28D'
        ? _buildFixedIntervalLabelIndices(salesData.length, 4,
            includeLast: true)
        : List<int>.generate(salesData.length, (index) => index);

    return SizedBox.expand(
      child: Padding(
        padding: const EdgeInsets.only(right: 24, top: 16, bottom: 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top section with "Plots Sold" label and arrow
            Padding(
              padding: EdgeInsets.only(left: 4, top: topLabelTopPadding),
              child: Row(
                children: [
                  Text(
                    'Plots Sold',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF5C5C5C),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: labelToChartGap),
            Transform.translate(
              offset: const Offset(0, 26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Chart area with grid
                  SizedBox(
                    height: 250,
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        const SizedBox(width: 8),

                        // Y-axis labels
                        SizedBox(
                          width: 61,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              for (int i = maxY; i > 0; i -= xInterval)
                                SizedBox(
                                  height: 50,
                                  child: Align(
                                    alignment: Alignment.topRight,
                                    child: Transform.translate(
                                      offset: const Offset(-14, -10),
                                      child: Text(
                                        i.toString(),
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: const Color(0xFF5C5C5C),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Grid and chart area
                        Expanded(
                          child: Transform.translate(
                            offset: const Offset(0, 0),
                            child: CustomPaint(
                              painter: _ChartPainter(
                                maxY: maxY,
                                xInterval: xInterval,
                                todaysSales: todaysSales,
                                timeFilter: timeFilter,
                                salesData: salesData,
                                labelIndices: labelIndices,
                              ),
                              child: Container(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // X-axis labels with proper alignment
                  if (timeFilter == '1D')
                    SizedBox(
                      height: 52,
                      child: Row(
                        children: [
                          const SizedBox(width: 8),
                          const SizedBox(width: 8),
                          const SizedBox(width: 61),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Align(
                              alignment: Alignment.center,
                              child: Transform.translate(
                                offset: const Offset(-10, 0),
                                child: Column(
                                  children: [
                                    Container(
                                      height: 4,
                                      width: 2,
                                      decoration: BoxDecoration(
                                        color: Colors.black,
                                        borderRadius: BorderRadius.circular(1),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Today',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.normal,
                                        color: Colors.black,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    SizedBox(
                      height: 52,
                      child: Row(
                        children: [
                          const SizedBox(width: 8),
                          const SizedBox(width: 8),
                          const SizedBox(width: 61),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Transform.translate(
                              offset: const Offset(0, 0),
                              child: _buildMultiDateXAxisRow(
                                  timeFilter, salesData, labelIndices),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSiteInfoCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.normal,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSiteProgressCard(
    String label,
    String value,
    Color valueColor, {
    double width = 130,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.normal,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSiteTabContent() {
    // Show skeleton until site data is loaded
    if (_dashboardData == null) {
      return _buildSiteTabLoadingSkeleton();
    }

    if (_isSiteDataLoading) {
      return _buildSiteTabLoadingSkeleton();
    }

    final totalExpenses = _dashboardData!['totalExpenses'] as double;
    final sellingArea = _dashboardData!['sellingArea'] as double;
    final allInCost = _dashboardData!['allInCost'] as double;
    final totalSalesValue = _dashboardData!['totalSalesValue'] as double;
    final totalLayouts = _dashboardData!['totalLayouts'] as int? ?? 0;
    final totalPlots = _dashboardData!['totalPlots'] as int? ?? 0;
    final soldPlots = _dashboardData!['soldPlots'] as int? ?? 0;
    final pendingPlots = _dashboardData!['pendingPlots'] as int? ?? 0;
    final availablePlots = _dashboardData!['availablePlots'] as int? ??
        math.max(0, totalPlots - soldPlots - pendingPlots);

    // Calculate Total Plot Cost = sum of (area * all-in cost) for all plots
    double totalPlotCost = 0.0;
    // Calculate Gross Profit = sum of gross profit of all layouts
    double grossProfit = 0.0;
    double totalAreaSold = 0.0;
    double totalCommittedArea = 0.0;

    for (var layout in _siteLayouts) {
      final plots = layout['plots'] as List<dynamic>;
      double layoutGrossProfit = 0.0;

      for (var plot in plots) {
        final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
        totalPlotCost += area * allInCost;

        // Calculate profit for sold plots
        final status = (plot['status'] as String? ?? 'available').toLowerCase();
        final isPending = status == 'pending' || status == 'reserved';
        if (status == 'sold') {
          final salePrice = ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
          final saleValue = salePrice * area;
          final plotCost = area * allInCost;
          final plotProfit = saleValue - plotCost;
          layoutGrossProfit += plotProfit;
          totalAreaSold += area;
          totalCommittedArea += area;
        } else if (isPending) {
          totalCommittedArea += area;
        }
      }

      grossProfit += layoutGrossProfit;
    }

    if (pendingPlots > 0) {
      return _buildSiteTabContentWithPending(
        totalLayouts: totalLayouts,
        totalPlots: totalPlots,
        soldPlots: soldPlots,
        pendingPlots: pendingPlots,
        availablePlots: availablePlots,
        totalAreaSold: totalAreaSold,
        totalCommittedArea: totalCommittedArea,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Site Sales Progress + Site card (fixed width, no stretch on wide screens)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 1140,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 808,
                    child: _buildSiteSalesProgressSummary(
                      totalSalesValue: totalSalesValue,
                      totalAreaSold: totalAreaSold,
                      soldPlots: soldPlots,
                      availablePlots: availablePlots,
                    ),
                  ),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: 308,
                    child: _buildSitePanelCard(
                      totalLayouts: totalLayouts,
                      totalPlots: totalPlots,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        _buildLayoutsToolbar(),
        const SizedBox(height: 24),

        // Layout Wise Financial Summary
        _buildLayoutWiseFinancialSummary(),
      ],
    );
  }

  Widget _buildSiteTabContentWithPending({
    required int totalLayouts,
    required int totalPlots,
    required int soldPlots,
    required int pendingPlots,
    required int availablePlots,
    required double totalAreaSold,
    required double totalCommittedArea,
  }) {
    final soldPercent = totalPlots > 0 ? (soldPlots / totalPlots) * 100 : 0.0;
    final pendingPercent =
        totalPlots > 0 ? (pendingPlots / totalPlots) * 100 : 0.0;
    final availablePercent =
        totalPlots > 0 ? (availablePlots / totalPlots) * 100 : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Last updated: 1 sec ago',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF5C5C5C),
          ),
        ),
        const SizedBox(height: 24),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: 1140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildPendingSiteAreaOverviewCard(
                  totalAreaSold: totalAreaSold,
                  totalCommittedArea: totalCommittedArea,
                ),
                const SizedBox(width: 24),
                _buildPendingSiteSalesProgressSummary(
                  totalLayouts: totalLayouts,
                  totalPlots: totalPlots,
                  soldPlots: soldPlots,
                  pendingPlots: pendingPlots,
                  availablePlots: availablePlots,
                  soldPercent: soldPercent,
                  pendingPercent: pendingPercent,
                  availablePercent: availablePercent,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        _buildLayoutsToolbar(),
        const SizedBox(height: 24),
        _buildLayoutWiseFinancialSummary(),
      ],
    );
  }

  Widget _buildPendingSiteAreaOverviewCard({
    required double totalAreaSold,
    required double totalCommittedArea,
  }) {
    return Container(
      width: 362,
      height: 305,
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
            'Area Sales Overview',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Column(
              children: [
                _buildPendingSiteAreaMetricCard(
                  title: 'Total Sold Area',
                  value: _formatNumberNoDecimals(totalAreaSold),
                ),
                const SizedBox(height: 24),
                _buildPendingSiteAreaMetricCard(
                  title: 'Total Committed Area',
                  value: _formatNumberNoDecimals(totalCommittedArea),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingSiteAreaMetricCard({
    required String title,
    required String value,
  }) {
    return Expanded(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF5C5C5C),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  value,
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _areaUnitSuffix,
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingSiteSalesProgressSummary({
    required int totalLayouts,
    required int totalPlots,
    required int soldPlots,
    required int pendingPlots,
    required int availablePlots,
    required double soldPercent,
    required double pendingPercent,
    required double availablePercent,
  }) {
    return Container(
      width: 754,
      height: 305,
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
            'Site Sales Progress',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _buildPendingSiteProgressMetric(
                title: 'Total Layouts',
                value: _formatNumber(totalLayouts),
              ),
              const SizedBox(width: 16),
              _buildPendingSiteProgressMetric(
                title: 'Total Plots',
                value: _formatNumber(totalPlots),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _buildPendingSiteProgressMetric(
                title: 'Sold Plots',
                value: _formatNumber(soldPlots),
                backgroundColor: const Color(0xFFF8F1F2),
              ),
              const SizedBox(width: 16),
              _buildPendingSiteProgressMetric(
                title: 'Pending Plots',
                value: _formatNumber(pendingPlots),
                backgroundColor: const Color(0xFFF9F2E6),
              ),
              const SizedBox(width: 16),
              _buildPendingSiteProgressMetric(
                title: 'Available Plots',
                value: _formatNumber(availablePlots),
                backgroundColor: const Color(0xFFE8F4EA),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 2,
                  offset: const Offset(0, 0),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final soldFraction =
                      totalPlots > 0 ? (soldPlots / totalPlots) : 0.0;
                  final pendingFraction =
                      totalPlots > 0 ? (pendingPlots / totalPlots) : 0.0;
                  final availableFraction =
                      totalPlots > 0 ? (availablePlots / totalPlots) : 0.0;

                  final soldWidth =
                      constraints.maxWidth * soldFraction.clamp(0.0, 1.0);
                  final pendingWidth =
                      constraints.maxWidth * pendingFraction.clamp(0.0, 1.0);
                  final availableWidth = math.max(
                    0.0,
                    constraints.maxWidth - soldWidth - pendingWidth,
                  );

                  return Stack(
                    children: [
                      if (soldWidth > 0)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: soldWidth,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF0000),
                              borderRadius: soldFraction >= 1
                                  ? BorderRadius.circular(8)
                                  : const BorderRadius.only(
                                      topLeft: Radius.circular(8),
                                      bottomLeft: Radius.circular(8),
                                    ),
                            ),
                          ),
                        ),
                      if (pendingWidth > 0)
                        Positioned(
                          left: soldWidth,
                          top: 0,
                          bottom: 0,
                          width: pendingWidth,
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0xFFFFB12A),
                            ),
                          ),
                        ),
                      if (availableWidth > 0)
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          width: availableWidth,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xFF5DE90C),
                              borderRadius: availableFraction >= 1
                                  ? BorderRadius.circular(8)
                                  : const BorderRadius.only(
                                      topRight: Radius.circular(8),
                                      bottomRight: Radius.circular(8),
                                    ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${soldPercent.toStringAsFixed(0)}%',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFFF0000),
                ),
              ),
              Text(
                '${pendingPercent.toStringAsFixed(0)}%',
                style: GoogleFonts.inter(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFFFB12A),
                ),
              ),
              SizedBox(
                width: 60,
                child: Text(
                  '${availablePercent.toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF5DE90C),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Sold',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFFF0000),
                ),
              ),
              Text(
                'Pending',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFFFB12A),
                ),
              ),
              Text(
                'Available',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF5DE90C),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPendingSiteProgressMetric({
    required String title,
    required String value,
    Color backgroundColor = Colors.white,
  }) {
    return Container(
      width: 230,
      height: 56,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: backgroundColor,
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
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF5C5C5C),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w400,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSiteSalesProgressSummary({
    required double totalSalesValue,
    required double totalAreaSold,
    required int soldPlots,
    required int availablePlots,
  }) {
    final totalPlots = soldPlots + availablePlots;
    final soldPercent = totalPlots > 0 ? (soldPlots / totalPlots) * 100 : 0.0;
    final availablePercent =
        totalPlots > 0 ? (availablePlots / totalPlots) * 100 : 0.0;

    return Container(
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
            'Site Sales Progress',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _buildSiteSummaryCard(
                  title: 'Total Sales Value',
                  valueWidget: Row(
                    children: [
                      Text(
                        '₹',
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.normal,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _formatNumberNoDecimals(totalSalesValue),
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: _buildSiteSummaryCard(
                  title: 'Total Area Sold',
                  valueWidget: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _formatNumberNoDecimals(totalAreaSold),
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _areaUnitSuffix,
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.normal,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _buildSiteSummaryCard(
                  title: 'Sold Plots',
                  valueWidget: Text(
                    soldPlots.toString(),
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF06AB00),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _buildSiteSummaryCard(
                  title: 'Available Plots',
                  valueWidget: Text(
                    availablePlots.toString(),
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFFCF9B00),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                      spreadRadius: 0,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final soldFraction = totalPlots > 0
                          ? (soldPlots / totalPlots).clamp(0.0, 1.0)
                          : 0.0;
                      final availableFraction =
                          (1.0 - soldFraction).clamp(0.0, 1.0);
                      final soldWidth = constraints.maxWidth * soldFraction;
                      final availableWidth =
                          constraints.maxWidth * availableFraction;
                      final soldRadius = soldFraction >= 1.0
                          ? BorderRadius.circular(8)
                          : const BorderRadius.only(
                              topLeft: Radius.circular(8),
                              bottomLeft: Radius.circular(8),
                            );
                      final availableRadius = availableFraction >= 1.0
                          ? BorderRadius.circular(8)
                          : const BorderRadius.only(
                              topRight: Radius.circular(8),
                              bottomRight: Radius.circular(8),
                            );

                      return Stack(
                        children: [
                          if (availableWidth > 0)
                            Positioned(
                              right: 0,
                              top: 0,
                              bottom: 0,
                              width: availableWidth,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFCF9B00),
                                  borderRadius: availableRadius,
                                ),
                              ),
                            ),
                          if (soldWidth > 0)
                            Positioned(
                              left: 0,
                              top: 0,
                              bottom: 0,
                              width: soldWidth,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF06AB00),
                                  borderRadius: soldRadius,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${soldPercent.toStringAsFixed(0)}%',
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF06AB00),
                    ),
                  ),
                  Text(
                    '${availablePercent.toStringAsFixed(0)}%',
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFFCF9B00),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Sold',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF06AB00),
                    ),
                  ),
                  Text(
                    'Available',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFFCF9B00),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSiteSummaryCard({
    required String title,
    required Widget valueWidget,
    double? width,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 16),
          valueWidget,
        ],
      ),
    );
  }

  Widget _buildSitePanelCard({
    required int totalLayouts,
    required int totalPlots,
  }) {
    return Container(
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
            'Site',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 16),
          _buildSitePanelMiniCard(
            title: 'Total Layouts',
            value: totalLayouts.toString(),
          ),
          const SizedBox(height: 16),
          _buildSitePanelMiniCard(
            title: 'Total Plots',
            value: totalPlots.toString(),
          ),
        ],
      ),
    );
  }

  Widget _buildSitePanelMiniCard({
    required String title,
    required String value,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.normal,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLayoutsToolbar() {
    const filterIconAsset = 'assets/images/Filter.svg';
    const expandIconAsset = 'assets/images/Expand.svg';
    const collapseIconAsset = 'assets/images/Collapse.svg';
    const zoomOutAsset = 'assets/images/Zoom_out.svg';
    const zoomInAsset = 'assets/images/Zoom_in.svg';

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Layouts',
          style: GoogleFonts.inter(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.black,
          ),
        ),
        Row(
          children: [
            PopupMenuButton<String>(
              initialValue: _selectedLayoutFilter,
              onSelected: (value) {
                setState(() {
                  _selectedLayoutFilter = value;
                });
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'All',
                  child: Text('All layouts'),
                ),
                PopupMenuItem(
                  value: 'Available',
                  child: Text('Available layouts'),
                ),
                PopupMenuItem(
                  value: 'Sold out',
                  child: Text('Sold out layouts'),
                ),
              ],
              child: _buildLayoutsActionButton(
                label: 'Filter',
                leading: SvgPicture.asset(
                  filterIconAsset,
                  width: 16,
                  height: 10,
                  fit: BoxFit.contain,
                  placeholderBuilder: (context) => const SizedBox(
                    width: 16,
                    height: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 24),
            _buildLayoutsActionButton(
              label: 'Expand all layouts',
              trailing: SvgPicture.asset(
                expandIconAsset,
                width: 14,
                height: 7,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const SizedBox(
                  width: 14,
                  height: 7,
                ),
              ),
              onTap: () {
                setState(() {
                  _collapsedLayouts.clear();
                });
              },
            ),
            const SizedBox(width: 24),
            _buildLayoutsActionButton(
              label: 'Collapse all layouts',
              trailing: SvgPicture.asset(
                collapseIconAsset,
                width: 14,
                height: 7,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const SizedBox(
                  width: 14,
                  height: 7,
                ),
              ),
              onTap: () {
                setState(() {
                  _collapsedLayouts.clear();
                  for (int i = 0; i < _siteLayouts.length; i++) {
                    _collapsedLayouts.add(i);
                  }
                });
              },
            ),
            const SizedBox(width: 24),
            Row(
              children: [
                Text(
                  'Zoom:',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(width: 8),
                _buildZoomButton(
                  zoomOutAsset,
                  onTap: () {
                    setState(() {
                      _tableZoomLevel =
                          _stepZoomLevel(_tableZoomLevel, increase: false);
                    });
                  },
                ),
                const SizedBox(width: 8),
                Text(
                  '${(_tableZoomLevel * 100).round()}%',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black.withOpacity(0.75),
                  ),
                ),
                const SizedBox(width: 8),
                _buildZoomButton(
                  zoomInAsset,
                  onTap: () {
                    setState(() {
                      _tableZoomLevel =
                          _stepZoomLevel(_tableZoomLevel, increase: true);
                    });
                  },
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCompensationLayoutsToolbar() {
    const filterIconAsset = 'assets/images/Filter.svg';
    const expandIconAsset = 'assets/images/Expand.svg';
    const collapseIconAsset = 'assets/images/Collapse.svg';
    const zoomOutAsset = 'assets/images/Zoom_out.svg';
    const zoomInAsset = 'assets/images/Zoom_in.svg';

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Layouts',
          style: GoogleFonts.inter(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.black,
          ),
        ),
        Row(
          children: [
            PopupMenuButton<String>(
              initialValue: _selectedCompensationLayoutFilter,
              onSelected: (value) {
                setState(() {
                  _selectedCompensationLayoutFilter = value;
                });
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'All',
                  child: Text('All layouts'),
                ),
                PopupMenuItem(
                  value: 'Available',
                  child: Text('Available layouts'),
                ),
                PopupMenuItem(
                  value: 'Sold out',
                  child: Text('Sold out layouts'),
                ),
              ],
              child: _buildLayoutsActionButton(
                label: 'Filter',
                leading: SvgPicture.asset(
                  filterIconAsset,
                  width: 16,
                  height: 10,
                  fit: BoxFit.contain,
                  placeholderBuilder: (context) => const SizedBox(
                    width: 16,
                    height: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 24),
            _buildLayoutsActionButton(
              label: 'Expand all layouts',
              trailing: SvgPicture.asset(
                expandIconAsset,
                width: 14,
                height: 7,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const SizedBox(
                  width: 14,
                  height: 7,
                ),
              ),
              onTap: () {
                setState(() {
                  _collapsedCompensationLayouts.clear();
                });
              },
            ),
            const SizedBox(width: 24),
            _buildLayoutsActionButton(
              label: 'Collapse all layouts',
              trailing: SvgPicture.asset(
                collapseIconAsset,
                width: 14,
                height: 7,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const SizedBox(
                  width: 14,
                  height: 7,
                ),
              ),
              onTap: () {
                setState(() {
                  _collapsedCompensationLayouts.clear();
                  for (int i = 0; i < _compensationLayouts.length; i++) {
                    _collapsedCompensationLayouts.add(i);
                  }
                });
              },
            ),
            const SizedBox(width: 24),
            Row(
              children: [
                Text(
                  'Zoom:',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(width: 8),
                _buildZoomButton(
                  zoomOutAsset,
                  onTap: () {
                    setState(() {
                      _compensationTableZoomLevel = _stepZoomLevel(
                          _compensationTableZoomLevel,
                          increase: false);
                    });
                  },
                ),
                const SizedBox(width: 8),
                Text(
                  '${(_compensationTableZoomLevel * 100).round()}%',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black.withOpacity(0.75),
                  ),
                ),
                const SizedBox(width: 8),
                _buildZoomButton(
                  zoomInAsset,
                  onTap: () {
                    setState(() {
                      _compensationTableZoomLevel = _stepZoomLevel(
                          _compensationTableZoomLevel,
                          increase: true);
                    });
                  },
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLayoutsActionButton({
    required String label,
    Widget? leading,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
            if (leading != null) ...[
              leading,
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildZoomButton(String iconUrl, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
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
          child: FittedBox(
            fit: BoxFit.contain,
            child: SvgPicture.asset(
              iconUrl,
              placeholderBuilder: (context) => const SizedBox(
                width: 20,
                height: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _stepZoomLevel(double current, {required bool increase}) {
    final currentStep = (current * 10).round();
    final nextStep = (currentStep + (increase ? 1 : -1)).clamp(5, 12);
    return nextStep / 10.0;
  }

  Widget _buildLayoutWiseFinancialSummary() {
    final filteredLayouts = _siteLayouts.asMap().entries.where((entry) {
      return _layoutMatchesFilter(entry.value);
    }).toList();

    if (filteredLayouts.isEmpty) {
      return Container(
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
        child: Text(
          'No layouts found',
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w400,
            color: const Color(0xFF5C5C5C),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Layout cards
        ...filteredLayouts.asMap().entries.map((entry) {
          final position = entry.key;
          final originalIndex = entry.value.key;
          final layout = entry.value.value;
          return Padding(
            padding: EdgeInsets.only(
                bottom: position < filteredLayouts.length - 1 ? 24 : 0),
            child: _buildLayoutFinancialCard(layout, originalIndex),
          );
        }).toList(),
      ],
    );
  }

  bool _layoutMatchesFilter(Map<String, dynamic> layout) {
    if (_selectedLayoutFilter == 'All') {
      return true;
    }

    final plots = layout['plots'] as List<dynamic>? ?? [];
    final totalPlots = plots.length;
    if (totalPlots == 0) {
      return _selectedLayoutFilter == 'Available';
    }

    final soldPlots = plots.where((plot) {
      final status = (plot['status'] as String? ?? 'available').toLowerCase();
      return status == 'sold';
    }).length;

    if (_selectedLayoutFilter == 'Sold out') {
      return soldPlots == totalPlots;
    }

    if (_selectedLayoutFilter == 'Available') {
      return soldPlots < totalPlots;
    }

    return true;
  }

  bool _compensationLayoutMatchesFilter(Map<String, dynamic> layout) {
    if (_selectedCompensationLayoutFilter == 'All') {
      return true;
    }

    final plots = layout['plots'] as List<dynamic>? ?? [];
    final totalPlots = plots.length;
    if (totalPlots == 0) {
      return _selectedCompensationLayoutFilter == 'Available';
    }

    final soldPlots = plots.where((plot) {
      final status = (plot['status'] as String? ?? 'available').toLowerCase();
      return status == 'sold';
    }).length;

    if (_selectedCompensationLayoutFilter == 'Sold out') {
      return soldPlots == totalPlots;
    }

    if (_selectedCompensationLayoutFilter == 'Available') {
      return soldPlots < totalPlots;
    }

    return true;
  }

  Widget _buildLayoutFinancialCard(
      Map<String, dynamic> layout, int layoutIndex) {
    final layoutName = layout['name'] as String? ?? 'Layout ${layoutIndex + 1}';
    final plots = layout['plots'] as List<dynamic>? ?? [];

    final allInCost = _dashboardData!['allInCost'] as double;
    final projectManagersCompensation = _projectManagersCompensation;
    final agentsCompensation = _agentsCompensation;

    // Calculate layout totals
    double totalArea = 0.0;
    double totalPlotCost = 0.0;
    double totalSalePrice = 0.0;
    double totalSaleValue = 0.0;
    double areaSold = 0.0;
    double grossProfit = 0.0; // Sum of profit column values
    int availablePlots = 0;
    int soldPlots = 0;

    for (var plot in plots) {
      final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
      final status = (plot['status'] as String? ?? 'available').toLowerCase();
      final salePrice = ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);

      totalArea += area;
      totalPlotCost += area * allInCost;

      if (status == 'sold') {
        soldPlots++;
        totalSalePrice += salePrice;
        final saleValue = salePrice * area;
        totalSaleValue += saleValue;
        areaSold += area;
        // Calculate profit for this plot: (saleValue - plotCost)
        final plotCost = area * allInCost;
        final plotProfit = saleValue - plotCost;
        grossProfit += plotProfit;
      } else {
        availablePlots++;
      }
    }

    final totalPlots = plots.length;
    final percentSold = totalPlots > 0 ? (soldPlots / totalPlots) * 100 : 0.0;
    final netProfit =
        grossProfit - projectManagersCompensation - agentsCompensation;
    const collapseIconAsset = 'assets/images/Indi_collapse.svg';
    const expandIconAsset = 'assets/images/Indi_expand.svg';
    final isCollapsed = _collapsedLayouts.contains(layoutIndex);
    final layoutTableScrollController =
        _getSiteLayoutTableScrollController(layoutIndex);

    return Container(
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
                  Text(
                    '${layoutIndex + 1}.',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    'Layout:',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      layoutName,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${percentSold.toStringAsFixed(0)}%',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$soldPlots/$totalPlots plots sold',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF5C5C5C),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 0,
                      runSpacing: 8,
                      children: [
                        Text(
                          '${totalPlots == 1 ? '1 plot' : '$totalPlots plots'}',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                        ),
                        _buildLayoutInfoDot(),
                        _buildLayoutInfoItem(
                          label: 'Total Area:',
                          value:
                              '${_formatArea(AreaUnitUtils.areaFromSqftToDisplay(totalArea, _isSqm))} $_areaUnitSuffix',
                        ),
                        _buildLayoutInfoDot(),
                        _buildLayoutInfoItem(
                          label: 'All-in Cost:',
                          value:
                              '₹/$_areaUnitSuffix ${_formatCurrencyNumber(AreaUnitUtils.rateFromSqftToDisplay(allInCost, _isSqm))}',
                        ),
                        _buildLayoutInfoDot(),
                        _buildLayoutInfoItem(
                          label: 'Total Plot Cost:',
                          value: '₹ ${_formatCurrencyNumber(totalPlotCost)}',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 0,
                      runSpacing: 8,
                      children: [
                        _buildLayoutInfoItem(
                          label: 'Actual Total Sale Value:',
                          value: '${_formatCurrencyNumber(totalSaleValue)} ₹',
                          valueColor: Colors.black.withOpacity(0.75),
                        ),
                        _buildLayoutInfoDot(),
                        _buildLayoutInfoItem(
                          label: 'Actual Gross Profit:',
                          value: '${_formatCurrencyNumber(grossProfit)} ₹',
                          valueColor: Colors.black.withOpacity(0.75),
                        ),
                        _buildLayoutInfoDot(),
                        _buildLayoutInfoItem(
                          label: 'Actual Net Profit:',
                          value: '₹ ${_formatCurrencyNumber(netProfit)}',
                          valueColor: Colors.black.withOpacity(0.75),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(() {
                    if (isCollapsed) {
                      _collapsedLayouts.remove(layoutIndex);
                    } else {
                      _collapsedLayouts.add(layoutIndex);
                    }
                  });
                },
                child: SvgPicture.asset(
                  isCollapsed ? expandIconAsset : collapseIconAsset,
                  width: 12,
                  height: 12,
                  fit: BoxFit.contain,
                  placeholderBuilder: (context) => const SizedBox(
                    width: 12,
                    height: 12,
                  ),
                ),
              ),
            ],
          ),
          if (!isCollapsed) ...[
            const SizedBox(height: 16),
            Container(
              padding: EdgeInsets.only(
                left: 8 + (12 * (_tableZoomLevel - 1.0).clamp(0.0, 0.2)),
                right: 8 + (12 * (_tableZoomLevel - 1.0).clamp(0.0, 0.2)),
                top: 8 + (12 * (_tableZoomLevel - 1.0).clamp(0.0, 0.2)),
                bottom: 8 +
                    (12 * (_tableZoomLevel - 1.0).clamp(0.0, 0.2)) +
                    (50 * (_tableZoomLevel - 1.0).clamp(0.0, 0.2)),
              ),
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
              child: _buildLayoutPlotsTable(
                plots,
                allInCost,
                scrollController: layoutTableScrollController,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLayoutInfoDot() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: 4,
        height: 4,
        decoration: const BoxDecoration(
          color: Colors.black,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  Widget _buildLayoutInfoItem({
    required String label,
    required String value,
    Color? valueColor,
  }) {
    return RichText(
      text: TextSpan(
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.normal,
          color: Colors.black,
        ),
        children: [
          TextSpan(
            text: '$label ',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black,
            ),
          ),
          TextSpan(
            text: value,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              fontStyle: FontStyle.italic,
              color: valueColor ?? Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  String _normalizeAmenityStatus(dynamic value) {
    final raw = (value ?? 'available').toString().trim().toLowerCase();
    if (raw == 'sold') return 'sold';
    if (raw == 'pending' || raw == 'reserved') return 'pending';
    return 'available';
  }

  bool _amenityRowMatchesFilter(Map<String, dynamic> row) {
    if (_selectedAmenityFilter == 'All') return true;
    final status = _normalizeAmenityStatus(row['status']);
    if (_selectedAmenityFilter == 'Sold out') return status == 'sold';
    if (_selectedAmenityFilter == 'Available') return status != 'sold';
    return true;
  }

  double _amenityAreaSqft(Map<String, dynamic> row) {
    return _parsePlotNumeric(row['area']);
  }

  double _amenityAllInCostSqft(Map<String, dynamic> row) {
    return _parsePlotNumeric(row['all_in_cost']);
  }

  double _amenitySalePriceSqft(Map<String, dynamic> row) {
    return _parsePlotNumeric(row['sale_price']);
  }

  double _amenitySaleValue(Map<String, dynamic> row) {
    final explicit = _parsePlotNumeric(row['sale_value']);
    if (explicit > 0) return explicit;
    final area = _amenityAreaSqft(row);
    final salePrice = _amenitySalePriceSqft(row);
    if (area <= 0 || salePrice <= 0) return 0.0;
    return area * salePrice;
  }

  double _calculateAmenityAgentEarnings(Map<String, dynamic> row) {
    final status = _normalizeAmenityStatus(row['status']);
    if (status != 'sold') return 0.0;

    final agentName = (row['agent_name'] ?? '').toString().trim().toLowerCase();
    if (agentName.isEmpty || _agents.isEmpty) return 0.0;

    final matchedAgent = _agents.firstWhere(
      (agent) =>
          (agent['name'] ?? '').toString().trim().toLowerCase() == agentName,
      orElse: () => <String, dynamic>{},
    );
    if (matchedAgent.isEmpty) return 0.0;

    // Mirror exactly what is shown in Agent(s) tab.
    return _calculateAgentEarnings(matchedAgent);
  }

  String _formatDashboardDateValue(dynamic value) {
    final raw = (value ?? '').toString().trim();
    if (raw.isEmpty) return '-';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final dd = parsed.day.toString().padLeft(2, '0');
    final mm = parsed.month.toString().padLeft(2, '0');
    final yyyy = parsed.year.toString();
    return '$dd/$mm/$yyyy';
  }

  Widget _buildAmenityPlotHeaderCell({
    bool isLast = false,
  }) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFE2E2E2),
        borderRadius: isLast
            ? const BorderRadius.only(topRight: Radius.circular(8))
            : null,
      ),
      child: Align(
        alignment: Alignment.center,
        child: RichText(
          text: TextSpan(
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black,
            ),
            children: const [
              TextSpan(text: 'Amenity plot'),
              TextSpan(text: '*', style: TextStyle(color: Color(0xFFFF0000))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAmenityMetricCard({
    required double width,
    required String title,
    required Widget valueWidget,
    EdgeInsetsGeometry? padding,
  }) {
    return Container(
      width: width,
      padding: padding ?? const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(height: 16),
          valueWidget,
        ],
      ),
    );
  }

  Widget _buildAmenityAreaSalesProgressCard({
    required double totalSalesValue,
    required double totalAreaSoldSqft,
    required int soldPlots,
    required int availablePlots,
    required int totalPlots,
  }) {
    final soldPercent = totalPlots > 0 ? (soldPlots / totalPlots) * 100 : 0.0;
    final availablePercent = totalPlots > 0
        ? (availablePlots / totalPlots) * 100
        : (soldPlots > 0 ? 0.0 : 100.0);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 1140,
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
              Text(
                'Amenity Area Sales Progress',
                style: GoogleFonts.inter(
                  fontSize: 32 > 20 ? 32 - 12 : 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _buildAmenityMetricCard(
                    width: 265,
                    title: 'Total Amenity Plot Sales Value',
                    valueWidget: Row(
                      children: [
                        Text(
                          '₹',
                          style: GoogleFonts.inter(
                            fontSize: 32 > 20 ? 32 - 12 : 20,
                            fontWeight: FontWeight.w400,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _formatNumberNoDecimals(totalSalesValue),
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 32 > 20 ? 32 - 12 : 20,
                              fontWeight: FontWeight.w400,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildAmenityMetricCard(
                    width: 265,
                    title: 'Total Amenity Area Sold',
                    valueWidget: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _formatNumberNoDecimals(
                                AreaUnitUtils.areaFromSqftToDisplay(
                                    totalAreaSoldSqft, _isSqm)),
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 20,
                              fontWeight: FontWeight.w400,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _areaUnitSuffix,
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w400,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildAmenityMetricCard(
                    width: 156,
                    title: 'Sold Amenity Plot',
                    valueWidget: Text(
                      soldPlots.toString(),
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFF06AB00),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildAmenityMetricCard(
                    width: 156,
                    title: 'Available Amenity Plot',
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 5,
                    ),
                    valueWidget: Text(
                      availablePlots.toString(),
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w400,
                        color: const Color(0xFFCF9B00),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _buildAmenityMetricCard(
                    width: 172,
                    title: 'Total Amenity Plot',
                    valueWidget: Text(
                      totalPlots.toString(),
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w400,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final soldFraction = totalPlots > 0
                          ? (soldPlots / totalPlots).clamp(0.0, 1.0)
                          : 0.0;
                      final availableFraction =
                          (1.0 - soldFraction).clamp(0.0, 1.0);
                      final soldWidth = constraints.maxWidth * soldFraction;
                      final availableWidth =
                          constraints.maxWidth * availableFraction;

                      return Stack(
                        children: [
                          if (availableWidth > 0)
                            Positioned(
                              right: 0,
                              top: 0,
                              bottom: 0,
                              width: availableWidth,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFCF9B00),
                                  borderRadius: availableFraction >= 1.0
                                      ? BorderRadius.circular(8)
                                      : const BorderRadius.only(
                                          topRight: Radius.circular(8),
                                          bottomRight: Radius.circular(8),
                                        ),
                                ),
                              ),
                            ),
                          if (soldWidth > 0)
                            Positioned(
                              left: 0,
                              top: 0,
                              bottom: 0,
                              width: soldWidth,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF06AB00),
                                  borderRadius: soldFraction >= 1.0
                                      ? BorderRadius.circular(8)
                                      : const BorderRadius.only(
                                          topLeft: Radius.circular(8),
                                          bottomLeft: Radius.circular(8),
                                        ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${soldPercent.toStringAsFixed(0)}%',
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF06AB00),
                    ),
                  ),
                  Text(
                    '${availablePercent.toStringAsFixed(0)}%',
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFFCF9B00),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Sold',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF06AB00),
                    ),
                  ),
                  Text(
                    'Available',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFFCF9B00),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAmenityAgentTable(List<Map<String, dynamic>> rows) {
    return Table(
      border: TableBorder(
        horizontalInside: const BorderSide(color: Colors.black, width: 1),
        verticalInside: const BorderSide(color: Colors.black, width: 1),
      ),
      columnWidths: const {
        0: FixedColumnWidth(60),
        1: FixedColumnWidth(266),
        2: FixedColumnWidth(215),
        3: FixedColumnWidth(248),
        4: FixedColumnWidth(241),
        5: FixedColumnWidth(167),
      },
      children: [
        TableRow(
          decoration: const BoxDecoration(color: Color(0xFFE2E2E2)),
          children: [
            _buildTableHeaderCell('Sl. No.', isFirst: true, centerAlign: true),
            _buildAmenityPlotHeaderCell(),
            _buildTableHeaderCell('Area ($_areaUnitSuffix)', centerAlign: true),
            _buildTableHeaderCell('Agent', centerAlign: true),
            _buildTableHeaderCell('Earnings (₹)', centerAlign: true),
            _buildTableHeaderCell('Sale date', isLast: true, centerAlign: true),
          ],
        ),
        ...rows.asMap().entries.map((entry) {
          final index = entry.key;
          final row = entry.value;
          final status = _normalizeAmenityStatus(row['status']);
          final isSold = status == 'sold';
          final amenityName = (row['name'] ?? '').toString().trim();
          final areaDisplay = AreaUnitUtils.areaFromSqftToDisplay(
            _amenityAreaSqft(row),
            _isSqm,
          );
          final agentName = (row['agent_name'] ?? '').toString().trim();
          final earnings = _calculateAmenityAgentEarnings(row);
          final saleDate = _formatDashboardDateValue(row['sale_date']);
          final isLastRow = index == rows.length - 1;

          return TableRow(
            children: [
              _buildTableDataCell(
                '${index + 1}',
                isFirst: true,
                isLastRow: isLastRow,
              ),
              _buildTableDataCell(
                amenityName.isEmpty ? '-' : amenityName,
                isLastRow: isLastRow,
              ),
              _buildAreaCell(areaDisplay, isLastRow),
              _buildTableDataCell(
                isSold && agentName.isNotEmpty ? agentName : '-',
                isLastRow: isLastRow,
              ),
              _buildTableDataCell(
                isSold ? '₹ ${_formatCurrencyNumber(earnings)}' : '-',
                isLastRow: isLastRow,
              ),
              _buildSaleDateCell(
                isSold ? (saleDate == '-' ? '' : saleDate) : '',
                isSold,
                isLastRow,
                isLast: true,
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildAmenityAgentSection(List<Map<String, dynamic>> rows) {
    const tableBaseWidth = 1197.0;
    final baseHeaderHeight = 48.0;
    final baseRowHeight = 48.0;
    final baseHeight = baseHeaderHeight + (rows.length * baseRowHeight);
    final scaledHeight = (baseHeight * _tableZoomLevel)
        .clamp(baseHeaderHeight * _tableZoomLevel, double.infinity);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 1140,
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
              Text(
                'Agent',
                style: GoogleFonts.inter(
                  fontSize: 32 > 20 ? 32 - 12 : 20,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
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
                child: Scrollbar(
                  controller: _amenityAgentTableScrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _amenityAgentTableScrollController,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      height: scaledHeight,
                      child: Padding(
                        padding: EdgeInsets.only(
                          left:
                              ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0),
                          right: ((_tableZoomLevel - 1.0) * 10.0)
                                  .clamp(0.0, 10.0) +
                              ((_tableZoomLevel - 1.0) * tableBaseWidth)
                                  .clamp(0.0, tableBaseWidth),
                          top:
                              ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0),
                          bottom: ((_tableZoomLevel - 1.0) * 10.0)
                                  .clamp(0.0, 10.0) +
                              ((_tableZoomLevel - 1.0) * 100.0)
                                  .clamp(0.0, 100.0),
                        ),
                        child: Transform.scale(
                          scale: _tableZoomLevel,
                          alignment: Alignment.topLeft,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.all(1),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(7),
                              child: Container(
                                color: Colors.white,
                                child: _buildAmenityAgentTable(rows),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAmenityAreaDetailedTable(List<Map<String, dynamic>> rows) {
    final totalProjectManagerCompensation =
        _calculateTotalProjectManagersCompensation();

    return Table(
      border: TableBorder(
        horizontalInside: const BorderSide(color: Colors.black, width: 1),
        verticalInside: const BorderSide(color: Colors.black, width: 1),
      ),
      columnWidths: const {
        0: FixedColumnWidth(60),
        1: FixedColumnWidth(266),
        2: FixedColumnWidth(215),
        3: FixedColumnWidth(145),
        4: FixedColumnWidth(215),
        5: FixedColumnWidth(215),
        6: FixedColumnWidth(215),
        7: FixedColumnWidth(215),
        8: FixedColumnWidth(215),
        9: FixedColumnWidth(215),
        10: FixedColumnWidth(241),
        11: FixedColumnWidth(320),
        12: FixedColumnWidth(241),
        13: FixedColumnWidth(167),
      },
      children: [
        TableRow(
          decoration: const BoxDecoration(color: Color(0xFFE2E2E2)),
          children: [
            _buildTableHeaderCell('Sl. No.', isFirst: true, centerAlign: true),
            _buildAmenityPlotHeaderCell(),
            _buildTableHeaderCell('Area ($_areaUnitSuffix)', centerAlign: true),
            _buildTableHeaderCell('Status', centerAlign: true),
            _buildTableHeaderCell('All-in Cost (₹/$_areaUnitSuffix)',
                centerAlign: true),
            _buildTableHeaderCell('Plot Cost (₹)', centerAlign: true),
            _buildTableHeaderCell('Sale Price (₹/$_areaUnitSuffix)',
                centerAlign: true),
            _buildTableHeaderCell('Sale Value (₹)', centerAlign: true),
            _buildTableHeaderCell('Gross Profit (₹)', centerAlign: true),
            _buildTableHeaderCell('Net Profit (₹)', centerAlign: true),
            _buildTableHeaderCell('Partner(s)', centerAlign: true),
            _buildTableHeaderCell('Buyer Name', centerAlign: true),
            _buildTableHeaderCell('Agent', centerAlign: true),
            _buildTableHeaderCell('Sale date', isLast: true, centerAlign: true),
          ],
        ),
        ...rows.asMap().entries.map((entry) {
          final index = entry.key;
          final row = entry.value;
          final status = _normalizeAmenityStatus(row['status']);
          final isSold = status == 'sold';
          final isPending = status == 'pending';
          final showSaleDetails = isSold || isPending;
          final statusLabel =
              isSold ? 'Sold' : (isPending ? 'Pending' : 'Available');
          final areaSqft = _amenityAreaSqft(row);
          final allInCostSqft = _amenityAllInCostSqft(row);
          final salePriceSqft = _amenitySalePriceSqft(row);
          final plotCost = areaSqft * allInCostSqft;
          final saleValue = _amenitySaleValue(row);
          final grossProfit =
              showSaleDetails && saleValue > 0 ? saleValue - plotCost : 0.0;
          final agentCompensation = _calculateAmenityAgentEarnings(row);
          final netProfit = showSaleDetails && saleValue > 0
              ? (grossProfit -
                  agentCompensation -
                  totalProjectManagerCompensation)
              : 0.0;
          final amenityName = (row['name'] ?? '').toString().trim();
          final buyerName = (row['buyer_name'] ?? '').toString().trim();
          final agentName = (row['agent_name'] ?? '').toString().trim();
          final saleDate = _formatDashboardDateValue(row['sale_date']);
          final isLastRow = index == rows.length - 1;

          return TableRow(
            children: [
              _buildTableDataCell(
                '${index + 1}',
                isFirst: true,
                isLastRow: isLastRow,
              ),
              _buildTableDataCell(
                amenityName.isEmpty ? '-' : amenityName,
                isLastRow: isLastRow,
              ),
              _buildAreaCell(
                AreaUnitUtils.areaFromSqftToDisplay(areaSqft, _isSqm),
                isLastRow,
              ),
              _buildStatusCell(statusLabel, isSold, isPending, isLastRow),
              _buildCostCell(
                '₹/$_areaUnitSuffix',
                _formatCurrencyNumber(
                  AreaUnitUtils.rateFromSqftToDisplay(allInCostSqft, _isSqm),
                ),
                isLastRow,
              ),
              _buildCostCell('₹', _formatCurrencyNumber(plotCost), isLastRow),
              _buildTableDataCell(
                showSaleDetails && salePriceSqft > 0
                    ? '₹/$_areaUnitSuffix ${_formatCurrencyNumber(AreaUnitUtils.rateFromSqftToDisplay(salePriceSqft, _isSqm))}'
                    : '-',
                isLastRow: isLastRow,
              ),
              _buildTableDataCell(
                showSaleDetails && saleValue > 0
                    ? '₹ ${_formatCurrencyNumber(saleValue)}'
                    : '-',
                isLastRow: isLastRow,
              ),
              _buildTableDataCell(
                showSaleDetails && saleValue > 0
                    ? '₹ ${_formatCurrencyNumber(grossProfit)}'
                    : '-',
                isLastRow: isLastRow,
              ),
              _buildTableDataCell(
                showSaleDetails && saleValue > 0
                    ? '₹ ${_formatCurrencyNumber(netProfit)}'
                    : '-',
                isLastRow: isLastRow,
              ),
              _buildTableDataCell('-', isLastRow: isLastRow),
              _buildTableDataCell(
                showSaleDetails && buyerName.isNotEmpty ? buyerName : '-',
                isLastRow: isLastRow,
              ),
              _buildTableDataCell(
                showSaleDetails && agentName.isNotEmpty ? agentName : '-',
                isLastRow: isLastRow,
              ),
              _buildSaleDateCell(
                showSaleDetails && saleDate != '-' ? saleDate : '',
                showSaleDetails && saleDate != '-',
                isLastRow,
                isLast: true,
              ),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildAmenityLayoutsToolbar(int amenityCount) {
    const filterIconAsset = 'assets/images/Filter.svg';
    const expandIconAsset = 'assets/images/Expand.svg';
    const collapseIconAsset = 'assets/images/Collapse.svg';
    const zoomOutAsset = 'assets/images/Zoom_out.svg';
    const zoomInAsset = 'assets/images/Zoom_in.svg';

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Amenity Area',
          style: GoogleFonts.inter(
            fontSize: 32 > 20 ? 32 - 12 : 20,
            fontWeight: FontWeight.w600,
            color: Colors.black,
          ),
        ),
        Row(
          children: [
            PopupMenuButton<String>(
              initialValue: _selectedAmenityFilter,
              onSelected: (value) {
                setState(() {
                  _selectedAmenityFilter = value;
                });
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'All',
                  child: Text('All'),
                ),
                PopupMenuItem(
                  value: 'Available',
                  child: Text('Available'),
                ),
                PopupMenuItem(
                  value: 'Sold out',
                  child: Text('Sold'),
                ),
              ],
              child: _buildLayoutsActionButton(
                label: 'Filter',
                leading: SvgPicture.asset(
                  filterIconAsset,
                  width: 16,
                  height: 10,
                  fit: BoxFit.contain,
                  placeholderBuilder: (context) => const SizedBox(
                    width: 16,
                    height: 10,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            _buildLayoutsActionButton(
              label: 'Expand all layouts',
              trailing: SvgPicture.asset(
                expandIconAsset,
                width: 14,
                height: 7,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const SizedBox(
                  width: 14,
                  height: 7,
                ),
              ),
              onTap: amenityCount == 0
                  ? null
                  : () {
                      setState(() {
                        _isAmenityAreaSectionCollapsed = false;
                      });
                    },
            ),
            const SizedBox(width: 16),
            _buildLayoutsActionButton(
              label: 'Collapse all layouts',
              trailing: SvgPicture.asset(
                collapseIconAsset,
                width: 14,
                height: 7,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const SizedBox(
                  width: 14,
                  height: 7,
                ),
              ),
              onTap: amenityCount == 0
                  ? null
                  : () {
                      setState(() {
                        _isAmenityAreaSectionCollapsed = true;
                      });
                    },
            ),
            const SizedBox(width: 16),
            Row(
              children: [
                Text(
                  'Zoom:',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(width: 8),
                _buildZoomButton(
                  zoomOutAsset,
                  onTap: () {
                    setState(() {
                      _tableZoomLevel =
                          _stepZoomLevel(_tableZoomLevel, increase: false);
                    });
                  },
                ),
                const SizedBox(width: 8),
                Text(
                  '${(_tableZoomLevel * 100).round()}%',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black.withOpacity(0.75),
                  ),
                ),
                const SizedBox(width: 8),
                _buildZoomButton(
                  zoomInAsset,
                  onTap: () {
                    setState(() {
                      _tableZoomLevel =
                          _stepZoomLevel(_tableZoomLevel, increase: true);
                    });
                  },
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAmenityAreaSummarySection({
    required List<Map<String, dynamic>> allRows,
    required List<Map<String, dynamic>> filteredRows,
  }) {
    final totalRows = allRows.length;
    final soldRows = allRows
        .where((row) => _normalizeAmenityStatus(row['status']) == 'sold')
        .length;
    final soldPercent = totalRows > 0 ? (soldRows / totalRows) * 100 : 0.0;

    final totalAreaSqft = filteredRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityAreaSqft(row),
    );
    final totalPlotCost = filteredRows.fold<double>(
      0.0,
      (sum, row) => sum + (_amenityAreaSqft(row) * _amenityAllInCostSqft(row)),
    );
    final totalSaleValue = filteredRows.fold<double>(
      0.0,
      (sum, row) {
        final status = _normalizeAmenityStatus(row['status']);
        if (status != 'sold') return sum;
        return sum + _amenitySaleValue(row);
      },
    );
    final grossProfit = filteredRows.fold<double>(
      0.0,
      (sum, row) {
        final status = _normalizeAmenityStatus(row['status']);
        if (status != 'sold') return sum;
        final plotCost = _amenityAreaSqft(row) * _amenityAllInCostSqft(row);
        return sum + (_amenitySaleValue(row) - plotCost);
      },
    );
    final totalAgentCompensation = filteredRows.fold<double>(
      0.0,
      (sum, row) => sum + _calculateAmenityAgentEarnings(row),
    );
    final totalProjectManagerCompensation =
        _calculateTotalProjectManagersCompensation();
    final netProfit =
        grossProfit - totalAgentCompensation - totalProjectManagerCompensation;
    final avgAllInCostSqft =
        totalAreaSqft > 0 ? (totalPlotCost / totalAreaSqft) : 0.0;

    const collapseIconAsset = 'assets/images/Indi_collapse.svg';
    const expandIconAsset = 'assets/images/Indi_expand.svg';
    const tableBaseWidth = 2920.0;

    final baseHeaderHeight = 48.0;
    final baseRowHeight = 48.0;
    final rowCount = filteredRows.isEmpty ? 1 : filteredRows.length;
    final baseHeight = baseHeaderHeight + (rowCount * baseRowHeight);
    final scaledHeight = (baseHeight * _tableZoomLevel)
        .clamp(baseHeaderHeight * _tableZoomLevel, double.infinity);

    return Container(
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Amenity Area',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
              Text(
                '${soldPercent.toStringAsFixed(0)}%',
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w400,
                  color: Colors.black,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '$soldRows/$totalRows Amenity plot sold',
              style: GoogleFonts.inter(
                fontSize: 24 > 14 ? 24 - 10 : 14,
                fontWeight: FontWeight.w400,
                color: Colors.black.withOpacity(0.75),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 0,
            runSpacing: 8,
            children: [
              Text(
                '${filteredRows.length} ${filteredRows.length == 1 ? 'Amenity Area' : 'Amenity Areas'}',
                style: GoogleFonts.inter(
                  fontSize: 24 > 14 ? 24 - 10 : 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                  fontStyle: FontStyle.italic,
                ),
              ),
              _buildLayoutInfoDot(),
              _buildLayoutInfoItem(
                label: 'Total Area:',
                value:
                    '${_formatNumberNoDecimals(AreaUnitUtils.areaFromSqftToDisplay(totalAreaSqft, _isSqm))} $_areaUnitSuffix',
              ),
              _buildLayoutInfoDot(),
              _buildLayoutInfoItem(
                label: 'All-in Cost:',
                value:
                    '₹/$_areaUnitSuffix ${_formatCurrencyNumber(AreaUnitUtils.rateFromSqftToDisplay(avgAllInCostSqft, _isSqm))}',
              ),
              _buildLayoutInfoDot(),
              _buildLayoutInfoItem(
                label: 'Total Plot Cost:',
                value: '₹ ${_formatCurrencyNumber(totalPlotCost)}',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 0,
            runSpacing: 8,
            children: [
              _buildLayoutInfoItem(
                label: 'Total Sale Value:',
                value: '₹ ${_formatCurrencyNumber(totalSaleValue)}',
                valueColor: Colors.black.withOpacity(0.75),
              ),
              _buildLayoutInfoDot(),
              _buildLayoutInfoItem(
                label: 'Gross Profit:',
                value: '₹ ${_formatCurrencyNumber(grossProfit)}',
                valueColor: Colors.black.withOpacity(0.75),
              ),
              _buildLayoutInfoDot(),
              _buildLayoutInfoItem(
                label: 'Net Profit:',
                value: '₹ ${_formatCurrencyNumber(netProfit)}',
                valueColor: Colors.black.withOpacity(0.75),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _isAmenityAreaSectionCollapsed =
                      !_isAmenityAreaSectionCollapsed;
                });
              },
              child: SvgPicture.asset(
                _isAmenityAreaSectionCollapsed
                    ? expandIconAsset
                    : collapseIconAsset,
                width: 12,
                height: 12,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const SizedBox(
                  width: 12,
                  height: 12,
                ),
              ),
            ),
          ),
          if (!_isAmenityAreaSectionCollapsed) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(8),
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
              child: Scrollbar(
                controller: _amenityAreaTableScrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _amenityAreaTableScrollController,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    height: scaledHeight,
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0),
                        right:
                            ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0) +
                                ((_tableZoomLevel - 1.0) * tableBaseWidth)
                                    .clamp(0.0, tableBaseWidth),
                        top: ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0),
                        bottom: ((_tableZoomLevel - 1.0) * 10.0)
                                .clamp(0.0, 10.0) +
                            ((_tableZoomLevel - 1.0) * 100.0).clamp(0.0, 100.0),
                      ),
                      child: Transform.scale(
                        scale: _tableZoomLevel,
                        alignment: Alignment.topLeft,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.all(1),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(7),
                            child: Container(
                              color: Colors.white,
                              child:
                                  _buildAmenityAreaDetailedTable(filteredRows),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAmenityAreaTabContent() {
    if (_dashboardData == null) {
      return _buildSiteTabLoadingSkeleton();
    }

    final allRows = _amenityAreaRows
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) {
      final name = (row['name'] ?? '').toString().trim();
      final area = _amenityAreaSqft(row);
      final allInCost = _amenityAllInCostSqft(row);
      return name.isNotEmpty || area > 0 || allInCost > 0;
    }).toList();

    if (allRows.isEmpty) {
      return Container(
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
        child: Text(
          'No amenity area found',
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.normal,
            color: const Color(0xFF5C5C5C),
          ),
        ),
      );
    }

    final soldRows = allRows
        .where((row) => _normalizeAmenityStatus(row['status']) == 'sold')
        .toList();
    final totalPlots = allRows.length;
    final soldPlots = soldRows.length;
    final availablePlots = math.max(0, totalPlots - soldPlots);
    final totalAreaSoldSqft = soldRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenityAreaSqft(row),
    );
    final totalSalesValue = soldRows.fold<double>(
      0.0,
      (sum, row) => sum + _amenitySaleValue(row),
    );
    final filteredRows = allRows.where(_amenityRowMatchesFilter).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Last updated: 1 sec ago',
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: const Color(0xFF5C5C5C),
          ),
        ),
        const SizedBox(height: 24),
        _buildAmenityAreaSalesProgressCard(
          totalSalesValue: totalSalesValue,
          totalAreaSoldSqft: totalAreaSoldSqft,
          soldPlots: soldPlots,
          availablePlots: availablePlots,
          totalPlots: totalPlots,
        ),
        const SizedBox(height: 24),
        _buildAmenityAgentSection(allRows),
        const SizedBox(height: 24),
        _buildAmenityLayoutsToolbar(allRows.length),
        const SizedBox(height: 24),
        _buildAmenityAreaSummarySection(
          allRows: allRows,
          filteredRows: filteredRows,
        ),
      ],
    );
  }

  Widget _buildPartnersSection() {
    // Show skeleton until all required data is loaded
    if (_dashboardData == null ||
        _isPartnersLoading ||
        _isProjectManagersLoading ||
        _isAgentsLoading ||
        _dashboardData!['netProfit'] == null) {
      return _buildPartnersLoadingSkeleton();
    }

    if (_partners.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Partner(s) Earnings',
              style: GoogleFonts.inter(
                fontSize: 24,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No partners found',
              style: GoogleFonts.inter(
                fontSize: 16,
                color: const Color(0xFF5C5C5C),
              ),
            ),
          ],
        ),
      );
    }

    // Calculate total gross profit (sum of all layouts' gross profits)
    final totalGrossProfit = _calculateTotalGrossProfit();

    // Calculate total capital contribution
    final totalCapitalContribution = _partners.fold<double>(
      0.0,
      (sum, partner) => sum + (partner['amount'] as double? ?? 0.0),
    );

    return Container(
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Partners Profit Pool card (Figma design)
          Container(
            width: 320,
            padding: const EdgeInsets.all(16),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Partners Profit Pool',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF5C5C5C),
                  ),
                ),
                const SizedBox(height: 16),
                Builder(
                  builder: (context) {
                    // Calculate net profit the same way as overview section for consistency
                    final totalSalesValue =
                        _dashboardData?['totalSalesValue'] as double? ?? 0.0;
                    final totalExpenses =
                        _dashboardData?['totalExpenses'] as double? ?? 0.0;
                    final grossProfit = totalSalesValue - totalExpenses;
                    final totalCompensation =
                        _calculateTotalProjectManagersCompensation() +
                            _calculateTotalAgentsCompensation();
                    final netProfit = grossProfit - totalCompensation;
                    return Row(
                      children: [
                        Text(
                          '₹  ',
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatNumberNoDecimals(netProfit),
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  'Net profit distribution',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF5C5C5C),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Partners table
          _buildPartnersTable(totalCapitalContribution, totalGrossProfit),
        ],
      ),
    );
  }

  Widget _buildPartnersTable(
      double totalCapitalContribution, double totalGrossProfit) {
    // Get estimated development cost for share calculation (matching project details page)
    final estimatedDevelopmentCost =
        _dashboardData!['estimatedDevelopmentCost'] as double? ?? 0.0;

    // Use the net profit from _dashboardData (calculated in overview section)
    // This ensures consistency between overview and partners sections
    final totalSalesValue =
        _dashboardData!['totalSalesValue'] as double? ?? 0.0;
    final totalExpenses = _dashboardData!['totalExpenses'] as double? ?? 0.0;
    final grossProfit = totalSalesValue - totalExpenses;
    final totalCompensation = _calculateTotalProjectManagersCompensation() +
        _calculateTotalAgentsCompensation();
    final totalNetProfit = grossProfit - totalCompensation;

    // Pre-calculate profit shares for all partners to ensure consistency
    // Use estimated development cost as denominator (matching project details page)
    final partnersWithProfitShare = _partners.map((partner) {
      final capitalContribution = partner['amount'] as double? ?? 0.0;
      final profitShare = estimatedDevelopmentCost > 0
          ? (capitalContribution / estimatedDevelopmentCost) * 100
          : 0.0;
      return {
        ...partner,
        'profitShare': profitShare,
        'allocatedProfit': (totalNetProfit * profitShare) / 100,
      };
    }).toList();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: _partnersTableScrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _partnersTableScrollController,
          scrollDirection: Axis.horizontal,
          child: IntrinsicWidth(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Sl. No. column
                Column(
                  children: [
                    _buildPartnersTableHeaderCell('Sl. No.',
                        isFirst: true, isLast: false),
                    ...partnersWithProfitShare.asMap().entries.map((entry) {
                      final index = entry.key;
                      final isLastRow =
                          index == partnersWithProfitShare.length - 1;
                      return _buildPartnersTableDataCell(
                        '${index + 1}',
                        columnName: 'Sl. No.',
                        isFirst: true,
                        isLastRow: isLastRow,
                        isLast: false,
                      );
                    }),
                  ],
                ),
                // Partner Name column
                Column(
                  children: [
                    _buildPartnersTableHeaderCell('Partner Name',
                        isFirst: false, isLast: false),
                    ...partnersWithProfitShare.asMap().entries.map((entry) {
                      final index = entry.key;
                      final partner = entry.value;
                      final isLastRow =
                          index == partnersWithProfitShare.length - 1;
                      return _buildPartnersTableDataCell(
                        partner['name'] as String? ?? '',
                        columnName: 'Partner Name',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: false,
                        isPartnerName: true,
                      );
                    }),
                  ],
                ),
                // Capital Contribution (₹) column
                Column(
                  children: [
                    _buildPartnersTableHeaderCell('Capital Contribution (₹)',
                        isFirst: false, isLast: false),
                    ...partnersWithProfitShare.asMap().entries.map((entry) {
                      final index = entry.key;
                      final partner = entry.value;
                      final amount = partner['amount'] as double? ?? 0.0;
                      final isLastRow =
                          index == partnersWithProfitShare.length - 1;
                      return _buildPartnersTableDataCell(
                        _formatCurrencyNumber(amount),
                        columnName: 'Capital Contribution (₹)',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: false,
                        prefix: '₹ ',
                      );
                    }),
                  ],
                ),
                // Profit Share (%) column
                Column(
                  children: [
                    _buildPartnersTableHeaderCell('Profit Share (%)',
                        isFirst: false, isLast: false, flexible: false),
                    ...partnersWithProfitShare.asMap().entries.map((entry) {
                      final index = entry.key;
                      final partner = entry.value;
                      final profitShare =
                          partner['profitShare'] as double? ?? 0.0;
                      final isLastRow =
                          index == partnersWithProfitShare.length - 1;
                      return _buildPartnersTableDataCell(
                        '${profitShare.toStringAsFixed(0)} %',
                        columnName: 'Profit Share (%)',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: false,
                        flexible: false,
                        textColor: const Color(0xFF5D5D5D),
                      );
                    }),
                  ],
                ),
                // Allocated Profit (₹) column
                Column(
                  children: [
                    _buildPartnersTableHeaderCell('Allocated Profit (₹)',
                        isFirst: false, isLast: true),
                    ...partnersWithProfitShare.asMap().entries.map((entry) {
                      final index = entry.key;
                      final partner = entry.value;
                      final allocatedProfit =
                          partner['allocatedProfit'] as double? ?? 0.0;
                      final isLastRow =
                          index == partnersWithProfitShare.length - 1;
                      return _buildPartnersTableDataCell(
                        _formatCurrencyNumber(allocatedProfit),
                        columnName: 'Allocated Profit (₹)',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: true,
                        prefix: '₹ ',
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPartnersTableHeaderCell(String text,
      {bool isFirst = false, bool isLast = false, bool flexible = false}) {
    final width = _getPartnersColumnWidth(text);
    return Container(
      height: 48,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFE2E2E2),
        border: Border(
          top: const BorderSide(color: Colors.black, width: 1),
          bottom: const BorderSide(color: Colors.black, width: 1),
          left: isFirst
              ? const BorderSide(color: Colors.black, width: 1)
              : BorderSide.none,
          right: const BorderSide(color: Colors.black, width: 1),
        ),
        borderRadius: isFirst
            ? const BorderRadius.only(topLeft: Radius.circular(8))
            : isLast
                ? const BorderRadius.only(topRight: Radius.circular(8))
                : null,
      ),
      child: Center(
        child: Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildPartnersTableDataCell(
    String text, {
    required String columnName,
    bool isFirst = false,
    bool isLastRow = false,
    bool isLast = false,
    bool isPartnerName = false,
    bool flexible = false,
    String? prefix,
    Color? textColor,
  }) {
    final width = _getPartnersColumnWidth(columnName);
    // Determine if this column should be left-aligned
    final shouldLeftAlign = columnName == 'Partner Name' ||
        columnName == 'Capital Contribution (₹)' ||
        columnName == 'Allocated Profit (₹)';
    return Container(
      height: 48,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: const BorderSide(color: Colors.black, width: 1),
          left: isFirst
              ? const BorderSide(color: Colors.black, width: 1)
              : BorderSide.none,
          right: const BorderSide(color: Colors.black, width: 1),
        ),
        borderRadius: isFirst && isLastRow
            ? const BorderRadius.only(bottomLeft: Radius.circular(8))
            : isLast && isLastRow
                ? const BorderRadius.only(bottomRight: Radius.circular(8))
                : null,
      ),
      child: Align(
        alignment: shouldLeftAlign ? Alignment.centerLeft : Alignment.center,
        child: isPartnerName
            ? Text(
                text,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
                textAlign: TextAlign.left,
                overflow: TextOverflow.ellipsis,
              )
            : Text(
                prefix != null ? '$prefix$text' : text,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: textColor ?? Colors.black,
                ),
                textAlign: shouldLeftAlign ? TextAlign.left : TextAlign.center,
              ),
      ),
    );
  }

  Widget _buildPartnerPlotDistribution() {
    if (_partners.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Partner - Plot Distribution',
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No partners found',
              style: GoogleFonts.inter(
                fontSize: 16,
                color: const Color(0xFF5C5C5C),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Partner - Plot Distribution',
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              // Calculate available width for the last column
              // Subtract fixed column widths: Sl. No. (60) + Partner Name (320) + No. of Plots (200) + padding/borders
              final fixedColumnsWidth = 60 + 320 + 200 + 32; // 32px for padding
              final lastColumnWidth = (constraints.maxWidth - fixedColumnsWidth)
                  .clamp(400.0, double.infinity);

              return Container(
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Sl. No. column
                    Column(
                      children: [
                        _buildPartnerDistHeaderCell('Sl. No.', isFirst: true),
                        ..._partners.asMap().entries.map((entry) {
                          final index = entry.key;
                          final isLastRow = index == _partners.length - 1;
                          return _buildPartnerDistDataCell(
                            '${index + 1}',
                            width: 60,
                            isFirst: true,
                            isLastRow: isLastRow,
                            centered: true,
                          );
                        }),
                      ],
                    ),
                    // Partner Name column
                    Column(
                      children: [
                        _buildPartnerDistHeaderCell('Partner Name'),
                        ..._partners.asMap().entries.map((entry) {
                          final index = entry.key;
                          final partner = entry.value;
                          final isLastRow = index == _partners.length - 1;
                          return _buildPartnerDistDataCell(
                            partner['name'] as String? ?? '',
                            width: 320,
                            isLastRow: isLastRow,
                            hasBackground: true,
                            leftAlign: true,
                          );
                        }),
                      ],
                    ),
                    // No. of Plots Assigned column
                    Column(
                      children: [
                        _buildPartnerDistHeaderCell('No. of Plots Assigned'),
                        ..._partners.asMap().entries.map((entry) {
                          final index = entry.key;
                          final partner = entry.value;
                          final plotCount = partner['plotCount'] as int? ?? 0;
                          final isLastRow = index == _partners.length - 1;
                          return _buildPartnerDistDataCell(
                            plotCount.toString(),
                            width: 200,
                            isLastRow: isLastRow,
                            centered: true,
                            hasBackground: true,
                          );
                        }),
                      ],
                    ),
                    // Plot(s) Assigned column - flexible width
                    Expanded(
                      child: Column(
                        children: [
                          _buildPartnerDistHeaderCell('Plot(s) Assigned',
                              isLast: true, width: lastColumnWidth),
                          ..._partners.asMap().entries.map((entry) {
                            final index = entry.key;
                            final partner = entry.value;
                            final assignedPlots =
                                partner['assignedPlots'] as List<dynamic>? ??
                                    [];
                            final isLastRow = index == _partners.length - 1;
                            return _buildPlotAssignedCell(
                              assignedPlots,
                              width: lastColumnWidth,
                              isLastRow: isLastRow,
                              isLast: true,
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPartnerDistHeaderCell(String text,
      {bool isFirst = false, bool isLast = false, double? width}) {
    double cellWidth = width ?? 200;
    if (width == null) {
      if (text == 'Sl. No.')
        cellWidth = 60;
      else if (text == 'Partner Name')
        cellWidth = 320;
      else if (text == 'No. of Plots Assigned')
        cellWidth = 200;
      else if (text == 'Plot(s) Assigned') cellWidth = 400;
    }

    return Container(
      height: 48,
      width: width == null ? cellWidth : null,
      constraints: width != null ? BoxConstraints(minWidth: cellWidth) : null,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFE2E2E2),
        border: Border(
          top: const BorderSide(color: Colors.black, width: 1),
          bottom: const BorderSide(color: Colors.black, width: 1),
          left: isFirst
              ? const BorderSide(color: Colors.black, width: 1)
              : BorderSide.none,
          right: const BorderSide(color: Colors.black, width: 1),
        ),
        borderRadius: isFirst
            ? const BorderRadius.only(topLeft: Radius.circular(8))
            : isLast
                ? const BorderRadius.only(topRight: Radius.circular(8))
                : null,
      ),
      child: Center(
        child: Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildPartnerDistDataCell(
    String text, {
    required double width,
    bool isFirst = false,
    bool isLastRow = false,
    bool isLast = false,
    bool centered = false,
    bool hasBackground = false,
    bool leftAlign = false,
  }) {
    return Container(
      height: 48,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: const BorderSide(color: Colors.black, width: 1),
          left: isFirst
              ? const BorderSide(color: Colors.black, width: 1)
              : BorderSide.none,
          right: const BorderSide(color: Colors.black, width: 1),
        ),
        borderRadius: isFirst && isLastRow
            ? const BorderRadius.only(bottomLeft: Radius.circular(8))
            : isLast && isLastRow
                ? const BorderRadius.only(bottomRight: Radius.circular(8))
                : null,
      ),
      child: Align(
        alignment: leftAlign
            ? Alignment.centerLeft
            : (centered ? Alignment.center : Alignment.centerLeft),
        child: Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: hasBackground ? FontWeight.w500 : FontWeight.normal,
            color: Colors.black,
          ),
          textAlign: leftAlign
              ? TextAlign.left
              : (centered ? TextAlign.center : TextAlign.left),
        ),
      ),
    );
  }

  Widget _buildPlotAssignedCell(
    List<dynamic> assignedPlots, {
    required double width,
    bool isFirst = false,
    bool isLastRow = false,
    bool isLast = false,
  }) {
    return Container(
      height: 48,
      constraints: BoxConstraints(minWidth: width),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: const BorderSide(color: Colors.black, width: 1),
          left: isFirst
              ? const BorderSide(color: Colors.black, width: 1)
              : BorderSide.none,
          right: const BorderSide(color: Colors.black, width: 1),
        ),
        borderRadius: isFirst && isLastRow
            ? const BorderRadius.only(bottomLeft: Radius.circular(8))
            : isLast && isLastRow
                ? const BorderRadius.only(bottomRight: Radius.circular(8))
                : null,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: assignedPlots.isEmpty
            ? Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5D5D5D),
                ),
              )
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < assignedPlots.length; i++) ...[
                      Container(
                        height: 36,
                        constraints: const BoxConstraints(minWidth: 36),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8F9FA),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            assignedPlots[i].toString(),
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ),
                      if (i < assignedPlots.length - 1)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            ',',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.normal,
                              color: Colors.black,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  double _getPartnersColumnWidth(String columnName) {
    switch (columnName) {
      case 'Sl. No.':
        return 60;
      case 'Partner Name':
        return 320;
      case 'Capital Contribution (₹)':
        return 215;
      case 'Profit Share (%)':
        return 200; // Fixed width to ensure visibility and alignment
      case 'Allocated Profit (₹)':
        return 215;
      default:
        // For data cells, try to infer from text content
        if (columnName.length < 10) return 60;
        if (columnName.length < 20) return 200;
        return 320;
    }
  }

  // Helper function to calculate total gross profit (sum of all layouts' gross profits)
  double _calculateTotalGrossProfit() {
    if (_dashboardData == null || _siteLayouts.isEmpty) {
      return 0.0;
    }

    final allInCost = _dashboardData!['allInCost'] as double;
    double totalGrossProfit = 0.0;

    for (var layout in _siteLayouts) {
      final plots = layout['plots'] as List<dynamic>? ?? [];
      double layoutGrossProfit = 0.0;

      for (var plot in plots) {
        final status = (plot['status'] as String? ?? 'available').toLowerCase();
        if (status == 'sold') {
          final salePrice = ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
          final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
          final saleValue = salePrice * area;
          final plotCost = area * allInCost;
          final plotProfit = saleValue - plotCost;
          layoutGrossProfit += plotProfit;
        }
      }

      totalGrossProfit += layoutGrossProfit;
    }

    return totalGrossProfit;
  }

  double _calculateProjectManagerEarnings(Map<String, dynamic> manager) {
    final compensationType = manager['compensation_type'] as String? ?? '';
    final earningType = manager['earning_type'] as String? ?? '';

    if (compensationType == 'Fixed Fee') {
      return manager['fixed_fee'] as double? ?? 0.0;
    } else if (compensationType == 'Monthly Fee') {
      final monthlyFee = manager['monthly_fee'] as double? ?? 0.0;
      final months = manager['months'] as int? ?? 0;
      return monthlyFee * months;
    } else if (compensationType == 'Percentage Bonus') {
      final percentage = manager['percentage'] as double? ?? 0.0;

      // Check earning type to determine calculation method
      final isLumpSum = earningType == 'Lump Sum' ||
          earningType == '% of Total Project Profit' ||
          (earningType.toLowerCase().contains('total project profit') ||
              earningType.toLowerCase().contains('lump'));

      if (isLumpSum) {
        // Deduct agent compensation first, then apply PM percentage on remaining.
        final totalGrossProfit = _calculateTotalGrossProfit();
        final totalAgentCompensation = _calculateTotalAgentsCompensation();
        final remainingAfterAgent = totalGrossProfit - totalAgentCompensation;
        return (remainingAfterAgent * percentage) / 100;
      } else {
        // For per-plot earnings (Profit Per Plot or Selling Price Per Plot),
        // calculate from individual plots assigned to this manager
        double totalEarnings = 0.0;
        final managerName = manager['name'] as String? ?? '';
        final managerId = manager['id'] as String?;

        if (_siteLayouts.isNotEmpty && managerName.isNotEmpty) {
          // Get plots assigned to this manager from project_manager_blocks
          final allInCost = _dashboardData!['allInCost'] as double? ?? 0.0;

          for (var layout in _siteLayouts) {
            final plots = layout['plots'] as List<dynamic>? ?? [];
            for (var plot in plots) {
              final status = (plot['status'] as String? ?? '').toLowerCase();
              if (status == 'sold') {
                // Check if this plot is assigned to this manager via project_manager_blocks
                // Note: We'll need to load manager-block associations, but for now,
                // we'll calculate based on all sold plots if manager has percentage bonus
                // This is a simplified approach - you may need to load block associations

                // Calculate per-plot compensation
                final salePrice =
                    (plot['sale_price'] as num?)?.toDouble() ?? 0.0;
                final area = (plot['area'] as num?)?.toDouble() ?? 0.0;
                final saleValue = salePrice * area;

                // Check for "Selling Price Per Plot"
                final isSellingPriceBased =
                    earningType == 'Selling Price Per Plot' ||
                        earningType == '% of Selling Price per Plot' ||
                        (earningType.toLowerCase().contains('selling price') &&
                            earningType.toLowerCase().contains('plot'));

                if (isSellingPriceBased) {
                  final remainingAfterAgent = saleValue -
                      _calculateAssignedAgentPerPlotCompensation(plot);
                  totalEarnings += (remainingAfterAgent * percentage) / 100;
                } else {
                  // Profit Per Plot
                  final plotCost = area * allInCost;
                  final plotProfit = saleValue - plotCost;
                  final remainingAfterAgent = plotProfit -
                      _calculateAssignedAgentPerPlotCompensation(plot);
                  totalEarnings += (remainingAfterAgent * percentage) / 100;
                }
              }
            }
          }
        }

        return totalEarnings;
      }
    }

    return 0.0;
  }

  Widget _buildProjectManagersSection() {
    if (_dashboardData == null) {
      return _buildProjectManagersLoadingSkeleton();
    }

    if (_projectManagers.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Project Manager(s) Earnings',
              style: GoogleFonts.inter(
                fontSize: 24,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No project managers found',
              style: GoogleFonts.inter(
                fontSize: 16,
                color: const Color(0xFF5C5C5C),
              ),
            ),
          ],
        ),
      );
    }

    // Calculate earnings for each project manager
    final managersWithEarnings = _projectManagers.map((manager) {
      final earnings = _calculateProjectManagerEarnings(manager);
      return {
        ...manager,
        'earnings': earnings,
      };
    }).toList();

    // Calculate total earnings
    final totalEarnings = managersWithEarnings.fold<double>(
      0.0,
      (sum, manager) => sum + (manager['earnings'] as double? ?? 0.0),
    );

    return Container(
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title
          Text(
            'Project Manager(s) Earnings',
            style: GoogleFonts.inter(
              fontSize: 24,
              fontWeight: FontWeight.w500,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 24),

          // Total Earnings card
          Container(
            width: 320,
            padding: const EdgeInsets.all(16),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Total Earnings',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF5C5C5C),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _formatCurrency(totalEarnings),
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Project Managers table
          _buildProjectManagersTable(managersWithEarnings),
        ],
      ),
    );
  }

  Widget _buildProjectManagersTable(List<Map<String, dynamic>> managers) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: _projectManagersTableScrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _projectManagersTableScrollController,
          scrollDirection: Axis.horizontal,
          child: IntrinsicWidth(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Sl. No. column
                Column(
                  children: [
                    _buildProjectManagersTableHeaderCell('Sl. No.',
                        isFirst: true, isLast: false),
                    ...managers.asMap().entries.map((entry) {
                      final index = entry.key;
                      final isLastRow = index == managers.length - 1;
                      return _buildProjectManagersTableDataCell(
                        '${index + 1}',
                        columnName: 'Sl. No.',
                        isFirst: true,
                        isLastRow: isLastRow,
                        isLast: false,
                      );
                    }),
                  ],
                ),
                // Project Manager Name column
                Column(
                  children: [
                    _buildProjectManagersTableHeaderCell('Project Manager Name',
                        isFirst: false, isLast: false),
                    ...managers.asMap().entries.map((entry) {
                      final index = entry.key;
                      final manager = entry.value;
                      final isLastRow = index == managers.length - 1;
                      return _buildProjectManagersTableDataCell(
                        manager['name'] as String? ?? '',
                        columnName: 'Project Manager Name',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: false,
                        isManagerName: true,
                      );
                    }),
                  ],
                ),
                // Compensation column
                Column(
                  children: [
                    _buildProjectManagersTableHeaderCell('Compensation ',
                        isFirst: false, isLast: false),
                    ...managers.asMap().entries.map((entry) {
                      final index = entry.key;
                      final manager = entry.value;
                      final compensationType =
                          manager['compensation_type'] as String? ?? '';
                      final isLastRow = index == managers.length - 1;
                      return _buildProjectManagersTableDataCell(
                        compensationType.isEmpty ? 'None' : compensationType,
                        columnName: 'Compensation ',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: false,
                        isCompensation: true,
                        compensationType: compensationType,
                      );
                    }),
                  ],
                ),
                // Earning Type column
                Column(
                  children: [
                    _buildProjectManagersTableHeaderCell('Earning Type ',
                        isFirst: false, isLast: false),
                    ...managers.asMap().entries.map((entry) {
                      final index = entry.key;
                      final manager = entry.value;
                      final compensationType =
                          manager['compensation_type'] as String? ?? '';
                      final earningType =
                          manager['earning_type'] as String? ?? '';
                      final percentage = manager['percentage'] as double?;
                      final fixedFee = manager['fixed_fee'] as double?;
                      final monthlyFee = manager['monthly_fee'] as double?;
                      final months = manager['months'] as int?;
                      final isLastRow = index == managers.length - 1;
                      return _buildProjectManagersEarningTypeCell(
                        manager: manager,
                        compensationType: compensationType,
                        earningType: earningType,
                        percentage: percentage,
                        fixedFee: fixedFee,
                        monthlyFee: monthlyFee,
                        months: months,
                        isLastRow: isLastRow,
                      );
                    }),
                  ],
                ),
                // Earnings (₹) column
                Column(
                  children: [
                    _buildProjectManagersTableHeaderCell('Earnings (₹)',
                        isFirst: false, isLast: true),
                    ...managers.asMap().entries.map((entry) {
                      final index = entry.key;
                      final manager = entry.value;
                      final earnings = manager['earnings'] as double? ?? 0.0;
                      final isLastRow = index == managers.length - 1;
                      return _buildProjectManagersTableDataCell(
                        _formatCurrencyNumber(earnings),
                        columnName: 'Earnings (₹)',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: true,
                        prefix: '₹ ',
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProjectManagersTableHeaderCell(String text,
      {bool isFirst = false, bool isLast = false}) {
    final width = _getProjectManagersColumnWidth(text);
    return Container(
      height: 48,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFE2E2E2),
        border: Border(
          top: const BorderSide(color: Colors.black, width: 1),
          bottom: const BorderSide(color: Colors.black, width: 1),
          left: isFirst
              ? const BorderSide(color: Colors.black, width: 1)
              : BorderSide.none,
          right: const BorderSide(color: Colors.black, width: 1),
        ),
        borderRadius: isFirst
            ? const BorderRadius.only(topLeft: Radius.circular(8))
            : isLast
                ? const BorderRadius.only(topRight: Radius.circular(8))
                : null,
      ),
      child: Center(
        child: RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            children: [
              TextSpan(
                text: text.replaceAll(' *', ''),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
              if (text.contains('*'))
                TextSpan(
                  text: ' *',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.red,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProjectManagersTableDataCell(
    String text, {
    required String columnName,
    bool isFirst = false,
    bool isLastRow = false,
    bool isLast = false,
    bool isManagerName = false,
    bool isCompensation = false,
    String? compensationType,
    String? prefix,
  }) {
    final width = _getProjectManagersColumnWidth(columnName);
    final shouldLeftAlign =
        isManagerName || isCompensation || prefix == '₹ ' || text == '-';
    return Container(
      height: 48,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: const BorderSide(color: Colors.black, width: 1),
          left: isFirst
              ? const BorderSide(color: Colors.black, width: 1)
              : BorderSide.none,
          right: const BorderSide(color: Colors.black, width: 1),
        ),
        borderRadius: isFirst && isLastRow
            ? const BorderRadius.only(bottomLeft: Radius.circular(8))
            : isLast && isLastRow
                ? const BorderRadius.only(bottomRight: Radius.circular(8))
                : null,
      ),
      child: Align(
        alignment: shouldLeftAlign ? Alignment.centerLeft : Alignment.center,
        child: isManagerName
            ? Text(
                text,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
                textAlign: TextAlign.left,
                overflow: TextOverflow.ellipsis,
              )
            : isCompensation
                ? IntrinsicWidth(
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD8EDFB),
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
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          text,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                          textAlign: TextAlign.left,
                        ),
                      ),
                    ),
                  )
                : Text(
                    prefix != null ? '$prefix$text' : text,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                    textAlign:
                        shouldLeftAlign ? TextAlign.left : TextAlign.center,
                  ),
      ),
    );
  }

  Widget _buildProjectManagersEarningTypeCell({
    required Map<String, dynamic> manager,
    required String compensationType,
    required String earningType,
    double? percentage,
    double? fixedFee,
    double? monthlyFee,
    int? months,
    required bool isLastRow,
  }) {
    final width = _getProjectManagersColumnWidth('Earning Type ');
    return Container(
      height: 48,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: const BorderSide(color: Colors.black, width: 1),
          right: const BorderSide(color: Colors.black, width: 1),
        ),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _buildEarningTypeContent(
          compensationType: compensationType,
          earningType: earningType,
          percentage: percentage,
          fixedFee: fixedFee,
          monthlyFee: monthlyFee,
          months: months,
        ),
      ),
    );
  }

  Widget _buildEarningTypeContent({
    required String compensationType,
    required String earningType,
    double? percentage,
    double? fixedFee,
    double? monthlyFee,
    int? months,
  }) {
    if (compensationType == 'Percentage Bonus') {
      // Map database earning type to UI display (same mapping as project_details_page)
      String displayEarningType = earningType;
      final lowerEarningType = earningType.toLowerCase();

      if (lowerEarningType == 'profit per plot') {
        displayEarningType = '% of Profit on Each Sold Plot';
      } else if (lowerEarningType == 'selling price per plot' ||
          lowerEarningType == '% of selling price per plot') {
        displayEarningType = '% of Selling Price per Plot';
      } else if (lowerEarningType == 'lump sum' ||
          lowerEarningType == '% of total project profit') {
        displayEarningType = '% of Total Project Profit';
      } else if (lowerEarningType == 'per plot') {
        displayEarningType = '% of Profit on Each Sold Plot';
      }

      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _formatPercentageDisplay(percentage),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
                textAlign: TextAlign.left,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFD8EDFB),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0C8CE9),
                  blurRadius: 2,
                  offset: const Offset(0, 0),
                  spreadRadius: 0,
                ),
              ],
            ),
            constraints: const BoxConstraints(maxWidth: 350),
            child: Text(
              displayEarningType,
              textAlign: TextAlign.left,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            ),
          ),
        ],
      );
    } else if (compensationType == 'Fixed Fee') {
      return Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            fixedFee != null ? _formatCurrencyNumber(fixedFee) : '₹ 0.00',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5D5D5D),
            ),
            textAlign: TextAlign.left,
          ),
        ),
      );
    } else if (compensationType == 'Monthly Fee') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                monthlyFee != null
                    ? _formatCurrencyNumber(monthlyFee)
                    : '₹ 0.00',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5D5D5D),
                ),
                textAlign: TextAlign.left,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '*',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                months != null ? '$months' : '0',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
                textAlign: TextAlign.left,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'Months',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5C5C5C),
            ),
          ),
        ],
      );
    } else {
      return Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'NA',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5C5C5C),
            ),
            textAlign: TextAlign.left,
          ),
        ),
      );
    }
  }

  double _getProjectManagersColumnWidth(String columnName) {
    switch (columnName) {
      case 'Sl. No.':
        return 60;
      case 'Project Manager Name':
        return 320;
      case 'Compensation ':
        return 176;
      case 'Earning Type ':
        return 340;
      case 'Earnings (₹)':
        return 215;
      default:
        return 200;
    }
  }

  Widget _buildLayoutPlotsTable(
    List<dynamic> plots,
    double allInCost, {
    required ScrollController scrollController,
  }) {
    const tableBaseWidth = 2966.0;
    final baseHeaderHeight = 48.0;
    final baseRowHeight = 48.0;
    final baseHeight = baseHeaderHeight + (plots.length * baseRowHeight);
    final scaledHeight = (baseHeight * _tableZoomLevel)
        .clamp(baseHeaderHeight * _tableZoomLevel, double.infinity);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: RawScrollbar(
          controller: scrollController,
          thumbVisibility: true,
          trackVisibility: true,
          interactive: true,
          thickness: 6.4,
          radius: const Radius.circular(100),
          trackRadius: const Radius.circular(100),
          thumbColor: const Color.fromRGBO(125, 125, 125, 0.27),
          trackColor: const Color(0xFFE4E7EB),
          crossAxisMargin: 2,
          child: SingleChildScrollView(
            controller: scrollController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              height: scaledHeight,
              child: Padding(
                padding: EdgeInsets.only(
                  left: ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0),
                  right: ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0) +
                      ((_tableZoomLevel - 1.0) * tableBaseWidth)
                          .clamp(0.0, tableBaseWidth),
                  top: ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0),
                  bottom: ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0) +
                      ((_tableZoomLevel - 1.0) * 100.0).clamp(0.0, 100.0),
                ),
                child: Transform.scale(
                  scale: _tableZoomLevel,
                  alignment: Alignment.topLeft,
                  child: Table(
                    border: TableBorder(
                      horizontalInside:
                          BorderSide(color: Colors.black, width: 1),
                      verticalInside: BorderSide(color: Colors.black, width: 1),
                    ),
                    columnWidths: const {
                      0: FixedColumnWidth(60), // Sl. No.
                      1: FixedColumnWidth(186), // Plot Number
                      2: FixedColumnWidth(215), // Area ($_areaUnitSuffix)
                      3: FixedColumnWidth(180), // Status
                      4: FixedColumnWidth(215), // All-in Cost
                      5: FixedColumnWidth(215), // Total Plot Cost
                      6: FixedColumnWidth(215), // Sale Price
                      7: FixedColumnWidth(215), // Sale Value
                      8: FixedColumnWidth(248), // Profit (₹/$_areaUnitSuffix)
                      9: FixedColumnWidth(248), // Profit (₹)
                      10: FixedColumnWidth(241), // Partner(s)
                      11: FixedColumnWidth(241), // Agent
                      12: FixedColumnWidth(320), // Buyer Name
                      13: FixedColumnWidth(167), // Sale date
                    },
                    children: [
                      // Header row
                      TableRow(
                        decoration: const BoxDecoration(
                          color: Color(0xFFE2E2E2),
                        ),
                        children: [
                          _buildTableHeaderCell('Sl. No.',
                              isFirst: true, centerAlign: true),
                          _buildTableHeaderCell('Plot Number'),
                          _buildTableHeaderCell('Area ($_areaUnitSuffix)'),
                          _buildTableHeaderCell('Status'),
                          _buildTableHeaderCell(
                              'All-in Cost (₹/$_areaUnitSuffix)'),
                          _buildTableHeaderCell('Total Plot Cost (₹)'),
                          _buildTableHeaderCell(
                              'Sale Price (₹/$_areaUnitSuffix)'),
                          _buildTableHeaderCell('Sale Value (₹)'),
                          _buildTableHeaderCell('Profit (₹/$_areaUnitSuffix)'),
                          _buildTableHeaderCell('Profit (₹)'),
                          _buildTableHeaderCell('Partner(s)'),
                          _buildTableHeaderCell('Agent'),
                          _buildTableHeaderCell('Buyer Name'),
                          _buildTableHeaderCell('Sale date', isLast: true),
                        ],
                      ),
                      // Data rows
                      ...plots.asMap().entries.map((entry) {
                        final index = entry.key;
                        final plot = entry.value;
                        final area =
                            ((plot['area'] as num?)?.toDouble() ?? 0.0);
                        final status =
                            (plot['status'] as String? ?? 'available')
                                .toLowerCase();
                        final isSold = status == 'sold';
                        final isPending =
                            status == 'pending' || status == 'reserved';
                        final showSaleDetails = isSold || isPending;
                        final statusLabel = isSold
                            ? 'Sold'
                            : (isPending ? 'Pending' : 'Available');
                        final salePrice =
                            ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
                        final hasSalePrice = salePrice > 0;
                        final plotNumber =
                            (plot['plot_number'] as String? ?? '').toString();
                        final totalPlotCost = area * allInCost;
                        final saleValue = showSaleDetails && hasSalePrice
                            ? salePrice * area
                            : 0.0;
                        final profitPerSqft =
                            showSaleDetails && hasSalePrice && area > 0
                                ? (salePrice - allInCost)
                                : 0.0;
                        final profit = showSaleDetails && hasSalePrice
                            ? (saleValue - totalPlotCost)
                            : 0.0;
                        final partners =
                            (plot['partners'] as List<dynamic>? ?? [])
                                .map((p) => p.toString())
                                .toList();
                        final agent =
                            (plot['agent_name'] as String? ?? '').toString();
                        final buyerName =
                            (plot['buyer_name'] as String? ?? '').toString();
                        final saleDate =
                            (plot['sale_date'] as String? ?? '').toString();
                        final isLastRow = index == plots.length - 1;

                        return TableRow(
                          children: [
                            _buildTableDataCell('${index + 1}',
                                isFirst: true,
                                isLastRow: isLastRow,
                                centerAlign: true),
                            _buildTableDataCell(plotNumber,
                                isFirst: false, isLastRow: isLastRow),
                            _buildAreaCell(
                                AreaUnitUtils.areaFromSqftToDisplay(
                                    area, _isSqm),
                                isLastRow),
                            _buildStatusCell(
                                statusLabel, isSold, isPending, isLastRow),
                            _buildCostCell(
                                '₹/$_areaUnitSuffix',
                                _formatCurrencyNumber(
                                    AreaUnitUtils.rateFromSqftToDisplay(
                                        allInCost, _isSqm)),
                                isLastRow),
                            _buildCostCell(
                                '₹',
                                _formatCurrencyNumber(totalPlotCost),
                                isLastRow),
                            _buildTableDataCell(
                                showSaleDetails && hasSalePrice
                                    ? '₹/$_areaUnitSuffix ${_formatCurrencyNumber(AreaUnitUtils.rateFromSqftToDisplay(salePrice, _isSqm))}'
                                    : '-',
                                isFirst: false,
                                isLastRow: isLastRow),
                            _buildTableDataCell(
                                showSaleDetails && hasSalePrice
                                    ? '₹ ${_formatCurrencyNumber(saleValue)}'
                                    : '-',
                                isFirst: false,
                                isLastRow: isLastRow),
                            _buildTableDataCell(
                                showSaleDetails && hasSalePrice
                                    ? '₹/$_areaUnitSuffix ${_formatCurrencyNumber(AreaUnitUtils.rateFromSqftToDisplay(profitPerSqft, _isSqm))}'
                                    : '-',
                                isFirst: false,
                                isLastRow: isLastRow),
                            _buildTableDataCell(
                                showSaleDetails && hasSalePrice
                                    ? '₹ ${_formatCurrencyNumber(profit)}'
                                    : '-',
                                isFirst: false,
                                isLastRow: isLastRow),
                            _buildPartnerCell(partners, isLastRow),
                            _buildAgentCell(agent, showSaleDetails, isLastRow),
                            _buildBuyerNameCell(
                                buyerName, showSaleDetails, isLastRow),
                            _buildSaleDateCell(
                                saleDate, showSaleDetails, isLastRow,
                                isLast: true),
                          ],
                        );
                      }).toList(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTableHeaderCell(String text,
      {bool isFirst = false, bool isLast = false, bool centerAlign = false}) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFE2E2E2),
        borderRadius: isFirst
            ? const BorderRadius.only(topLeft: Radius.circular(8))
            : isLast
                ? const BorderRadius.only(topRight: Radius.circular(8))
                : null,
      ),
      child: Align(
        alignment: centerAlign ? Alignment.center : Alignment.centerLeft,
        child: Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
          textAlign: centerAlign ? TextAlign.center : TextAlign.left,
        ),
      ),
    );
  }

  Widget _buildTableDataCell(String text,
      {bool isFirst = false,
      bool isLastRow = false,
      bool centerAlign = false}) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: isFirst && isLastRow
            ? const BorderRadius.only(bottomLeft: Radius.circular(8))
            : null,
      ),
      child: Align(
        alignment: centerAlign ? Alignment.center : Alignment.centerLeft,
        child: Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: text == '-' ? const Color(0xFF5D5D5D) : Colors.black,
          ),
          textAlign: centerAlign ? TextAlign.center : TextAlign.left,
        ),
      ),
    );
  }

  Widget _buildStatusCell(
      String text, bool isSold, bool isPending, bool isLastRow) {
    final statusColor = isSold
        ? const Color(0xFFFF0000)
        : (isPending ? const Color(0xFFFFA200) : const Color(0xFF50CD89));
    final statusBackgroundColor = isSold
        ? const Color(0xFFFFECEC)
        : (isPending ? const Color(0xFFFAE8C8) : const Color(0xFFE9F7EB));

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: statusBackgroundColor,
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
              Container(
                width: 16,
                height: 16,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                text,
                textAlign: TextAlign.left,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  fontStyle: FontStyle.normal,
                  color: Colors.black,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPartnerCell(List<String> partners, bool isLastRow) {
    final partnerText = partners.isEmpty ? '-' : partners.join(', ');
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          partnerText,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: partners.isEmpty
                ? const Color(0xFF5D5D5D)
                : Colors.black.withOpacity(0.8),
          ),
          textAlign: TextAlign.left,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildAgentCell(String agent, bool showSaleDetails, bool isLastRow) {
    if (!showSaleDetails) {
      return Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '-',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5D5D5D),
            ),
            textAlign: TextAlign.left,
          ),
        ),
      );
    }

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          agent.isEmpty ? 'Select Agent' : agent,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: agent.isEmpty ? const Color(0xFF5D5D5D) : Colors.black,
          ),
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.left,
          maxLines: 1,
        ),
      ),
    );
  }

  Widget _buildBuyerNameCell(
      String buyerName, bool showSaleDetails, bool isLastRow) {
    if (!showSaleDetails) {
      return Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '-',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5D5D5D),
            ),
            textAlign: TextAlign.left,
          ),
        ),
      );
    }

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          buyerName.isEmpty ? "Enter buyer's name" : buyerName,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: buyerName.isEmpty ? const Color(0xFF5D5D5D) : Colors.black,
          ),
          textAlign: TextAlign.left,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildAreaCell(double area, bool isLastRow) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _formatArea(area),
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
            ),
            Text(
              _areaUnitSuffix,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF5C5C5C),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaleDateCell(
      String saleDate, bool showSaleDetails, bool isLastRow,
      {bool isLast = false}) {
    if (!showSaleDetails) {
      return Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: isLastRow && isLast
              ? const BorderRadius.only(bottomRight: Radius.circular(8))
              : null,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '-',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5D5D5D),
            ),
            textAlign: TextAlign.left,
          ),
        ),
      );
    }

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: isLastRow && isLast
            ? const BorderRadius.only(bottomRight: Radius.circular(8))
            : null,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Icon(
              Icons.calendar_today,
              size: 16,
              color: const Color(0xFF5D5D5D),
            ),
            const SizedBox(width: 8),
            Text(
              saleDate.isEmpty ? 'dd/mm/yyyy' : saleDate,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF5D5D5D),
              ),
              textAlign: TextAlign.left,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCostCell(String prefix, String value, bool isLastRow) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              prefix,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: const Color(0xFF5C5C5C),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Calculate per-plot compensation for an agent
  double _calculateAgentPerPlotCompensation(
      Map<String, dynamic> agent, Map<String, dynamic> plot) {
    final compensationType = agent['compensation_type'] as String? ?? '';
    final earningType = agent['earning_type'] as String? ?? '';
    final status = (plot['status'] as String? ?? 'available').toLowerCase();

    // Only calculate compensation for sold plots
    if (status != 'sold') {
      return 0.0;
    }

    if (compensationType == 'Fixed Fee') {
      // Fixed fee is not per plot, return 0 for individual plot
      return 0.0;
    } else if (compensationType == 'Monthly Fee') {
      // Monthly fee is not per plot, return 0 for individual plot
      return 0.0;
    } else if (compensationType == 'Per Sqft Fee') {
      final perSqftFee = agent['per_sqft_fee'] as double? ?? 0.0;
      final area = (plot['area'] as num?)?.toDouble() ?? 0.0;
      return perSqftFee * area;
    } else if (compensationType == 'Percentage Bonus') {
      final percentage = agent['percentage'] as double? ?? 0.0;
      final salePrice = (plot['sale_price'] as num?)?.toDouble() ?? 0.0;
      final area = (plot['area'] as num?)?.toDouble() ?? 0.0;
      final saleValue = salePrice * area;

      // Check for "Selling Price Per Plot" - calculate percentage from sale value
      if (earningType == 'Selling Price Per Plot' ||
          earningType == '% of Selling Price per Plot' ||
          (earningType.toLowerCase().contains('selling price') &&
              earningType.toLowerCase().contains('plot'))) {
        // Apply percentage to this plot's sale value
        return (saleValue * percentage) / 100;
      }
      // Check for "Profit Per Plot" - calculate percentage from profit
      else if (earningType == 'Profit Per Plot' ||
          earningType == 'Per Plot' ||
          earningType == '% of Profit on Each Sold Plot' ||
          (earningType.toLowerCase().contains('profit') &&
              earningType.toLowerCase().contains('plot'))) {
        // Calculate profit for this specific plot
        final allInCost = _dashboardData?['allInCost'] as double? ?? 0.0;
        final plotCost = area * allInCost;
        final plotProfit = saleValue - plotCost;

        // Apply percentage to this plot's profit
        return (plotProfit * percentage) / 100;
      } else if (earningType == 'Lump Sum' ||
          earningType == '% of Total Project Profit') {
        // This is not per plot, return 0 for individual plot
        return 0.0;
      }
    }

    return 0.0;
  }

  double _calculateAssignedAgentPerPlotCompensation(Map<String, dynamic> plot) {
    if (_agents.isEmpty) return 0.0;
    final status = (plot['status'] as String? ?? 'available').toLowerCase();
    if (status != 'sold') return 0.0;

    final plotAgentName =
        (plot['agent_name'] as String? ?? plot['agent'] as String? ?? '')
            .trim()
            .toLowerCase();
    if (plotAgentName.isEmpty) return 0.0;

    final matchedAgent = _agents.firstWhere(
      (agent) =>
          (agent['name'] as String? ?? '').trim().toLowerCase() ==
          plotAgentName,
      orElse: () => <String, dynamic>{},
    );
    if (matchedAgent.isEmpty) return 0.0;

    return _calculateAgentPerPlotCompensation(matchedAgent, plot);
  }

  // Calculate total project managers compensation (sum of earnings)
  double _calculateTotalProjectManagersCompensation() {
    if (_projectManagers.isEmpty) {
      return 0.0;
    }

    return _projectManagers.fold<double>(
      0.0,
      (sum, manager) => sum + _calculateProjectManagerEarnings(manager),
    );
  }

  // Calculate total agents compensation (sum of earnings)
  double _calculateTotalAgentsCompensation() {
    if (_agents.isEmpty) {
      return 0.0;
    }

    return _agents.fold<double>(
      0.0,
      (sum, agent) => sum + _calculateAgentEarnings(agent),
    );
  }

  // Helper: check if an agent has at least one sold plot assigned in site layouts
  bool _agentHasSoldPlot(String agentName) {
    if (_siteLayouts.isEmpty || agentName.trim().isEmpty) {
      print('_agentHasSoldPlot: Empty layouts or agent name - returning false');
      return false;
    }

    print(
        '_agentHasSoldPlot: Checking agent "$agentName" in ${_siteLayouts.length} layouts');

    for (var layout in _siteLayouts) {
      final plots = layout['plots'] as List<dynamic>? ?? [];
      print('  Layout "${layout['name']}": ${plots.length} plots');
      for (var plot in plots) {
        final status = (plot['status'] as String? ?? '').toLowerCase();
        // Check both 'agent' and 'agent_name' fields for backward compatibility
        final plotAgent =
            (plot['agent_name'] as String? ?? plot['agent'] as String? ?? '')
                .trim();
        if (status == 'sold') {
          print(
              '    Found sold plot with agent "$plotAgent" (looking for "$agentName")');
          if (plotAgent == agentName.trim()) {
            print('    -> MATCH! Agent has sold plot');
            return true;
          }
        }
      }
    }

    print('_agentHasSoldPlot: No sold plots found for agent "$agentName"');
    return false;
  }

  bool _isTotalProjectProfitBonus(String earningType) {
    final lower = earningType.toLowerCase();
    return earningType == 'Lump Sum' ||
        earningType == '% of Total Project Profit' ||
        lower.contains('total project profit') ||
        lower.contains('lump');
  }

  double _calculateAgentEarnings(Map<String, dynamic> agent) {
    final compensationType = agent['compensation_type'] as String? ?? '';
    final earningType = agent['earning_type'] as String? ?? '';
    final agentName = agent['name'] as String? ?? '';

    if (compensationType == 'Fixed Fee') {
      return agent['fixed_fee'] as double? ?? 0.0;
    } else if (compensationType == 'Monthly Fee') {
      final monthlyFee = agent['monthly_fee'] as double? ?? 0.0;
      final months = agent['months'] as int? ?? 0;
      return monthlyFee * months;
    } else if (compensationType == 'Per Sqft Fee' ||
        compensationType == 'Per Sqm Fee') {
      final perSqftFee = agent['per_sqft_fee'] as double? ?? 0.0;
      // Calculate total area of sold plots for this agent
      double totalSoldArea = 0.0;

      if (_dashboardData != null && _siteLayouts.isNotEmpty) {
        for (var layout in _siteLayouts) {
          final plots = layout['plots'] as List<dynamic>? ?? [];
          for (var plot in plots) {
            final status = plot['status'] as String? ?? '';
            // Check both 'agent_name' and 'agent' fields for backward compatibility
            final plotAgentName = (plot['agent_name'] as String? ??
                    plot['agent'] as String? ??
                    '')
                .trim();
            if (status == 'sold' &&
                plotAgentName == (agent['name'] as String? ?? '').trim()) {
              final area = (plot['area'] as num?)?.toDouble() ?? 0.0;
              totalSoldArea += area;
            }
          }
        }
      }

      // per_sqft_fee is stored in sqft internally; convert to display unit if needed
      final feeToUse = _isSqm
          ? AreaUnitUtils.rateFromSqftToDisplay(perSqftFee, true)
          : perSqftFee;
      final areaToUse = _isSqm
          ? AreaUnitUtils.areaFromSqftToDisplay(totalSoldArea, true)
          : totalSoldArea;
      return feeToUse * areaToUse;
    } else if (compensationType == 'Percentage Bonus') {
      final percentage = agent['percentage'] as double? ?? 0.0;
      final isLumpSum = _isTotalProjectProfitBonus(earningType);

      // Sold-plot dependency applies only to sold-plot based bonus types.
      if (!isLumpSum && !_agentHasSoldPlot(agentName)) {
        return 0.0;
      }

      // Check earning type to determine calculation method
      final isSellingPriceBased = earningType == 'Selling Price Per Plot' ||
          earningType == '% of Selling Price per Plot' ||
          (earningType.toLowerCase().contains('selling price') &&
              earningType.toLowerCase().contains('plot'));

      if (isSellingPriceBased) {
        // Calculate agent earnings as percentage of selling price on each of their sold plots
        double totalSaleValue = 0.0;

        if (_siteLayouts.isNotEmpty && agentName.isNotEmpty) {
          for (var layout in _siteLayouts) {
            final plots = layout['plots'] as List<dynamic>? ?? [];
            for (var plot in plots) {
              final status = (plot['status'] as String? ?? '').toLowerCase();
              final plotAgentName = (plot['agent_name'] as String? ??
                      plot['agent'] as String? ??
                      '')
                  .trim();

              if (status == 'sold' && plotAgentName == agentName.trim()) {
                final salePrice =
                    ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
                final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
                final saleValue = salePrice * area;
                totalSaleValue += saleValue;
              }
            }
          }
        }

        return (totalSaleValue * percentage) / 100;
      } else {
        if (isLumpSum) {
          // Calculate as percentage of total gross profit
          final totalGrossProfit = _calculateTotalGrossProfit();
          return (totalGrossProfit * percentage) / 100;
        } else {
          // Calculate agent earnings as percentage of profit on each of their sold plots
          double agentProfit = 0.0;
          final allInCost = _dashboardData!['allInCost'] as double? ?? 0.0;

          if (_siteLayouts.isNotEmpty && agentName.isNotEmpty) {
            for (var layout in _siteLayouts) {
              final plots = layout['plots'] as List<dynamic>? ?? [];
              for (var plot in plots) {
                final status = (plot['status'] as String? ?? '').toLowerCase();
                final plotAgentName = (plot['agent_name'] as String? ??
                        plot['agent'] as String? ??
                        '')
                    .trim();

                if (status == 'sold' && plotAgentName == agentName.trim()) {
                  final salePrice =
                      ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
                  final area = ((plot['area'] as num?)?.toDouble() ?? 0.0);
                  final saleValue = salePrice * area;
                  final plotCost = area * allInCost;
                  final plotProfit = saleValue - plotCost;
                  agentProfit += plotProfit;
                }
              }
            }
          }

          return (agentProfit * percentage) / 100;
        }
      }
    }

    return 0.0;
  }

  Widget _buildAgentsSection() {
    if (_dashboardData == null) {
      return _buildAgentsLoadingSkeleton();
    }

    // Ensure _agents is initialized - check if it's null or not a list
    final agentsList = _agents ?? <Map<String, dynamic>>[];
    if (agentsList.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Agent(s) Earnings',
              style: GoogleFonts.inter(
                fontSize: 24,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No agents found',
              style: GoogleFonts.inter(
                fontSize: 16,
                color: const Color(0xFF5C5C5C),
              ),
            ),
          ],
        ),
      );
    }

    // Calculate earnings for each agent
    final agentsWithEarnings = agentsList.map((agent) {
      final earnings = _calculateAgentEarnings(agent);
      return {
        ...agent,
        'earnings': earnings,
      };
    }).toList();

    // Calculate total earnings
    final totalEarnings = agentsWithEarnings.fold<double>(
      0.0,
      (sum, agent) => sum + (agent['earnings'] as double? ?? 0.0),
    );

    final filteredCompensationLayouts =
        _compensationLayouts.asMap().entries.where((entry) {
      return _compensationLayoutMatchesFilter(entry.value);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                'Agent(s) Earnings',
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 24),

              // Total Earnings card
              Container(
                width: 320,
                padding: const EdgeInsets.all(16),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Total Earnings',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF5C5C5C),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _formatCurrency(totalEarnings),
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Agents table
              _buildAgentsTable(agentsWithEarnings),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _buildCompensationLayoutsToolbar(),
        const SizedBox(height: 24),
        if (filteredCompensationLayouts.isEmpty)
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
            child: Text(
              'No layouts found',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w400,
                color: const Color(0xFF5C5C5C),
              ),
            ),
          )
        else
          ...filteredCompensationLayouts.asMap().entries.map((entry) {
            final position = entry.key;
            final originalIndex = entry.value.key;
            final layout = entry.value.value;
            return Padding(
              padding: EdgeInsets.only(
                  bottom: position < filteredCompensationLayouts.length - 1
                      ? 24
                      : 0),
              child: _buildLayoutCompensationCardWithSaleDate(
                  layout, originalIndex),
            );
          }).toList(),
      ],
    );
  }

  Widget _buildAgentsTable(List<Map<String, dynamic>> agents) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: _agentsTableScrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _agentsTableScrollController,
          scrollDirection: Axis.horizontal,
          child: IntrinsicWidth(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Sl. No. column
                Column(
                  children: [
                    _buildAgentsTableHeaderCell('Sl. No.',
                        isFirst: true, isLast: false),
                    ...agents.asMap().entries.map((entry) {
                      final index = entry.key;
                      final isLastRow = index == agents.length - 1;
                      return _buildAgentsTableDataCell(
                        '${index + 1}',
                        columnName: 'Sl. No.',
                        isFirst: true,
                        isLastRow: isLastRow,
                        isLast: false,
                      );
                    }),
                  ],
                ),
                // Agent Name column
                Column(
                  children: [
                    _buildAgentsTableHeaderCell('Agent Name',
                        isFirst: false, isLast: false),
                    ...agents.asMap().entries.map((entry) {
                      final index = entry.key;
                      final agent = entry.value;
                      final isLastRow = index == agents.length - 1;
                      return _buildAgentsTableDataCell(
                        agent['name'] as String? ?? '',
                        columnName: 'Agent Name',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: false,
                        isAgentName: true,
                      );
                    }),
                  ],
                ),
                // Compensation column
                Column(
                  children: [
                    _buildAgentsTableHeaderCell('Compensation Type',
                        isFirst: false, isLast: false),
                    ...agents.asMap().entries.map((entry) {
                      final index = entry.key;
                      final agent = entry.value;
                      final compensationType =
                          agent['compensation_type'] as String? ?? '';
                      final isLastRow = index == agents.length - 1;
                      final displayCompensationType =
                          (compensationType == 'Per Sqft Fee' ||
                                  compensationType == 'Per Sqm Fee')
                              ? _perAreaFeeLabel
                              : (compensationType.isEmpty
                                  ? 'None'
                                  : compensationType);
                      return _buildAgentsTableDataCell(
                        displayCompensationType,
                        columnName: 'Compensation ',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: false,
                        isCompensation: true,
                        compensationType: compensationType,
                      );
                    }),
                  ],
                ),
                // Earning Type column
                Column(
                  children: [
                    _buildAgentsTableHeaderCell('Earning Type ',
                        isFirst: false, isLast: false),
                    ...agents.asMap().entries.map((entry) {
                      final index = entry.key;
                      final agent = entry.value;
                      final compensationType =
                          agent['compensation_type'] as String? ?? '';
                      final earningType =
                          agent['earning_type'] as String? ?? '';
                      final percentage = agent['percentage'] as double?;
                      final fixedFee = agent['fixed_fee'] as double?;
                      final monthlyFee = agent['monthly_fee'] as double?;
                      final months = agent['months'] as int?;
                      final perSqftFee = agent['per_sqft_fee'] as double?;
                      final isLastRow = index == agents.length - 1;

                      final perSqmFee = agent['per_sqm_fee'] as double?;
                      return _buildAgentsEarningTypeCell(
                        agent: agent,
                        compensationType: compensationType,
                        earningType: earningType,
                        percentage: percentage,
                        fixedFee: fixedFee,
                        monthlyFee: monthlyFee,
                        months: months,
                        perSqftFee: perSqftFee,
                        perSqmFee: perSqmFee,
                        isLastRow: isLastRow,
                      );
                    }),
                  ],
                ),
                // Earnings (₹) column
                Column(
                  children: [
                    _buildAgentsTableHeaderCell('Earnings (₹)',
                        isFirst: false, isLast: true),
                    ...agents.asMap().entries.map((entry) {
                      final index = entry.key;
                      final agent = entry.value;
                      final compensationType =
                          agent['compensation_type'] as String? ?? '';
                      final isPercentageBonus =
                          compensationType == 'Percentage Bonus';
                      final earnings = agent['earnings'] as double? ?? 0.0;
                      final hasSoldPlot =
                          _agentHasSoldPlot(agent['name'] as String? ?? '');
                      final isLastRow = index == agents.length - 1;
                      final earningType =
                          agent['earning_type'] as String? ?? '';
                      final isTotalProjectProfitBonus =
                          _isTotalProjectProfitBonus(earningType);
                      // Keep percentage bonus dependent on sold-plot data.
                      final displayText = (isPercentageBonus &&
                              !isTotalProjectProfitBonus &&
                              !hasSoldPlot)
                          ? '-'
                          : _formatCurrencyNumber(earnings);
                      return _buildAgentsTableDataCell(
                        displayText,
                        columnName: 'Earnings (₹)',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: true,
                        prefix: '₹ ',
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAgentsTableHeaderCell(String text,
      {bool isFirst = false, bool isLast = false}) {
    final width = _getAgentsColumnWidth(text);
    return Container(
      height: 48,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFE2E2E2),
        border: Border(
          top: const BorderSide(color: Colors.black, width: 1),
          bottom: const BorderSide(color: Colors.black, width: 1),
          left: isFirst
              ? const BorderSide(color: Colors.black, width: 1)
              : BorderSide.none,
          right: const BorderSide(color: Colors.black, width: 1),
        ),
        borderRadius: isFirst
            ? const BorderRadius.only(topLeft: Radius.circular(8))
            : isLast
                ? const BorderRadius.only(topRight: Radius.circular(8))
                : null,
      ),
      child: Center(
        child: RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            children: [
              TextSpan(
                text: text.replaceAll(' *', ''),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
              if (text.contains('*'))
                TextSpan(
                  text: ' *',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.red,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAgentsTableDataCell(
    String text, {
    required String columnName,
    bool isFirst = false,
    bool isLastRow = false,
    bool isLast = false,
    bool isAgentName = false,
    bool isCompensation = false,
    String? compensationType,
    String? prefix,
  }) {
    final width = _getAgentsColumnWidth(columnName);
    final shouldLeftAlign = columnName == 'Agent Name' ||
        columnName == 'Earning Type ' ||
        columnName == 'Earnings (₹)' ||
        isCompensation ||
        prefix == '₹ ' ||
        text == '-';
    return Container(
      height: 48,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: const BorderSide(color: Colors.black, width: 1),
          left: isFirst
              ? const BorderSide(color: Colors.black, width: 1)
              : BorderSide.none,
          right: const BorderSide(color: Colors.black, width: 1),
        ),
        borderRadius: isFirst && isLastRow
            ? const BorderRadius.only(bottomLeft: Radius.circular(8))
            : isLast && isLastRow
                ? const BorderRadius.only(bottomRight: Radius.circular(8))
                : null,
      ),
      child: Align(
        alignment: shouldLeftAlign ? Alignment.centerLeft : Alignment.center,
        child: isAgentName
            ? Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    text,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                    textAlign: TextAlign.left,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
            : isCompensation
                ? IntrinsicWidth(
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD8EDFB),
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
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          text,
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.normal,
                            color: Colors.black,
                          ),
                          textAlign: TextAlign.left,
                        ),
                      ),
                    ),
                  )
                : Text(
                    prefix != null ? '$prefix$text' : text,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                    textAlign:
                        shouldLeftAlign ? TextAlign.left : TextAlign.center,
                  ),
      ),
    );
  }

  Widget _buildAgentsEarningTypeCell({
    required Map<String, dynamic> agent,
    required String compensationType,
    required String earningType,
    double? percentage,
    double? fixedFee,
    double? monthlyFee,
    int? months,
    double? perSqftFee,
    double? perSqmFee,
    required bool isLastRow,
  }) {
    final width = _getAgentsColumnWidth('Earning Type ');
    return Container(
      height: 48,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: const BorderSide(color: Colors.black, width: 1),
          right: const BorderSide(color: Colors.black, width: 1),
        ),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _buildAgentsEarningTypeContent(
          compensationType: compensationType,
          earningType: earningType,
          percentage: percentage,
          fixedFee: fixedFee,
          monthlyFee: monthlyFee,
          months: months,
          perSqftFee: perSqftFee,
          perSqmFee: perSqmFee,
        ),
      ),
    );
  }

  Widget _buildAgentsEarningTypeContent({
    required String compensationType,
    required String earningType,
    double? percentage,
    double? fixedFee,
    double? monthlyFee,
    int? months,
    double? perSqftFee,
    double? perSqmFee,
  }) {
    if (compensationType == 'Percentage Bonus') {
      // Map database earning type to UI display format
      String displayEarningType = earningType;
      final lowerEarningType = earningType.toLowerCase();

      if (lowerEarningType == 'profit per plot' ||
          lowerEarningType == 'per plot') {
        displayEarningType = '% of Profit on Each Sold Plot';
      } else if (lowerEarningType == 'selling price per plot') {
        displayEarningType = '% of Selling Price per Plot';
      } else if (lowerEarningType == 'lump sum') {
        displayEarningType = '% of Total Project Profit';
      }

      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _formatPercentageDisplay(percentage),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
                textAlign: TextAlign.left,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFD8EDFB),
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
            child: Text(
              displayEarningType,
              textAlign: TextAlign.left,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            ),
          ),
        ],
      );
    } else if (compensationType == 'Fixed Fee') {
      return Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            fixedFee != null ? _formatCurrencyNumber(fixedFee) : '₹ 0.00',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5D5D5D),
            ),
            textAlign: TextAlign.left,
          ),
        ),
      );
    } else if (compensationType == 'Monthly Fee') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                monthlyFee != null
                    ? _formatCurrencyNumber(monthlyFee)
                    : '₹ 0.00',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5D5D5D),
                ),
                textAlign: TextAlign.left,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '*',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                months != null ? '$months' : '0',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
                textAlign: TextAlign.left,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'Months',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5C5C5C),
            ),
          ),
        ],
      );
    } else if (compensationType == 'Per Sqft Fee' ||
        compensationType == 'Per Sqm Fee') {
      // Convert per_sqft_fee from sqft to display unit
      final feeToDisplay = perSqftFee != null
          ? AreaUnitUtils.rateFromSqftToDisplay(perSqftFee!, _isSqm)
          : 0.0;
      return Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            feeToDisplay > 0
                ? '₹ ${_formatCurrencyNumber(feeToDisplay)}'
                : '₹ 0.00',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5D5D5D),
            ),
            textAlign: TextAlign.left,
          ),
        ),
      );
    } else {
      return Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'NA',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5C5C5C),
            ),
            textAlign: TextAlign.left,
          ),
        ),
      );
    }
  }

  double _getAgentsColumnWidth(String columnName) {
    switch (columnName) {
      case 'Sl. No.':
        return 60;
      case 'Agent Name':
        return 320;
      case 'Compensation ':
        return 230;
      case 'Compensation Type':
        return 230;
      case 'Earning Type ':
        return 337;
      case 'Earnings (₹)':
        return 215;
      default:
        return 200;
    }
  }

  Widget _buildCompensationSection() {
    if (_dashboardData == null) {
      return _buildAgentsLoadingSkeleton();
    }

    return Container(
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
          // Header
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Compensation Summary',
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Track Project Managers and Agents compensation plot wise',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.normal,
                  color: Colors.black.withOpacity(0.8),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${_compensationLayouts.length} Layouts',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Compensation cards row
          Row(
            children: [
              // Total Compensation card (first)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Compensation given',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF5C5C5C),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _formatCurrency(
                            _calculateTotalProjectManagersCompensation() +
                                _calculateTotalAgentsCompensation()),
                        style: GoogleFonts.inter(
                          fontSize: 24,
                          fontWeight: FontWeight.normal,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // Project Managers Compensation card
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Project Managers Compensation',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF5C5C5C),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _formatCurrency(
                            _calculateTotalProjectManagersCompensation()),
                        style: GoogleFonts.inter(
                          fontSize: 24,
                          fontWeight: FontWeight.normal,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // Agents Compensation card
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Agents Compensation',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFF5C5C5C),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _formatCurrency(_calculateTotalAgentsCompensation()),
                        style: GoogleFonts.inter(
                          fontSize: 24,
                          fontWeight: FontWeight.normal,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Layout sections
          ..._compensationLayouts.asMap().entries.map((entry) {
            final index = entry.key;
            final layout = entry.value;
            return Padding(
              padding: EdgeInsets.only(
                  bottom: index < _compensationLayouts.length - 1 ? 24 : 0),
              child: _buildLayoutCompensationCard(layout, index),
            );
          }).toList(),
        ],
      ),
    );
  }

  Widget _buildLayoutCompensationCard(
      Map<String, dynamic> layout, int layoutIndex) {
    final layoutName = layout['name'] as String? ?? 'Layout ${layoutIndex + 1}';
    final plots = layout['plots'] as List<dynamic>? ?? [];
    final totalPlots = layout['totalPlots'] as int? ?? 0;
    final availablePlots = layout['availablePlots'] as int? ?? 0;
    final soldPlots = layout['soldPlots'] as int? ?? 0;
    final grossProfit = layout['grossProfit'] as double? ?? 0.0;
    final totalCompensation = layout['totalCompensation'] as double? ?? 0.0;

    return Container(
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
          // Layout header
          Row(
            children: [
              Text(
                '${layoutIndex + 1}.',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF5C5C5C),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Layout: $layoutName',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF5C5C5C),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Plot count and status
          Row(
            children: [
              Text(
                '$totalPlots plots',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              ),
              const SizedBox(width: 16),
              Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: Color(0xFF06AB00),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$availablePlots Available',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF5C5C5C),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$soldPlots Sold',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.normal,
                      color: const Color(0xFF5C5C5C),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Agents Compensation summary
          RichText(
            text: TextSpan(
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
              children: [
                const TextSpan(text: 'Agents Compensation:'),
                TextSpan(
                  text: ' ${_formatCurrency(totalCompensation)}',
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Compensation table
          _buildCompensationTable(plots),
        ],
      ),
    );
  }

  Widget _buildLayoutCompensationCardWithSaleDate(
      Map<String, dynamic> layout, int layoutIndex) {
    final layoutName = layout['name'] as String? ?? 'Layout ${layoutIndex + 1}';
    final plots = layout['plots'] as List<dynamic>? ?? [];
    final totalPlots = layout['totalPlots'] as int? ?? 0;
    final availablePlots = layout['availablePlots'] as int? ?? 0;
    final soldPlots = layout['soldPlots'] as int? ?? 0;
    final soldPercent =
        totalPlots > 0 ? ((soldPlots / totalPlots) * 100).round() : 0;

    const collapseIconAsset = 'assets/images/Indi_collapse.svg';
    const expandIconAsset = 'assets/images/Indi_expand.svg';
    final isCollapsed = _collapsedCompensationLayouts.contains(layoutIndex);

    return Container(
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
          // Layout header (Figma)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  SizedBox(
                    height: 36,
                    child: Center(
                      child: Text(
                        '${layoutIndex + 1}.',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    height: 36,
                    child: Center(
                      child: Text(
                        'Layout:',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.black,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: const Color.fromRGBO(255, 255, 255, 0.95),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Text(
                        layoutName,
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
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '$soldPercent%',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$soldPlots/$totalPlots plots sold',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF5C5C5C),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(
                      totalPlots == 1 ? '1 plot' : '$totalPlots plots',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Container(
                      width: 4,
                      height: 4,
                      decoration: const BoxDecoration(
                        color: Colors.black,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      'Total Agent Compensation:',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '₹ ${_formatNumberNoDecimals(layout['totalCompensation'] as double? ?? 0.0)}',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black.withOpacity(0.75),
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(() {
                    if (isCollapsed) {
                      _collapsedCompensationLayouts.remove(layoutIndex);
                    } else {
                      _collapsedCompensationLayouts.add(layoutIndex);
                    }
                  });
                },
                child: SvgPicture.asset(
                  isCollapsed ? expandIconAsset : collapseIconAsset,
                  width: 12,
                  height: 12,
                  fit: BoxFit.contain,
                  placeholderBuilder: (context) => const SizedBox(
                    width: 12,
                    height: 12,
                  ),
                ),
              ),
            ],
          ),
          if (!isCollapsed) ...[
            const SizedBox(height: 16),
            Container(
              padding: EdgeInsets.only(
                left: 8 +
                    (12 * (_compensationTableZoomLevel - 1.0).clamp(0.0, 0.2)),
                right: 8 +
                    (12 * (_compensationTableZoomLevel - 1.0).clamp(0.0, 0.2)),
                top: 8 +
                    (12 * (_compensationTableZoomLevel - 1.0).clamp(0.0, 0.2)),
                bottom: 8 +
                    (12 * (_compensationTableZoomLevel - 1.0).clamp(0.0, 0.2)) +
                    (50 * (_compensationTableZoomLevel - 1.0).clamp(0.0, 0.2)),
              ),
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
              child: _buildCompensationTableWithSaleDate(plots),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompensationTable(List<dynamic> plots) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(1),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Scrollbar(
          controller: _compensationTableScrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _compensationTableScrollController,
            scrollDirection: Axis.horizontal,
            child: Table(
              border: TableBorder(
                horizontalInside: BorderSide(color: Colors.black, width: 1),
                verticalInside: BorderSide(color: Colors.black, width: 1),
              ),
              columnWidths: const {
                0: FixedColumnWidth(60), // Sl. No.
                1: FixedColumnWidth(186), // Plot Number
                2: FixedColumnWidth(215), // Area (sqft)
                3: FixedColumnWidth(180), // Status
                4: FixedColumnWidth(174), // Agent
                5: FixedColumnWidth(215), // Compensation
              },
              children: [
                // Header row
                TableRow(
                  decoration: BoxDecoration(
                    color: const Color(0xFFE2E2E2),
                  ),
                  children: [
                    _buildCompensationTableHeaderCell('Sl. No.', isFirst: true),
                    _buildCompensationTableHeaderCell('Plot Number'),
                    _buildCompensationTableHeaderCell(
                        'Area ($_areaUnitSuffix)'),
                    _buildCompensationTableHeaderCell('Status'),
                    _buildCompensationTableHeaderCell('Agent'),
                    _buildCompensationTableHeaderCell('Earnings (₹)',
                        isLast: true),
                  ],
                ),
                // Data rows
                ...plots.asMap().entries.map((entry) {
                  final index = entry.key;
                  final plot = entry.value as Map<String, dynamic>;
                  final plotNumber = plot['plot_number'] as String? ?? '-';
                  final area = (plot['area'] as num?)?.toDouble() ?? 0.0;
                  final status =
                      (plot['status'] as String? ?? 'available').toLowerCase();
                  final isSold = status == 'sold';
                  final isPending = status == 'pending' || status == 'reserved';
                  final showSaleDetails = isSold || isPending;
                  final statusLabel =
                      isSold ? 'Sold' : (isPending ? 'Pending' : 'Available');
                  final agentName = plot['agent_name'] as String? ?? '';

                  // Calculate agent's compensation for THIS SPECIFIC PLOT
                  double plotCompensation = 0.0;
                  if (agentName.isNotEmpty && isSold && _agents != null) {
                    final agent = _agents!.firstWhere(
                      (a) =>
                          (a['name'] as String? ?? '').toLowerCase() ==
                          agentName.toLowerCase(),
                      orElse: () => <String, dynamic>{},
                    );
                    if (agent.isNotEmpty) {
                      final compensationType =
                          agent['compensation_type'] as String? ?? '';

                      if (compensationType == 'Fixed Fee') {
                        plotCompensation = agent['fixed_fee'] as double? ?? 0.0;
                      } else if (compensationType == 'Monthly Fee') {
                        final monthlyFee =
                            agent['monthly_fee'] as double? ?? 0.0;
                        final months = agent['months'] as int? ?? 0;
                        plotCompensation = monthlyFee * months;
                      } else if (compensationType == 'Per Sqft Fee') {
                        final perSqftFee =
                            agent['per_sqft_fee'] as double? ?? 0.0;
                        plotCompensation = perSqftFee * area;
                      } else if (compensationType == 'Percentage Bonus') {
                        final percentage =
                            agent['percentage'] as double? ?? 0.0;
                        final earningType =
                            agent['earning_type'] as String? ?? '';
                        final salePrice =
                            ((plot['sale_price'] as num?)?.toDouble() ?? 0.0);
                        final saleValue = salePrice * area;

                        // Check for "Selling Price Per Plot" - calculate percentage from sale value
                        final isSellingPriceBased =
                            earningType == 'Selling Price Per Plot' ||
                                earningType == '% of Selling Price per Plot' ||
                                (earningType
                                        .toLowerCase()
                                        .contains('selling price') &&
                                    earningType.toLowerCase().contains('plot'));

                        // Check if it's Lump Sum / Total Project Profit
                        final isLumpSum = earningType == 'Lump Sum' ||
                            earningType == '% of Total Project Profit' ||
                            (earningType
                                    .toLowerCase()
                                    .contains('total project profit') ||
                                earningType.toLowerCase().contains('lump'));

                        if (isSellingPriceBased) {
                          // Apply percentage to this plot's sale value
                          plotCompensation = (saleValue * percentage) / 100;
                        } else if (isLumpSum) {
                          // For "% of Total Project Profit", calculate total agent compensation
                          // then distribute proportionally across agent's sold plots
                          final totalGrossProfit = _calculateTotalGrossProfit();
                          final totalAgentCompensation =
                              (totalGrossProfit * percentage) / 100;

                          // Calculate total sale value for all plots sold by this agent
                          double totalAgentSaleValue = 0.0;
                          if (_siteLayouts.isNotEmpty && agentName.isNotEmpty) {
                            for (var layout in _siteLayouts) {
                              final layoutPlots =
                                  layout['plots'] as List<dynamic>? ?? [];
                              for (var layoutPlot in layoutPlots) {
                                final plotStatus =
                                    (layoutPlot['status'] as String? ?? '')
                                        .toLowerCase();
                                final plotAgentName =
                                    (layoutPlot['agent_name'] as String? ??
                                            layoutPlot['agent'] as String? ??
                                            '')
                                        .trim();

                                if (plotStatus == 'sold' &&
                                    plotAgentName == agentName.trim()) {
                                  final plotSalePrice =
                                      ((layoutPlot['sale_price'] as num?)
                                              ?.toDouble() ??
                                          0.0);
                                  final plotArea = ((layoutPlot['area'] as num?)
                                          ?.toDouble() ??
                                      0.0);
                                  totalAgentSaleValue +=
                                      plotSalePrice * plotArea;
                                }
                              }
                            }
                          }

                          // Distribute compensation proportionally based on this plot's sale value
                          if (totalAgentSaleValue > 0) {
                            plotCompensation =
                                (totalAgentCompensation * saleValue) /
                                    totalAgentSaleValue;
                          } else {
                            plotCompensation = 0.0;
                          }
                        } else {
                          // Calculate profit for this specific plot
                          final allInCost =
                              _dashboardData!['allInCost'] as double? ?? 0.0;
                          final plotCost = area * allInCost;
                          final plotProfit = saleValue - plotCost;

                          // Apply percentage to this plot's profit
                          plotCompensation = (plotProfit * percentage) / 100;
                        }
                      }
                    }
                  }

                  final isLastRow = index == plots.length - 1;

                  return TableRow(
                    children: [
                      _buildCompensationTableDataCell('${index + 1}',
                          isFirst: true, isLastRow: isLastRow),
                      _buildCompensationTableDataCell(plotNumber,
                          isFirst: false, isLastRow: isLastRow),
                      _buildCompensationAreaCell(
                          AreaUnitUtils.areaFromSqftToDisplay(area, _isSqm),
                          isLastRow),
                      _buildCompensationStatusCell(
                          statusLabel, isSold, isPending, isLastRow),
                      _buildCompensationAgentCell(
                          agentName, showSaleDetails, isLastRow),
                      _buildCompensationTableDataCell(
                        plotCompensation > 0
                            ? _formatCurrency(plotCompensation)
                            : '-',
                        isFirst: false,
                        isLastRow: isLastRow,
                        isLast: true,
                      ),
                    ],
                  );
                }).toList(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompensationTableWithSaleDate(List<dynamic> plots) {
    const tableBaseWidth = 1197.0;
    final baseHeaderHeight = 48.0;
    final baseRowHeight = 48.0;
    final baseHeight = baseHeaderHeight + (plots.length * baseRowHeight);
    final scaledHeight = (baseHeight * _compensationTableZoomLevel)
        .clamp(baseHeaderHeight * _compensationTableZoomLevel, double.infinity);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(1),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Scrollbar(
          controller: _compensationTableScrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _compensationTableScrollController,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              height: scaledHeight,
              child: Padding(
                padding: EdgeInsets.only(
                  left: ((_compensationTableZoomLevel - 1.0) * 10.0)
                      .clamp(0.0, 10.0),
                  right: ((_compensationTableZoomLevel - 1.0) * 10.0)
                          .clamp(0.0, 10.0) +
                      ((_compensationTableZoomLevel - 1.0) * tableBaseWidth)
                          .clamp(0.0, tableBaseWidth),
                  top: ((_compensationTableZoomLevel - 1.0) * 10.0)
                      .clamp(0.0, 10.0),
                  bottom: ((_compensationTableZoomLevel - 1.0) * 10.0)
                          .clamp(0.0, 10.0) +
                      ((_compensationTableZoomLevel - 1.0) * 100.0)
                          .clamp(0.0, 100.0),
                ),
                child: Transform.scale(
                  scale: _compensationTableZoomLevel,
                  alignment: Alignment.topLeft,
                  child: Table(
                    border: TableBorder(
                      horizontalInside:
                          BorderSide(color: Colors.black, width: 1),
                      verticalInside: BorderSide(color: Colors.black, width: 1),
                    ),
                    columnWidths: const {
                      0: FixedColumnWidth(60), // Sl. No.
                      1: FixedColumnWidth(186), // Plot Number
                      2: FixedColumnWidth(215), // Area (sqft)
                      3: FixedColumnWidth(180), // Status
                      4: FixedColumnWidth(174), // Agent
                      5: FixedColumnWidth(215), // Compensation
                      6: FixedColumnWidth(167), // Sale date
                    },
                    children: [
                      // Header row
                      TableRow(
                        decoration: BoxDecoration(
                          color: const Color(0xFFE2E2E2),
                        ),
                        children: [
                          _buildCompensationTableHeaderCell('Sl. No.',
                              isFirst: true),
                          _buildCompensationTableHeaderCell('Plot Number'),
                          _buildCompensationTableHeaderCell(
                              'Area ($_areaUnitSuffix)'),
                          _buildCompensationTableHeaderCell('Status'),
                          _buildCompensationTableHeaderCell('Agent'),
                          _buildCompensationTableHeaderCell('Earnings (₹)'),
                          _buildCompensationTableHeaderCell('Sale date',
                              isLast: true),
                        ],
                      ),
                      // Data rows
                      ...plots.asMap().entries.map((entry) {
                        final index = entry.key;
                        final plot = entry.value as Map<String, dynamic>;
                        final plotNumber =
                            plot['plot_number'] as String? ?? '-';
                        final area = (plot['area'] as num?)?.toDouble() ?? 0.0;
                        final status =
                            (plot['status'] as String? ?? 'available')
                                .toLowerCase();
                        final isSold = status == 'sold';
                        final isPending =
                            status == 'pending' || status == 'reserved';
                        final showSaleDetails = isSold || isPending;
                        final statusLabel = isSold
                            ? 'Sold'
                            : (isPending ? 'Pending' : 'Available');
                        final agentName = plot['agent_name'] as String? ?? '';
                        final saleDate =
                            (plot['sale_date'] as String? ?? '').toString();

                        // Calculate agent's compensation for THIS SPECIFIC PLOT
                        double plotCompensation = 0.0;
                        if (agentName.isNotEmpty && isSold && _agents != null) {
                          final agent = _agents!.firstWhere(
                            (a) =>
                                (a['name'] as String? ?? '').toLowerCase() ==
                                agentName.toLowerCase(),
                            orElse: () => <String, dynamic>{},
                          );
                          if (agent.isNotEmpty) {
                            final compensationType =
                                agent['compensation_type'] as String? ?? '';

                            if (compensationType == 'Fixed Fee') {
                              plotCompensation =
                                  agent['fixed_fee'] as double? ?? 0.0;
                            } else if (compensationType == 'Monthly Fee') {
                              final monthlyFee =
                                  agent['monthly_fee'] as double? ?? 0.0;
                              final months = agent['months'] as int? ?? 0;
                              plotCompensation = monthlyFee * months;
                            } else if (compensationType == 'Per Sqft Fee' ||
                                compensationType == 'Per Sqm Fee') {
                              final perSqftFee =
                                  agent['per_sqft_fee'] as double? ?? 0.0;
                              // per_sqft_fee is stored in sqft internally
                              if (_isSqm) {
                                // Convert fee from sqft to sqm
                                final perSqmFee =
                                    AreaUnitUtils.rateFromSqftToDisplay(
                                        perSqftFee, true);
                                final areaSqm =
                                    AreaUnitUtils.areaFromSqftToDisplay(
                                        area, true);
                                plotCompensation = perSqmFee * areaSqm;
                              } else {
                                plotCompensation = perSqftFee * area;
                              }
                            } else if (compensationType == 'Percentage Bonus') {
                              final percentage =
                                  agent['percentage'] as double? ?? 0.0;
                              final earningType =
                                  agent['earning_type'] as String? ?? '';
                              final salePrice =
                                  ((plot['sale_price'] as num?)?.toDouble() ??
                                      0.0);
                              final saleValue = salePrice * area;

                              // Check for "Selling Price Per Plot" - calculate percentage from sale value
                              final isSellingPriceBased =
                                  earningType == 'Selling Price Per Plot' ||
                                      earningType ==
                                          '% of Selling Price per Plot' ||
                                      (earningType
                                              .toLowerCase()
                                              .contains('selling price') &&
                                          earningType
                                              .toLowerCase()
                                              .contains('plot'));

                              // Check if it's Lump Sum / Total Project Profit
                              final isLumpSum = earningType == 'Lump Sum' ||
                                  earningType == '% of Total Project Profit' ||
                                  (earningType
                                          .toLowerCase()
                                          .contains('total project profit') ||
                                      earningType
                                          .toLowerCase()
                                          .contains('lump'));

                              if (isSellingPriceBased) {
                                // Apply percentage to this plot's sale value
                                plotCompensation =
                                    (saleValue * percentage) / 100;
                              } else if (isLumpSum) {
                                // For "% of Total Project Profit", calculate total agent compensation
                                // then distribute proportionally across agent's sold plots
                                final totalGrossProfit =
                                    _calculateTotalGrossProfit();
                                final totalAgentCompensation =
                                    (totalGrossProfit * percentage) / 100;

                                // Calculate total sale value for all plots sold by this agent
                                double totalAgentSaleValue = 0.0;
                                if (_siteLayouts.isNotEmpty &&
                                    agentName.isNotEmpty) {
                                  for (var layout in _siteLayouts) {
                                    final layoutPlots =
                                        layout['plots'] as List<dynamic>? ?? [];
                                    for (var layoutPlot in layoutPlots) {
                                      final plotStatus =
                                          (layoutPlot['status'] as String? ??
                                                  '')
                                              .toLowerCase();
                                      final plotAgentName =
                                          (layoutPlot['agent_name']
                                                      as String? ??
                                                  layoutPlot['agent']
                                                      as String? ??
                                                  '')
                                              .trim();

                                      if (plotStatus == 'sold' &&
                                          plotAgentName == agentName.trim()) {
                                        final plotSalePrice =
                                            ((layoutPlot['sale_price'] as num?)
                                                    ?.toDouble() ??
                                                0.0);
                                        final plotArea =
                                            ((layoutPlot['area'] as num?)
                                                    ?.toDouble() ??
                                                0.0);
                                        totalAgentSaleValue +=
                                            plotSalePrice * plotArea;
                                      }
                                    }
                                  }
                                }

                                // Distribute compensation proportionally based on this plot's sale value
                                if (totalAgentSaleValue > 0) {
                                  plotCompensation =
                                      (totalAgentCompensation * saleValue) /
                                          totalAgentSaleValue;
                                } else {
                                  plotCompensation = 0.0;
                                }
                              } else {
                                // Calculate profit for this specific plot
                                final allInCost =
                                    _dashboardData!['allInCost'] as double? ??
                                        0.0;
                                final plotCost = area * allInCost;
                                final plotProfit = saleValue - plotCost;

                                // Apply percentage to this plot's profit
                                plotCompensation =
                                    (plotProfit * percentage) / 100;
                              }
                            }
                          }
                        }

                        final isLastRow = index == plots.length - 1;
                        final displaySaleDate =
                            showSaleDetails && saleDate.isNotEmpty
                                ? saleDate
                                : '-';

                        return TableRow(
                          children: [
                            _buildCompensationTableDataCell('${index + 1}',
                                isFirst: true, isLastRow: isLastRow),
                            _buildCompensationTableDataCell(plotNumber,
                                isFirst: false, isLastRow: isLastRow),
                            _buildCompensationAreaCell(
                                AreaUnitUtils.areaFromSqftToDisplay(
                                    area, _isSqm),
                                isLastRow),
                            _buildCompensationStatusCell(
                                statusLabel, isSold, isPending, isLastRow),
                            _buildCompensationAgentCell(
                                agentName, showSaleDetails, isLastRow),
                            _buildCompensationTableDataCell(
                              plotCompensation > 0
                                  ? _formatCurrency(plotCompensation)
                                  : '-',
                              isFirst: false,
                              isLastRow: isLastRow,
                            ),
                            _buildCompensationTableDataCell(
                              displaySaleDate,
                              isFirst: false,
                              isLastRow: isLastRow,
                              isLast: true,
                            ),
                          ],
                        );
                      }).toList(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompensationTableHeaderCell(String text,
      {bool isFirst = false, bool isLast = false}) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Color(0xFFE2E2E2),
      ),
      child: Center(
        child: Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Colors.black,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildCompensationTableDataCell(String text,
      {bool isFirst = false, bool isLastRow = false, bool isLast = false}) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
      ),
      child: Center(
        child: Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: text == '-' ? const Color(0xFF5D5D5D) : Colors.black,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildCompensationAreaCell(double area, bool isLastRow,
      {bool isLast = false}) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
      ),
      child: Center(
        child: RichText(
          text: TextSpan(
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5D5D5D),
            ),
            children: [
              TextSpan(text: '$_areaUnitSuffix '),
              TextSpan(
                text: area.toStringAsFixed(2),
                style: GoogleFonts.inter(
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompensationStatusCell(
      String text, bool isSold, bool isPending, bool isLastRow,
      {bool isLast = false}) {
    final statusColor = isSold
        ? const Color(0xFFFF0000)
        : (isPending ? const Color(0xFFFFA200) : const Color(0xFF50CD89));
    final statusBackgroundColor = isSold
        ? const Color(0xFFFFECEC)
        : (isPending ? const Color(0xFFFAE8C8) : const Color(0xFFE9F7EB));

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: const BoxDecoration(
        color: Colors.white,
      ),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: statusBackgroundColor,
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
              Container(
                width: 16,
                height: 16,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                text,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  fontStyle: FontStyle.normal,
                  color: Colors.black,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompensationAgentCell(
      String agentName, bool showSaleDetails, bool isLastRow,
      {bool isLast = false}) {
    if (!showSaleDetails || agentName.isEmpty) {
      return Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: const BoxDecoration(
          color: Colors.white,
        ),
        child: Center(
          child: Text(
            '-',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5D5D5D),
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final isDirectSale = agentName.toLowerCase() == 'direct sale';

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: const BoxDecoration(
        color: Colors.white,
      ),
      child: Center(
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFE3F2FD),
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 2,
                offset: const Offset(0, 0),
                spreadRadius: 0,
              ),
            ],
          ),
          child: Center(
            child: Text(
              agentName,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: isDirectSale ? const Color(0xFF0C8CE9) : Colors.black,
              ),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  void _showLayoutDeleteMenu(BuildContext context, int layoutIndex) {
    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final screenSize = MediaQuery.of(context).size;
    final buttonOffset = renderBox.localToGlobal(Offset.zero);
    final buttonSize = renderBox.size;

    OverlayEntry? backdropEntry;
    OverlayEntry? overlayEntry;

    void closeMenu() {
      overlayEntry?.remove();
      backdropEntry?.remove();
    }

    // Create backdrop
    backdropEntry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: GestureDetector(
          onTap: closeMenu,
          child: Container(color: Colors.transparent),
        ),
      ),
    );

    // Calculate menu position (below the button, aligned to right)
    const double menuWidth = 150.0;
    const double menuHeight =
        56.0; // 10px padding + 36px button height + 10px padding
    final double leftPosition = buttonOffset.dx + buttonSize.width - menuWidth;
    final double topPosition = buttonOffset.dy + buttonSize.height + 4;

    // Create menu
    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: leftPosition,
        top: topPosition,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: menuWidth,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 2,
                  offset: const Offset(0, 0),
                  spreadRadius: 0,
                ),
              ],
            ),
            child: GestureDetector(
              onTap: () async {
                // Delete the layout from database
                if (_siteLayouts.isNotEmpty &&
                    layoutIndex < _siteLayouts.length) {
                  final layout = _siteLayouts[layoutIndex];
                  final layoutId = layout['id'] as String?;

                  if (layoutId != null && widget.projectId != null) {
                    try {
                      // Delete all plots in this layout first (cascade delete should handle this, but being explicit)
                      await _supabase
                          .from('plots')
                          .delete()
                          .eq('layout_id', layoutId);

                      // Delete the layout
                      await _supabase
                          .from('layouts')
                          .delete()
                          .eq('id', layoutId)
                          .eq('project_id', widget.projectId!);

                      // Reload site data to refresh the UI
                      await _loadSiteData();
                    } catch (e) {
                      print('Error deleting layout: $e');
                    }
                  }
                }
                closeMenu();
              },
              child: Container(
                height: 36,
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
                      spreadRadius: 0,
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    'Delete layout',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.red,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(backdropEntry);
    overlay.insert(overlayEntry);
  }
}

/// Draws the chart axes to match the Figma designs for
/// positive-only and mixed positive/negative value ranges.
class _AxisPainter extends CustomPainter {
  final double zeroX;
  final bool hasNegative;
  final bool hasPositive;
  final double axisLineHeight;
  final List<double> tickXs;

  /// Y position where the vertical axis ends below the last bar row.
  final double verticalAxisEndY;

  const _AxisPainter({
    required this.zeroX,
    required this.hasNegative,
    required this.hasPositive,
    required this.axisLineHeight,
    required this.tickXs,
    required this.verticalAxisEndY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }

    const axisLineWidth = 1.5;
    final verticalPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = axisLineWidth;

    final horizontalPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = axisLineWidth;

    final arrowPaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.5;

    final bottomY = size.height;
    final axisY = bottomY - (axisLineWidth / 2);
    const arrowSize = 8.0;

    // Vertical axis line from top to 30px below the last bar row.
    final verticalEndY = verticalAxisEndY.clamp(0.0, size.height);
    canvas.drawLine(
      Offset(zeroX, 0),
      Offset(zeroX, verticalEndY),
      verticalPaint,
    );

    // Upward arrow on vertical axis.
    canvas.drawLine(
      Offset(zeroX, 0),
      Offset(zeroX - arrowSize / 2, arrowSize),
      arrowPaint,
    );
    canvas.drawLine(
      Offset(zeroX, 0),
      Offset(zeroX + arrowSize / 2, arrowSize),
      arrowPaint,
    );

    // Horizontal axis line.
    final startX = hasNegative ? 0.0 : zeroX;
    // End the axis 50px after the last tick/axis value,
    // clamped so it never goes beyond the chart width.
    final lastTick =
        tickXs.isEmpty ? 0.0 : tickXs.last.clamp(0.0, size.width).toDouble();
    const extraAfterLastTick = 50.0;
    final desiredEndX = lastTick + extraAfterLastTick;
    final endX = desiredEndX.clamp(0.0, size.width).toDouble();

    canvas.drawLine(
      Offset(startX, axisY),
      Offset(endX, axisY),
      horizontalPaint,
    );

    // Right arrow (always present).
    canvas.drawLine(
      Offset(endX, axisY),
      Offset(endX - arrowSize, axisY - arrowSize / 2),
      arrowPaint,
    );
    canvas.drawLine(
      Offset(endX, axisY),
      Offset(endX - arrowSize, axisY + arrowSize / 2),
      arrowPaint,
    );

    // Small black tick at each vertical line / value position (1px × 4px).
    final tickPaint = Paint()..color = const Color(0xFF000000);
    const tickWidth = 1.0;
    const tickHeight = 4.0;
    for (final x in tickXs) {
      final clampedX = x.clamp(0.0, size.width).toDouble();
      final tickLeft = clampedX - (tickWidth / 2);
      final tickTop = axisY;
      canvas.drawRect(
        Rect.fromLTWH(tickLeft, tickTop, tickWidth, tickHeight),
        tickPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AxisPainter oldDelegate) {
    if (oldDelegate.zeroX != zeroX ||
        oldDelegate.hasNegative != hasNegative ||
        oldDelegate.hasPositive != hasPositive ||
        oldDelegate.axisLineHeight != axisLineHeight ||
        oldDelegate.verticalAxisEndY != verticalAxisEndY) {
      return true;
    }
    if (oldDelegate.tickXs.length != tickXs.length) return true;
    for (var i = 0; i < tickXs.length; i++) {
      if (oldDelegate.tickXs[i] != tickXs[i]) return true;
    }
    return false;
  }
}

class _VerticalGridPainter extends CustomPainter {
  final List<double> tickXs;
  final double plotHeight;

  const _VerticalGridPainter({
    required this.tickXs,
    required this.plotHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final paint = Paint()
      ..color = const Color(0xFFE0E0E0)
      ..strokeWidth = 1;

    final yMax = plotHeight.clamp(0.0, size.height).toDouble();

    for (final x in tickXs) {
      // Keep inside bounds to avoid half-pixel clipping.
      final clampedX = x.clamp(0.0, size.width).toDouble();
      canvas.drawLine(Offset(clampedX, 0), Offset(clampedX, yMax), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _VerticalGridPainter oldDelegate) {
    if (oldDelegate.plotHeight != plotHeight) return true;
    if (oldDelegate.tickXs.length != tickXs.length) return true;
    for (var i = 0; i < tickXs.length; i++) {
      if (oldDelegate.tickXs[i] != tickXs[i]) return true;
    }
    return false;
  }
}

class _ExpenseBreakdownItem {
  final String label;
  final Color color;
  final double amount;

  const _ExpenseBreakdownItem({
    required this.label,
    required this.color,
    required this.amount,
  });
}

/// Positions the axis label so its center is at [tickX], so the small black
/// tick sits in the middle of the value (second-picture style).
class _AxisLabelLayoutDelegate extends SingleChildLayoutDelegate {
  final double tickX;

  _AxisLabelLayoutDelegate({required this.tickX});

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return Offset(tickX - (childSize.width / 2), 0);
  }

  @override
  bool shouldRelayout(covariant _AxisLabelLayoutDelegate oldDelegate) {
    return oldDelegate.tickX != tickX;
  }
}

class _AxisScale {
  final double axisMin;
  final double axisMax;
  final double step;
  final double unit;
  final String suffix;

  const _AxisScale({
    required this.axisMin,
    required this.axisMax,
    required this.step,
    required this.unit,
    required this.suffix,
  });
}

class _DonutPainter extends CustomPainter {
  final List<_ExpenseBreakdownItem> items;
  final double totalExpenses;

  _DonutPainter({
    required this.items,
    required this.totalExpenses,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = 131.0;
    final innerRadius = 100.0;

    // Step 1: Draw white outer circle background (#FFFFFF)
    final outerPaint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, outerRadius, outerPaint);

    // Step 2: Draw category segments as arc rings with white separators
    var currentAngle = -math.pi / 2; // Start at top center

    final separatorAngle = (2.0 / (outerRadius + innerRadius) / 2) *
        2; // 2px separator width converted to angle

    for (final item in items) {
      if (item.amount <= 0) continue;

      final percentage = (item.amount / totalExpenses);
      final sweepAngle = percentage * 2 * math.pi - separatorAngle;

      // Draw arc for this category
      final arcPaint = Paint()
        ..color = item.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 31; // Ring thickness (outerRadius - innerRadius = 31)

      canvas.drawArc(
        Rect.fromCircle(
            center: center, radius: (outerRadius + innerRadius) / 2),
        currentAngle,
        sweepAngle,
        false,
        arcPaint,
      );

      currentAngle += sweepAngle + separatorAngle;
    }

    // Step 3: Inset shadow on the inner edge of outer circle
    final insetShadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.0);

    final outerClipPath = Path()
      ..addOval(Rect.fromCircle(center: center, radius: outerRadius));
    canvas.save();
    canvas.clipPath(outerClipPath);
    canvas.translate(0, 2.5); // move shadow down by ~2% of radius
    final arcRect = Rect.fromCircle(
        center: center,
        radius: outerRadius + 1); // Reduce radius to overlap arc
    const arcSweep = math.pi * 0.95; // longer arc, centered at top
    final arcStart = -math.pi / 2 - (arcSweep / 2);
    const segmentCount = 12;
    final segmentSweep = arcSweep / segmentCount;
    for (var i = 0; i < segmentCount; i++) {
      final t = (i + 0.5) / segmentCount;
      final fade = 1.0 - (2 * (t - 0.5)).abs();
      final segmentPaint = Paint()
        ..color = Colors.black.withOpacity(0.35 * fade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = insetShadowPaint.strokeWidth
        ..maskFilter = insetShadowPaint.maskFilter;
      canvas.drawArc(
        arcRect,
        arcStart + (i * segmentSweep),
        segmentSweep,
        false,
        segmentPaint,
      );
    }
    canvas.restore();

    // Step 4: Drop shadow for inner circle
    final dropShadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    canvas.drawCircle(
      Offset(center.dx, center.dy + 4),
      innerRadius,
      dropShadowPaint,
    );

    // Step 5: Draw white inner circle
    final innerCirclePaint = Paint()
      ..color = const Color(0xFFF8F9FA)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
      center,
      innerRadius,
      innerCirclePaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    if (oldDelegate is! _DonutPainter) return true;
    return oldDelegate.totalExpenses != totalExpenses ||
        oldDelegate.items.length != items.length;
  }
}

class _ChartPainter extends CustomPainter {
  final int maxY;
  final int xInterval;
  final int todaysSales;
  final String timeFilter;
  final List<int> salesData;
  final List<int> labelIndices;

  _ChartPainter({
    required this.maxY,
    required this.xInterval,
    required this.todaysSales,
    required this.timeFilter,
    required this.salesData,
    required this.labelIndices,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE0E0E0)
      ..strokeWidth = 1;

    final thickPaint = Paint()
      ..color = const Color(0xFF5C5C5C)
      ..strokeWidth = 2;

    // Matching waterfall chart spacing: adjusted to avoid overflow in the chart container
    const gridSpacing = 50.0;

    // Draw horizontal grid lines
    for (int i = 0; i <= 5; i++) {
      final y = size.height - (i * gridSpacing);

      if (i == 0) {
        // Bottom line (X-axis)
        canvas.drawLine(Offset(0, y), Offset(size.width, y), thickPaint);
      } else if (i == 5) {
        // Top line
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      } else {
        // Grid lines
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }

    // Draw vertical Y-axis (extended 60px above grid)
    final yAxisTop = size.height - (5 * gridSpacing) - 60;
    canvas.drawLine(Offset(0, yAxisTop), Offset(0, size.height), thickPaint);

    // Draw arrow at top of Y-axis
    final arrowPath = Path()
      ..moveTo(0, yAxisTop)
      ..lineTo(-4, yAxisTop + 8)
      ..lineTo(4, yAxisTop + 8)
      ..close();

    final arrowPaint = Paint()
      ..color = const Color(0xFF5C5C5C)
      ..style = PaintingStyle.fill;

    canvas.drawPath(arrowPath, arrowPaint);

    print(
        'DEBUG ChartPainter: todaysSales = $todaysSales, maxY = $maxY, timeFilter = $timeFilter, salesData = $salesData');

    // Draw sales data based on time filter
    if (timeFilter == '1D') {
      // For 1D: draw horizontal dashed line at today's sales value
      if (todaysSales > 0) {
        print('DEBUG ChartPainter: Drawing 1D line for $todaysSales sales');
        // Calculate Y position for the sales value
        final valueRatio = todaysSales / maxY;
        final yPosition = size.height - (valueRatio * (5 * gridSpacing));

        print(
            'DEBUG ChartPainter: yPosition = $yPosition, size.height = ${size.height}');

        // Draw dashed horizontal line
        final dashedPaint = Paint()
          ..color = const Color(0xFF0C8CE9)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;

        const dashWidth = 5.0;
        const dashSpace = 3.0;
        double startX = 0;

        while (startX < size.width) {
          canvas.drawLine(
            Offset(startX, yPosition),
            Offset(startX + dashWidth, yPosition),
            dashedPaint,
          );
          startX += dashWidth + dashSpace;
        }

        // Draw diamond/dot marker at consistent position (Today position)
        const xOffset = 40.0;
        final markerX = xOffset;
        final markerPaint = Paint()
          ..color = const Color(0xFF0C8CE9)
          ..style = PaintingStyle.fill;

        // Draw diamond shape (rotated square)
        final markerSize = 6.0;
        final markerPath = Path()
          ..moveTo(markerX, yPosition - markerSize) // top
          ..lineTo(markerX + markerSize, yPosition) // right
          ..lineTo(markerX, yPosition + markerSize) // bottom
          ..lineTo(markerX - markerSize, yPosition) // left
          ..close();

        canvas.drawPath(markerPath, markerPaint);
      }
    } else {
      // For 7D and 28D: draw lines connecting data points
      if (salesData.isNotEmpty) {
        print(
            'DEBUG ChartPainter: Drawing ${timeFilter} lines with ${salesData.length} data points');

        final dashedPaint = Paint()
          ..color = const Color(0xFF0C8CE9)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;

        final markerPaint = Paint()
          ..color = const Color(0xFF0C8CE9)
          ..style = PaintingStyle.fill;

        // Calculate X positions for each data point
        // First data point starts at a smaller offset for left alignment
        final xOffset = timeFilter == '28D' ? 14.0 : 18.0;
        final pointShift = timeFilter == '28D' ? 11.0 : 0.0;
        final rightInset = timeFilter == '28D' ? 48.0 : 40.0;
        final availableWidth = size.width - xOffset - rightInset;
        final xSpacing =
            availableWidth / (salesData.length > 1 ? salesData.length - 1 : 1);
        print(
            'DEBUG ChartPainter: xOffset=$xOffset, size.width=${size.width}, availableWidth=$availableWidth, xSpacing=$xSpacing');
        List<Offset> dataPoints = [];

        for (int i = 0; i < salesData.length; i++) {
          final sales = salesData[i];
          final xPos = xOffset + (i * xSpacing) + pointShift;
          final yRatio = (sales / maxY).clamp(0.0, 1.0);
          final yPos = size.height - (yRatio * (5 * gridSpacing));

          dataPoints.add(Offset(xPos, yPos));
          print('DEBUG: Point $i: sales=$sales, x=$xPos, y=$yPos');
        }

        // Draw dashed lines connecting points
        const dashWidth = 5.0;
        const dashSpace = 3.0;

        for (int i = 0; i < dataPoints.length - 1; i++) {
          final start = dataPoints[i];
          final end = dataPoints[i + 1];

          // Draw dashed line between points
          double len = (end - start).distance;
          if (len > 0) {
            double segments = len / (dashWidth + dashSpace);

            for (int j = 0; j < segments.ceil(); j++) {
              double t0 = (j * (dashWidth + dashSpace)) / len;
              double t1 = ((j * (dashWidth + dashSpace)) + dashWidth) / len;

              t0 = t0.clamp(0.0, 1.0);
              t1 = t1.clamp(0.0, 1.0);

              final p0 = Offset(
                start.dx + (end.dx - start.dx) * t0,
                start.dy + (end.dy - start.dy) * t0,
              );
              final p1 = Offset(
                start.dx + (end.dx - start.dx) * t1,
                start.dy + (end.dy - start.dy) * t1,
              );

              canvas.drawLine(p0, p1, dashedPaint);
            }
          }
        }

        // Draw markers and value labels at each data point (skip zero sales unless labeled)
        for (int i = 0; i < dataPoints.length; i++) {
          final point = dataPoints[i];
          final sales = salesData[i];
          final isLabelIndex = labelIndices.contains(i);
          final shouldShowMarker = sales > 0 ||
              ((timeFilter == '28D' || timeFilter == '7D') && isLabelIndex);

          if (!shouldShowMarker) {
            continue;
          }

          // Draw diamond marker
          final markerSize = 6.0;
          final markerPath = Path()
            ..moveTo(point.dx, point.dy - markerSize) // top
            ..lineTo(point.dx + markerSize, point.dy) // right
            ..lineTo(point.dx, point.dy + markerSize) // bottom
            ..lineTo(point.dx - markerSize, point.dy) // left
            ..close();

          canvas.drawPath(markerPath, markerPaint);

          // Draw value label above the marker
          final textPainter = TextPainter(
            text: TextSpan(
              text: sales.toString(),
              style: const TextStyle(
                color: Color(0xFF5C5C5C),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            textDirection: TextDirection.ltr,
          );
          textPainter.layout();
          textPainter.paint(
            canvas,
            Offset(point.dx - textPainter.width / 2,
                point.dy - textPainter.height - 12),
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter oldDelegate) {
    return oldDelegate.maxY != maxY ||
        oldDelegate.xInterval != xInterval ||
        oldDelegate.todaysSales != todaysSales ||
        oldDelegate.timeFilter != timeFilter ||
        oldDelegate.salesData != salesData ||
        oldDelegate.labelIndices != labelIndices;
  }
}
