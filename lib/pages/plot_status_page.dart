import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:ui';
import '../widgets/decimal_input_field.dart';
import '../services/layout_storage_service.dart';
import '../services/project_storage_service.dart';
import '../services/area_unit_service.dart';
import '../utils/area_unit_utils.dart';
import '../widgets/area_unit_selector.dart';
import '../widgets/app_scale_metrics.dart';
import '../widgets/project_save_status.dart';

// TextInputFormatter for Indian numbering system (commas every 2 digits)
class IndianNumberFormatter extends TextInputFormatter {
  final int? maxIntegerDigits;

  IndianNumberFormatter({this.maxIntegerDigits});

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) {
      return newValue;
    }

    // Remove all non-digit characters except decimal point
    String cleaned = newValue.text.replaceAll(RegExp(r'[^\d.]'), '');

    // If cleaning removed all content (user typed only letters), reject the input
    if (cleaned.isEmpty || (cleaned == '.' && oldValue.text.isNotEmpty)) {
      return oldValue;
    }

    // Only allow one decimal point
    final parts = cleaned.split('.');
    if (parts.length > 2) {
      cleaned = '${parts[0]}.${parts.sublist(1).join()}';
    }

    // Limit integer part length if maxIntegerDigits is specified
    if (maxIntegerDigits != null) {
      final integerPart = parts[0];
      if (integerPart.length > maxIntegerDigits!) {
        return oldValue; // Reject the input if it exceeds max digits
      }
    }

    // Limit decimal places to 2
    if (parts.length == 2 && parts[1].length > 2) {
      cleaned = '${parts[0]}.${parts[1].substring(0, 2)}';
    }

    // Split into integer and decimal parts
    String integerPart;
    String decimalPart = '';

    if (cleaned.contains('.')) {
      final splitParts = cleaned.split('.');
      integerPart = splitParts[0].isEmpty
          ? '0'
          : splitParts[0]; // Default to '0' if empty
      decimalPart = splitParts.length > 1 ? splitParts[1] : '';
    } else {
      integerPart = cleaned.isEmpty ? '0' : cleaned; // Default to '0' if empty
    }

    // Format integer part with Indian numbering
    // Numbers < 10000: no commas (e.g., 1000, 9999)
    // Numbers >= 10000: Indian numbering (e.g., 10,000, 1,00,000)
    String formattedInteger = '';

    if (integerPart.isEmpty || integerPart == '0') {
      formattedInteger = integerPart.isEmpty ? '0' : integerPart;
    } else if (integerPart.length <= 4) {
      // No commas for numbers less than 10000
      formattedInteger = integerPart;
    } else {
      // Indian numbering for numbers >= 10000
      // First 3 digits from right have no comma, then every 2 digits get a comma
      final length = integerPart.length;
      final lastThreeDigits = integerPart.substring(length - 3);
      final remainingDigits = integerPart.substring(0, length - 3);

      // Format remaining digits with Indian numbering (comma every 2 digits)
      String formattedRemaining = '';
      int count = 0;
      for (int i = remainingDigits.length - 1; i >= 0; i--) {
        if (count > 0 && count % 2 == 0 && i >= 0) {
          formattedRemaining = ',' + formattedRemaining;
        }
        formattedRemaining = remainingDigits[i] + formattedRemaining;
        count++;
      }

      // Combine: remaining digits (with commas) + last 3 digits (no comma)
      formattedInteger = formattedRemaining.isEmpty
          ? lastThreeDigits
          : '$formattedRemaining,$lastThreeDigits';
    }

    // Combine formatted integer with decimal part
    // Keep the decimal point even if decimalPart is empty (user might still be typing)
    String formattedText = cleaned.contains('.')
        ? '$formattedInteger.${decimalPart}'
        : formattedInteger;

    // Calculate cursor position
    int cursorPosition = formattedText.length;
    int unformattedLength = newValue.selection.baseOffset;
    int commaCount = 0;
    int charCount = 0;

    for (int i = 0;
        i < formattedText.length && charCount < unformattedLength;
        i++) {
      if (formattedText[i] != ',') {
        charCount++;
      } else {
        commaCount++;
      }
    }

    cursorPosition = unformattedLength + commaCount;
    cursorPosition = cursorPosition.clamp(0, formattedText.length);

    return TextEditingValue(
      text: formattedText,
      selection: TextSelection.collapsed(offset: cursorPosition),
    );
  }
}

enum PlotStatus {
  available,
  sold,
  reserved,
  blocked,
}

enum PlotStatusContentTab {
  site,
  amenityArea,
}

class PlotStatusPage extends StatefulWidget {
  final List<Map<String, dynamic>>? layouts;
  final List<Map<String, dynamic>>? agents;
  final String? projectId;
  final Function(bool)? onPlotStatusErrorsChanged;
  final ValueChanged<bool>? onLoadingStateChanged;
  final Function(ProjectSaveStatusType)? onSaveStatusChanged;

  const PlotStatusPage({
    super.key,
    this.layouts,
    this.agents,
    this.projectId,
    this.onPlotStatusErrorsChanged,
    this.onLoadingStateChanged,
    this.onSaveStatusChanged,
  });

  @override
  State<PlotStatusPage> createState() => _PlotStatusPageState();
}

class _PlotStatusPageState extends State<PlotStatusPage> {
  void _notifyLoadingState(bool isLoading) {
    widget.onLoadingStateChanged?.call(isLoading);
  }

  final SupabaseClient _supabase = Supabase.instance.client;
  final ScrollController _scrollController = ScrollController();
  String _selectedLayout = 'All Layouts';
  String _selectedStatus = 'All Status';
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  // Loading state
  bool _isLoading = true;
  bool _hasUnsavedChanges = false;
  bool _isAutoRetryInProgress = false;
  StreamSubscription<html.Event>? _onlineSubscription;

  // Plot data structure
  List<Map<String, dynamic>> _allPlots = [];

  // Layouts with plots data - loaded from Site section
  List<Map<String, dynamic>> _layouts = [];
  List<Map<String, dynamic>> _amenityAreas = [];

  // Controllers for editable fields
  final Map<String, TextEditingController> _salePriceControllers = {};
  final Map<String, TextEditingController> _buyerNameControllers = {};
  final Map<String, TextEditingController> _buyerContactControllers = {};
  final Map<String, TextEditingController> _saleDateControllers = {};
  final Map<String, TextEditingController> _paymentAmountControllers = {};
  final Map<String, TextEditingController> _paymentTextControllers = {};

  // FocusNodes for editable fields
  final Map<String, FocusNode> _salePriceFocusNodes = {};
  final Map<String, FocusNode> _buyerNameFocusNodes = {};
  final Map<String, FocusNode> _buyerContactFocusNodes = {};
  final Map<String, FocusNode> _saleDateFocusNodes = {};
  final Map<String, FocusNode> _paymentAmountFocusNodes = {};
  final Map<String, FocusNode> _paymentTextFocusNodes = {};

  // Stored agents list from storage
  List<Map<String, dynamic>> _storedAgents = [];

  // Scroll controllers for tables
  final ScrollController _plotStatusTableScrollController = ScrollController();
  final Map<int, ScrollController> _layoutTableScrollControllers =
      {}; // Key: layoutIndex
  final ScrollController _amenityAreaTableScrollController = ScrollController();
  final ScrollController _editDialogScrollController = ScrollController();
  final GlobalKey _paymentMethodFieldKey = GlobalKey();
  final GlobalKey _agentFieldKey = GlobalKey();
  final GlobalKey _filterButtonKey = GlobalKey();

  // Edit dialog state
  int? _editingLayoutIndex;
  int? _editingPlotIndex;
  PlotStatus? _editingStatus;
  bool _isStatusDropdownOpen = false;
  final GlobalKey _statusDropdownKey = GlobalKey();
  final GlobalKey _statusDropdownMenuKey = GlobalKey();
  bool _isPaymentMethodDropdownOpen = false;
  bool _isAgentDropdownOpen = false;
  int _currentPaymentIndex = 0;
  int? _editingAmenityAreaIndex;
  int? _amenityEditTempLayoutIndex;

  // Layout expand/collapse and zoom state
  Set<int> _collapsedLayouts = {}; // Set of collapsed layout indices
  bool _isAmenityAreaCollapsed = false;
  PlotStatusContentTab _activeContentTab = PlotStatusContentTab.site;
  double _tableZoomLevel =
      1.0; // Table zoom level (1.0 = 100%, 0.5 = 50%, 1.2 = 120%, etc.)
  String _areaUnit = AreaUnitService.defaultUnit;
  bool get _isSqm => AreaUnitUtils.isSqm(_areaUnit);
  String get _areaUnitSuffix => AreaUnitUtils.unitSuffix(_isSqm);
  bool? _supportsBuyerContactNumberColumn;

  double _stepTableZoomLevel(double current, {required bool increase}) {
    final currentStep = (current * 10).round();
    final nextStep = (currentStep + (increase ? 1 : -1)).clamp(5, 12);
    return nextStep / 10.0;
  }

  bool get _isEditingAmenityArea =>
      _editingAmenityAreaIndex != null && _amenityEditTempLayoutIndex != null;

  Future<bool> _canSaveBuyerContactNumber() async {
    // Cache only successful detection. If this was false earlier and DB
    // schema has now been updated, re-check and enable saving automatically.
    if (_supportsBuyerContactNumberColumn == true) {
      return true;
    }
    try {
      await _supabase.from('plots').select('buyer_contact_number').limit(1);
      _supportsBuyerContactNumberColumn = true;
    } catch (_) {
      _supportsBuyerContactNumberColumn = false;
    }
    return _supportsBuyerContactNumberColumn!;
  }

  bool get _hasAmenityAreaData {
    if (_amenityAreas.isEmpty) return false;
    for (final area in _amenityAreas) {
      final name = (area['name'] ?? '').toString().trim();
      final areaValue = _parseMoneyLikeValue(area['area']);
      if (name.isNotEmpty || areaValue > 0) {
        return true;
      }
    }
    return false;
  }

  String _formatWithFixedDecimals(dynamic value, int decimals) {
    if (value == null) return '0.${'0' * decimals}';
    if (value is String) {
      final parsed = double.tryParse(value);
      return parsed != null
          ? parsed.toStringAsFixed(decimals)
          : '0.${'0' * decimals}';
    }
    if (value is num) {
      return value.toStringAsFixed(decimals);
    }
    return '0.${'0' * decimals}';
  }

  // Helper function to format date from database (YYYY-MM-DD) to UI format (DD/MM/YYYY)
  String _formatDateFromDatabase(dynamic value) {
    if (value == null) return '';
    final dateStr = value.toString().trim();
    if (dateStr.isEmpty) return '';

    // Try to parse ISO format (YYYY-MM-DD)
    final isoPattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
    final match = isoPattern.firstMatch(dateStr);
    if (match != null) {
      final year = match.group(1) ?? '';
      final month = match.group(2) ?? '';
      final day = match.group(3) ?? '';
      return '$day/$month/$year';
    }

    // If already in DD/MM/YYYY format, return as is
    return dateStr;
  }

  String? _formatDateForDatabase(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final ddmmyyyy = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$');
    final match = ddmmyyyy.firstMatch(trimmed);
    if (match != null) {
      final day = int.tryParse(match.group(1) ?? '');
      final month = int.tryParse(match.group(2) ?? '');
      final year = int.tryParse(match.group(3) ?? '');
      if (day != null &&
          month != null &&
          year != null &&
          day >= 1 &&
          day <= 31 &&
          month >= 1 &&
          month <= 12) {
        return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
      }
    }
    final iso = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (iso.hasMatch(trimmed)) return trimmed;
    return null;
  }

  PlotStatus _parsePlotStatus(dynamic statusData) {
    if (statusData is PlotStatus) return statusData;
    if (statusData is String) {
      final normalized = statusData.trim().toLowerCase();
      switch (normalized) {
        case 'sold':
          return PlotStatus.sold;
        case 'reserved':
        case 'pending':
          return PlotStatus.reserved;
        case 'blocked':
          return PlotStatus.blocked;
        case 'available':
        default:
          return PlotStatus.available;
      }
    }
    return PlotStatus.available;
  }

  String _plotStatusToDatabaseValue(PlotStatus status) {
    // DB constraint uses "reserved" for pending-like states.
    if (status == PlotStatus.reserved || status == PlotStatus.blocked) {
      return 'reserved';
    }
    return status.name; // available, sold
  }

  bool _isGlobalTapInsideKey(GlobalKey key, Offset globalPosition) {
    final keyContext = key.currentContext;
    if (keyContext == null) return false;
    final renderObject = keyContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final bounds = topLeft & renderObject.size;
    return bounds.contains(globalPosition);
  }

  void _handleEditDialogTapDown(TapDownDetails details) {
    final tapPosition = details.globalPosition;
    bool didUpdate = false;

    if (_isStatusDropdownOpen &&
        !_isGlobalTapInsideKey(_statusDropdownKey, tapPosition) &&
        !_isGlobalTapInsideKey(_statusDropdownMenuKey, tapPosition)) {
      _isStatusDropdownOpen = false;
      didUpdate = true;
    }

    if (_isPaymentMethodDropdownOpen &&
        !_isGlobalTapInsideKey(_paymentMethodFieldKey, tapPosition)) {
      _isPaymentMethodDropdownOpen = false;
      didUpdate = true;
    }

    if (didUpdate) {
      setState(() {});
    }
  }

  void _syncEditingPlotToAllPlots() {
    if (_editingLayoutIndex == null || _editingPlotIndex == null) return;
    print(
        '🔄 SYNC: Starting sync for layout=$_editingLayoutIndex, plot=$_editingPlotIndex');
    final layout = _layouts[_editingLayoutIndex!];
    final plots = layout['plots'] as List<dynamic>? ?? [];
    if (_editingPlotIndex! >= plots.length) return;
    final plot = plots[_editingPlotIndex!] as Map<String, dynamic>;
    final layoutName = layout['name'] as String? ?? '';
    final plotNumber = plot['plotNumber'] as String? ?? '';
    final status = _parsePlotStatus(plot['status']);
    print(
        '🔄 SYNC: Plot data - layout=$layoutName, plot=$plotNumber, status=$status');

    for (var plotData in _allPlots) {
      final matchesByIndex = plotData['layoutIndex'] == _editingLayoutIndex &&
          plotData['plotIndex'] == _editingPlotIndex;
      final matchesByName =
          (plotData['layout'] as String? ?? '') == layoutName &&
              (plotData['plotNumber'] as String? ?? '') == plotNumber;
      if (matchesByIndex || matchesByName) {
        print('🔄 SYNC: Found match, updating _allPlots entry');
        plotData['layout'] = layoutName;
        plotData['layoutIndex'] = _editingLayoutIndex;
        plotData['plotIndex'] = _editingPlotIndex;
        plotData['plotNumber'] = plotNumber;
        plotData['status'] = status;
        plotData['salePrice'] = plot['salePrice'] as String? ?? '';
        plotData['buyerName'] = plot['buyerName'] as String? ?? '';
        plotData['buyerContactNumber'] =
            plot['buyerContactNumber'] as String? ?? '';
        plotData['agent'] = plot['agent'] as String? ?? '';
        plotData['saleDate'] = plot['saleDate'] as String? ?? '';
        plotData['payments'] = (plot['payments'] as List<dynamic>?) ?? [];
        print(
            '🔄 SYNC: Updated with status=$status, price=${plotData['salePrice']}, buyer=${plotData['buyerName']}');
        break;
      }
    }
    print('🔄 SYNC: Completed');
  }

  void _rebuildAllPlotsFromLayouts() {
    print('🔨 REBUILD: Starting full rebuild from _layouts');
    final rebuilt = <Map<String, dynamic>>[];
    for (var layoutIndex = 0; layoutIndex < _layouts.length; layoutIndex++) {
      final layout = _layouts[layoutIndex];
      final layoutName = layout['name'] as String? ?? '';
      final plots = layout['plots'] as List<Map<String, dynamic>>? ?? [];
      for (var plotIndex = 0; plotIndex < plots.length; plotIndex++) {
        final plot = plots[plotIndex];
        rebuilt.add({
          'layout': layoutName,
          'layoutIndex': layoutIndex,
          'plotIndex': plotIndex,
          'plotNumber': plot['plotNumber'] as String? ?? '',
          'area': plot['area'] as String? ?? '0.00',
          'status': _parsePlotStatus(plot['status']),
          'purchaseRate': plot['purchaseRate'] as String? ?? '0.00',
          'totalPlotCost': plot['totalPlotCost'] as String? ?? '0.00',
          'salePrice': plot['salePrice'] as String? ?? '',
          'buyerName': plot['buyerName'] as String? ?? '',
          'buyerContactNumber': plot['buyerContactNumber'] as String? ?? '',
          'agent': plot['agent'] as String? ?? '',
          'saleDate': plot['saleDate'] as String? ?? '',
          'payments': (plot['payments'] as List<dynamic>?) ?? [],
        });
      }
    }

    _allPlots = rebuilt;
    print(
        '🔨 REBUILD: Completed. Total plots in _allPlots: ${_allPlots.length}');
  }

  void _removePaymentBlock(int paymentIndex) {
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;
    if (plot['payments'] == null) {
      plot['payments'] = [];
    }
    final payments = plot['payments'] as List<dynamic>;
    if (paymentIndex >= 0 && paymentIndex < payments.length) {
      payments.removeAt(paymentIndex);
      setState(() {
        _syncEditingPlotToAllPlots();
      });
      _saveLayoutsData();
    }
  }

  // Get available agents list
  List<String> get _availableAgents {
    final List<String> agents = ['Direct Sale']; // Direct Sale is always first

    // First, try to use agents from widget (if passed directly)
    List<Map<String, dynamic>> agentsToUse = widget.agents ?? [];

    // If not provided, use stored agents
    if (agentsToUse.isEmpty) {
      agentsToUse = _storedAgents;
    }

    // Add agents from the agent section
    for (var agent in agentsToUse) {
      final agentName = agent['name']?.toString().trim() ?? '';
      if (agentName.isNotEmpty && !agents.contains(agentName)) {
        agents.add(agentName);
      }
    }

    return agents;
  }

  @override
  void initState() {
    super.initState();
    _notifyLoadingState(true);
    _loadPlotDataAndNotify();
    _onlineSubscription = html.window.onOnline.listen((_) {
      _retrySaveOnReconnect();
    });
  }

  Future<void> _loadPlotDataAndNotify() async {
    if (mounted) setState(() => _isLoading = true);
    _notifyLoadingState(true);
    await _loadPlotData();
    if (mounted) setState(() => _isLoading = false);
    _notifyLoadingState(false);
    _notifyErrorState();
  }

  void _notifyErrorState() {
    final hasErrors = _hasValidationErrors();
    print(
        '🔴 PlotStatusPage._notifyErrorState: hasErrors=$hasErrors, callback=${widget.onPlotStatusErrorsChanged != null}');
    widget.onPlotStatusErrorsChanged?.call(hasErrors);
  }

  void _setSaveStatus(ProjectSaveStatusType status) {
    widget.onSaveStatusChanged?.call(status);
  }

  void _markUnsaved() {
    if (_hasUnsavedChanges) return;
    _hasUnsavedChanges = true;
    _setSaveStatus(ProjectSaveStatusType.notSaved);
  }

  Future<void> _retrySaveOnReconnect() async {
    if (_isAutoRetryInProgress) return;
    if (!_hasUnsavedChanges) return;

    _isAutoRetryInProgress = true;
    try {
      await _saveLayoutsData();
    } finally {
      _isAutoRetryInProgress = false;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    for (var controller in _salePriceControllers.values) {
      controller.dispose();
    }
    for (var controller in _buyerNameControllers.values) {
      controller.dispose();
    }
    for (var controller in _buyerContactControllers.values) {
      controller.dispose();
    }
    for (var controller in _saleDateControllers.values) {
      controller.dispose();
    }
    for (var focusNode in _salePriceFocusNodes.values) {
      focusNode.dispose();
    }
    for (var focusNode in _buyerNameFocusNodes.values) {
      focusNode.dispose();
    }
    for (var focusNode in _buyerContactFocusNodes.values) {
      focusNode.dispose();
    }
    for (var focusNode in _saleDateFocusNodes.values) {
      focusNode.dispose();
    }
    for (var focusNode in _paymentAmountFocusNodes.values) {
      focusNode.dispose();
    }
    for (var focusNode in _paymentTextFocusNodes.values) {
      focusNode.dispose();
    }
    for (var controller in _paymentAmountControllers.values) {
      controller.dispose();
    }
    for (var controller in _paymentTextControllers.values) {
      controller.dispose();
    }
    // Dispose scroll controllers
    _plotStatusTableScrollController.dispose();
    _amenityAreaTableScrollController.dispose();
    _editDialogScrollController.dispose();
    for (var controller in _layoutTableScrollControllers.values) {
      controller.dispose();
    }
    _layoutTableScrollControllers.clear();
    _onlineSubscription?.cancel();
    super.dispose();
  }

  FocusNode _createDialogFocusNode() {
    final node = FocusNode();
    node.addListener(() {
      if (mounted) setState(() {});
    });
    return node;
  }

  Map<String, dynamic> _createDefaultPaymentEntry([String method = '']) {
    return <String, dynamic>{
      'paymentMethod': method,
      'paymentAmount': '0',
      'chequeDate': '',
      'chequeNumber': '',
      'transferDate': '',
      'transactionId': '',
      'paymentDate': '',
      'upiTransactionId': '',
      'upiApp': '',
      'ddDate': '',
      'ddNumber': '',
      'otherPaymentDate': '',
      'otherPaymentMethod': '',
      'referenceNumber': '',
      'bankName': '',
    };
  }

  List<Map<String, dynamic>> _buildAmenityPaymentsFromText(String paymentText) {
    final methods = paymentText
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (methods.isEmpty) return <Map<String, dynamic>>[];
    return methods.map((method) => _createDefaultPaymentEntry(method)).toList();
  }

  void _disposeDialogControllersForLayoutPlot(int layoutIndex, int plotIndex) {
    final prefix = '${layoutIndex}_${plotIndex}_';
    final exactKeys = <String>[
      '${layoutIndex}_${plotIndex}_price',
      '${layoutIndex}_${plotIndex}_buyer',
      '${layoutIndex}_${plotIndex}_buyer_contact',
      '${layoutIndex}_${plotIndex}_date',
    ];

    for (final key in exactKeys) {
      _salePriceControllers.remove(key)?.dispose();
      _buyerNameControllers.remove(key)?.dispose();
      _buyerContactControllers.remove(key)?.dispose();
      _saleDateControllers.remove(key)?.dispose();

      _salePriceFocusNodes.remove(key)?.dispose();
      _buyerNameFocusNodes.remove(key)?.dispose();
      _buyerContactFocusNodes.remove(key)?.dispose();
      _saleDateFocusNodes.remove(key)?.dispose();
    }

    final paymentAmountKeys = _paymentAmountControllers.keys
        .where((k) => k.startsWith(prefix))
        .toList();
    for (final key in paymentAmountKeys) {
      _paymentAmountControllers.remove(key)?.dispose();
      _paymentAmountFocusNodes.remove(key)?.dispose();
    }

    final paymentTextKeys = _paymentTextControllers.keys
        .where((k) => k.startsWith(prefix))
        .toList();
    for (final key in paymentTextKeys) {
      _paymentTextControllers.remove(key)?.dispose();
      _paymentTextFocusNodes.remove(key)?.dispose();
    }
  }

  void _removeAmenityEditTempLayoutIfNeeded() {
    if (_amenityEditTempLayoutIndex != null &&
        _amenityEditTempLayoutIndex! >= 0 &&
        _amenityEditTempLayoutIndex! < _layouts.length) {
      _disposeDialogControllersForLayoutPlot(_amenityEditTempLayoutIndex!, 0);
      _layouts.removeAt(_amenityEditTempLayoutIndex!);
    }
    _amenityEditTempLayoutIndex = null;
    _editingAmenityAreaIndex = null;
  }

  void _closeCurrentEditDialog() {
    _removeAmenityEditTempLayoutIfNeeded();
    _editingLayoutIndex = null;
    _editingPlotIndex = null;
    _editingStatus = null;
    _isStatusDropdownOpen = false;
    _isPaymentMethodDropdownOpen = false;
    _isAgentDropdownOpen = false;
    _currentPaymentIndex = 0;
  }

  void _openSiteEditDialog(
    int layoutIndex,
    int plotIndex, {
    bool preserveAmenityTemp = false,
  }) {
    if (layoutIndex < 0 || layoutIndex >= _layouts.length) return;
    final plots = _layouts[layoutIndex]['plots'] as List<dynamic>? ?? const [];
    if (plotIndex < 0 || plotIndex >= plots.length) return;
    final plot = plots[plotIndex];
    if (plot is! Map<String, dynamic>) return;

    setState(() {
      if (!preserveAmenityTemp) {
        _removeAmenityEditTempLayoutIfNeeded();
      }
      _editingLayoutIndex = layoutIndex;
      _editingPlotIndex = plotIndex;
      _editingStatus = _parsePlotStatus(plot['status']);
      _isStatusDropdownOpen = false;
      _isPaymentMethodDropdownOpen = false;
      _isAgentDropdownOpen = false;
      _currentPaymentIndex = 0;
    });
  }

  void _openAmenityEditDialog(int amenityIndex) {
    if (amenityIndex < 0 || amenityIndex >= _amenityAreas.length) return;

    final amenityArea = _amenityAreas[amenityIndex];
    final name = (amenityArea['name'] ?? '').toString().trim();
    final areaText = (amenityArea['area'] ?? '0').toString();
    final status = _parsePlotStatus(amenityArea['status']);
    final salePrice = (amenityArea['salePrice'] ?? '').toString();
    final buyerName = (amenityArea['buyerName'] ?? '').toString();
    final agentName = (amenityArea['agent'] ?? '').toString();
    final saleDate = (amenityArea['saleDate'] ?? '').toString();
    final paymentText = (amenityArea['payment'] ?? '').toString();
    final payments = _buildAmenityPaymentsFromText(paymentText);
    final tempPayments = payments
        .map<Map<String, Object>>(
            (payment) => Map<String, Object>.from(payment))
        .toList();
    final tempLayout = <String, Object>{
      'name': 'Amenity Area',
      'plots': <Map<String, Object>>[
        <String, Object>{
          'plotNumber': name.isEmpty ? 'Amenity Area' : name,
          'area': areaText.isEmpty ? '0.000' : areaText,
          'status': status,
          'salePrice': salePrice,
          'buyerName': buyerName,
          'buyerContactNumber': '',
          'agent': agentName,
          'saleDate': saleDate,
          'payments': tempPayments,
        },
      ],
    };

    setState(() {
      _closeCurrentEditDialog();
      _layouts.add(tempLayout);
      _amenityEditTempLayoutIndex = _layouts.length - 1;
      _editingAmenityAreaIndex = amenityIndex;
    });

    _openSiteEditDialog(
      _amenityEditTempLayoutIndex!,
      0,
      preserveAmenityTemp: true,
    );
  }

  void _handleAmenityEditIconTap(
    Map<String, dynamic> area,
    int visibleIndex,
  ) {
    int originalIndex = -1;
    final sourceIndexRaw = area['_sourceIndex'];
    if (sourceIndexRaw is int) {
      originalIndex = sourceIndexRaw;
    } else if (sourceIndexRaw is num) {
      originalIndex = sourceIndexRaw.toInt();
    }
    if (originalIndex < 0 || originalIndex >= _amenityAreas.length) {
      final id = (area['id'] ?? '').toString().trim();
      if (id.isNotEmpty) {
        originalIndex =
            _amenityAreas.indexWhere((element) => element['id'] == id);
      }
    }
    if (originalIndex < 0 || originalIndex >= _amenityAreas.length) {
      originalIndex = visibleIndex;
    }
    if (originalIndex < 0 || originalIndex >= _amenityAreas.length) return;
    _openAmenityEditDialog(originalIndex);
  }

  Future<void> _saveAmenityAreaEditFromDialog() async {
    if (!_isEditingAmenityArea) return;
    if (_amenityEditTempLayoutIndex! >= _layouts.length) return;
    if (_editingAmenityAreaIndex! >= _amenityAreas.length) return;

    final tempLayout = _layouts[_amenityEditTempLayoutIndex!];
    final tempPlots = tempLayout['plots'] as List<dynamic>? ?? const [];
    if (tempPlots.isEmpty || tempPlots.first is! Map<String, dynamic>) return;
    final editedPlot = tempPlots.first as Map<String, dynamic>;
    final amenityRow = _amenityAreas[_editingAmenityAreaIndex!];

    final status = _parsePlotStatus(editedPlot['status']);
    final salePriceValue = _parseMoneyLikeValue(editedPlot['salePrice']);
    final salePriceText =
        salePriceValue > 0 ? _formatWithFixedDecimals(salePriceValue, 2) : '';
    final areaSqft = _parseMoneyLikeValue(amenityRow['area']);
    final saleValue = areaSqft * salePriceValue;
    final saleValueText =
        saleValue > 0 ? _formatWithFixedDecimals(saleValue, 2) : '';
    final buyerName = (editedPlot['buyerName'] ?? '').toString().trim();
    final agentName = (editedPlot['agent'] ?? '').toString().trim();
    final saleDate = (editedPlot['saleDate'] ?? '').toString().trim();
    final payments = editedPlot['payments'] as List<dynamic>? ?? const [];
    final paymentMethods = <String>[];
    for (final payment in payments) {
      if (payment is! Map<String, dynamic>) continue;
      final method = (payment['paymentMethod'] ?? '').toString().trim();
      if (method.isNotEmpty && !paymentMethods.contains(method)) {
        paymentMethods.add(method);
      }
    }
    final paymentText = paymentMethods.join(', ');

    setState(() {
      amenityRow['status'] = status;
      amenityRow['salePrice'] = salePriceText;
      amenityRow['saleValue'] = saleValueText;
      amenityRow['buyerName'] = buyerName;
      amenityRow['agent'] = agentName;
      amenityRow['saleDate'] = saleDate;
      amenityRow['payment'] = paymentText;
      _closeCurrentEditDialog();
    });

    final amenityId = (amenityRow['id'] ?? '').toString().trim();
    final projectId = widget.projectId?.trim() ?? '';
    if (amenityId.isEmpty || projectId.isEmpty) return;

    try {
      final updateData = <String, dynamic>{
        'status': _plotStatusToDatabaseValue(status),
        'sale_price': salePriceValue > 0 ? salePriceValue : null,
        'sale_value': saleValue > 0 ? saleValue : null,
        'buyer_name': buyerName.isEmpty ? null : buyerName,
        'payment': paymentText.isEmpty ? null : paymentText,
        'agent_name': agentName.isEmpty ? null : agentName,
        'sale_date': _formatDateForDatabase(saleDate),
      };
      await _supabase
          .from('amenity_areas')
          .update(updateData)
          .eq('id', amenityId);
    } catch (e) {
      print('Error saving amenity area edits: $e');
    }
  }

  Future<void> _loadPlotData() async {
    _areaUnit = await AreaUnitService.getAreaUnit(widget.projectId);
    List<Map<String, dynamic>> sourceLayouts = widget.layouts ?? [];
    List<Map<String, dynamic>> sourceAmenityAreas = [];
    List<Map<String, dynamic>> agents = [];

    print(
        '🔵 _loadPlotData ENTRY: widget.layouts=${widget.layouts?.length ?? "null"}, widget.projectId=${widget.projectId}');

    // If projectId is available, load from database first
    if (widget.projectId != null && widget.projectId!.isNotEmpty) {
      try {
        print(
            'PlotStatusPage: Loading data from database for projectId=${widget.projectId}');

        // Load layouts from database
        final layouts = await _supabase
            .from('layouts')
            .select('id, name')
            .eq('project_id', widget.projectId!)
            .order('created_at', ascending: true);

        print('📥 LOADED LAYOUTS FROM DB: ${layouts.length} layouts');
        for (var i = 0; i < layouts.length; i++) {
          print(
              '   Layout $i: id=${layouts[i]['id']}, name=${layouts[i]['name']}');
        }

        final layoutsData = <Map<String, dynamic>>[];
        try {
          final amenityAreasData = await _supabase
              .from('amenity_areas')
              .select()
              .eq('project_id', widget.projectId!)
              .order('sort_order', ascending: true)
              .order('created_at', ascending: true)
              .order('id', ascending: true);
          sourceAmenityAreas = amenityAreasData.cast<Map<String, dynamic>>();
        } catch (e) {
          sourceAmenityAreas = [];
          print('PlotStatusPage: Unable to load amenity_areas: $e');
        }

        if (layouts.isNotEmpty) {
          for (var layout in layouts) {
            final layoutId = layout['id'];
            final plots = await _supabase
                .from('plots')
                .select()
                .eq('layout_id', layoutId)
                .order('created_at', ascending: true);

            print('   📥 Layout ${layout['name']} has ${plots.length} plots');
            for (var p = 0; p < plots.length; p++) {
              print(
                  '      Plot $p: plotNumber=${plots[p]['plot_number']}, status=${plots[p]['status']}');
            }

            final plotsData = <Map<String, dynamic>>[];
            for (var plot in plots) {
              // Load plot partners
              final plotPartners = await _supabase
                  .from('plot_partners')
                  .select('partner_name')
                  .eq('plot_id', plot['id']);

              // Parse DB status string to PlotStatus enum
              final plotStatus = _parsePlotStatus(plot['status']);

              // Log what payments data is in the database for this plot
              final paymentsFromDb = plot['payments'];
              print(
                  '📥 LOADING Plot ${plot['plot_number']}: payments from DB = ${paymentsFromDb.runtimeType} - $paymentsFromDb');

              plotsData.add({
                'plotNumber': (plot['plot_number'] ?? '').toString(),
                'area': _formatWithFixedDecimals(plot['area'] ?? 0.0, 3),
                'purchaseRate': _formatWithFixedDecimals(
                    plot['all_in_cost_per_sqft'] ?? 0.0, 2),
                'totalPlotCost':
                    _formatWithFixedDecimals(plot['total_plot_cost'] ?? 0.0, 2),
                'status': plotStatus,
                'salePrice':
                    plot['sale_price'] != null && plot['sale_price'] != 0
                        ? _formatWithFixedDecimals(plot['sale_price'], 2)
                        : '',
                'buyerName': (plot['buyer_name'] ?? '').toString(),
                'buyerContactNumber': (plot['buyer_contact_number'] ??
                        plot['buyer_mobile_number'] ??
                        '')
                    .toString(),
                'saleDate': _formatDateFromDatabase(plot['sale_date']),
                'agent': (plot['agent_name'] ?? '').toString(),
                'partners': plotPartners
                    .map((p) => (p['partner_name'] ?? '').toString())
                    .toList(),
                'payments': (plot['payments'] as List<dynamic>?) ?? [],
              });
            }

            layoutsData.add({
              'name': (layout['name'] ?? '').toString(),
              'plots': plotsData,
            });
          }
        }

        print('📥 TOTAL LAYOUTS FROM DB TO ADD: ${layoutsData.length} layouts');
        for (var i = 0; i < layoutsData.length; i++) {
          final plots = layoutsData[i]['plots'] as List<dynamic>? ?? [];
          print(
              '   Loaded Layout $i (${layoutsData[i]['name']}): ${plots.length} plots');
        }

        // Only use database data if we have layouts with actual plots
        // Otherwise fall back to local storage which may have more recent data
        final hasAnyPlots = layoutsData.any((layout) =>
            (layout['plots'] as List<dynamic>?)?.isNotEmpty ?? false);

        if (hasAnyPlots) {
          sourceLayouts = layoutsData;
          print(
              '✅ Using database layouts (has ${layoutsData.length} layouts with plots)');
        } else {
          print('⚠️ Database has layouts but no plots, will try local storage');
        }

        // Load agents from database
        final agentsData = await _supabase
            .from('agents')
            .select('name')
            .eq('project_id', widget.projectId!)
            .order('created_at', ascending: true);

        agents = agentsData
            .map((a) => {
                  'name': (a['name'] ?? '').toString(),
                })
            .toList();

        print(
            'PlotStatusPage: Loaded ${sourceLayouts.length} layouts and ${agents.length} agents from database');
      } catch (e, stackTrace) {
        print('PlotStatusPage: Error loading from database: $e');
        print('Stack trace: $stackTrace');
        // Fall back to local storage if database load fails
      }
    }

    // Fallback to local storage or provided layouts if database load didn't work
    if (sourceLayouts.isEmpty) {
      print('⚠️ sourceLayouts is empty, loading from local storage');
      sourceLayouts = await LayoutStorageService.loadLayoutsData(
        projectKey: widget.projectId,
      );
      print('📥 Loaded from local storage: ${sourceLayouts.length} layouts');
    }

    // If local edits are newer than the last successful remote save, keep
    // showing local layouts so a refresh does not drop the latest edits.
    final projectId = widget.projectId?.trim();
    if (projectId != null && projectId.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final localEditMs =
            prefs.getInt('project_${projectId}_last_local_edit_ms') ?? 0;
        final remoteSaveMs =
            prefs.getInt('project_${projectId}_last_remote_save_ms') ?? 0;
        if (localEditMs > remoteSaveMs) {
          final localLayouts = await LayoutStorageService.loadLayoutsData(
            projectKey: widget.projectId,
          );
          if (localLayouts.isNotEmpty) {
            print(
                '📥 PlotStatusPage using newer local layouts (local=$localEditMs remote=$remoteSaveMs)');
            sourceLayouts = localLayouts;
          }
        }
      } catch (e) {
        print(
            'PlotStatusPage: Failed to compare local/remote layout timestamps: $e');
      }
    }

    // Fallback to local storage for agents if not loaded from database
    if (agents.isEmpty) {
      agents = await LayoutStorageService.loadAgentsData();
    }

    // Cleanup: Revert any incomplete sold plots back to available in the database
    if (widget.projectId != null && widget.projectId!.isNotEmpty) {
      await _cleanupIncompleteSoldPlots();
    }

    // Convert layout data from Site section format to plot status format
    setState(() {
      _storedAgents = agents;
      _layouts = _convertLayoutsData(sourceLayouts);
      _amenityAreas = _convertAmenityAreasData(sourceAmenityAreas);
      _allPlots = [];

      // Populate _allPlots from layouts for filtering/search
      for (var layoutIndex = 0; layoutIndex < _layouts.length; layoutIndex++) {
        final layout = _layouts[layoutIndex];
        final layoutName = layout['name'] as String? ?? '';
        final plots = layout['plots'] as List<Map<String, dynamic>>? ?? [];
        for (var plotIndex = 0; plotIndex < plots.length; plotIndex++) {
          final plot = plots[plotIndex];
          _allPlots.add({
            'layout': layoutName,
            'layoutIndex': layoutIndex,
            'plotIndex': plotIndex,
            'plotNumber': plot['plotNumber'] as String? ?? '',
            'area': plot['area'] as String? ?? '0.00',
            'status': plot['status'] is PlotStatus
                ? plot['status'] as PlotStatus
                : _parsePlotStatus(plot['status']),
            'purchaseRate': plot['purchaseRate'] as String? ?? '0.00',
            'totalPlotCost': plot['totalPlotCost'] as String? ?? '0.00',
            'salePrice': plot['salePrice'] as String? ?? null,
            'buyerName': plot['buyerName'] as String? ?? '',
            'buyerContactNumber': plot['buyerContactNumber'] as String? ?? '',
            'agent': plot['agent'] as String? ?? '',
            'saleDate': plot['saleDate'] as String? ?? '',
            'payments': (plot['payments'] as List<dynamic>?) ?? [],
          });
        }
      }

      print('PlotStatusPage: Loaded ${_allPlots.length} plots total');

      if (!_hasAmenityAreaData &&
          _activeContentTab == PlotStatusContentTab.amenityArea) {
        _activeContentTab = PlotStatusContentTab.site;
      }

      // Initialize controllers for sale price, buyer name, and sale date from loaded data
      _initializeControllersFromData();
    });
  }

  void _initializeControllersFromData() {
    // Dispose old controllers first
    for (var controller in _salePriceControllers.values) {
      controller.dispose();
    }
    for (var controller in _buyerNameControllers.values) {
      controller.dispose();
    }
    for (var controller in _buyerContactControllers.values) {
      controller.dispose();
    }
    for (var controller in _saleDateControllers.values) {
      controller.dispose();
    }
    _salePriceControllers.clear();
    _buyerNameControllers.clear();
    _buyerContactControllers.clear();
    _saleDateControllers.clear();

    // Initialize controllers with data from _layouts
    for (int layoutIndex = 0; layoutIndex < _layouts.length; layoutIndex++) {
      final plots = _layouts[layoutIndex]['plots'] as List<dynamic>? ?? [];
      for (int plotIndex = 0; plotIndex < plots.length; plotIndex++) {
        final plot = plots[plotIndex] as Map<String, dynamic>;
        final status = plot['status'] is PlotStatus
            ? plot['status'] as PlotStatus
            : _parsePlotStatus(plot['status']);

        if (status == PlotStatus.sold) {
          // Initialize sale price controller
          final priceKey = '${layoutIndex}_${plotIndex}_price';
          final salePrice = plot['salePrice'] as String?;
          _salePriceControllers[priceKey] = TextEditingController(
            text: (salePrice != null &&
                    salePrice.isNotEmpty &&
                    salePrice != '0.00')
                ? salePrice
                : '',
          );
          _salePriceFocusNodes[priceKey] = _createDialogFocusNode();

          // Initialize buyer name controller
          final buyerKey = '${layoutIndex}_${plotIndex}_buyer';
          final buyerName = plot['buyerName'] as String? ?? '';
          _buyerNameControllers[buyerKey] = TextEditingController(
            text: buyerName,
          );
          _buyerNameFocusNodes[buyerKey] = _createDialogFocusNode();

          // Initialize buyer contact controller
          final buyerContactKey = '${layoutIndex}_${plotIndex}_buyer_contact';
          final buyerContactNumber =
              plot['buyerContactNumber'] as String? ?? '';
          _buyerContactControllers[buyerContactKey] = TextEditingController(
            text: buyerContactNumber,
          );
          _buyerContactFocusNodes[buyerContactKey] = _createDialogFocusNode();

          // Initialize sale date controller
          final dateKey = '${layoutIndex}_${plotIndex}_date';
          final saleDate = plot['saleDate'] as String? ?? '';
          _saleDateControllers[dateKey] = TextEditingController(
            text: saleDate,
          );
          _saleDateFocusNodes[dateKey] = _createDialogFocusNode();
        }
      }
    }

    print(
        'PlotStatusPage: Initialized ${_salePriceControllers.length} sale price controllers, ${_buyerNameControllers.length} buyer name controllers, ${_buyerContactControllers.length} buyer contact controllers, ${_saleDateControllers.length} sale date controllers');
  }

  Future<void> _cleanupIncompleteSoldPlots() async {
    /// This function cleans up the database by reverting any "sold" plots that don't have all required fields
    /// It queries all sold plots and checks if they have complete data (agent, buyer_name, sale_price, sale_date)
    /// If any field is missing, it reverts the status back to 'available'
    // Disabled to allow saving status as Sold even when details are added later.
    return;
    try {
      print(
          '_cleanupIncompleteSoldPlots: Starting cleanup of incomplete sold plots...');

      // Get all layouts for this project
      final layouts = await _supabase
          .from('layouts')
          .select('id')
          .eq('project_id', widget.projectId!);

      for (var layout in layouts) {
        final layoutId = layout['id'] as String;

        // Get all sold plots for this layout
        final soldPlots = await _supabase
            .from('plots')
            .select()
            .eq('layout_id', layoutId)
            .eq('status', 'sold');

        // Check each sold plot and revert if incomplete
        for (var plot in soldPlots) {
          final plotId = plot['id'] as String;
          final agent = (plot['agent_name'] as String? ?? '').trim();
          final buyerName = (plot['buyer_name'] as String? ?? '').trim();
          final salePrice = plot['sale_price'];
          final saleDate = (plot['sale_date'] as String? ?? '').trim();

          final isComplete = agent.isNotEmpty &&
              buyerName.isNotEmpty &&
              salePrice != null &&
              salePrice != 0 &&
              saleDate.isNotEmpty;

          if (!isComplete) {
            print(
                '_cleanupIncompleteSoldPlots: Reverting plot $plotId to available');
            // Revert status to available
            await _supabase
                .from('plots')
                .update({'status': 'available'}).eq('id', plotId);
          }
        }
      }

      print('_cleanupIncompleteSoldPlots: Cleanup completed');
    } catch (e) {
      print('_cleanupIncompleteSoldPlots: Error during cleanup: $e');
    }
  }

  Future<void> _saveLayoutsData() async {
    if (_isEditingAmenityArea) {
      return;
    }
    print(
        '🔷 _saveLayoutsData ENTRY: Starting save, _layouts has ${_layouts.length} layouts');

    // Debug: Print current state  of _layouts before conversion
    for (var i = 0; i < _layouts.length; i++) {
      final layout = _layouts[i];
      final plots = layout['plots'] as List<dynamic>? ?? [];
      print(
          'PRE-CONVERSION Layout $i (${layout['name']}): ${plots.length} plots');
      for (var j = 0; j < plots.length; j++) {
        final plot = plots[j] as Map<String, dynamic>? ?? {};
        print(
            '  Plot $j: plotNumber=${plot['plotNumber']}, status=${plot['status']}');
      }
    }

    // Save updated layout data back to storage
    // Convert _layouts back to the format expected by storage
    bool didAutoPromotePendingToSold = false;
    final layoutsToSave = _layouts.asMap().entries.map((layoutEntry) {
      final layoutIndex = layoutEntry.key;
      final layout = layoutEntry.value;
      final plots =
          (layout['plots'] as List<dynamic>).asMap().entries.map((plotEntry) {
        final plotIndex = plotEntry.key;
        final plotMap = plotEntry.value as Map<String, dynamic>;
        final currentStatus = _parsePlotStatus(plotMap['status']);
        final effectiveStatus = _resolveAutoStatusForPlot(plotMap);
        if (effectiveStatus != currentStatus) {
          didAutoPromotePendingToSold = true;
          plotMap['status'] = effectiveStatus;
          if (_editingLayoutIndex == layoutIndex &&
              _editingPlotIndex == plotIndex) {
            _editingStatus = effectiveStatus;
          }
        }

        // Get values from controllers using the correct key format
        final priceKey = '${layoutIndex}_${plotIndex}_price';
        final buyerKey = '${layoutIndex}_${plotIndex}_buyer';
        final buyerContactKey = '${layoutIndex}_${plotIndex}_buyer_contact';
        final dateKey = '${layoutIndex}_${plotIndex}_date';

        final salePriceController = _salePriceControllers[priceKey];
        final buyerNameController = _buyerNameControllers[buyerKey];
        final buyerContactController =
            _buyerContactControllers[buyerContactKey];
        final saleDateController = _saleDateControllers[dateKey];

        // Get sale price - convert empty string to null
        final salePriceText = salePriceController?.text.trim() ??
            plotMap['salePrice']?.toString() ??
            '';
        final cleanedSalePrice = salePriceText
            .replaceAll(',', '')
            .replaceAll('₹', '')
            .replaceAll(' ', '')
            .trim();
        final salePrice = (cleanedSalePrice.isEmpty ||
                cleanedSalePrice == '0' ||
                cleanedSalePrice == '0.00')
            ? null
            : cleanedSalePrice;

        // Get buyer name - convert empty string to null
        final buyerNameText = buyerNameController?.text.trim() ??
            plotMap['buyerName']?.toString() ??
            '';
        final buyerName = buyerNameText.isEmpty ? null : buyerNameText;

        // Get buyer contact number - convert empty string to null
        final buyerContactText = buyerContactController?.text.trim() ??
            plotMap['buyerContactNumber']?.toString() ??
            '';
        final buyerContactNumber =
            buyerContactText.isEmpty ? null : buyerContactText;

        // Get agent - convert empty string to null
        final agentText = plotMap['agent']?.toString() ?? '';
        final agent = agentText.isEmpty ? null : agentText;

        // Get sale date - convert empty string to null
        final saleDateText = saleDateController?.text.trim() ??
            plotMap['saleDate']?.toString() ??
            '';
        final saleDate = saleDateText.isEmpty ? null : saleDateText;

        // Get partners - ensure it's a list
        final partners = plotMap['partners'] as List<dynamic>? ?? [];
        final partnersList = partners.map((p) => p.toString()).toList();

        // Get payments - ensure it's a list with all payment details
        final payments = plotMap['payments'] as List<dynamic>? ?? [];
        print(
            'DEBUG _saveLayoutsData: LAYOUT=${layoutIndex}_PLOT=${plotIndex} - Number=${plotMap['plotNumber']}, payments=${payments.isEmpty ? "EMPTY" : "${payments.length} items"}');
        final paymentsList = payments.map((payment) {
          if (payment is Map<String, dynamic>) {
            return Map<String, dynamic>.from(payment);
          }
          return payment;
        }).toList();

        return {
          'plotNumber': plotMap['plotNumber'] as String? ?? '',
          'area': plotMap['area'] as String? ?? '0.00',
          'purchaseRate': plotMap['purchaseRate'] as String? ?? '0.00',
          'totalPlotCost': plotMap['totalPlotCost'] as String? ?? '0.00',
          'status': _plotStatusToDatabaseValue(effectiveStatus),
          'salePrice': salePrice,
          'buyerName': buyerName,
          'buyerContactNumber': buyerContactNumber,
          'agent': agent,
          'saleDate': saleDate,
          'partners': partnersList,
          'payments': paymentsList,
        };
      }).toList();

      return {
        'name': layout['name'] as String? ?? 'Layout',
        'plots': plots,
      };
    }).toList();

    if (didAutoPromotePendingToSold && mounted) {
      setState(() {
        _rebuildAllPlotsFromLayouts();
      });
    }

    // Persist local draft first and mark it as the newest edit.
    await LayoutStorageService.saveLayoutsDataDirect(
      layoutsToSave,
      projectKey: widget.projectId,
    );
    await _markLocalEditTimestamp();
    _markUnsaved();

    // Save to Supabase if projectId is available, otherwise save to local storage
    print(
        '🔷 _saveLayoutsData BEFORE SAVE: projectId=${widget.projectId}, layoutsToSave has ${layoutsToSave.length} layouts');
    for (var i = 0; i < layoutsToSave.length; i++) {
      final layout = layoutsToSave[i];
      final plots = layout['plots'] as List<dynamic>? ?? [];
      print('   Layout $i: ${layout['name']} - ${plots.length} plots');
      for (var j = 0; j < plots.length; j++) {
        final plot = plots[j] as Map<String, dynamic>? ?? {};
        final payments = plot['payments'] as List<dynamic>? ?? [];
        print(
            '     Plot $j (${plot['plotNumber']}): status=${plot['status']}, payments=${payments.isEmpty ? "EMPTY" : "${payments.length} items"}');
      }
    }
    if (widget.projectId != null && widget.projectId!.isNotEmpty) {
      try {
        _setSaveStatus(ProjectSaveStatusType.saving);
        await ProjectStorageService.saveProjectData(
          projectId: widget.projectId!,
          projectName: '', // Not updating project name
          layouts: layoutsToSave,
        );
        await _markRemoteSaveTimestamp();
        _hasUnsavedChanges = false;
        _setSaveStatus(ProjectSaveStatusType.saved);
      } catch (e) {
        print('Error saving plot status to Supabase: $e');
        // Local draft is already saved and will be retried on the next save.
        _setSaveStatus(ProjectSaveStatusType.connectionLost);
      }
    } else {
      // Save to local storage if no projectId
      await LayoutStorageService.saveLayoutsDataDirect(
        layoutsToSave,
        projectKey: widget.projectId,
      );
      _hasUnsavedChanges = false;
      _setSaveStatus(ProjectSaveStatusType.saved);
    }
    print('🔷 _saveLayoutsData COMPLETE: Save finished successfully');
    _notifyErrorState();
  }

  Future<void> _saveToStorage(List<Map<String, dynamic>> layouts) async {
    await LayoutStorageService.saveLayoutsDataDirect(
      layouts,
      projectKey: widget.projectId,
    );
  }

  Future<void> _markLocalEditTimestamp() async {
    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      'project_${projectId}_last_local_edit_ms',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _markRemoteSaveTimestamp() async {
    final projectId = widget.projectId?.trim();
    if (projectId == null || projectId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      'project_${projectId}_last_remote_save_ms',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  List<Map<String, dynamic>> _convertLayoutsData(
      List<Map<String, dynamic>> sourceLayouts) {
    // Convert layouts from Site section format to Plot Status format
    // Site format: plots have plotNumber, area, purchaseRate, partner (values may be in controllers)
    // Plot Status format: plots need status, salePrice, buyerName, agent, saleDate
    // If data comes from project_details_page, extract values from controllers
    return sourceLayouts.map((layout) {
      final plots = (layout['plots'] as List<dynamic>? ?? []).map((plot) {
        final plotMap = plot as Map<String, dynamic>;

        // Extract plot data - handle both direct values and controller-based values
        String plotNumber = '';
        String area = '0.00';
        String purchaseRate = '0.00';
        String totalPlotCost = '0.00';

        // If plotNumber is a controller, get its text, otherwise use the value directly
        if (plotMap['plotNumber'] is TextEditingController) {
          plotNumber = (plotMap['plotNumber'] as TextEditingController).text;
        } else {
          plotNumber = plotMap['plotNumber'] as String? ?? '';
        }

        // Same for area
        if (plotMap['area'] is TextEditingController) {
          area = (plotMap['area'] as TextEditingController).text;
        } else {
          area = plotMap['area'] as String? ?? '0.00';
        }

        // Same for purchaseRate
        if (plotMap['purchaseRate'] is TextEditingController) {
          purchaseRate =
              (plotMap['purchaseRate'] as TextEditingController).text;
        } else {
          purchaseRate = plotMap['purchaseRate'] as String? ?? '0.00';
        }

        // Same for totalPlotCost
        if (plotMap['totalPlotCost'] is TextEditingController) {
          totalPlotCost =
              (plotMap['totalPlotCost'] as TextEditingController).text;
        } else {
          totalPlotCost = plotMap['totalPlotCost'] as String? ?? '0.00';
        }

        // Handle status - can be PlotStatus enum or string
        final plotStatus = _parsePlotStatus(plotMap['status']);

        return {
          'plotNumber': plotNumber,
          'area': area.isEmpty ? '0.00' : area,
          'status': plotStatus,
          'salePrice': plotMap['salePrice'] as String? ?? '',
          'buyerName': plotMap['buyerName'] as String? ?? '',
          'buyerContactNumber': (plotMap['buyerContactNumber'] ??
                  plotMap['buyer_contact_number'] ??
                  '')
              .toString(),
          'agent': plotMap['agent'] as String? ?? '',
          'saleDate': plotMap['saleDate'] as String? ?? '',
          'purchaseRate': purchaseRate.isEmpty ? '0.00' : purchaseRate,
          'totalPlotCost': totalPlotCost.isEmpty ? '0.00' : totalPlotCost,
          'partners': (plotMap['partners'] as List<dynamic>? ?? [])
              .map((p) => p.toString())
              .toList(),
          'payments': (plotMap['payments'] as List<dynamic>?) ?? [],
        };
      }).toList();

      // Extract layout name - handle controller case
      String layoutName = 'Layout';
      if (layout['name'] is TextEditingController) {
        layoutName = (layout['name'] as TextEditingController).text;
      } else {
        layoutName = layout['name'] as String? ?? 'Layout';
      }

      return {
        'name': layoutName.isEmpty ? 'Layout' : layoutName,
        'plots': plots,
      };
    }).toList();
  }

  List<Map<String, dynamic>> _convertAmenityAreasData(
    List<Map<String, dynamic>> sourceAmenityAreas,
  ) {
    return sourceAmenityAreas.map((row) {
      final areaSqft = (row['area'] is num)
          ? (row['area'] as num).toDouble()
          : double.tryParse((row['area'] ?? '0').toString()) ?? 0.0;
      final statusRaw = (row['status'] ?? 'available').toString();
      final salePriceRaw = (row['sale_price'] ?? '').toString();
      final saleValueRaw = (row['sale_value'] ?? '').toString();
      return <String, dynamic>{
        'id': (row['id'] ?? '').toString(),
        'name': (row['name'] ?? '').toString().trim(),
        // Store in sqft, convert to display only while rendering.
        'area': _formatWithFixedDecimals(areaSqft, 3),
        'status': _parsePlotStatus(statusRaw),
        'salePrice': salePriceRaw,
        'saleValue': saleValueRaw,
        'buyerName': (row['buyer_name'] ?? '').toString(),
        'payment': (row['payment'] ?? '').toString(),
        'agent': (row['agent_name'] ?? '').toString(),
        'saleDate': _formatDateFromDatabase(row['sale_date']),
      };
    }).toList();
  }

  Future<void> _savePlotsToDatabase() async {
    if (_isEditingAmenityArea) {
      return;
    }
    // Save plot data (including agent, status, buyer, price, date) to Supabase
    if (widget.projectId == null) return;

    try {
      _markUnsaved();
      _setSaveStatus(ProjectSaveStatusType.saving);
      final canSaveBuyerContactNumber = await _canSaveBuyerContactNumber();
      for (var layout in _layouts) {
        final layoutId = layout['layoutId'] as String?;
        if (layoutId == null) continue;

        final plots = layout['plots'] as List<dynamic>? ?? [];
        for (var plot in plots) {
          final plotId = plot['id'] as String?;
          if (plotId == null) continue;

          // Get values from the plot data
          // Handle status - can be PlotStatus enum or string
          final status =
              _plotStatusToDatabaseValue(_parsePlotStatus(plot['status']));

          final agent = (plot['agent'] as String? ?? '').toString().trim();
          final buyerName =
              (plot['buyerName'] as String? ?? '').toString().trim();
          final salePrice = (plot['salePrice'] as String? ?? '')
              .toString()
              .replaceAll(',', '')
              .replaceAll('₹', '')
              .replaceAll(' ', '')
              .trim();
          final saleDate =
              (plot['saleDate'] as String? ?? '').toString().trim();
          final buyerContactNumber =
              (plot['buyerContactNumber'] as String? ?? '').toString().trim();

          final updateData = <String, dynamic>{
            'status': status,
            'agent_name': agent.isEmpty ? null : agent,
            'buyer_name': buyerName.isEmpty ? null : buyerName,
            'sale_price':
                salePrice.isEmpty || salePrice == '0' || salePrice == '0.00'
                    ? null
                    : double.tryParse(salePrice),
            'sale_date': saleDate.isEmpty ? null : saleDate,
          };

          if (canSaveBuyerContactNumber) {
            updateData['buyer_contact_number'] =
                buyerContactNumber.isEmpty ? null : buyerContactNumber;
          }

          // Update the plot in the database
          await _supabase.from('plots').update(updateData).eq('id', plotId);
        }
      }
      _hasUnsavedChanges = false;
      await _markRemoteSaveTimestamp();
      _setSaveStatus(ProjectSaveStatusType.saved);
      print('Successfully saved plots to database');
    } catch (e) {
      _setSaveStatus(ProjectSaveStatusType.connectionLost);
      print('Error saving plots to database: $e');
    }
  }

  void _updatePlotStatus(int index, PlotStatus newStatus) {
    setState(() {
      if (index < _allPlots.length) {
        final plot = _allPlots[index];
        final plotNumber = plot['plotNumber'] as String? ?? '';
        final layoutName = plot['layout'] as String? ?? '';

        // If trying to set status to 'sold', check if all required fields are filled
        PlotStatus statusToSet = newStatus;
        String? warningMessage;

        if (newStatus == PlotStatus.sold) {
          final agent = (plot['agent'] as String? ?? '').toString().trim();
          final buyerName =
              (plot['buyerName'] as String? ?? '').toString().trim();
          final salePrice = (plot['salePrice'] as String? ?? '')
              .toString()
              .replaceAll(',', '')
              .replaceAll('₹', '')
              .replaceAll(' ', '')
              .trim();
          final saleDate =
              (plot['saleDate'] as String? ?? '').toString().trim();

          // Check if any required field is missing
          final missingFields = <String>[];
          if (agent.isEmpty) missingFields.add('Agent');
          if (buyerName.isEmpty) missingFields.add('Buyer Name');
          if (salePrice.isEmpty || salePrice == '0' || salePrice == '0.00')
            missingFields.add('Sale Price');
          if (saleDate.isEmpty) missingFields.add('Sale Date');

          if (missingFields.isNotEmpty) {
            statusToSet = PlotStatus.available;
            warningMessage =
                'Cannot mark as sold. Missing: ${missingFields.join(', ')}';
            print(
                '_updatePlotStatus: Blocking status change to sold. $warningMessage');
          } else {
            print(
                '_updatePlotStatus: All required fields present, allowing status change to sold');
          }
        }

        // Update _allPlots
        _allPlots[index]['status'] = statusToSet;

        // Also update the corresponding plot in _layouts
        for (var layout in _layouts) {
          if ((layout['name'] as String? ?? '') == layoutName) {
            final plots = layout['plots'] as List<dynamic>? ?? [];
            for (var plotData in plots) {
              if (plotData is Map<String, dynamic>) {
                final pn = plotData['plotNumber'] as String? ?? '';
                if (pn == plotNumber) {
                  plotData['status'] = statusToSet;
                  break;
                }
              }
            }
            break;
          }
        }

        // Show warning if validation failed
        if (warningMessage != null) {
          Future.delayed(Duration.zero, () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(warningMessage!),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 3),
              ),
            );
          });
        }
      }
    });
    _saveLayoutsData();
    _savePlotsToDatabase(); // Save to database
    _notifyErrorState();
  }

  List<String> get _availableLayouts {
    final layouts = _allPlots
        .map((plot) => plot['layout'] as String? ?? '')
        .toSet()
        .toList();
    layouts.remove('');
    layouts.sort();
    return ['All Layouts', ...layouts];
  }

  List<Map<String, dynamic>> get _filteredPlots {
    print(
        '🔍 FILTER: Computing filtered plots from ${_allPlots.length} total plots');
    final result = _allPlots.where((plot) {
      // Filter by layout
      if (_selectedLayout != 'All Layouts') {
        if ((plot['layout'] as String? ?? '') != _selectedLayout) {
          return false;
        }
      }

      // Filter by status
      if (_selectedStatus != 'All Status') {
        final plotStatus = _parsePlotStatus(plot['status']);
        final statusString = _getStatusString(plotStatus);
        if (statusString != _selectedStatus) {
          return false;
        }
      }

      // Filter by search query
      if (_searchQuery.isNotEmpty) {
        final plotNumber = (plot['plotNumber'] as String? ?? '').toLowerCase();
        final layout = (plot['layout'] as String? ?? '').toLowerCase();
        final query = _searchQuery.toLowerCase();
        if (!plotNumber.contains(query) && !layout.contains(query)) {
          return false;
        }
      }

      return true;
    }).toList();
    print('🔍 FILTER: Returning ${result.length} filtered plots');
    return result;
  }

  List<Map<String, dynamic>> get _filteredAmenityAreas {
    final filtered = <Map<String, dynamic>>[];
    for (int i = 0; i < _amenityAreas.length; i++) {
      final area = _amenityAreas[i];
      final name = (area['name'] ?? '').toString().trim().toLowerCase();
      final areaStatus = _parsePlotStatus(area['status']);
      if (_selectedStatus != 'All Status') {
        final statusString = _getStatusString(areaStatus);
        if (statusString != _selectedStatus) {
          continue;
        }
      }
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        if (!name.contains(query)) {
          continue;
        }
      }
      if (name.isEmpty && _parseMoneyLikeValue(area['area']) <= 0) {
        continue;
      }

      final row = Map<String, dynamic>.from(area);
      row['_sourceIndex'] = i;
      filtered.add(row);
    }
    return filtered;
  }

  List<Map<String, dynamic>> get _salesData {
    final salesData = <Map<String, dynamic>>[];
    for (var layout in _layouts) {
      final plots = layout['plots'] as List<Map<String, dynamic>>? ?? [];
      for (var plot in plots) {
        final status = _parsePlotStatus(plot['status']);
        if (status == PlotStatus.sold) {
          salesData.add({
            'plotNumber': plot['plotNumber'] as String? ?? '',
            'area': plot['area'] as String? ?? '0.00',
            'status': status,
            'salePrice': plot['salePrice'] as String? ?? '0.00',
            'buyerName': plot['buyerName'] as String? ?? '',
            'buyerContactNumber': plot['buyerContactNumber'] as String? ?? '',
            'agent': plot['agent'] as String? ?? '',
            'saleDate': plot['saleDate'] as String? ?? '',
          });
        }
      }
    }
    return salesData;
  }

  String _getStatusString(PlotStatus status) {
    switch (status) {
      case PlotStatus.available:
        return 'Available';
      case PlotStatus.sold:
        return 'Sold';
      case PlotStatus.reserved:
        return 'Pending';
      case PlotStatus.blocked:
        return 'Blocked';
    }
  }

  bool _isSoldLikeStatus(PlotStatus status) {
    return status == PlotStatus.sold || status == PlotStatus.reserved;
  }

  Color _getStatusColor(PlotStatus status) {
    switch (status) {
      case PlotStatus.available:
        return const Color(0xFF50CD89); // Bright green (matching Figma)
      case PlotStatus.sold:
        return const Color(0xFFFF0000); // Red #FF0000
      case PlotStatus.reserved:
        return const Color(0xFFFFA500); // Orange
      case PlotStatus.blocked:
        return const Color(0xFFFF0000); // Red
    }
  }

  Color _getStatusBackgroundColor(PlotStatus status) {
    switch (status) {
      case PlotStatus.available:
        return const Color(0xFFE9F7EB); // Light green (matching Figma)
      case PlotStatus.sold:
        return const Color(0xFFFFECEC); // Light pink (matching Figma)
      case PlotStatus.reserved:
        return const Color(0xFFFFF4E6); // Light orange
      case PlotStatus.blocked:
        return const Color(0xFFFFEBEE); // Light red
    }
  }

  String _getStatusDropdownLabel(PlotStatus status) {
    if (status == PlotStatus.reserved) return 'Pending';
    return _getStatusString(status);
  }

  Color _getStatusDropdownDotColor(PlotStatus status) {
    switch (status) {
      case PlotStatus.reserved:
        return const Color(0xFFFEB12A);
      case PlotStatus.available:
        return const Color(0xFF53D10C);
      case PlotStatus.sold:
        return const Color(0xFFFF0000);
      case PlotStatus.blocked:
        return const Color(0xFFFF0000);
    }
  }

  Color _getStatusDropdownChipBackgroundColor(PlotStatus status) {
    switch (status) {
      case PlotStatus.reserved:
        return const Color(0xFFFAE8C8);
      case PlotStatus.available:
        return const Color(0xFFD1EDD2);
      case PlotStatus.sold:
        return const Color(0xFFF9E5E6);
      case PlotStatus.blocked:
        return const Color(0xFFF9E5E6);
    }
  }

  String _formatIntegerWithIndianNumbering(String integerPart) {
    if (integerPart.length <= 4) {
      return integerPart;
    } else {
      final length = integerPart.length;
      final lastThreeDigits = integerPart.substring(length - 3);
      final remainingDigits = integerPart.substring(0, length - 3);

      String formattedRemaining = '';
      int count = 0;
      for (int i = remainingDigits.length - 1; i >= 0; i--) {
        if (count > 0 && count % 2 == 0 && i >= 0) {
          formattedRemaining = ',' + formattedRemaining;
        }
        formattedRemaining = remainingDigits[i] + formattedRemaining;
        count++;
      }

      return formattedRemaining.isEmpty
          ? lastThreeDigits
          : '$formattedRemaining,$lastThreeDigits';
    }
  }

  String _formatAmount(String value) {
    if (value.trim().isEmpty) {
      return '0.00';
    }

    String cleaned = value
        .trim()
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .replaceAll(',', '');

    String integerPart;
    String decimalPart;

    if (!cleaned.contains('.')) {
      integerPart = cleaned.isEmpty ? '0' : cleaned;
      decimalPart = '00';
    } else {
      final parts = cleaned.split('.');
      integerPart = parts[0].isEmpty ? '0' : parts[0];
      decimalPart = parts.length > 1 ? parts[1] : '00';
      decimalPart = decimalPart.length > 2
          ? decimalPart.substring(0, 2)
          : decimalPart.padRight(2, '0');
    }

    final formattedInteger = _formatIntegerWithIndianNumbering(integerPart);
    return '$formattedInteger.$decimalPart';
  }

  String _formatAreaValue(String value) {
    if (value.trim().isEmpty) {
      return '0.000';
    }

    String cleaned = value
        .trim()
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .replaceAll(',', '');

    String integerPart;
    String decimalPart;

    if (!cleaned.contains('.')) {
      integerPart = cleaned.isEmpty ? '0' : cleaned;
      decimalPart = '000';
    } else {
      final parts = cleaned.split('.');
      integerPart = parts[0].isEmpty ? '0' : parts[0];
      decimalPart = parts.length > 1 ? parts[1] : '000';
      decimalPart = decimalPart.length > 3
          ? decimalPart.substring(0, 3)
          : decimalPart.padRight(3, '0');
    }

    final formattedInteger = _formatIntegerWithIndianNumbering(integerPart);
    return '$formattedInteger.$decimalPart';
  }

  String _formatAreaNoTrailingZeros(String value) {
    final raw = value
        .trim()
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .replaceAll(',', '');
    final parsed = double.tryParse(raw) ?? 0.0;
    final fixed = parsed.toStringAsFixed(3);
    final trimmed = fixed.replaceFirst(RegExp(r'\.?0+$'), '');
    final parts = trimmed.split('.');
    final formattedInteger = _formatIntegerWithIndianNumbering(parts.first);
    if (parts.length == 1) return formattedInteger;
    return '$formattedInteger.${parts[1]}';
  }

  // Format amount without trailing zeros (shows "0" instead of "0.00")
  String _formatAmountNoTrailingZeros(String value) {
    if (value.trim().isEmpty) {
      return '0';
    }

    String cleaned = value
        .trim()
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .replaceAll(',', '');

    String integerPart;
    String decimalPart;

    if (!cleaned.contains('.')) {
      integerPart = cleaned.isEmpty ? '0' : cleaned;
      decimalPart = '';
    } else {
      final parts = cleaned.split('.');
      integerPart = parts[0].isEmpty ? '0' : parts[0];
      decimalPart = parts.length > 1 ? parts[1] : '';
      // Remove trailing zeros from decimal part
      decimalPart = decimalPart.replaceAll(RegExp(r'0+$'), '');
      // Limit to 2 decimal places
      if (decimalPart.length > 2) {
        decimalPart = decimalPart.substring(0, 2);
        decimalPart = decimalPart.replaceAll(RegExp(r'0+$'), '');
      }
    }

    final formattedInteger = _formatIntegerWithIndianNumbering(integerPart);
    return decimalPart.isEmpty
        ? formattedInteger
        : '$formattedInteger.$decimalPart';
  }

  double _parseMoneyLikeValue(dynamic value) {
    if (value == null) return 0.0;
    final raw = value
        .toString()
        .replaceAll(',', '')
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .trim();
    return double.tryParse(raw) ?? 0.0;
  }

  double _calculateTotalPaidAmount(Map<String, dynamic> plot) {
    final payments = plot['payments'] as List<dynamic>? ?? const [];
    double totalAmount = 0.0;
    for (final payment in payments) {
      final paymentMap = payment as Map<String, dynamic>;
      totalAmount += _parseMoneyLikeValue(paymentMap['paymentAmount']);
    }
    return totalAmount;
  }

  PlotStatus _resolveAutoStatusForPlot(Map<String, dynamic> plot) {
    final currentStatus = _parsePlotStatus(plot['status']);
    // Respect explicit Available/Blocked selections.
    if (currentStatus == PlotStatus.available ||
        currentStatus == PlotStatus.blocked) {
      return currentStatus;
    }

    const epsilon = 0.01;
    final area = _parseMoneyLikeValue(plot['area']);
    final salePrice = _parseMoneyLikeValue(plot['salePrice']);
    final saleValue = area * salePrice;
    if (saleValue <= epsilon) {
      return currentStatus;
    }

    final remainingAmount = saleValue - _calculateTotalPaidAmount(plot);
    if (remainingAmount.abs() <= epsilon) {
      return PlotStatus.sold;
    }

    return PlotStatus.reserved;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload agents when page becomes visible to get latest data
    _refreshAgents();
  }

  Future<void> _refreshAgents() async {
    final agents = await LayoutStorageService.loadAgentsData();
    if (mounted) {
      setState(() {
        _storedAgents = agents;
      });
    }
  }

  bool _hasValidationErrors() {
    // Keep this in sync with row-level red shadow rules used in the table.
    // If any sold row would show a red required-field shadow, surface a
    // section-level error badge on the "Site" tab header.
    for (var layout in _layouts) {
      final plots = layout['plots'] as List<Map<String, dynamic>>? ?? [];
      for (var plot in plots) {
        if (_rowHasRequiredSoldFieldError(plot)) {
          return true;
        }
      }
    }
    return false;
  }

  // Helper widget to build focus-aware input container with dynamic shadow
  Widget _buildFocusAwareInputContainer({
    required Widget child,
    required FocusNode focusNode,
    VoidCallback? onFocusLost,
    double width = double.infinity,
    double height = 40,
    Color backgroundColor = const Color(0xFFF8F9FA),
    double borderRadius = 8,
    bool hasError = false,
  }) {
    return _FocusAwareInputContainer(
      focusNode: focusNode,
      onFocusLost: onFocusLost,
      width: width,
      height: height,
      backgroundColor: backgroundColor,
      borderRadius: borderRadius,
      hasError: hasError,
      child: child,
    );
  }

  bool _rowHasRequiredSoldFieldError(Map<String, dynamic> plot) {
    final status = _parsePlotStatus(plot['status']);
    if (status != PlotStatus.sold && status != PlotStatus.reserved) {
      return false;
    }

    final salePrice = (plot['salePrice'] as String? ?? '')
        .replaceAll(',', '')
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .trim();
    final buyerName = (plot['buyerName'] as String? ?? '').trim();
    final agent = (plot['agent'] as String? ?? '').trim();
    final saleDate = (plot['saleDate'] as String? ?? '').trim();
    final payments = plot['payments'] as List<dynamic>? ?? [];
    final hasPaymentMethod = payments.any((p) {
      final m = p as Map<String, dynamic>;
      return (m['paymentMethod'] as String? ?? '').trim().isNotEmpty;
    });

    final salePriceMissing =
        salePrice.isEmpty || salePrice == '0' || salePrice == '0.00';
    return salePriceMissing ||
        buyerName.isEmpty ||
        agent.isEmpty ||
        saleDate.isEmpty ||
        !hasPaymentMethod;
  }

  void _showFilterDropdown(BuildContext context) {
    final RenderBox? buttonRenderBox =
        _filterButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (buttonRenderBox == null) return;
    final buttonOffset = buttonRenderBox.localToGlobal(Offset.zero);
    final screenWidth = MediaQuery.of(context).size.width;

    const basePopupWidth = 160.0;
    final popupWidth = _activeContentTab == PlotStatusContentTab.site
        ? basePopupWidth * 0.85
        : basePopupWidth;
    final optionFontSize =
        _activeContentTab == PlotStatusContentTab.site ? 12.0 : 14.0;
    final optionHeight =
        _activeContentTab == PlotStatusContentTab.site ? 28.0 : 36.0;
    final optionVerticalPadding =
        _activeContentTab == PlotStatusContentTab.site ? 4.0 : 8.0;
    final optionTextYOffset =
        _activeContentTab == PlotStatusContentTab.site ? 0.0 : 0.0;
    var popupLeft = buttonOffset.dx;
    if (popupLeft + popupWidth > screenWidth - 16) {
      popupLeft = screenWidth - popupWidth - 16;
    }
    if (popupLeft < 16) {
      popupLeft = 16;
    }
    final popupTop = buttonOffset.dy + buttonRenderBox.size.height + 4;

    // Calculate totals
    int totalPlots = 0;
    int availablePlots = 0;
    int soldPlots = 0;
    int pendingPlots = 0;

    if (_activeContentTab == PlotStatusContentTab.amenityArea) {
      for (final area in _amenityAreas) {
        final status = _parsePlotStatus(area['status']);
        totalPlots++;
        if (status == PlotStatus.sold) {
          soldPlots++;
        } else if (status == PlotStatus.available) {
          availablePlots++;
        } else if (status == PlotStatus.reserved) {
          pendingPlots++;
        }
      }
    } else {
      for (var layout in _layouts) {
        final plots = layout['plots'] as List<Map<String, dynamic>>? ?? [];
        for (var plot in plots) {
          final status = _parsePlotStatus(plot['status']);
          totalPlots++;

          if (status == PlotStatus.sold) {
            soldPlots++;
          } else if (status == PlotStatus.available) {
            availablePlots++;
          } else if (status == PlotStatus.reserved) {
            pendingPlots++;
          }
        }
      }
    }

    showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.transparent,
      builder: (BuildContext dialogContext) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  Navigator.of(dialogContext).pop();
                },
                child: Container(),
              ),
            ),
            Positioned(
              top: popupTop,
              left: popupLeft,
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  width: popupWidth,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F9FA),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x80000000),
                        blurRadius: 2,
                        offset: Offset(0, 0),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Pending option
                      _buildFilterOption(
                        label: 'Pending ($pendingPlots)',
                        color: const Color(0xFFFEB12A),
                        isSelected: _selectedStatus == 'Pending',
                        fontSize: optionFontSize,
                        optionHeight: optionHeight,
                        optionVerticalPadding: optionVerticalPadding,
                        textYOffset: optionTextYOffset,
                        onTap: () {
                          print('Selected: Pending');
                          setState(() {
                            _selectedStatus = 'Pending';
                          });
                          Navigator.of(dialogContext).pop();
                        },
                      ),
                      const SizedBox(height: 8),
                      // Available option
                      _buildFilterOption(
                        label: 'Available ($availablePlots)',
                        color: const Color(0xFF4CAF50),
                        isSelected: _selectedStatus == 'Available',
                        fontSize: optionFontSize,
                        optionHeight: optionHeight,
                        optionVerticalPadding: optionVerticalPadding,
                        textYOffset: optionTextYOffset,
                        onTap: () {
                          print('Selected: Available');
                          setState(() {
                            _selectedStatus = 'Available';
                          });
                          Navigator.of(dialogContext).pop();
                        },
                      ),
                      const SizedBox(height: 8),
                      // Sold option
                      _buildFilterOption(
                        label: 'Sold ($soldPlots)',
                        color: const Color(0xFFF44336),
                        isSelected: _selectedStatus == 'Sold',
                        fontSize: optionFontSize,
                        optionHeight: optionHeight,
                        optionVerticalPadding: optionVerticalPadding,
                        textYOffset: optionTextYOffset,
                        onTap: () {
                          print('Selected: Sold');
                          setState(() {
                            _selectedStatus = 'Sold';
                          });
                          Navigator.of(dialogContext).pop();
                        },
                      ),
                      const SizedBox(height: 8),
                      // All option
                      _buildFilterOption(
                        label: 'All ($totalPlots)',
                        color: const Color(0xFF0C8CE9),
                        isSelected: _selectedStatus == 'All Status',
                        fontSize: optionFontSize,
                        optionHeight: optionHeight,
                        optionVerticalPadding: optionVerticalPadding,
                        textYOffset: optionTextYOffset,
                        onTap: () {
                          print('Selected: All');
                          setState(() {
                            _selectedStatus = 'All Status';
                          });
                          Navigator.of(dialogContext).pop();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // Helper widget to build a single filter option
  Widget _buildFilterOption({
    required String label,
    required Color color,
    required bool isSelected,
    required double fontSize,
    required double optionHeight,
    required double optionVerticalPadding,
    required double textYOffset,
    required VoidCallback onTap,
  }) {
    final bool isSold = color.value == const Color(0xFFF44336).value;
    final bool isAvailable = color.value == const Color(0xFF4CAF50).value;
    final bool isPending = color.value == const Color(0xFFFEB12A).value;
    final bool isAll = color.value == const Color(0xFF0C8CE9).value;

    final Color backgroundColor = isSelected
        ? (isPending
            ? const Color(0xFFFAE8C8)
            : isSold
                ? const Color(0xFFF9E5E6)
                : isAvailable
                    ? const Color(0xFFD1EDD2)
                    : const Color(0xFFEFF5F9))
        : Colors.white;

    final List<BoxShadow> optionShadow = isSelected
        ? [
            BoxShadow(
              color: isAll ? const Color(0xFF0C8CE9) : const Color(0x40000000),
              blurRadius: 2,
              offset: const Offset(0, 0),
            ),
          ]
        : const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 2,
              offset: Offset(0, 0),
            ),
          ];

    return GestureDetector(
      onTap: () {
        print('FilterOption tapped: $label, isSelected: $isSelected');
        onTap();
      },
      child: Container(
        height: optionHeight,
        padding: EdgeInsets.symmetric(
          horizontal: 8,
          vertical: optionVerticalPadding,
        ),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(8),
          boxShadow: optionShadow,
        ),
        child: Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: 1,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Transform.translate(
                offset: Offset(0, textYOffset),
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w400,
                    color: Colors.black,
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
  @override
  Widget build(BuildContext context) {
    print('🔨 BUILD: Widget rebuilding. _allPlots count: ${_allPlots.length}');
    final screenWidth = MediaQuery.of(context).size.width;
    final scaleMetrics = AppScaleMetrics.of(context);
    final tabLineWidth = (scaleMetrics?.designViewportWidth ?? screenWidth) +
        (scaleMetrics?.rightOverflowWidth ?? 0.0);
    final extraTabLineWidth =
        tabLineWidth > screenWidth ? tabLineWidth - screenWidth : 0.0;
    final isMobile = screenWidth < 768;
    final isTablet = screenWidth >= 768 && screenWidth < 1024;

    return Stack(
      children: [
        Column(
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
                          'Plot Status',
                          style: GoogleFonts.inter(
                            fontSize: 32,
                            fontWeight: FontWeight.w600,
                            color: Colors.black,
                            height: 40 / 32, // 125% line-height
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Track and update the status of each plot.',
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w400,
                            color: Colors.black.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
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
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _activeContentTab = PlotStatusContentTab.site;
                          });
                        },
                        child: Stack(
                          clipBehavior: Clip.none,
                          alignment: Alignment.topCenter,
                          children: [
                            Container(
                              height: 32,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              decoration:
                                  _activeContentTab == PlotStatusContentTab.site
                                      ? const BoxDecoration(
                                          border: Border(
                                            bottom: BorderSide(
                                              color: Color(0xFF0C8CE9),
                                              width: 2,
                                            ),
                                          ),
                                        )
                                      : null,
                              child: Center(
                                child: Text(
                                  "Site",
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: _activeContentTab ==
                                            PlotStatusContentTab.site
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: _activeContentTab ==
                                            PlotStatusContentTab.site
                                        ? const Color(0xFF0C8CE9)
                                        : const Color(0xFF858585),
                                  ),
                                ),
                              ),
                            ),
                            if (_hasValidationErrors())
                              Positioned(
                                top: -8,
                                child: SvgPicture.asset(
                                  'assets/images/Error_msg.svg',
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
                              ),
                          ],
                        ),
                      ),
                      if (_hasAmenityAreaData) ...[
                        const SizedBox(width: 36),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _activeContentTab =
                                  PlotStatusContentTab.amenityArea;
                            });
                          },
                          child: Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: _activeContentTab ==
                                    PlotStatusContentTab.amenityArea
                                ? const BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(
                                        color: Color(0xFF0C8CE9),
                                        width: 2,
                                      ),
                                    ),
                                  )
                                : null,
                            child: Center(
                              child: Text(
                                'Amenity Area',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: _activeContentTab ==
                                          PlotStatusContentTab.amenityArea
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: _activeContentTab ==
                                          PlotStatusContentTab.amenityArea
                                      ? const Color(0xFF0C8CE9)
                                      : const Color(0xFF858585),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Content - Scrollable
            Expanded(
              child: ScrollbarTheme(
                data: ScrollbarThemeData(
                  thickness: MaterialStateProperty.all(8),
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
                      top: 28,
                      left: 24,
                      right: 24,
                      bottom: 24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildTopOverallSalesAndSiteStatusCards(),
                        const SizedBox(height: 24),
                        // Layouts heading with expand/collapse/zoom controls
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
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
                                // Expand all layouts button
                                Row(
                                  children: [
                                    // Filter button
                                    GestureDetector(
                                      onTap: () {
                                        print(
                                            'Filter button tapped, showing dropdown');
                                        _showFilterDropdown(context);
                                      },
                                      child: Container(
                                        key: _filterButtonKey,
                                        height: 36,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 8),
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          color: Colors.white,
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
                                            SvgPicture.asset(
                                              'assets/images/Filter.svg',
                                              width: 16,
                                              height: 10,
                                              fit: BoxFit.contain,
                                              placeholderBuilder: (context) =>
                                                  const SizedBox(
                                                width: 16,
                                                height: 10,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Filter',
                                              style: GoogleFonts.inter(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w400,
                                                color: Colors.black,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 24),
                                    GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          if (_activeContentTab ==
                                              PlotStatusContentTab
                                                  .amenityArea) {
                                            _isAmenityAreaCollapsed = false;
                                          } else {
                                            _collapsedLayouts.clear();
                                          }
                                        });
                                      },
                                      child: Container(
                                        width: 188,
                                        height: 36,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 4),
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          color: Colors.white,
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
                                          children: [
                                            Expanded(
                                              child: Text(
                                                'Expand all layouts',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w400,
                                                  color: Colors.black,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 16),
                                            SizedBox(
                                              width: 14,
                                              height: 7,
                                              child: Center(
                                                child: SvgPicture.asset(
                                                  'assets/images/Expand.svg',
                                                  width: 14,
                                                  height: 7,
                                                  fit: BoxFit.contain,
                                                  placeholderBuilder:
                                                      (context) =>
                                                          const SizedBox(
                                                    width: 14,
                                                    height: 7,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 24),
                                    // Collapse all layouts button
                                    GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          if (_activeContentTab ==
                                              PlotStatusContentTab
                                                  .amenityArea) {
                                            _isAmenityAreaCollapsed = true;
                                          } else {
                                            _collapsedLayouts.clear();
                                            // Add all layout indices to collapsed set
                                            for (int i = 0;
                                                i < _layouts.length;
                                                i++) {
                                              _collapsedLayouts.add(i);
                                            }
                                          }
                                        });
                                      },
                                      child: Container(
                                        width: 210,
                                        height: 36,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 4),
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          color: Colors.white,
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
                                          children: [
                                            Expanded(
                                              child: Text(
                                                'Collapse all layouts',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w400,
                                                  color: Colors.black,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 16),
                                            SizedBox(
                                              width: 14,
                                              height: 7,
                                              child: Center(
                                                child: SvgPicture.asset(
                                                  'assets/images/Collapse.svg',
                                                  width: 14,
                                                  height: 7,
                                                  fit: BoxFit.contain,
                                                  placeholderBuilder:
                                                      (context) =>
                                                          const SizedBox(
                                                    width: 14,
                                                    height: 7,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 24),
                                    // Zoom label and controls
                                    Text(
                                      'Zoom',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w400,
                                        color: Colors.black,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Zoom out button
                                    GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _tableZoomLevel = _stepTableZoomLevel(
                                              _tableZoomLevel,
                                              increase: false);
                                        });
                                      },
                                      child: Container(
                                        width: 36,
                                        height: 36,
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
                                        child: SvgPicture.asset(
                                          'assets/images/Zoom_out.svg',
                                          width: 36,
                                          height: 36,
                                          fit: BoxFit.contain,
                                          placeholderBuilder: (context) =>
                                              const SizedBox(
                                            width: 36,
                                            height: 36,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Zoom percentage display
                                    SizedBox(
                                      width: 50,
                                      child: Text(
                                        '${(_tableZoomLevel * 100).round()}%',
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w400,
                                          color: Colors.black,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Zoom in button
                                    GestureDetector(
                                      onTap: () {
                                        setState(() {
                                          _tableZoomLevel = _stepTableZoomLevel(
                                              _tableZoomLevel,
                                              increase: true);
                                        });
                                      },
                                      child: Container(
                                        width: 36,
                                        height: 36,
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
                                        child: SvgPicture.asset(
                                          'assets/images/Zoom_in.svg',
                                          width: 36,
                                          height: 36,
                                          fit: BoxFit.contain,
                                          placeholderBuilder: (context) =>
                                              const SizedBox(
                                            width: 36,
                                            height: 36,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        if (_activeContentTab == PlotStatusContentTab.site) ...[
                          if (_isLoading && _layouts.isEmpty)
                            _buildLayoutsLoadingSkeleton()
                          else if (_layouts.isEmpty)
                            Container(
                              width: double.infinity,
                              constraints: const BoxConstraints(minHeight: 320),
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.inbox_outlined,
                                    size: 64,
                                    color: Colors.black.withOpacity(0.3),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    'No layouts found',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inter(
                                      fontSize: 16,
                                      fontWeight: FontWeight.normal,
                                      color: Colors.black.withOpacity(0.5),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Add layouts and plots in the Site tab to view their status here',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.normal,
                                      color: Colors.black.withOpacity(0.4),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            ...List.generate(_layouts.length, (layoutIndex) {
                              return Container(
                                margin: const EdgeInsets.only(bottom: 24),
                                child: _buildLayoutCard(
                                    layoutIndex, _layouts[layoutIndex]),
                              );
                            }),
                        ] else ...[
                          if (!_hasAmenityAreaData)
                            Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.inbox_outlined,
                                    size: 64,
                                    color: Colors.black.withOpacity(0.3),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    'No amenity area found',
                                    style: GoogleFonts.inter(
                                      fontSize: 16,
                                      fontWeight: FontWeight.normal,
                                      color: Colors.black.withOpacity(0.5),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            Container(
                              margin: const EdgeInsets.only(bottom: 24),
                              child: _buildAmenityAreaCard(),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        // Edit dialog overlay
        if (_editingLayoutIndex != null && _editingPlotIndex != null)
          Positioned.fill(
            child: Stack(
              children: [
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                    child: Container(
                      color: Colors.black.withOpacity(0.06),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _closeCurrentEditDialog();
                          });
                        },
                        child: Container(),
                      ),
                    ),
                    _buildEditDialog(),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  // Helper methods for building form fields in the dialog
  Widget _buildSaleDateField() {
    final key = '${_editingLayoutIndex!}_${_editingPlotIndex!}_date';
    if (!_saleDateControllers.containsKey(key)) {
      final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
          as Map<String, dynamic>;
      _saleDateControllers[key] =
          TextEditingController(text: plot['saleDate'] as String? ?? '');
      _saleDateFocusNodes[key] = _createDialogFocusNode();
    }
    final controller = _saleDateControllers[key]!;
    final isEmpty = controller.text.trim().isEmpty;

    return Container(
      height: 40,
      width: 123,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: _saleDateFocusNodes[key]!.hasFocus
                ? const Color(0xFF0C8CE9)
                : (isEmpty ? Colors.red : Colors.black.withOpacity(0.25)),
            blurRadius: 2,
            offset: const Offset(0, 0),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        children: [
          SvgPicture.asset(
            'assets/images/Date.svg',
            width: 16,
            height: 16,
            fit: BoxFit.contain,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: _saleDateFocusNodes[key],
              readOnly: true,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: isEmpty ? const Color(0xFFC1C1C1) : Colors.black,
              ),
              decoration: InputDecoration(
                hintText: 'dd/mm/yyyy',
                hintStyle: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFFC1C1C1),
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onTap: () async {
                final DateTime? picked = await showDatePicker(
                  context: context,
                  initialDate: DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  final formattedDate =
                      '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
                  controller.text = formattedDate;
                  _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
                      ['saleDate'] = formattedDate;
                  setState(() {
                    _syncEditingPlotToAllPlots();
                  });
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAgentField() {
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;
    final currentAgent = plot['agent'] as String? ?? '';
    final isEmpty = currentAgent.isEmpty;

    return Container(
      height: 40,
      width: 265,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: _isAgentDropdownOpen
                ? const Color(0xFF0C8CE9)
                : (isEmpty ? Colors.red : Colors.black.withOpacity(0.25)),
            blurRadius: 2,
            offset: const Offset(0, 0),
            spreadRadius: 0,
          ),
        ],
      ),
      child: GestureDetector(
        key: _agentFieldKey,
        onTap: () {
          setState(() {
            _isAgentDropdownOpen = !_isAgentDropdownOpen;
          });
          if (_isAgentDropdownOpen) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_agentFieldKey.currentContext != null &&
                  _editDialogScrollController.hasClients) {
                Scrollable.ensureVisible(
                  _agentFieldKey.currentContext!,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  alignment: 0.1,
                );
              }
            });
          }
        },
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: isEmpty
                    ? Text(
                        'Select Agent',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: const Color(0xFFC1C1C1),
                        ),
                      )
                    : Text(
                        currentAgent,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Colors.black,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              SvgPicture.asset(
                'assets/images/Drrrop_down.svg',
                width: 14,
                height: 7,
                fit: BoxFit.contain,
                placeholderBuilder: (context) => const SizedBox(
                  width: 14,
                  height: 7,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAgentDropdownInDialog(String currentAgent) {
    final agents = _availableAgents;
    return Container(
      width: 265,
      decoration: BoxDecoration(
        color: Colors.white,
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          GestureDetector(
            onTap: () {
              setState(() {
                _isAgentDropdownOpen = false;
              });
            },
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Select Agent',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  Transform.rotate(
                    angle: 3.14159,
                    child: SvgPicture.asset(
                      'assets/images/Drrrop_down.svg',
                      width: 14,
                      height: 7,
                      fit: BoxFit.contain,
                      placeholderBuilder: (context) => const SizedBox(
                        width: 14,
                        height: 7,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: agents.map((agent) {
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _layouts[_editingLayoutIndex!]['plots']
                          [_editingPlotIndex!]['agent'] = agent;
                      _syncEditingPlotToAllPlots();
                      _isAgentDropdownOpen = false;
                    });
                    _saveLayoutsData();
                  },
                  child: Container(
                    width: double.infinity,
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    margin: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Colors.black.withOpacity(0.1),
                        width: 1,
                      ),
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        agent,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: agent == 'Direct Sale'
                              ? const Color(0xFF0C8CE9)
                              : Colors.black,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSalePriceField() {
    final key = '${_editingLayoutIndex!}_${_editingPlotIndex!}_price';
    if (!_salePriceControllers.containsKey(key)) {
      final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
          as Map<String, dynamic>;
      final salePrice = plot['salePrice'] as String? ?? '';
      _salePriceControllers[key] = TextEditingController(text: salePrice);
      _salePriceFocusNodes[key] = _createDialogFocusNode();
    }
    final controller = _salePriceControllers[key]!;
    final cleaned = controller.text
        .replaceAll(',', '')
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .trim();
    final isEmpty = cleaned.isEmpty || cleaned == '0' || cleaned == '0.00';

    return Container(
      height: 40,
      width: 209,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: _salePriceFocusNodes[key]!.hasFocus
                ? const Color(0xFF0C8CE9)
                : (isEmpty ? Colors.red : Colors.black.withOpacity(0.25)),
            blurRadius: 2,
            offset: const Offset(0, 0),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        children: [
          Text(
            '₹/$_areaUnitSuffix',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: const Color(0xFF5C5C5C),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: _salePriceFocusNodes[key],
              keyboardType: TextInputType.number,
              inputFormatters: [IndianNumberFormatter()],
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isEmpty
                    ? const Color(0xFFADADAD).withOpacity(0.75)
                    : Colors.black,
              ),
              decoration: InputDecoration(
                hintText: '0',
                hintStyle: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFADADAD).withOpacity(0.75),
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (value) {
                final rawValue = value
                    .replaceAll(',', '')
                    .replaceAll('₹', '')
                    .replaceAll(' ', '');
                final formatted =
                    rawValue.isEmpty ? '0.00' : _formatAmount(rawValue);
                setState(() {
                  _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
                      ['salePrice'] = formatted;
                  _syncEditingPlotToAllPlots();
                });
                _saveLayoutsData();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaleValueField() {
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;
    final area =
        double.tryParse((plot['area'] as String? ?? '0').replaceAll(',', '')) ??
            0.0;
    final salePriceStr = (plot['salePrice'] as String? ?? '0')
        .replaceAll(',', '')
        .replaceAll('₹', '')
        .replaceAll(' ', '')
        .trim();
    final salePrice = double.tryParse(salePriceStr) ?? 0.0;
    final saleValue = area * salePrice;

    return Container(
      height: 40,
      width: 178,
      padding: const EdgeInsets.symmetric(horizontal: 8),
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
          Expanded(
            child: Text(
              saleValue == 0
                  ? '0'
                  : _formatAmountNoTrailingZeros(saleValue.toString()),
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBuyerNameField() {
    final key = '${_editingLayoutIndex!}_${_editingPlotIndex!}_buyer';
    if (!_buyerNameControllers.containsKey(key)) {
      final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
          as Map<String, dynamic>;
      _buyerNameControllers[key] =
          TextEditingController(text: plot['buyerName'] as String? ?? '');
      _buyerNameFocusNodes[key] = _createDialogFocusNode();
    }
    final controller = _buyerNameControllers[key]!;
    final isEmpty = controller.text.trim().isEmpty;

    return Container(
      height: 40,
      width: 304,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: _buyerNameFocusNodes[key]!.hasFocus
                ? const Color(0xFF0C8CE9)
                : (isEmpty ? Colors.red : Colors.black.withOpacity(0.25)),
            blurRadius: 2,
            offset: const Offset(0, 0),
            spreadRadius: 0,
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        focusNode: _buyerNameFocusNodes[key],
        textAlignVertical: TextAlignVertical.center,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: isEmpty ? const Color(0xFFC1C1C1) : Colors.black,
        ),
        decoration: InputDecoration(
          hintText: 'Enter buyer\'s name',
          hintStyle: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: const Color(0xFFC1C1C1),
          ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
        onChanged: (value) {
          setState(() {
            _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
                ['buyerName'] = value;
            _syncEditingPlotToAllPlots();
          });
          _saveLayoutsData();
        },
      ),
    );
  }

  Widget _buildBuyerContactNumberField() {
    final key = '${_editingLayoutIndex!}_${_editingPlotIndex!}_buyer_contact';
    if (!_buyerContactControllers.containsKey(key)) {
      final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
          as Map<String, dynamic>;
      _buyerContactControllers[key] = TextEditingController(
          text: (plot['buyerContactNumber'] as String? ?? '').trim());
      _buyerContactFocusNodes[key] = _createDialogFocusNode();
    }
    final controller = _buyerContactControllers[key]!;
    final isEmpty = controller.text.trim().isEmpty;

    return Container(
      height: 40,
      width: 304,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: _buyerContactFocusNodes[key]!.hasFocus
                ? const Color(0xFF0C8CE9)
                : (isEmpty ? Colors.red : Colors.black.withOpacity(0.25)),
            blurRadius: 2,
            offset: const Offset(0, 0),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        children: [
          Text(
            '+91',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.black,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: _buyerContactFocusNodes[key],
              textAlignVertical: TextAlignVertical.center,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: isEmpty ? const Color(0xFFC1C1C1) : Colors.black,
              ),
              decoration: InputDecoration(
                hintText: '0',
                hintStyle: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFC1C1C1),
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onChanged: (value) {
                setState(() {
                  _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
                      ['buyerContactNumber'] = value;
                  _syncEditingPlotToAllPlots();
                });
                _saveLayoutsData();
              },
            ),
          ),
        ],
      ),
    );
  }

  // Payment methods list
  static const List<Map<String, String>> _paymentMethods = [
    {'name': 'Cash', 'icon': 'assets/images/Cash.svg'},
    {'name': 'Cheque', 'icon': 'assets/images/Cheque.svg'},
    {
      'name': 'Bank Transfer (NEFT / RTGS / IMPS)',
      'icon': 'assets/images/Bank.svg'
    },
    {'name': 'UPI', 'icon': 'assets/images/UPI.svg'},
    {'name': 'Demand Draft (DD)', 'icon': 'assets/images/Demand_draft.svg'},
    {'name': 'Other', 'icon': 'assets/images/Other.svg'},
  ];

  String? _getPaymentMethodIcon(String? paymentMethod) {
    if (paymentMethod == null || paymentMethod.isEmpty) return null;
    final method = _paymentMethods.firstWhere(
      (m) => m['name'] == paymentMethod,
      orElse: () => {},
    );
    return method['icon'];
  }

  Future<Uint8List?>? _upiIconBytesFuture;

  Future<Uint8List?> _loadUpiIconBytes() {
    _upiIconBytesFuture ??= _extractUpiIconBytes();
    return _upiIconBytesFuture!;
  }

  Future<Uint8List?> _extractUpiIconBytes() async {
    try {
      final svg = await rootBundle.loadString('assets/images/UPI.svg');
      final match = RegExp(r'data:image\/png;base64,([^"]+)').firstMatch(svg);
      if (match == null) return null;
      return base64Decode(match.group(1)!);
    } catch (_) {
      return null;
    }
  }

  Widget _buildPaymentMethodIcon(String iconPath, {double size = 16}) {
    if (iconPath == 'assets/images/UPI.svg') {
      return FutureBuilder<Uint8List?>(
        future: _loadUpiIconBytes(),
        builder: (context, snapshot) {
          if (snapshot.hasData && snapshot.data != null) {
            return Image.memory(
              snapshot.data!,
              width: size,
              height: size,
              fit: BoxFit.contain,
            );
          }
          return SizedBox(width: size, height: size);
        },
      );
    }

    return SvgPicture.asset(
      iconPath,
      width: size,
      height: size,
      fit: BoxFit.contain,
      placeholderBuilder: (context) => SizedBox(
        width: size,
        height: size,
      ),
    );
  }

  Widget _buildPaymentMethodContent() {
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;

    // Initialize payments list if it doesn't exist
    if (plot['payments'] == null) {
      // Migrate old single payment to list format
      final oldPaymentMethod = plot['paymentMethod'] as String? ?? '';
      if (oldPaymentMethod.isNotEmpty) {
        plot['payments'] = [
          {
            'paymentMethod': oldPaymentMethod,
            'paymentAmount': plot['paymentAmount'] ?? '0',
            'chequeDate': plot['chequeDate'] ?? '',
            'chequeNumber': plot['chequeNumber'] ?? '',
            'transferDate': plot['transferDate'] ?? '',
            'transactionId': plot['transactionId'] ?? '',
            'paymentDate': plot['paymentDate'] ?? '',
            'upiTransactionId': plot['upiTransactionId'] ?? '',
            'upiApp': plot['upiApp'] ?? '',
            'ddDate': plot['ddDate'] ?? '',
            'ddNumber': plot['ddNumber'] ?? '',
            'otherPaymentDate': plot['otherPaymentDate'] ?? '',
            'otherPaymentMethod': plot['otherPaymentMethod'] ?? '',
            'referenceNumber': plot['referenceNumber'] ?? '',
            'bankName': plot['bankName'] ?? '',
          }
        ];
      } else {
        plot['payments'] = [];
      }
    }

    final payments = plot['payments'] as List<dynamic>;

    // If no payments, show at least one empty payment block so user can select payment method
    if (payments.isEmpty) {
      payments.add({
        'paymentMethod': '',
        'paymentAmount': '0',
        'chequeDate': '',
        'chequeNumber': '',
        'transferDate': '',
        'transactionId': '',
        'paymentDate': '',
        'upiTransactionId': '',
        'upiApp': '',
        'ddDate': '',
        'ddNumber': '',
        'otherPaymentDate': '',
        'otherPaymentMethod': '',
        'referenceNumber': '',
        'bankName': '',
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Render each payment
        ...payments.asMap().entries.map((entry) {
          final index = entry.key;
          final payment = entry.value as Map<String, dynamic>;
          return _buildSinglePaymentBlock(index, payment);
        }).toList(),
      ],
    );
  }

  Widget _buildSinglePaymentBlock(
      int paymentIndex, Map<String, dynamic> payment) {
    final currentPaymentMethod = payment['paymentMethod'] as String? ?? '';
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;
    final payments = plot['payments'] as List<dynamic>? ?? const [];
    final canRemovePayment = payments.length > 1;

    return Container(
      width: 321,
      margin: EdgeInsets.only(top: paymentIndex > 0 ? 16 : 0),
      padding: const EdgeInsets.all(12),
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    '${paymentIndex + 1}. Payment Method ',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                  Text(
                    '*',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.red,
                    ),
                  ),
                ],
              ),
              if (canRemovePayment)
                GestureDetector(
                  onTap: () => _removePaymentBlock(paymentIndex),
                  child: Container(
                    width: 85,
                    height: 36,
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
                        'Remove',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFFFF0000),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _buildPaymentMethodField(paymentIndex),
          // Show fields based on payment method
          if (currentPaymentMethod.isNotEmpty) ...[
            const SizedBox(height: 24),
            // Amount field (common to all payment methods)
            _buildAmountField(paymentIndex),
            // Payment method specific fields
            if (currentPaymentMethod == 'Cheque') ...[
              const SizedBox(height: 24),
              _buildChequeDateField(paymentIndex),
              const SizedBox(height: 24),
              _buildChequeNumberField(paymentIndex),
              const SizedBox(height: 24),
              _buildBankNameField(paymentIndex),
            ] else if (currentPaymentMethod ==
                'Bank Transfer (NEFT / RTGS / IMPS)') ...[
              const SizedBox(height: 24),
              _buildTransferDateField(paymentIndex),
              const SizedBox(height: 24),
              _buildTransactionIdField(paymentIndex),
              const SizedBox(height: 24),
              _buildBankNameField(paymentIndex),
            ] else if (currentPaymentMethod == 'UPI') ...[
              const SizedBox(height: 24),
              _buildPaymentDateField(paymentIndex),
              const SizedBox(height: 24),
              _buildUpiTransactionIdField(paymentIndex),
              const SizedBox(height: 24),
              _buildUpiAppField(paymentIndex),
            ] else if (currentPaymentMethod == 'Demand Draft (DD)') ...[
              const SizedBox(height: 24),
              _buildDDDateField(paymentIndex),
              const SizedBox(height: 24),
              _buildDDNumberField(paymentIndex),
              const SizedBox(height: 24),
              _buildBankNameField(paymentIndex),
            ] else if (currentPaymentMethod == 'Other') ...[
              const SizedBox(height: 24),
              _buildOtherPaymentDateField(paymentIndex),
              const SizedBox(height: 24),
              _buildOtherPaymentMethodField(paymentIndex),
              const SizedBox(height: 24),
              _buildReferenceNumberField(paymentIndex),
            ] else if (currentPaymentMethod == 'Cash') ...[
              const SizedBox(height: 24),
              _buildPaymentDateField(paymentIndex),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildAmountField([int paymentIndex = 0]) {
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;
    if (plot['payments'] == null) {
      plot['payments'] = [];
    }
    final payments = plot['payments'] as List<dynamic>;
    if (paymentIndex >= payments.length) {
      payments.add({
        'paymentMethod': '',
        'paymentAmount': '0',
      });
    }
    final payment = payments[paymentIndex] as Map<String, dynamic>;
    final plotKey = '${_editingLayoutIndex}_${_editingPlotIndex}_$paymentIndex';

    // Initialize controller if it doesn't exist
    if (_paymentAmountControllers[plotKey] == null) {
      final amount = payment['paymentAmount'] as String? ?? '0';
      final amountNum =
          double.tryParse(amount.toString().replaceAll(',', '')) ?? 0.0;
      _paymentAmountControllers[plotKey] = TextEditingController(
        text: amountNum == 0.0 ? '' : amount.toString(),
      );
    }
    _paymentAmountFocusNodes.putIfAbsent(plotKey, _createDialogFocusNode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Amount (₹) ',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
            ),
            Text(
              '*',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.red,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Builder(
          builder: (context) {
            final controller = _paymentAmountControllers[plotKey];
            final hasValue = controller != null &&
                controller.text.isNotEmpty &&
                controller.text
                        .replaceAll(',', '')
                        .replaceAll('₹', '')
                        .replaceAll(' ', '')
                        .trim() !=
                    '' &&
                controller.text
                        .replaceAll(',', '')
                        .replaceAll('₹', '')
                        .replaceAll(' ', '')
                        .trim() !=
                    '0' &&
                controller.text
                        .replaceAll(',', '')
                        .replaceAll('₹', '')
                        .replaceAll(' ', '')
                        .trim() !=
                    '0.00';

            return Container(
              width: 178,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: _paymentAmountFocusNodes[plotKey]!.hasFocus
                        ? const Color(0xFF0C8CE9)
                        : (hasValue
                            ? Colors.black.withOpacity(0.25)
                            : Colors.red),
                    blurRadius: 2,
                    offset: const Offset(0, 0),
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '₹',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF5D5D5D),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DecimalInputField(
                      controller: _paymentAmountControllers[plotKey]!,
                      focusNode: _paymentAmountFocusNodes[plotKey]!,
                      hintText: '0',
                      inputFormatters: [
                        IndianNumberFormatter(maxIntegerDigits: 11)
                      ],
                      onTap: () {
                        // Clear '0.00' when field is tapped
                        final cleaned = _paymentAmountControllers[plotKey]!
                            .text
                            .replaceAll(',', '')
                            .replaceAll('₹', '')
                            .replaceAll(' ', '')
                            .trim();
                        if (cleaned == '0' || cleaned == '0.00') {
                          _paymentAmountControllers[plotKey]!.text = '';
                          _paymentAmountControllers[plotKey]!.selection =
                              TextSelection.collapsed(offset: 0);
                          setState(() {});
                        }
                      },
                      onChanged: (value) {
                        // Remove commas for storage (for real-time calculations)
                        final rawValue = value
                            .replaceAll(',', '')
                            .replaceAll('₹', '')
                            .replaceAll(' ', '');
                        setState(() {
                          payment['paymentAmount'] =
                              rawValue.isEmpty ? '0.00' : rawValue;
                          _syncEditingPlotToAllPlots();
                        });
                        _saveLayoutsData();
                        // Trigger rebuild to update shadow color
                        setState(() {});
                      },
                      onEditingComplete: () {
                        // Remove commas before formatting
                        final cleaned = _paymentAmountControllers[plotKey]!
                            .text
                            .replaceAll(',', '')
                            .replaceAll('₹', '')
                            .replaceAll(' ', '');
                        final formatted = _formatAmount(cleaned);
                        FocusScope.of(context).unfocus();
                        _paymentAmountControllers[plotKey]!.value =
                            TextEditingValue(
                          text: formatted,
                          selection:
                              TextSelection.collapsed(offset: formatted.length),
                        );
                        setState(() {
                          payment['paymentAmount'] =
                              formatted.replaceAll(',', '');
                          _syncEditingPlotToAllPlots();
                        });
                        _saveLayoutsData();
                      },
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildDateField(String label, String fieldKey, String placeholder,
      [int paymentIndex = 0]) {
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;
    if (plot['payments'] == null) {
      plot['payments'] = [];
    }
    final payments = plot['payments'] as List<dynamic>;
    if (paymentIndex >= payments.length) {
      payments.add({
        'paymentMethod': '',
        'paymentAmount': '0',
      });
    }
    final payment = payments[paymentIndex] as Map<String, dynamic>;
    final dateValue = payment[fieldKey] as String? ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
        GestureDetector(
          onTap: () async {
            final DateTime? picked = await showDatePicker(
              context: context,
              initialDate: dateValue.isNotEmpty
                  ? _parseDate(dateValue) ?? DateTime.now()
                  : DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (picked != null) {
              final formattedDate =
                  '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
              setState(() {
                payment[fieldKey] = formattedDate;
                _syncEditingPlotToAllPlots();
              });
              _saveLayoutsData();
            }
          },
          child: Container(
            width: 128,
            height: 40,
            padding: const EdgeInsets.all(8),
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
              children: [
                SvgPicture.asset(
                  'assets/images/Date.svg',
                  width: 16,
                  height: 16,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      dateValue.isEmpty ? placeholder : dateValue,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: dateValue.isEmpty
                            ? const Color(0xFFC1C1C1)
                            : Colors.black,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTextInputField(String label, String fieldKey, String placeholder,
      {double? width, int paymentIndex = 0}) {
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;
    if (plot['payments'] == null) {
      plot['payments'] = [];
    }
    final payments = plot['payments'] as List<dynamic>;
    if (paymentIndex >= payments.length) {
      payments.add({
        'paymentMethod': '',
        'paymentAmount': '0',
      });
    }
    final payment = payments[paymentIndex] as Map<String, dynamic>;
    final value = payment[fieldKey] as String? ?? '';
    final controlKey =
        '${_editingLayoutIndex}_${_editingPlotIndex}_${paymentIndex}_$fieldKey';
    final controller = _paymentTextControllers.putIfAbsent(
      controlKey,
      () => TextEditingController(text: value),
    );
    if (!(_paymentTextFocusNodes[controlKey]?.hasFocus ?? false) &&
        controller.text != value) {
      controller.text = value;
    }
    final focusNode =
        _paymentTextFocusNodes.putIfAbsent(controlKey, _createDialogFocusNode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
          width: width ?? double.infinity,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: focusNode.hasFocus
                    ? const Color(0xFF0C8CE9)
                    : Colors.black.withOpacity(0.25),
                blurRadius: 2,
                offset: const Offset(0, 0),
                spreadRadius: 0,
              ),
            ],
          ),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            textAlignVertical: TextAlignVertical.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: controller.text.isEmpty
                  ? const Color.fromARGB(191, 173, 173, 173)
                  : Colors.black,
            ),
            decoration: InputDecoration(
              hintText: placeholder,
              hintStyle: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color.fromARGB(191, 173, 173, 173),
              ),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (text) {
              setState(() {
                payment[fieldKey] = text;
                _syncEditingPlotToAllPlots();
              });
              _saveLayoutsData();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildChequeDateField([int paymentIndex = 0]) =>
      _buildDateField('Cheque Date', 'chequeDate', 'dd/mm/yyyy', paymentIndex);
  Widget _buildTransferDateField([int paymentIndex = 0]) => _buildDateField(
      'Transfer Date', 'transferDate', 'dd/mm/yyyy', paymentIndex);
  Widget _buildPaymentDateField([int paymentIndex = 0]) => _buildDateField(
      'Payment Date', 'paymentDate', 'dd/mm/yyyy', paymentIndex);
  Widget _buildDDDateField([int paymentIndex = 0]) =>
      _buildDateField('DD Date', 'ddDate', 'dd/mm/yyyy', paymentIndex);
  Widget _buildOtherPaymentDateField([int paymentIndex = 0]) => _buildDateField(
      'DD Date', 'otherPaymentDate', 'dd/mm/yyyy', paymentIndex);

  Widget _buildChequeNumberField([int paymentIndex = 0]) =>
      _buildTextInputField(
          'Cheque Number', 'chequeNumber', 'Enter Cheque Number',
          width: 175, paymentIndex: paymentIndex);
  Widget _buildTransactionIdField([int paymentIndex = 0]) =>
      _buildTextInputField(
          'Transaction ID / UTR', 'transactionId', 'Enter Transaction ID / UTR',
          width: 273, paymentIndex: paymentIndex);
  Widget _buildUpiTransactionIdField([int paymentIndex = 0]) =>
      _buildTextInputField(
          'UPI Transaction ID', 'upiTransactionId', 'Enter UPI Transaction ID',
          width: 273, paymentIndex: paymentIndex);
  Widget _buildDDNumberField([int paymentIndex = 0]) =>
      _buildTextInputField('DD Number', 'ddNumber', 'Enter DD Number',
          width: 273, paymentIndex: paymentIndex);
  Widget _buildReferenceNumberField(
          [int paymentIndex = 0]) =>
      _buildTextInputField(
          'Reference Number', 'referenceNumber', 'Enter Reference Number',
          width: 273, paymentIndex: paymentIndex);

  Widget _buildBankNameField([int paymentIndex = 0]) {
    return _buildTextInputField(
      'Bank Name',
      'bankName',
      'Enter a bank name',
      width: 304,
      paymentIndex: paymentIndex,
    );
  }

  Widget _buildUpiAppField([int paymentIndex = 0]) {
    return _buildTextInputField(
      'UPI App',
      'upiApp',
      'Enter UPI App',
      width: 304,
      paymentIndex: paymentIndex,
    );
  }

  Widget _buildOtherPaymentMethodField([int paymentIndex = 0]) {
    return _buildTextInputField(
      'Payment Method',
      'otherPaymentMethod',
      'Enter Payment Method',
      width: 304,
      paymentIndex: paymentIndex,
    );
  }

  DateTime? _parseDate(String dateStr) {
    try {
      // Try DD/MM/YYYY format
      final parts = dateStr.split('/');
      if (parts.length == 3) {
        final day = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final year = int.tryParse(parts[2]);
        if (day != null && month != null && year != null) {
          return DateTime(year, month, day);
        }
      }
      // Try YYYY-MM-DD format
      final isoParts = dateStr.split('-');
      if (isoParts.length == 3) {
        final year = int.tryParse(isoParts[0]);
        final month = int.tryParse(isoParts[1]);
        final day = int.tryParse(isoParts[2]);
        if (year != null && month != null && day != null) {
          return DateTime(year, month, day);
        }
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  Widget _buildPaymentMethodField([int paymentIndex = 0]) {
    final plot = _layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]
        as Map<String, dynamic>;
    if (plot['payments'] == null) {
      plot['payments'] = [];
    }
    final payments = plot['payments'] as List<dynamic>;
    if (paymentIndex >= payments.length) {
      payments.add({
        'paymentMethod': '',
        'paymentAmount': '0',
      });
    }
    final payment = payments[paymentIndex] as Map<String, dynamic>;
    final currentPaymentMethod = payment['paymentMethod'] as String? ?? '';
    final isEmpty = currentPaymentMethod.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 325,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 4),
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
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _isPaymentMethodDropdownOpen =
                          !_isPaymentMethodDropdownOpen;
                      _currentPaymentIndex = paymentIndex;
                    });
                    // Scroll to show the dropdown
                    if (_isPaymentMethodDropdownOpen) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (_paymentMethodFieldKey.currentContext != null &&
                            _editDialogScrollController.hasClients) {
                          Scrollable.ensureVisible(
                            _paymentMethodFieldKey.currentContext!,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                            alignment: 0.1,
                          );
                        }
                      });
                    }
                  },
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: isEmpty
                              ? Text(
                                  'Select Payment Method',
                                  style: GoogleFonts.inter(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: const Color(0xFFC1C1C1),
                                  ),
                                )
                              : Row(
                                  children: [
                                    if (_getPaymentMethodIcon(
                                            currentPaymentMethod) !=
                                        null)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(right: 16),
                                        child: _buildPaymentMethodIcon(
                                          _getPaymentMethodIcon(
                                            currentPaymentMethod,
                                          )!,
                                        ),
                                      ),
                                    Flexible(
                                      child: Text(
                                        currentPaymentMethod,
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.black,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                        SvgPicture.asset(
                          'assets/images/Drrrop_down.svg',
                          width: 14,
                          height: 7,
                          fit: BoxFit.contain,
                          placeholderBuilder: (context) => const SizedBox(
                            width: 14,
                            height: 7,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Dropdown inside the modal
        if (_isPaymentMethodDropdownOpen &&
            _currentPaymentIndex == paymentIndex) ...[
          const SizedBox(height: 4),
          _buildPaymentMethodDropdown(currentPaymentMethod),
        ],
      ],
    );
  }

  Widget _buildPaymentMethodDropdown(String currentPaymentMethod) {
    return Container(
      width: 325,
      decoration: BoxDecoration(
        color: Colors.white,
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          GestureDetector(
            onTap: () {
              setState(() {
                _isPaymentMethodDropdownOpen = false;
              });
            },
            child: Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Select Payment Method',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _isPaymentMethodDropdownOpen = false;
                      });
                    },
                    child: Transform.rotate(
                      angle:
                          3.14159, // 180 degrees in radians (pointing up when dropdown is open)
                      child: SvgPicture.asset(
                        'assets/images/Drrrop_down.svg',
                        width: 14,
                        height: 7,
                        fit: BoxFit.contain,
                        placeholderBuilder: (context) => const SizedBox(
                          width: 14,
                          height: 7,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Payment method options
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _paymentMethods.asMap().entries.map((entry) {
                final index = entry.key;
                final method = entry.value;
                final methodName = method['name']!;
                final iconPath = method['icon']!;
                final isSelected = methodName == currentPaymentMethod;
                final isLast = index == _paymentMethods.length - 1;

                return Container(
                  margin: EdgeInsets.only(
                    bottom: isLast ? 0 : 12,
                    left: 8,
                    right: 8,
                    top: index == 0 ? 8 : 0,
                  ),
                  child: GestureDetector(
                    onTap: () {
                      final plot = _layouts[_editingLayoutIndex!]['plots']
                          [_editingPlotIndex!] as Map<String, dynamic>;
                      if (plot['payments'] == null) {
                        plot['payments'] = [];
                      }
                      final payments = plot['payments'] as List<dynamic>;
                      if (_currentPaymentIndex >= payments.length) {
                        payments.add({
                          'paymentMethod': methodName,
                          'paymentAmount': '0',
                        });
                      } else {
                        (payments[_currentPaymentIndex]
                                as Map<String, dynamic>)['paymentMethod'] =
                            methodName;
                      }
                      setState(() {
                        _syncEditingPlotToAllPlots();
                        _isPaymentMethodDropdownOpen = false;
                      });
                      _saveLayoutsData();
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
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
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: _buildPaymentMethodIcon(iconPath),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              methodName,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Colors.black,
                              ),
                              textAlign: TextAlign.left,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  void _showAgentDropdownInDialog(
      BuildContext context, String currentAgent, GlobalKey agentKey) {
    final RenderBox? renderBox =
        agentKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final agents = _availableAgents;
    final overlay = Overlay.of(context);
    final offset = renderBox.localToGlobal(Offset.zero);

    late OverlayEntry overlayEntry;
    late OverlayEntry backdropEntry;

    void closeDropdown() {
      overlayEntry.remove();
      backdropEntry.remove();
    }

    backdropEntry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: GestureDetector(
          onTap: closeDropdown,
          child: Container(color: Colors.transparent),
        ),
      ),
    );

    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx,
        top: offset.dy + renderBox.size.height + 4,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 265,
            decoration: BoxDecoration(
              color: Colors.white,
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                GestureDetector(
                  onTap: closeDropdown,
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Select Agent',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: closeDropdown,
                          child: Transform.rotate(
                            angle: 3.14159,
                            child: SvgPicture.asset(
                              'assets/images/Drrrop_down.svg',
                              width: 14,
                              height: 7,
                              fit: BoxFit.contain,
                              placeholderBuilder: (context) => const SizedBox(
                                width: 14,
                                height: 7,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Options
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: agents.map((agent) {
                      final isSelected = agent == currentAgent;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _layouts[_editingLayoutIndex!]['plots']
                                [_editingPlotIndex!]['agent'] = agent;
                            _syncEditingPlotToAllPlots();
                          });
                          _saveLayoutsData();
                          closeDropdown();

                          // Scroll to show the updated field
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (_editDialogScrollController.hasClients) {
                              _editDialogScrollController.animateTo(
                                _editDialogScrollController.position.pixels,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            }
                          });
                        },
                        child: Container(
                          width: double.infinity,
                          height: 40,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          margin: const EdgeInsets.only(
                              left: 8, right: 8, bottom: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: Colors.black.withOpacity(0.1),
                              width: 1,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              agent,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: agent == 'Direct Sale'
                                    ? const Color(0xFF0C8CE9)
                                    : Colors.black,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    overlay.insert(backdropEntry);
    overlay.insert(overlayEntry);

    // Scroll to show the dropdown
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_editDialogScrollController.hasClients) {
        Scrollable.ensureVisible(
          agentKey.currentContext!,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.3,
        );
      }
    });
  }

  Widget _buildEditDialog() {
    if (_editingLayoutIndex == null || _editingPlotIndex == null) {
      return const SizedBox.shrink();
    }

    final layout = _layouts[_editingLayoutIndex!];
    final plotsRaw = layout['plots'] as List<dynamic>? ?? const [];
    if (_editingPlotIndex! < 0 || _editingPlotIndex! >= plotsRaw.length) {
      return const SizedBox.shrink();
    }
    final plotRaw = plotsRaw[_editingPlotIndex!];
    if (plotRaw is! Map<String, dynamic>) {
      return const SizedBox.shrink();
    }

    // Get fresh plot data to ensure we have the latest status
    final plot = plotRaw;
    final layoutName =
        layout['name'] as String? ?? 'Layout ${_editingLayoutIndex! + 1}';
    final plotNumber = plot['plotNumber'] as String? ?? '';
    final area = plot['area'] as String? ?? '0';
    // Read status fresh from the plot data
    final statusData = plot['status'];
    final status = _parsePlotStatus(statusData);
    final effectiveStatus = _editingStatus ?? status;
    final isSoldLikeStatus = _isSoldLikeStatus(effectiveStatus);
    final statusColor = _getStatusColor(effectiveStatus);
    final statusText = _getStatusString(effectiveStatus);
    final statusBackgroundColor = _getStatusBackgroundColor(effectiveStatus);

    final screenHeight = MediaQuery.of(context).size.height;
    final maxDialogHeight = screenHeight * 0.9;

    return Container(
      width: 492,
      constraints: BoxConstraints(
        maxHeight: maxDialogHeight,
      ),
      margin: const EdgeInsets.only(top: 56, right: 24, bottom: 16, left: 24),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F3F3),
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
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: _handleEditDialogTapDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 2,
                    offset: const Offset(0, 0),
                    spreadRadius: 0,
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Plot Status Details',
                    style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Colors.black,
                    ),
                  ),
                  Row(
                    children: [
                      // Discard button
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _closeCurrentEditDialog();
                          });
                        },
                        child: Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
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
                              'Discard',
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.normal,
                                color: const Color(0xFF0C8CE9),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Update button
                      GestureDetector(
                        onTap: () async {
                          print('💾 UPDATE BUTTON: Clicked');
                          if (_isEditingAmenityArea) {
                            await _saveAmenityAreaEditFromDialog();
                            print('💾 UPDATE BUTTON: Amenity update complete');
                            return;
                          }
                          // Close dialog immediately on Update click.
                          setState(() {
                            _syncEditingPlotToAllPlots();
                            _rebuildAllPlotsFromLayouts();
                            _closeCurrentEditDialog();
                          });
                          // Save all changes in background after closing dialog.
                          await _saveLayoutsData();
                          await _savePlotsToDatabase();
                          print('💾 UPDATE BUTTON: Complete');
                        },
                        child: Container(
                          height: 36,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
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
                            children: [
                              Text(
                                'Update',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.normal,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 8),
                              SvgPicture.asset(
                                'assets/images/Update.svg',
                                width: 14,
                                height: 10,
                                fit: BoxFit.contain,
                                placeholderBuilder: (context) => const SizedBox(
                                  width: 14,
                                  height: 10,
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
            // Content
            Flexible(
              child: SingleChildScrollView(
                controller: _editDialogScrollController,
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 17),
                    // Layout, Plot Number, Area
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Layout:',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.black.withOpacity(0.75),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                height: 36,
                                alignment: Alignment.centerLeft,
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
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text(
                                'Plot Number:',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.black.withOpacity(0.75),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                height: 36,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  plotNumber,
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.normal,
                                    color: Colors.black,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text(
                                'Area:',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.black.withOpacity(0.75),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                height: 36,
                                child: Row(
                                  children: [
                                    Text(
                                      _formatAmountNoTrailingZeros(area),
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.normal,
                                        color: Colors.black,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
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
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Status
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                'Status ',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.black,
                                ),
                              ),
                              Text(
                                '*',
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.red,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              GestureDetector(
                                key: _statusDropdownKey,
                                onTap: () {
                                  print(
                                      '🎯 DROPDOWN TOGGLE: Clicked status field. Current state: $_isStatusDropdownOpen');
                                  setState(() {
                                    _isStatusDropdownOpen =
                                        !_isStatusDropdownOpen;
                                    print(
                                        '🎯 DROPDOWN TOGGLE: New state: $_isStatusDropdownOpen');
                                  });
                                },
                                child: Container(
                                  width: 194,
                                  height: 40,
                                  padding:
                                      const EdgeInsets.only(left: 4, right: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.95),
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
                                  child: Builder(
                                    key: ValueKey(
                                        'status_button_${_editingLayoutIndex}_${_editingPlotIndex}_${_layouts[_editingLayoutIndex!]['plots'][_editingPlotIndex!]['status']}'),
                                    builder: (context) {
                                      // Read status fresh each time widget rebuilds
                                      final currentPlot =
                                          _layouts[_editingLayoutIndex!]
                                                  ['plots'][_editingPlotIndex!]
                                              as Map<String, dynamic>;
                                      final currentStatusData =
                                          currentPlot['status'];
                                      final currentStatus =
                                          _parsePlotStatus(currentStatusData);
                                      final effectiveCurrentStatus =
                                          _editingStatus ?? currentStatus;
                                      final currentStatusColor =
                                          _getStatusDropdownDotColor(
                                              effectiveCurrentStatus);
                                      final currentStatusText =
                                          _getStatusDropdownLabel(
                                              effectiveCurrentStatus);
                                      final currentStatusBackgroundColor =
                                          _getStatusDropdownChipBackgroundColor(
                                              effectiveCurrentStatus);

                                      return Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Container(
                                            width: 152,
                                            height: 28,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8),
                                            decoration: BoxDecoration(
                                              color:
                                                  currentStatusBackgroundColor,
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
                                              children: [
                                                Container(
                                                  width: 16,
                                                  height: 16,
                                                  decoration: BoxDecoration(
                                                    color: currentStatusColor,
                                                    shape: BoxShape.circle,
                                                    border: Border.all(
                                                      color: Colors.white,
                                                      width: 1,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  currentStatusText,
                                                  style: GoogleFonts.inter(
                                                    fontSize: 14,
                                                    fontWeight:
                                                        FontWeight.normal,
                                                    color: Colors.black,
                                                    height: 1.2,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          SvgPicture.asset(
                                            'assets/images/Drrrop_down.svg',
                                            width: 14,
                                            height: 7,
                                            fit: BoxFit.contain,
                                            placeholderBuilder: (context) =>
                                                const SizedBox(
                                              width: 14,
                                              height: 7,
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                              // Dropdown menu - now inline instead of positioned
                              if (_isStatusDropdownOpen)
                                const SizedBox(height: 8),
                              if (_isStatusDropdownOpen)
                                Container(
                                  key: _statusDropdownMenuKey,
                                  width: 194,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
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
                                  child: Builder(
                                    builder: (context) {
                                      // Read current status fresh for dropdown options
                                      final currentPlotForDropdown =
                                          _layouts[_editingLayoutIndex!]
                                                  ['plots'][_editingPlotIndex!]
                                              as Map<String, dynamic>;
                                      final currentStatusDataForDropdown =
                                          currentPlotForDropdown['status'];
                                      final currentStatusForDropdown =
                                          _parsePlotStatus(
                                              currentStatusDataForDropdown);
                                      final effectiveStatusForDropdown =
                                          _editingStatus ??
                                              currentStatusForDropdown;

                                      print(
                                          '📋 DROPDOWN OPTIONS: effectiveStatus=$effectiveStatusForDropdown');
                                      final optionsList = <PlotStatus>[
                                        PlotStatus.reserved,
                                        PlotStatus.available,
                                        PlotStatus.sold,
                                      ];
                                      final dropdownOptions = optionsList
                                          .where((status) =>
                                              status !=
                                              effectiveStatusForDropdown)
                                          .toList();
                                      print(
                                          '📋 DROPDOWN OPTIONS: Creating ${optionsList.length} options: $optionsList');

                                      return Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: List.generate(
                                            dropdownOptions.length, (index) {
                                          final statusOption =
                                              dropdownOptions[index];
                                          print(
                                              '📋 DROPDOWN OPTIONS: Rendering option $statusOption');
                                          final optionColor =
                                              _getStatusDropdownDotColor(
                                                  statusOption);
                                          final optionText =
                                              _getStatusDropdownLabel(
                                                  statusOption);
                                          final isLastOption = index ==
                                              dropdownOptions.length - 1;

                                          return Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Material(
                                                color: Colors.transparent,
                                                child: InkWell(
                                                  onTap: () async {
                                                    print(
                                                        '📝 STATUS CHANGE: ✅✅✅ INKWELL TAPPED! User selected $statusOption');
                                                    // Get fresh references to ensure we're updating the right data
                                                    final currentLayout =
                                                        _layouts[
                                                            _editingLayoutIndex!];
                                                    final currentPlot =
                                                        currentLayout['plots'][
                                                                _editingPlotIndex!]
                                                            as Map<String,
                                                                dynamic>;
                                                    final plotNumber =
                                                        currentPlot['plotNumber']
                                                                as String? ??
                                                            '';
                                                    final layoutName =
                                                        currentLayout['name']
                                                                as String? ??
                                                            '';
                                                    print(
                                                        '📝 STATUS CHANGE: Updating layout=$layoutName, plot=$plotNumber to $statusOption');

                                                    // Use the same update pattern as _updatePlotStatus
                                                    setState(() {
                                                      print(
                                                          '📝 STATUS CHANGE: Inside setState');
                                                      _editingStatus =
                                                          statusOption;
                                                      // Directly update the plot we're editing (fastest way)
                                                      _layouts[_editingLayoutIndex!]
                                                                  ['plots'][
                                                              _editingPlotIndex!]
                                                          [
                                                          'status'] = statusOption;

                                                      // First update _allPlots (same as table update)
                                                      for (var plotData
                                                          in _allPlots) {
                                                        if ((plotData['plotNumber']
                                                                        as String? ??
                                                                    '') ==
                                                                plotNumber &&
                                                            (plotData['layout']
                                                                        as String? ??
                                                                    '') ==
                                                                layoutName) {
                                                          plotData['status'] =
                                                              statusOption;
                                                          print(
                                                              '📝 STATUS CHANGE: Updated _allPlots entry');
                                                          break;
                                                        }
                                                      }

                                                      // Then update the corresponding plot in _layouts (same as table update) - this ensures all copies are updated
                                                      for (var layout
                                                          in _layouts) {
                                                        if ((layout['name']
                                                                    as String? ??
                                                                '') ==
                                                            layoutName) {
                                                          final plots = layout[
                                                                      'plots']
                                                                  as List<
                                                                      dynamic>? ??
                                                              [];
                                                          for (var plotData
                                                              in plots) {
                                                            if (plotData is Map<
                                                                String,
                                                                dynamic>) {
                                                              final pn = plotData[
                                                                          'plotNumber']
                                                                      as String? ??
                                                                  '';
                                                              if (pn ==
                                                                  plotNumber) {
                                                                plotData[
                                                                        'status'] =
                                                                    statusOption;
                                                                break;
                                                              }
                                                            }
                                                          }
                                                          break;
                                                        }
                                                      }

                                                      _isStatusDropdownOpen =
                                                          false;
                                                      print(
                                                          '📝 STATUS CHANGE: Calling sync functions');
                                                      _syncEditingPlotToAllPlots();
                                                      _rebuildAllPlotsFromLayouts();
                                                      print(
                                                          '📝 STATUS CHANGE: setState complete');
                                                    });
                                                  },
                                                  child: Container(
                                                    width: double.infinity,
                                                    height: 40,
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 8),
                                                    child: Container(
                                                      width: 152,
                                                      height: 32,
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 8),
                                                      decoration: BoxDecoration(
                                                        color:
                                                            _getStatusDropdownChipBackgroundColor(
                                                                statusOption),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(8),
                                                        boxShadow: [
                                                          BoxShadow(
                                                            color: Colors.black
                                                                .withOpacity(
                                                                    0.25),
                                                            blurRadius: 2,
                                                            offset:
                                                                const Offset(
                                                                    0, 0),
                                                            spreadRadius: 0,
                                                          ),
                                                        ],
                                                      ),
                                                      child: Row(
                                                        children: [
                                                          Container(
                                                            width: 16,
                                                            height: 16,
                                                            decoration:
                                                                BoxDecoration(
                                                              color:
                                                                  optionColor,
                                                              shape: BoxShape
                                                                  .circle,
                                                              border:
                                                                  Border.all(
                                                                color: Colors
                                                                    .white,
                                                                width: 1,
                                                              ),
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                              width: 8),
                                                          Text(
                                                            optionText,
                                                            style: GoogleFonts
                                                                .inter(
                                                              fontSize: 14,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .normal,
                                                              color:
                                                                  Colors.black,
                                                              height: 1.2,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              if (!isLastOption)
                                                const SizedBox(height: 8),
                                            ],
                                          );
                                        }),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Additional sale fields (always visible). For non-sold/non-pending, show blurred/disabled preview.
                    const SizedBox(height: 24),
                    IgnorePointer(
                      ignoring: !isSoldLikeStatus,
                      child: Opacity(
                        opacity: isSoldLikeStatus ? 1.0 : 0.2,
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(
                            sigmaX: isSoldLikeStatus ? 0 : 1.2,
                            sigmaY: isSoldLikeStatus ? 0 : 1.2,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Sale date field
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          'Sale date ',
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.black,
                                          ),
                                        ),
                                        Text(
                                          '*',
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.red,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    _buildSaleDateField(),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),
                              // Agent field
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          'Agent ',
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.black,
                                          ),
                                        ),
                                        Text(
                                          '*',
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.red,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    _buildAgentField(),
                                    if (_isAgentDropdownOpen) ...[
                                      const SizedBox(height: 4),
                                      _buildAgentDropdownInDialog(
                                        (_layouts[_editingLayoutIndex!]['plots']
                                                        [_editingPlotIndex!]
                                                    as Map<String, dynamic>)[
                                                'agent'] as String? ??
                                            '',
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),
                              // Sale Price and Sale Value side by side
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Text(
                                                'Sale Price (₹/$_areaUnitSuffix) ',
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w500,
                                                  color: Colors.black,
                                                ),
                                              ),
                                              Text(
                                                '*',
                                                style: GoogleFonts.inter(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w500,
                                                  color: Colors.red,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          _buildSalePriceField(),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 24),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Sale Value (₹)',
                                            style: GoogleFonts.inter(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                              color: Colors.black,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          _buildSaleValueField(),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),
                              // Buyer Name field
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          'Buyer Name ',
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.black,
                                          ),
                                        ),
                                        Text(
                                          '*',
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.red,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    _buildBuyerNameField(),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),
                              // Buyer Contact Number field
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Buyer Contact Number',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    _buildBuyerContactNumberField(),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),
                              // Payment section
                              Padding(
                                key: _paymentMethodFieldKey,
                                padding:
                                    const EdgeInsets.only(left: 16, right: 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          'Payment ',
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.black,
                                          ),
                                        ),
                                        Text(
                                          '*',
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.red,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Builder(
                                      builder: (context) {
                                        final plot =
                                            _layouts[_editingLayoutIndex!]
                                                        ['plots']
                                                    [_editingPlotIndex!]
                                                as Map<String, dynamic>;
                                        final payments = plot['payments']
                                                as List<dynamic>? ??
                                            [];
                                        final area = double.tryParse(
                                                (plot['area'] as String? ?? '0')
                                                    .replaceAll(',', '')) ??
                                            0.0;
                                        final salePriceStr =
                                            (plot['salePrice'] as String? ??
                                                    '0')
                                                .replaceAll(',', '')
                                                .replaceAll('₹', '')
                                                .replaceAll(' ', '')
                                                .trim();
                                        final salePrice =
                                            double.tryParse(salePriceStr) ??
                                                0.0;
                                        final saleValue = area * salePrice;

                                        double totalAmount = 0.0;
                                        for (final payment in payments) {
                                          final paymentMap =
                                              payment as Map<String, dynamic>;
                                          final amountStr =
                                              (paymentMap['paymentAmount'] ??
                                                      '0')
                                                  .toString();
                                          final cleaned = amountStr
                                              .replaceAll(',', '')
                                              .replaceAll('₹', '')
                                              .replaceAll(' ', '')
                                              .trim();
                                          totalAmount +=
                                              double.tryParse(cleaned) ?? 0.0;
                                        }

                                        final remainingAmount =
                                            saleValue - totalAmount;
                                        const epsilon = 0.01;
                                        final totalExceeds =
                                            totalAmount > saleValue + epsilon;
                                        final totalIsZero =
                                            totalAmount.abs() <= epsilon;
                                        final remainingIsNegative =
                                            remainingAmount < -epsilon;
                                        final remainingIsZero =
                                            remainingAmount.abs() <= epsilon;
                                        final hasPaymentMethod = payments.any(
                                          (payment) {
                                            final paymentMap =
                                                payment as Map<String, dynamic>;
                                            final method =
                                                (paymentMap['paymentMethod'] ??
                                                        '')
                                                    .toString()
                                                    .trim();
                                            return method.isNotEmpty;
                                          },
                                        );
                                        final totalText = totalExceeds
                                            ? 'Total Amount: ₹ ${_formatAmount(totalAmount.toStringAsFixed(2))} [Exceeding Sale Value]'
                                            : 'Total Amount: ₹ ${_formatAmount(totalAmount.toStringAsFixed(2))}';
                                        final totalColor =
                                            (totalExceeds || totalIsZero)
                                                ? Colors.red
                                                : const Color(0xFF1A8F3E);

                                        late final String remainingText;
                                        late final Color remainingColor;
                                        if (remainingIsNegative) {
                                          remainingText =
                                              'Remaining Amount: - ₹ ${_formatAmount(remainingAmount.abs().toStringAsFixed(2))} [Exceeding Sale Value]';
                                          remainingColor = Colors.red;
                                        } else if (remainingIsZero) {
                                          remainingText =
                                              'Remaining Amount: ₹ ${_formatAmount(remainingAmount.toStringAsFixed(2))}';
                                          remainingColor =
                                              const Color(0xFF1A8F3E);
                                        } else {
                                          final remainingLabel =
                                              hasPaymentMethod
                                                  ? 'Pending Amount'
                                                  : 'Remaining Amount';
                                          remainingText =
                                              '$remainingLabel: ₹ ${_formatAmount(remainingAmount.toStringAsFixed(2))}';
                                          remainingColor =
                                              const Color(0xFFFFA200);
                                        }

                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              totalText,
                                              style: GoogleFonts.inter(
                                                fontSize: 14,
                                                fontWeight: FontWeight.normal,
                                                color: totalColor,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            _buildPaymentMethodContent(),
                                            const SizedBox(height: 16),
                                            Text(
                                              remainingText,
                                              style: GoogleFonts.inter(
                                                fontSize: 14,
                                                fontWeight: FontWeight.normal,
                                                color: remainingColor,
                                              ),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                                    const SizedBox(height: 8),
                                    GestureDetector(
                                      onTap: () {
                                        final plot =
                                            _layouts[_editingLayoutIndex!]
                                                        ['plots']
                                                    [_editingPlotIndex!]
                                                as Map<String, dynamic>;
                                        if (plot['payments'] == null) {
                                          plot['payments'] = [];
                                        }
                                        final payments =
                                            plot['payments'] as List<dynamic>;
                                        payments.add({
                                          'paymentMethod': '',
                                          'paymentAmount': '0',
                                          'chequeDate': '',
                                          'chequeNumber': '',
                                          'transferDate': '',
                                          'transactionId': '',
                                          'paymentDate': '',
                                          'upiTransactionId': '',
                                          'upiApp': '',
                                          'ddDate': '',
                                          'ddNumber': '',
                                          'otherPaymentDate': '',
                                          'otherPaymentMethod': '',
                                          'referenceNumber': '',
                                          'bankName': '',
                                        });
                                        setState(() {
                                          _syncEditingPlotToAllPlots();
                                        });
                                        _saveLayoutsData();
                                      },
                                      child: Builder(
                                        builder: (context) {
                                          final plot =
                                              _layouts[_editingLayoutIndex!]
                                                          ['plots']
                                                      [_editingPlotIndex!]
                                                  as Map<String, dynamic>;
                                          final payments = plot['payments']
                                                  as List<dynamic>? ??
                                              [];
                                          final hasPaymentMethod = payments
                                                  .isNotEmpty &&
                                              payments.any((p) =>
                                                  (p as Map<String, dynamic>)[
                                                          'paymentMethod']
                                                      ?.toString()
                                                      .isNotEmpty ??
                                                  false);

                                          return Container(
                                            height: 36,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 16, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: hasPaymentMethod
                                                  ? const Color(0xFF0C8CE9)
                                                  : const Color(0xFF0C8CE9)
                                                      .withOpacity(0.5),
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
                                                  'Add Payment Method',
                                                  style: GoogleFonts.inter(
                                                    fontSize: 14,
                                                    fontWeight:
                                                        FontWeight.normal,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Icon(
                                                  Icons.add,
                                                  size: 12,
                                                  color: Colors.white,
                                                ),
                                              ],
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
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

  Widget _buildLayoutsLoadingSkeleton() {
    return Column(
      children: [
        for (int i = 0; i < 2; i++) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 24),
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
                _skeletonBlock(width: 140, height: 20),
                const SizedBox(height: 16),
                // Table header
                Row(
                  children: [
                    _skeletonBlock(width: 80, height: 14),
                    const SizedBox(width: 24),
                    _skeletonBlock(width: 100, height: 14),
                    const SizedBox(width: 24),
                    _skeletonBlock(width: 100, height: 14),
                    const SizedBox(width: 24),
                    _skeletonBlock(width: 80, height: 14),
                    const SizedBox(width: 24),
                    _skeletonBlock(width: 100, height: 14),
                  ],
                ),
                const SizedBox(height: 12),
                // Table rows
                for (int j = 0; j < 3; j++) ...[
                  Row(
                    children: [
                      _skeletonBlock(width: 80, height: 36),
                      const SizedBox(width: 24),
                      _skeletonBlock(width: 100, height: 36),
                      const SizedBox(width: 24),
                      _skeletonBlock(width: 100, height: 36),
                      const SizedBox(width: 24),
                      _skeletonBlock(width: 80, height: 36),
                      const SizedBox(width: 24),
                      _skeletonBlock(width: 100, height: 36),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPlotStatusLoadingSkeleton() {
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
            spreadRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Table header
          Row(
            children: [
              Expanded(child: _skeletonBlock(width: 60, height: 14)),
              Expanded(child: _skeletonBlock(width: 80, height: 14)),
              Expanded(child: _skeletonBlock(width: 100, height: 14)),
              Expanded(child: _skeletonBlock(width: 80, height: 14)),
              Expanded(child: _skeletonBlock(width: 80, height: 14)),
              Expanded(child: _skeletonBlock(width: 100, height: 14)),
            ],
          ),
          const SizedBox(height: 12),
          // Table rows
          for (int i = 0; i < 5; i++) ...[
            Row(
              children: [
                Expanded(child: _skeletonBlock(width: 60, height: 36)),
                Expanded(child: _skeletonBlock(width: 80, height: 36)),
                Expanded(child: _skeletonBlock(width: 100, height: 36)),
                Expanded(child: _skeletonBlock(width: 80, height: 36)),
                Expanded(child: _skeletonBlock(width: 80, height: 36)),
                Expanded(child: _skeletonBlock(width: 100, height: 36)),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildPlotStatusTable() {
    final filteredPlots = _filteredPlots;

    if (_isLoading && filteredPlots.isEmpty) {
      return _buildPlotStatusLoadingSkeleton();
    }

    if (filteredPlots.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 64,
              color: Colors.black.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'No plots found',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add plots in the Site tab to view their status here',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black.withOpacity(0.4),
              ),
            ),
          ],
        ),
      );
    }

    return Scrollbar(
      controller: _plotStatusTableScrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _plotStatusTableScrollController,
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Sl. No. column
            _buildColumn(
              header: 'Sl. No.',
              width: 70,
              isFirst: true,
              children: List.generate(filteredPlots.length, (index) {
                return _buildCell(
                  width: 70,
                  content: Text(
                    '${index + 1}',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      fontStyle: FontStyle.normal,
                      color: Colors.black, // #000
                      height: 1.0, // normal line-height
                    ),
                  ),
                  isLast: index == filteredPlots.length - 1,
                );
              }),
            ),
            // Layout column
            _buildColumn(
              header: 'Layout',
              width: 186,
              children: List.generate(filteredPlots.length, (index) {
                final layout = filteredPlots[index]['layout'] as String? ?? '';
                return _buildCell(
                  width: 186,
                  content: Text(
                    layout.isEmpty ? '-' : layout,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  isLast: index == filteredPlots.length - 1,
                );
              }),
            ),
            // Plot Number column
            _buildColumn(
              header: 'Plot Number',
              width: 215,
              children: List.generate(filteredPlots.length, (index) {
                final plotNumber =
                    filteredPlots[index]['plotNumber'] as String? ?? '';
                return _buildCell(
                  width: 215,
                  content: Text(
                    plotNumber.isEmpty ? '-' : plotNumber,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  isLast: index == filteredPlots.length - 1,
                );
              }),
            ),
            // Area column
            _buildColumn(
              header: 'Area ($_areaUnitSuffix)',
              width: 180,
              children: List.generate(filteredPlots.length, (index) {
                final area = filteredPlots[index]['area'] as String? ?? '0.00';
                return _buildCell(
                  width: 180,
                  content: Text(
                    _formatAreaValue(area),
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  isLast: index == filteredPlots.length - 1,
                );
              }),
            ),
            // Purchase Rate column
            _buildColumn(
              header: 'Purchase Rate',
              width: 215,
              children: List.generate(filteredPlots.length, (index) {
                final rate =
                    filteredPlots[index]['purchaseRate'] as String? ?? '0.00';
                return _buildCell(
                  width: 215,
                  content: Text(
                    rate.isEmpty || rate == '0.00'
                        ? '-'
                        : '₹ ${_formatAmount(rate)}',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  isLast: index == filteredPlots.length - 1,
                );
              }),
            ),
            // Status column
            _buildColumn(
              header: 'Status',
              width: 320,
              isLast: true,
              children: List.generate(filteredPlots.length, (index) {
                final status = _parsePlotStatus(filteredPlots[index]['status']);
                final statusColor = _getStatusColor(status);
                final statusText = _getStatusString(status);
                final statusBackgroundColor = _getStatusBackgroundColor(status);
                return _buildCell(
                  width: 320,
                  content: Builder(
                    builder: (builderContext) {
                      final statusKey = GlobalKey();
                      final iconKey = GlobalKey();

                      // Read-only status display - no editing in table
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
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
                              decoration: BoxDecoration(
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
                              statusText,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.normal,
                                fontStyle: FontStyle.normal,
                                color: Colors.black, // #000
                                height: 1.0, // normal line-height
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  isLast: index == filteredPlots.length - 1,
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildColumn({
    required String header,
    required double width,
    required List<Widget> children,
    bool isFirst = false,
    bool isLast = false,
  }) {
    return Column(
      children: [
        // Header
        Container(
          width: width,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF707070).withOpacity(0.2),
            border: Border.all(color: Colors.black, width: 1.0),
            borderRadius: isFirst
                ? const BorderRadius.only(topLeft: Radius.circular(8))
                : isLast
                    ? const BorderRadius.only(topRight: Radius.circular(8))
                    : null,
          ),
          child: Center(
            child: Text(
              header,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.black,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        // Rows
        ...children,
      ],
    );
  }

  Widget _buildCell({
    required double width,
    required Widget content,
    bool isLast = false,
  }) {
    return Container(
      width: width,
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          right: const BorderSide(color: Colors.black, width: 1.0),
          bottom: BorderSide(
            color: Colors.black,
            width: isLast ? 1.0 : 1.0,
          ),
          top: BorderSide.none,
          left: BorderSide.none,
        ),
        borderRadius: isLast
            ? const BorderRadius.only(bottomRight: Radius.circular(8))
            : null,
      ),
      child: Center(child: content),
    );
  }

  Widget _buildTopOverallSalesAndSiteStatusCards() {
    double totalAreaSold = 0.0;
    double totalSaleValue = 0.0;
    double totalPendingAmount = 0.0;
    int totalPlots = 0;
    int availablePlots = 0;
    int soldPlots = 0;
    int pendingPlots = 0;
    if (_activeContentTab == PlotStatusContentTab.amenityArea) {
      for (final areaData in _amenityAreas) {
        totalPlots++;
        final status = _parsePlotStatus(areaData['status']);

        if (status == PlotStatus.available) {
          availablePlots++;
        } else if (status == PlotStatus.sold) {
          soldPlots++;
        } else if (status == PlotStatus.reserved) {
          pendingPlots++;
        }

        if (_isSoldLikeStatus(status)) {
          final areaSqft = _parseMoneyLikeValue(areaData['area']);
          final salePrice = _parseMoneyLikeValue(areaData['salePrice']);
          final explicitSaleValue = _parseMoneyLikeValue(areaData['saleValue']);
          final saleValue = explicitSaleValue > 0
              ? explicitSaleValue
              : (areaSqft * salePrice);
          final paidAmount = _parseMoneyLikeValue(areaData['payment']);

          totalAreaSold += areaSqft;
          totalSaleValue += saleValue;

          final pendingAmount = saleValue - paidAmount;
          if (pendingAmount > 0) {
            totalPendingAmount += pendingAmount;
          }
        }
      }
    } else {
      for (final layout in _layouts) {
        final plots = layout['plots'] as List<dynamic>? ?? const [];
        for (final plotData in plots) {
          if (plotData is! Map<String, dynamic>) continue;
          final plot = plotData;
          totalPlots++;

          final status = _parsePlotStatus(plot['status']);
          if (status == PlotStatus.available) {
            availablePlots++;
          } else if (status == PlotStatus.sold) {
            soldPlots++;
          } else if (status == PlotStatus.reserved) {
            pendingPlots++;
          }

          if (_isSoldLikeStatus(status)) {
            final area = double.tryParse(
                    (plot['area'] as String? ?? '0.00').replaceAll(',', '')) ??
                0.0;
            final salePriceStr = (plot['salePrice'] as String? ?? '0.00')
                .replaceAll(',', '')
                .replaceAll('₹', '')
                .replaceAll(' ', '')
                .trim();
            final salePrice = double.tryParse(salePriceStr) ?? 0.0;
            final saleValue = salePrice * area;

            totalAreaSold += area;
            totalSaleValue += saleValue;

            final payments = plot['payments'] as List<dynamic>? ?? const [];
            double paidAmount = 0.0;
            for (final payment in payments) {
              final paymentMap = payment as Map<String, dynamic>;
              final amountStr = (paymentMap['paymentAmount'] ?? '0').toString();
              final cleaned = amountStr
                  .replaceAll(',', '')
                  .replaceAll('₹', '')
                  .replaceAll(' ', '')
                  .trim();
              paidAmount += double.tryParse(cleaned) ?? 0.0;
            }

            final pendingAmount = saleValue - paidAmount;
            if (pendingAmount > 0) {
              totalPendingAmount += pendingAmount;
            }
          }
        }
      }
    }

    final double avgSalePriceSqft =
        totalAreaSold > 0 ? (totalSaleValue / totalAreaSold) : 0.0;
    final avgSalePriceDisplay =
        AreaUnitUtils.rateFromSqftToDisplay(avgSalePriceSqft, _isSqm);
    final statusCardTitle =
        _activeContentTab == PlotStatusContentTab.amenityArea
            ? 'Amenity Area Status'
            : 'Site Status';
    final totalLabel = _activeContentTab == PlotStatusContentTab.amenityArea
        ? 'Total Amenity Areas:'
        : 'Total Plots:';
    final showPendingUi = pendingPlots > 0;

    Widget buildStatusDot(Color dotColor) {
      return Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: dotColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 1,
              offset: const Offset(0, 0),
            ),
          ],
        ),
      );
    }

    if (!showPendingUi) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: 1142,
          child: Container(
            width: 1142,
            height: 144,
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
                  'Overall Sales',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF5C5C5C),
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 281,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: 36,
                            child: Row(
                              children: [
                                Text(
                                  'Total Sale Value:',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black,
                                    height: 1.0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '₹',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                    color: const Color(0xFF5C5C5C),
                                    height: 1.0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _formatAmountNoTrailingZeros(
                                        totalSaleValue.toString()),
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                      color: Colors.black.withOpacity(0.75),
                                      height: 1.0,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 36,
                            child: Row(
                              children: [
                                Text(
                                  'Total Area Sold:',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black,
                                    height: 1.0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          _formatAmountNoTrailingZeros(
                                            AreaUnitUtils.areaFromSqftToDisplay(
                                                    totalAreaSold, _isSqm)
                                                .toString(),
                                          ),
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w400,
                                            color: Colors.black,
                                            height: 1.0,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _areaUnitSuffix,
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w400,
                                          color: const Color(0xFF5C5C5C),
                                          height: 1.0,
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
                    const SizedBox(width: 24),
                    SizedBox(
                      width: 301,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: 36,
                            child: Row(
                              children: [
                                Text(
                                  'Avg Sale Price:',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black,
                                    height: 1.0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '₹/$_areaUnitSuffix',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                    color: const Color(0xFF5C5C5C),
                                    height: 1.0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _formatAmountNoTrailingZeros(
                                        avgSalePriceDisplay.toString()),
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                      color: Colors.black.withOpacity(0.75),
                                      height: 1.0,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 36,
                            child: Row(
                              children: [
                                Text(
                                  totalLabel,
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black,
                                    height: 1.0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _formatIntegerWithIndianNumbering(
                                        totalPlots.toString()),
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                      color: const Color(0xFF323232),
                                      height: 1.0,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: 36,
                            child: Row(
                              children: [
                                buildStatusDot(const Color(0xFF53D10C)),
                                const SizedBox(width: 8),
                                Text(
                                  'Available:',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black,
                                    height: 1.0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _formatIntegerWithIndianNumbering(
                                        availablePlots.toString()),
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                      color: const Color(0xFF323232),
                                      height: 1.0,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 36,
                            child: Row(
                              children: [
                                buildStatusDot(const Color(0xFFFF0000)),
                                const SizedBox(width: 8),
                                Text(
                                  'Sold:',
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.black,
                                    height: 1.0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _formatIntegerWithIndianNumbering(
                                        soldPlots.toString()),
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                      color: const Color(0xFF323232),
                                      height: 1.0,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
              ],
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 1142,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 638,
              height: 144,
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
                    'Overall Sales',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF5C5C5C),
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 281,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 36,
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      'Total Sale Value:',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black,
                                        height: 1.0,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Text(
                                          '₹',
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w400,
                                            color: const Color(0xFF5C5C5C),
                                            height: 1.0,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _formatAmountNoTrailingZeros(
                                                totalSaleValue.toString()),
                                            style: GoogleFonts.inter(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w400,
                                              color: Colors.black
                                                  .withOpacity(0.75),
                                              height: 1.0,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 36,
                              child: Row(
                                children: [
                                  Text(
                                    'Total Area Sold:',
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.black,
                                      height: 1.0,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            _formatAmountNoTrailingZeros(
                                              AreaUnitUtils
                                                      .areaFromSqftToDisplay(
                                                          totalAreaSold, _isSqm)
                                                  .toString(),
                                            ),
                                            style: GoogleFonts.inter(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w400,
                                              color: Colors.black,
                                              height: 1.0,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          _areaUnitSuffix,
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w400,
                                            color: const Color(0xFF5C5C5C),
                                            height: 1.0,
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
                      const SizedBox(width: 24),
                      SizedBox(
                        width: 301,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 36,
                              child: Row(
                                children: [
                                  Text(
                                    'Avg Sale Price:',
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.black,
                                      height: 1.0,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      '₹/$_areaUnitSuffix',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w400,
                                        color: const Color(0xFF5C5C5C),
                                        height: 1.0,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _formatAmountNoTrailingZeros(
                                          avgSalePriceDisplay.toString()),
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w400,
                                        color: Colors.black.withOpacity(0.75),
                                        height: 1.0,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (showPendingUi) ...[
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 36,
                                child: Row(
                                  children: [
                                    Text(
                                      'Pending Amount:',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black,
                                        height: 1.0,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '₹',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w400,
                                        color: const Color(0xFF5C5C5C),
                                        height: 1.0,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _formatAmountNoTrailingZeros(
                                            totalPendingAmount.toString()),
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w400,
                                          color: Colors.black.withOpacity(0.75),
                                          height: 1.0,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Container(
              width: 480,
              height: 144,
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
                    statusCardTitle,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFF5C5C5C),
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 448,
                    height: 80,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 156,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                height: 36,
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 106,
                                      child: Row(
                                        children: [
                                          buildStatusDot(
                                              const Color(0xFF0C8CE9)),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              totalLabel,
                                              style: GoogleFonts.inter(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w500,
                                                color: Colors.black,
                                                height: 1.0,
                                              ),
                                              maxLines: 1,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      constraints:
                                          const BoxConstraints(minHeight: 36),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4),
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        _formatIntegerWithIndianNumbering(
                                            totalPlots.toString()),
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w400,
                                          color: const Color(0xFF323232),
                                          height: 1.0,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 36,
                                child: Row(
                                  children: [
                                    buildStatusDot(const Color(0xFF53D10C)),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Available:',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black,
                                        height: 1.0,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _formatIntegerWithIndianNumbering(
                                          availablePlots.toString()),
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w400,
                                        color: const Color(0xFF323232),
                                        height: 1.0,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 212,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                height: 36,
                                child: Row(
                                  children: [
                                    buildStatusDot(const Color(0xFFFF0000)),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Sold:',
                                      style: GoogleFonts.inter(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black,
                                        height: 1.0,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _formatIntegerWithIndianNumbering(
                                            soldPlots.toString()),
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w400,
                                          color: const Color(0xFF323232),
                                          height: 1.0,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (showPendingUi) ...[
                                const SizedBox(height: 8),
                                SizedBox(
                                  height: 36,
                                  child: Row(
                                    children: [
                                      buildStatusDot(const Color(0xFFFEB12A)),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Pending:',
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w500,
                                          color: Colors.black,
                                          height: 1.0,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _formatIntegerWithIndianNumbering(
                                              pendingPlots.toString()),
                                          style: GoogleFonts.inter(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w400,
                                            color: const Color(0xFF323232),
                                            height: 1.0,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
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

  Widget _buildLayoutCard(int layoutIndex, Map<String, dynamic> layout) {
    final plots = layout['plots'] as List<Map<String, dynamic>>? ?? [];
    final layoutName = layout['name'] as String? ?? 'Layout ${layoutIndex + 1}';

    // Apply filter to get counts for display
    List<Map<String, dynamic>> filteredPlots = plots;
    if (_selectedStatus != 'All Status') {
      filteredPlots = plots.where((plot) {
        final plotStatus = _parsePlotStatus(plot['status']);
        final statusString = _getStatusString(plotStatus);
        return statusString == _selectedStatus;
      }).toList();
    }

    // Calculate totals and counts
    double totalAreaSold = 0.0;
    double totalSaleValue = 0.0; // Sum of sale value column (₹)
    double totalPendingAmount = 0.0;
    int availablePlots = 0;
    int soldPlots = 0;
    int pendingPlots = 0;

    for (var plot in filteredPlots) {
      final status = _parsePlotStatus(plot['status']);
      if (status == PlotStatus.available) {
        availablePlots++;
      } else if (status == PlotStatus.sold) {
        soldPlots++;
      } else if (status == PlotStatus.reserved) {
        pendingPlots++;
      }

      if (_isSoldLikeStatus(status)) {
        final area = double.tryParse(
                (plot['area'] as String? ?? '0.00').replaceAll(',', '')) ??
            0.0;
        final salePriceStr = (plot['salePrice'] as String? ?? '0.00')
            .replaceAll(',', '')
            .replaceAll('₹', '')
            .replaceAll(' ', '')
            .trim();
        final salePrice = double.tryParse(salePriceStr) ?? 0.0;
        final saleValue = salePrice * area;

        totalAreaSold += area;
        totalSaleValue += saleValue;

        final payments = plot['payments'] as List<dynamic>? ?? [];
        double paidAmount = 0.0;
        for (final payment in payments) {
          final paymentMap = payment as Map<String, dynamic>;
          final amountStr = (paymentMap['paymentAmount'] ?? '0').toString();
          final cleaned = amountStr
              .replaceAll(',', '')
              .replaceAll('₹', '')
              .replaceAll(' ', '')
              .trim();
          paidAmount += double.tryParse(cleaned) ?? 0.0;
        }

        final pendingAmount = saleValue - paidAmount;
        if (pendingAmount > 0) {
          totalPendingAmount += pendingAmount;
        }
      }
    }

    // Helper widget for separator dot
    Widget separatorDot = Container(
      width: 4,
      height: 4,
      decoration: const BoxDecoration(
        color: Colors.black,
        shape: BoxShape.circle,
      ),
    );

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
            spreadRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Layout header
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '${layoutIndex + 1}.',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 16),
              Text(
                'Layout:',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                  height: 1.0,
                ),
              ),
              const SizedBox(width: 26),
              Container(
                width: 304,
                height: 36,
                constraints: const BoxConstraints(minHeight: 36),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  layoutName,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                    height: 1.0,
                  ),
                  textAlign: TextAlign.left,
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      final isCollapsed =
                          _collapsedLayouts.contains(layoutIndex);
                      if (isCollapsed) {
                        _collapsedLayouts.remove(layoutIndex);
                      } else {
                        _collapsedLayouts.add(layoutIndex);
                      }
                    });
                  },
                  child: SvgPicture.asset(
                    _collapsedLayouts.contains(layoutIndex)
                        ? 'assets/images/Indi_expand.svg'
                        : 'assets/images/Indi_collapse.svg',
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
            ],
          ),
          const SizedBox(height: 16),
          // Summary line 1 (Figma node 2954:7050)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text(
                  '${plots.length} plots',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(width: 16),
                separatorDot,
                const SizedBox(width: 16),
                Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Color(0xFF53D10C),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$availablePlots Available',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                separatorDot,
                const SizedBox(width: 16),
                Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF0000),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$soldPlots Sold',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                separatorDot,
                const SizedBox(width: 16),
                Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFEB12A),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$pendingPlots Pending',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Summary line 2 (Figma node 2954:7700)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Row(
                  children: [
                    Text(
                      'Total Area Sold:',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatAmountNoTrailingZeros(
                        AreaUnitUtils.areaFromSqftToDisplay(
                                totalAreaSold, _isSqm)
                            .toString(),
                      ),
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black.withOpacity(0.75),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _areaUnitSuffix,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                separatorDot,
                const SizedBox(width: 16),
                Row(
                  children: [
                    Text(
                      'Total Sale Value:',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '₹',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatAmountNoTrailingZeros(totalSaleValue.toString()),
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black.withOpacity(0.75),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                separatorDot,
                const SizedBox(width: 16),
                Row(
                  children: [
                    Text(
                      'Total Pending Amount:',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '₹',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatAmountNoTrailingZeros(
                          totalPendingAmount.toString()),
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black.withOpacity(0.75),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Table - only show if layout is not collapsed
          if (!_collapsedLayouts.contains(layoutIndex))
            Builder(
              builder: (context) {
                // Initialize scroll controller for this layout if it doesn't exist
                if (!_layoutTableScrollControllers.containsKey(layoutIndex)) {
                  _layoutTableScrollControllers[layoutIndex] =
                      ScrollController();
                }
                final scrollController =
                    _layoutTableScrollControllers[layoutIndex]!;

                // Calculate dynamic height based on number of plots
                // Header row: 48px, each plot row: 48px
                double baseHeaderHeight = 48.0;
                double baseRowHeight = 48.0;
                double calculatedHeight =
                    baseHeaderHeight + (plots.length * baseRowHeight);
                // Store base height (same as when zoom = 1.0)
                final baseHeight = calculatedHeight;
                // Calculate scaled height for outer container
                // Only scale up, never scale down to prevent overflow when zooming out
                double scaledHeight = _tableZoomLevel >= 1.0
                    ? calculatedHeight * _tableZoomLevel
                    : calculatedHeight;
                // Only apply minimum height if calculated height is very small (less than header + 1 row)
                final minHeight =
                    (baseHeaderHeight + baseRowHeight) * _tableZoomLevel;
                if (scaledHeight < minHeight) {
                  scaledHeight = minHeight;
                }
                // Add buffer for scaled border to prevent clipping
                final borderBuffer = _tableZoomLevel > 1.0 ? 10.0 : 0.0;
                scaledHeight = scaledHeight + borderBuffer;

                return SizedBox(
                  width: double.infinity,
                  height: scaledHeight,
                  child: Scrollbar(
                    controller: scrollController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: scrollController,
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      clipBehavior: Clip.hardEdge,
                      child: Padding(
                        padding: EdgeInsets.only(
                          left:
                              ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0),
                          right: ((_tableZoomLevel - 1.0) * 10.0)
                                  .clamp(0.0, 10.0) +
                              ((_tableZoomLevel - 1.0) * 1350.0).clamp(0.0,
                                  1350.0), // Extra right padding when zoomed to allow full scrolling to last column
                          top:
                              ((_tableZoomLevel - 1.0) * 10.0).clamp(0.0, 10.0),
                          bottom: ((_tableZoomLevel - 1.0) * 10.0)
                                  .clamp(0.0, 10.0) +
                              ((_tableZoomLevel - 1.0) * 100.0).clamp(0.0,
                                  100.0), // Extra bottom padding for scaled borders to prevent clipping
                        ),
                        child: Transform.scale(
                          scale: _tableZoomLevel,
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            height:
                                baseHeight, // Use base height (same as when zoom = 1.0), Transform.scale will handle scaling
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: _buildLayoutTable(layoutIndex, plots),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildAmenityAreaCard() {
    final filteredAreas = _filteredAmenityAreas;
    int availableCount = 0;
    int soldCount = 0;
    int pendingCount = 0;
    double totalAreaSoldSqft = 0.0;
    double totalSaleValue = 0.0;

    for (final area in filteredAreas) {
      final status = _parsePlotStatus(area['status']);
      if (status == PlotStatus.available) {
        availableCount++;
      } else if (status == PlotStatus.sold) {
        soldCount++;
      } else if (status == PlotStatus.reserved) {
        pendingCount++;
      }

      if (_isSoldLikeStatus(status)) {
        final areaSqft = _parseMoneyLikeValue(area['area']);
        final salePrice = _parseMoneyLikeValue(area['salePrice']);
        totalAreaSoldSqft += areaSqft;
        totalSaleValue += areaSqft * salePrice;
      }
    }

    Widget separatorDot = Container(
      width: 4,
      height: 4,
      decoration: const BoxDecoration(
        color: Colors.black,
        shape: BoxShape.circle,
      ),
    );

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
            spreadRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Amenity Area',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _isAmenityAreaCollapsed = !_isAmenityAreaCollapsed;
                    });
                  },
                  child: SvgPicture.asset(
                    _isAmenityAreaCollapsed
                        ? 'assets/images/Indi_expand.svg'
                        : 'assets/images/Indi_collapse.svg',
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
            ],
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Text(
                  '${filteredAreas.length} ${filteredAreas.length == 1 ? 'Amenity Area' : 'Amenity Areas'}',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(width: 16),
                separatorDot,
                const SizedBox(width: 16),
                Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Color(0xFF53D10C),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$availableCount Available',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                separatorDot,
                const SizedBox(width: 16),
                Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF0000),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$soldCount Sold',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                separatorDot,
                const SizedBox(width: 16),
                Row(
                  children: [
                    Text(
                      'Total Area Sold:',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatAreaNoTrailingZeros(
                        AreaUnitUtils.areaFromSqftToDisplay(
                                totalAreaSoldSqft, _isSqm)
                            .toString(),
                      ),
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black.withOpacity(0.75),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _areaUnitSuffix,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 16),
                separatorDot,
                const SizedBox(width: 16),
                Row(
                  children: [
                    Text(
                      'Total Sale Value:',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '₹',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatAmountNoTrailingZeros(totalSaleValue.toString()),
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        color: Colors.black.withOpacity(0.75),
                      ),
                    ),
                  ],
                ),
                if (pendingCount > 0) ...[
                  const SizedBox(width: 16),
                  separatorDot,
                  const SizedBox(width: 16),
                  Row(
                    children: [
                      Container(
                        width: 16,
                        height: 16,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFEB12A),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$pendingCount Pending',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.normal,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (!_isAmenityAreaCollapsed) ...[
            const SizedBox(height: 16),
            Builder(
              builder: (context) {
                final int visibleRows =
                    filteredAreas.isEmpty ? 1 : filteredAreas.length;
                const double baseHeaderHeight = 48.0;
                const double baseRowHeight = 48.0;
                double baseHeight =
                    baseHeaderHeight + (visibleRows * baseRowHeight);
                double scaledHeight = _tableZoomLevel >= 1.0
                    ? baseHeight * _tableZoomLevel
                    : baseHeight;
                final minHeight =
                    (baseHeaderHeight + baseRowHeight) * _tableZoomLevel;
                if (scaledHeight < minHeight) {
                  scaledHeight = minHeight;
                }
                final borderBuffer = _tableZoomLevel > 1.0 ? 10.0 : 0.0;
                scaledHeight = scaledHeight + borderBuffer;

                return Container(
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
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: scaledHeight,
                    child: Scrollbar(
                      controller: _amenityAreaTableScrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _amenityAreaTableScrollController,
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        clipBehavior: Clip.hardEdge,
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: ((_tableZoomLevel - 1.0) * 10.0)
                                .clamp(0.0, 10.0),
                            right: ((_tableZoomLevel - 1.0) * 10.0)
                                    .clamp(0.0, 10.0) +
                                ((_tableZoomLevel - 1.0) * 1350.0)
                                    .clamp(0.0, 1350.0),
                            top: ((_tableZoomLevel - 1.0) * 10.0)
                                .clamp(0.0, 10.0),
                            bottom: ((_tableZoomLevel - 1.0) * 10.0)
                                    .clamp(0.0, 10.0) +
                                ((_tableZoomLevel - 1.0) * 100.0)
                                    .clamp(0.0, 100.0),
                          ),
                          child: Transform.scale(
                            scale: _tableZoomLevel,
                            alignment: Alignment.topLeft,
                            child: SizedBox(
                              height: baseHeight,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: _buildAmenityAreaTable(filteredAreas),
                              ),
                            ),
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
    );
  }

  Widget _buildAmenityAreaTable(List<Map<String, dynamic>> areas) {
    if (areas.isEmpty) {
      return const SizedBox.shrink();
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 42,
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF707070).withOpacity(0.2),
                border: Border(
                  left: const BorderSide(color: Colors.black, width: 1.0),
                  top: const BorderSide(color: Colors.black, width: 1.0),
                  bottom: const BorderSide(color: Colors.black, width: 1.0),
                  right: BorderSide.none,
                ),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                ),
              ),
              child: Center(
                child: Text(
                  'Edit',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
            ...List.generate(areas.length, (index) {
              final isLast = index == areas.length - 1;
              final area = areas[index];
              return Container(
                width: 42,
                height: 48,
                decoration: BoxDecoration(
                  border: Border(
                    left: const BorderSide(color: Colors.black, width: 1.0),
                    bottom: const BorderSide(color: Colors.black, width: 1.0),
                    top: BorderSide.none,
                    right: BorderSide.none,
                  ),
                  borderRadius: isLast
                      ? const BorderRadius.only(
                          bottomLeft: Radius.circular(8),
                        )
                      : null,
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapDown: (_) => _handleAmenityEditIconTap(area, index),
                  child: Center(
                    child: SvgPicture.asset(
                      'assets/images/Eddit.svg',
                      width: 16,
                      height: 15,
                      colorFilter: const ColorFilter.mode(
                        Color(0xFF0C8CE9),
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
        Column(
          children: [
            Container(
              width: 60,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF707070).withOpacity(0.2),
                border: Border.all(color: Colors.black, width: 1.0),
              ),
              child: Center(
                child: Text(
                  'Sl. No.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
            ...List.generate(areas.length, (index) {
              return Container(
                width: 60,
                height: 48,
                decoration: BoxDecoration(
                  border: Border(
                    left: const BorderSide(color: Colors.black, width: 1.0),
                    right: const BorderSide(color: Colors.black, width: 1.0),
                    bottom: const BorderSide(color: Colors.black, width: 1.0),
                    top: BorderSide.none,
                  ),
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
        _buildTableColumn(
          header: 'Amenity Plot *',
          width: 266,
          plots: areas,
          builder: (area, index) {
            final amenityName = (area['name'] ?? '').toString().trim();
            return Container(
              width: 250,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.95),
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
              alignment: Alignment.centerLeft,
              child: Text(
                amenityName.isEmpty ? '-' : amenityName,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            );
          },
        ),
        _buildTableColumn(
          header: 'Area ($_areaUnitSuffix)',
          width: 215,
          plots: areas,
          builder: (area, index) {
            final areaSqft = _parseMoneyLikeValue(area['area']);
            final areaDisplay =
                AreaUnitUtils.areaFromSqftToDisplay(areaSqft, _isSqm);
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatAreaNoTrailingZeros(areaDisplay.toString()),
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _areaUnitSuffix,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.normal,
                    color: const Color(0xFF5C5C5C),
                  ),
                ),
              ],
            );
          },
        ),
        _buildTableColumn(
          header: 'Status *',
          width: 145,
          plots: areas,
          builder: (area, index) {
            final status = _parsePlotStatus(area['status']);
            final statusText = _getStatusString(status);
            final statusBackgroundColor = _getStatusBackgroundColor(status);
            final statusColor = _getStatusColor(status);
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                    statusText,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        _buildTableColumn(
          header: 'Sale Price (₹/$_areaUnitSuffix) *',
          width: 209,
          plots: areas,
          builder: (area, index) {
            final salePrice = _parseMoneyLikeValue(area['salePrice']);
            if (salePrice <= 0) {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              );
            }
            return Text(
              '₹ ${_formatAmount(salePrice.toStringAsFixed(2))}',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            );
          },
        ),
        _buildTableColumn(
          header: 'Sale Value (₹)',
          width: 178,
          plots: areas,
          builder: (area, index) {
            final saleValue =
                _parseMoneyLikeValue(area['saleValue']).toStringAsFixed(2);
            if (_parseMoneyLikeValue(saleValue) <= 0) {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: const Color(0xFF5C5C5C),
                ),
              );
            }
            return Text(
              '₹ ${_formatAmount(saleValue)}',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
            );
          },
        ),
        _buildTableColumn(
          header: 'Buyer / Organization Name *',
          width: 320,
          plots: areas,
          builder: (area, index) {
            final buyerName = (area['buyerName'] ?? '').toString().trim();
            return Text(
              buyerName.isEmpty ? '-' : buyerName,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color:
                    buyerName.isEmpty ? const Color(0xFF5C5C5C) : Colors.black,
              ),
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        _buildTableColumn(
          header: 'Payment *',
          width: 339,
          plots: areas,
          builder: (area, index) {
            final payment = (area['payment'] ?? '').toString().trim();
            return Text(
              payment.isEmpty ? '-' : payment,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: payment.isEmpty ? const Color(0xFF5C5C5C) : Colors.black,
              ),
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        _buildTableColumn(
          header: 'Agent *',
          width: 265,
          plots: areas,
          builder: (area, index) {
            final agent = (area['agent'] ?? '').toString().trim();
            return Text(
              agent.isEmpty ? '-' : agent,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: agent.isEmpty ? const Color(0xFF5C5C5C) : Colors.black,
              ),
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        _buildTableColumn(
          header: 'Sale date *',
          width: 167,
          isLast: true,
          plots: areas,
          builder: (area, index) {
            final saleDate = (area['saleDate'] ?? '').toString().trim();
            return Text(
              saleDate.isEmpty ? '-' : saleDate,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color:
                    saleDate.isEmpty ? const Color(0xFF5C5C5C) : Colors.black,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildLayoutTable(int layoutIndex, List<Map<String, dynamic>> plots) {
    // Apply filter based on selected status
    List<Map<String, dynamic>> filteredPlots = plots;
    if (_selectedStatus != 'All Status') {
      filteredPlots = plots.where((plot) {
        final plotStatus = _parsePlotStatus(plot['status']);
        final statusString = _getStatusString(plotStatus);
        return statusString == _selectedStatus;
      }).toList();
    }

    if (filteredPlots.isEmpty) {
      return const SizedBox.shrink();
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Edit column
        Column(
          children: [
            Container(
              width: 60,
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF707070).withOpacity(0.2),
                border: Border(
                  left: const BorderSide(color: Colors.black, width: 1.0),
                  top: const BorderSide(color: Colors.black, width: 1.0),
                  bottom: const BorderSide(color: Colors.black, width: 1.0),
                  right: BorderSide.none,
                ),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                ),
              ),
              child: Center(
                child: Text(
                  'Edit',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    fontStyle: FontStyle.normal,
                    color: Colors.black,
                    height: 1.0,
                  ),
                ),
              ),
            ),
            ...List.generate(filteredPlots.length, (index) {
              final isLast = index == filteredPlots.length - 1;
              final rowPlot = filteredPlots[index];
              final hasRowError = _rowHasRequiredSoldFieldError(rowPlot);
              final rowStatus = _parsePlotStatus(rowPlot['status']);

              // For pending rows, also show red when required sold-like fields
              // are still missing (same intent as sold validation).
              final pendingHasMissingRequired = rowStatus == PlotStatus.reserved
                  ? () {
                      final salePrice = (rowPlot['salePrice'] as String? ?? '')
                          .replaceAll(',', '')
                          .replaceAll('₹', '')
                          .replaceAll(' ', '')
                          .trim();
                      final buyerName =
                          (rowPlot['buyerName'] as String? ?? '').trim();
                      final agent = (rowPlot['agent'] as String? ?? '').trim();
                      final saleDate =
                          (rowPlot['saleDate'] as String? ?? '').trim();
                      final payments =
                          rowPlot['payments'] as List<dynamic>? ?? [];
                      final hasPaymentMethod = payments.any((p) {
                        final m = p as Map<String, dynamic>;
                        return (m['paymentMethod'] as String? ?? '')
                            .trim()
                            .isNotEmpty;
                      });
                      final salePriceMissing = salePrice.isEmpty ||
                          salePrice == '0' ||
                          salePrice == '0.00';
                      return salePriceMissing ||
                          buyerName.isEmpty ||
                          agent.isEmpty ||
                          saleDate.isEmpty ||
                          !hasPaymentMethod;
                    }()
                  : false;

              final editIconColor = (hasRowError || pendingHasMissingRequired)
                  ? Colors.red
                  : (rowStatus == PlotStatus.reserved
                      ? const Color(0xFFFFB12A)
                      : const Color(0xFF0C8CE9));
              return Container(
                width: 60,
                height: 48,
                decoration: BoxDecoration(
                  border: Border(
                    left: const BorderSide(color: Colors.black, width: 1.0),
                    bottom: const BorderSide(color: Colors.black, width: 1.0),
                    top: BorderSide.none,
                    right: BorderSide.none,
                  ),
                  borderRadius: isLast
                      ? const BorderRadius.only(
                          bottomLeft: Radius.circular(8),
                        )
                      : null,
                ),
                child: GestureDetector(
                  onTap: () {
                    final originalIndex = plots.indexOf(rowPlot);
                    if (originalIndex < 0) return;
                    _openSiteEditDialog(layoutIndex, originalIndex);
                  },
                  child: Center(
                    child: SvgPicture.asset(
                      'assets/images/Eddit.svg',
                      width: 16,
                      height: 15,
                      colorFilter: ColorFilter.mode(
                        editIconColor,
                        BlendMode.srcIn,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
        // Sl. No. column
        Column(
          children: [
            Container(
              width: 60,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFF707070).withOpacity(0.2),
                border: Border.all(color: Colors.black, width: 1.0),
              ),
              child: Center(
                child: Text(
                  'Sl. No.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    fontStyle: FontStyle.normal,
                    color: Colors.black, // #000
                    height: 1.0, // normal line-height
                  ),
                ),
              ),
            ),
            ...List.generate(filteredPlots.length, (index) {
              return Container(
                width: 60,
                height: 48,
                decoration: BoxDecoration(
                  border: Border(
                    left: const BorderSide(color: Colors.black, width: 1.0),
                    right: const BorderSide(color: Colors.black, width: 1.0),
                    bottom: const BorderSide(color: Colors.black, width: 1.0),
                    top: BorderSide.none,
                  ),
                ),
                child: Center(
                  child: Text(
                    '${index + 1}',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      fontStyle: FontStyle.normal,
                      color: Colors.black, // #000
                      height: 1.0, // normal line-height
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
        // Plot Number column
        _buildTableColumn(
          header: 'Plot Number',
          width: 186,
          plots: filteredPlots,
          builder: (plot, index) => Text(
            (plot['plotNumber'] as String? ?? '').isEmpty
                ? '-'
                : (plot['plotNumber'] as String? ?? ''),
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.normal,
              color: Colors.black,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        // Area column
        _buildTableColumn(
          header: 'Area ($_areaUnitSuffix)',
          width: 215,
          plots: filteredPlots,
          builder: (plot, index) {
            final areaSqft = double.tryParse(
                    (plot['area'] as String? ?? '0.00').replaceAll(',', '')) ??
                0.0;
            final areaDisplay =
                AreaUnitUtils.areaFromSqftToDisplay(areaSqft, _isSqm);
            return Text(
              '$_areaUnitSuffix ${_formatAreaValue(areaDisplay.toString())}',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.black,
              ),
              textAlign: TextAlign.center,
            );
          },
        ),
        // Status * column
        _buildTableColumn(
          header: 'Status *',
          width: 180,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            final statusColor = _getStatusColor(status);
            final statusBackgroundColor = _getStatusBackgroundColor(status);
            final statusText = _getStatusString(status);
            final statusKey = GlobalKey();
            final iconKey = GlobalKey();

            // Read-only status display - no editing in table
            return Container(
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
                    decoration: BoxDecoration(
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
                    statusText,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      fontStyle: FontStyle.normal,
                      color: Colors.black, // #000
                      height: 1.0, // normal line-height
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        // Sale Price (₹/sqft) * column
        _buildTableColumn(
          header: 'Sale Price (₹/$_areaUnitSuffix) *',
          width: 215,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            if (_isSoldLikeStatus(status)) {
              final salePriceRaw = (plot['salePrice'] as String? ?? '')
                  .replaceAll(',', '')
                  .replaceAll('₹', '')
                  .replaceAll(' ', '')
                  .trim();
              final salePriceEmpty = salePriceRaw.isEmpty ||
                  salePriceRaw == '0' ||
                  salePriceRaw == '0.00';
              final salePriceValue = double.tryParse(salePriceRaw) ?? 0.0;
              final displayPrice =
                  _formatAmount(salePriceValue.toStringAsFixed(2));
              return Container(
                width: 200,
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: [
                    BoxShadow(
                      color: salePriceEmpty
                          ? Colors.red
                          : Colors.black.withOpacity(0.15),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                      spreadRadius: 0,
                    ),
                  ],
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  '₹ $displayPrice',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color:
                        salePriceEmpty ? const Color(0xFFC1C1C1) : Colors.black,
                  ),
                ),
              );
            } else {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              );
            }
          },
        ),
        // Sale Value (₹) column
        _buildTableColumn(
          header: 'Sale Value (₹)',
          width: 215,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            if (_isSoldLikeStatus(status)) {
              // Calculate sale value = sale price * area
              final salePriceStr = plot['salePrice'] as String? ?? '0.00';
              final areaStr = plot['area'] as String? ?? '0.00';

              // Parse values (remove commas and format)
              final salePrice = double.tryParse(salePriceStr
                      .replaceAll(',', '')
                      .replaceAll('₹', '')
                      .replaceAll(' ', '')
                      .trim()) ??
                  0.0;
              final area = double.tryParse(
                      areaStr.replaceAll(',', '').replaceAll(' ', '').trim()) ??
                  0.0;

              final saleValue = salePrice * area;
              final formattedValue = saleValue > 0
                  ? _formatAmount(saleValue.toStringAsFixed(2))
                  : '0.00';

              return Container(
                width: 200,
                height: 32,
                child: Center(
                  child: Text(
                    '₹ $formattedValue',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.normal,
                      color: Colors.black,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            } else {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              );
            }
          },
        ),
        // Buyer Name * column
        _buildTableColumn(
          header: 'Buyer Name *',
          width: 320,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            if (_isSoldLikeStatus(status)) {
              final currentBuyer = (plot['buyerName'] as String? ?? '').trim();
              final buyerNameEmpty = currentBuyer.isEmpty;
              return Container(
                width: 300,
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: [
                    BoxShadow(
                      color: buyerNameEmpty
                          ? Colors.red
                          : Colors.black.withOpacity(0.15),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                      spreadRadius: 0,
                    ),
                  ],
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  buyerNameEmpty ? "Enter buyer's name" : currentBuyer,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color:
                        buyerNameEmpty ? const Color(0xFFC1C1C1) : Colors.black,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              );
            } else {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              );
            }
          },
        ),
        // Buyer Contact Number column
        _buildTableColumn(
          header: 'Buyer Contact Number',
          width: 280,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            if (_isSoldLikeStatus(status)) {
              final rawBuyerContact =
                  (plot['buyerContactNumber'] as String? ?? '').trim();
              final normalizedBuyerContact =
                  rawBuyerContact.replaceFirst(RegExp(r'^\+91\s*'), '');
              final buyerContactEmpty = normalizedBuyerContact.isEmpty;

              return Container(
                width: 260,
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: [
                    BoxShadow(
                      color: buyerContactEmpty
                          ? Colors.red
                          : Colors.black.withOpacity(0.15),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                      spreadRadius: 0,
                    ),
                  ],
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  buyerContactEmpty
                      ? 'Enter buyer contact number'
                      : '+91 $normalizedBuyerContact',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: buyerContactEmpty
                        ? const Color(0xFFC1C1C1)
                        : Colors.black,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              );
            } else {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              );
            }
          },
        ),
        // Payment * column
        _buildTableColumn(
          header: 'Payment * ',
          width: 340,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            if (_isSoldLikeStatus(status)) {
              // Extract payment methods from payments array
              final payments = plot['payments'] as List<dynamic>? ?? [];
              final paymentMethods = <String>[];

              for (final payment in payments) {
                final paymentMap = payment as Map<String, dynamic>;
                final method = paymentMap['paymentMethod'] as String? ?? '';
                if (method.isNotEmpty && !paymentMethods.contains(method)) {
                  paymentMethods.add(method);
                }
              }

              final isEmpty = paymentMethods.isEmpty;
              final paymentText =
                  isEmpty ? 'Select Payment Method' : paymentMethods.join(', ');

              return Container(
                width: 320,
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: [
                    BoxShadow(
                      color:
                          isEmpty ? Colors.red : Colors.black.withOpacity(0.15),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                      spreadRadius: 0,
                    ),
                  ],
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  paymentText,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: isEmpty ? const Color(0xFFC1C1C1) : Colors.black,
                  ),
                  textAlign: TextAlign.left,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              );
            } else {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              );
            }
          },
        ),
        // Agent * column
        _buildTableColumn(
          header: 'Agent *',
          width: 241,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            final currentAgent = plot['agent'] as String? ?? '';
            if (_isSoldLikeStatus(status)) {
              final agentEmpty = currentAgent.trim().isEmpty;
              return Container(
                width: 220,
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: [
                    BoxShadow(
                      color: agentEmpty
                          ? Colors.red
                          : Colors.black.withOpacity(0.15),
                      blurRadius: 2,
                      offset: const Offset(0, 0),
                      spreadRadius: 0,
                    ),
                  ],
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  agentEmpty ? 'Select Agent' : currentAgent,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: agentEmpty ? const Color(0xFFC1C1C1) : Colors.black,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              );
            } else {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              );
            }
          },
        ),
        // Sale date * column
        _buildTableColumn(
          header: 'Sale date *',
          width: 220,
          isLast: true,
          plots: filteredPlots,
          builder: (plot, index) {
            final status = _parsePlotStatus(plot['status']);
            if (_isSoldLikeStatus(status)) {
              final currentSaleDate =
                  (plot['saleDate'] as String? ?? '').trim();
              final saleDateEmpty = currentSaleDate.isEmpty;
              return Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Container(
                        width: 180,
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: [
                            BoxShadow(
                              color: saleDateEmpty
                                  ? Colors.red
                                  : Colors.black.withOpacity(0.15),
                              blurRadius: 2,
                              offset: const Offset(0, 0),
                              spreadRadius: 0,
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.calendar_today,
                              size: 16,
                              color: Colors.black.withOpacity(0.6),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                saleDateEmpty ? 'dd/mm/yyyy' : currentSaleDate,
                                textAlign: TextAlign.center,
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.normal,
                                  color: saleDateEmpty
                                      ? const Color(0xFFC1C1C1)
                                      : Colors.black,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            } else {
              return Text(
                '-',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                  color: Colors.black,
                ),
                textAlign: TextAlign.center,
              );
            }
          },
        ),
      ],
    );
  }

  Widget _buildTableColumn({
    required String header,
    required double width,
    required List<Map<String, dynamic>> plots,
    required Widget Function(Map<String, dynamic> plot, int index) builder,
    bool isLast = false,
  }) {
    return Column(
      children: [
        Container(
          width: width,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF707070).withOpacity(0.2),
            border: const Border(
              top: BorderSide(color: Colors.black, width: 1.0),
              right: BorderSide(color: Colors.black, width: 1.0),
              bottom: BorderSide(color: Colors.black, width: 1.0),
              left: BorderSide.none,
            ),
            borderRadius: isLast
                ? const BorderRadius.only(
                    topRight: Radius.circular(8),
                  )
                : null,
          ),
          child: Center(
            child: RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                children: [
                  TextSpan(
                    text: header.replaceAll(' *', ''),
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.black,
                    ),
                  ),
                  if (header.contains('*'))
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
        ),
        ...List.generate(plots.length, (index) {
          final isLastRow = index == plots.length - 1;
          return Container(
            width: width,
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(
                right: const BorderSide(color: Colors.black, width: 1.0),
                bottom: const BorderSide(color: Colors.black, width: 1.0),
                top: BorderSide.none,
                left: BorderSide.none,
              ),
              borderRadius: isLast && isLastRow
                  ? const BorderRadius.only(
                      bottomRight: Radius.circular(8),
                    )
                  : null,
            ),
            child: Center(child: builder(plots[index], index)),
          );
        }),
      ],
    );
  }

  void _showStatusChangeDialog(BuildContext context, int layoutIndex,
      int plotIndex, PlotStatus currentStatus, GlobalKey statusKey) {
    final RenderBox? renderBox =
        statusKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final offset = renderBox.localToGlobal(Offset.zero);

    OverlayEntry? backdropEntry;
    OverlayEntry? overlayEntry;

    void closeDropdown() {
      overlayEntry?.remove();
      backdropEntry?.remove();
    }

    backdropEntry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: GestureDetector(
          onTap: closeDropdown,
          child: Container(color: Colors.transparent),
        ),
      ),
    );

    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx - 50,
        top: offset.dy + renderBox.size.height - 40,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: renderBox.size.width + 100,
            constraints: const BoxConstraints(maxHeight: 400),
            decoration: BoxDecoration(
              color: Colors.white,
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
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header section
                  Container(
                    padding: const EdgeInsets.only(
                        top: 4, left: 8, right: 8, bottom: 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Select Plot Status',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.normal,
                              color: Colors.black,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        Transform.rotate(
                          angle: 180 * 3.14159 / 180, // Rotate 180 degrees
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            size: 20,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Options section
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Status options - Only show Available and Sold (matching Figma)
                        ...([PlotStatus.available, PlotStatus.sold]
                            .map((status) {
                          final statusColor = _getStatusColor(status);
                          final statusText = _getStatusString(status);
                          final backgroundColor =
                              _getStatusBackgroundColor(status);

                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                _layouts[layoutIndex]['plots'][plotIndex]
                                    ['status'] = status;
                              });
                              _saveLayoutsData();
                              _savePlotsToDatabase(); // Save to database
                              closeDropdown();
                            },
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: backgroundColor,
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
                                    decoration: BoxDecoration(
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
                                    statusText,
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inter(
                                      fontSize: 16,
                                      fontWeight: FontWeight.normal,
                                      fontStyle: FontStyle.normal,
                                      color: Colors.black, // #000
                                      height: 1.0, // normal line-height
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        })),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(backdropEntry);
    overlay.insert(overlayEntry);
  }

  void _showStatusChangeDialogForFiltered(BuildContext context, int index,
      PlotStatus currentStatus, GlobalKey statusKey) {
    if (index >= _filteredPlots.length) return;

    final RenderBox? renderBox =
        statusKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context);
    final offset = renderBox.localToGlobal(Offset.zero);

    OverlayEntry? backdropEntry;
    OverlayEntry? overlayEntry;

    void closeDropdown() {
      overlayEntry?.remove();
      backdropEntry?.remove();
    }

    backdropEntry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: GestureDetector(
          onTap: closeDropdown,
          child: Container(color: Colors.transparent),
        ),
      ),
    );

    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx - 50,
        top: offset.dy + renderBox.size.height - 40,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: renderBox.size.width + 100,
            constraints: const BoxConstraints(maxHeight: 400),
            decoration: BoxDecoration(
              color: Colors.white,
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
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header section
                  Container(
                    padding: const EdgeInsets.only(
                        top: 4, left: 8, right: 8, bottom: 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Select Plot Status',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.normal,
                              color: Colors.black,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        Transform.rotate(
                          angle: 180 * 3.14159 / 180, // Rotate 180 degrees
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            size: 20,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Options section
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Status options - Only show Available and Sold (matching Figma)
                        ...([PlotStatus.available, PlotStatus.sold]
                            .map((status) {
                          final statusColor = _getStatusColor(status);
                          final statusText = _getStatusString(status);
                          final backgroundColor =
                              _getStatusBackgroundColor(status);

                          return GestureDetector(
                            onTap: () async {
                              final filteredPlot = _filteredPlots[index];
                              final actualIndex = _allPlots.indexWhere((p) =>
                                  p['plotNumber'] ==
                                      filteredPlot['plotNumber'] &&
                                  p['layout'] == filteredPlot['layout']);
                              if (actualIndex >= 0) {
                                _updatePlotStatus(actualIndex, status);
                              }
                              closeDropdown();
                            },
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: backgroundColor,
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
                                mainAxisSize: status == PlotStatus.sold
                                    ? MainAxisSize.min
                                    : MainAxisSize.max,
                                children: [
                                  Container(
                                    width: 16,
                                    height: 16,
                                    decoration: BoxDecoration(
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
                                    statusText,
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inter(
                                      fontSize: 16,
                                      fontWeight: FontWeight.normal,
                                      fontStyle: FontStyle.normal,
                                      color: Colors.black, // #000
                                      height: 1.0, // normal line-height
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        })),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(backdropEntry);
    overlay.insert(overlayEntry);
  }

  void _showAgentDropdown(BuildContext context, int layoutIndex, int plotIndex,
      String currentAgent, GlobalKey cellKey) {
    final RenderBox? renderBox =
        cellKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final agents = _availableAgents;
    final overlay = Overlay.of(context);
    final offset = renderBox.localToGlobal(Offset.zero);

    OverlayEntry? backdropEntry;
    OverlayEntry? overlayEntry;

    void closeDropdown() {
      setState(() {
        _isAgentDropdownOpen = false;
      });
      overlayEntry?.remove();
      backdropEntry?.remove();
    }

    backdropEntry = OverlayEntry(
      builder: (context) => Positioned.fill(
        child: GestureDetector(
          onTap: closeDropdown,
          child: Container(color: Colors.transparent),
        ),
      ),
    );

    overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx,
        top: offset.dy + renderBox.size.height + 4,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: renderBox.size.width,
            constraints: const BoxConstraints(maxHeight: 300),
            decoration: BoxDecoration(
              color: Colors.white,
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                GestureDetector(
                  onTap: closeDropdown,
                  child: Container(
                    height: 48,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            'Select Agent',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.black,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: closeDropdown,
                          child: Transform.rotate(
                            angle: 3.14159,
                            child: SvgPicture.asset(
                              'assets/images/Drrrop_down.svg',
                              width: 14,
                              height: 7,
                              fit: BoxFit.contain,
                              placeholderBuilder: (context) => const SizedBox(
                                width: 14,
                                height: 7,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Options section
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...agents.asMap().entries.map((entry) {
                        final agentIndex = entry.key;
                        final agent = entry.value;
                        final isLast = agentIndex == agents.length - 1;
                        final isDirectSale = agent == 'Direct Sale';
                        final isSelected = agent == currentAgent;

                        return GestureDetector(
                          onTap: () {
                            setState(() {
                              _layouts[layoutIndex]['plots'][plotIndex]
                                  ['agent'] = agent;
                              _isAgentDropdownOpen = false;
                            });
                            _saveLayoutsData();
                            _savePlotsToDatabase();
                            closeDropdown();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            margin: EdgeInsets.only(
                                left: 8, right: 8, bottom: isLast ? 0 : 8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: Colors.black.withOpacity(0.1),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    agent,
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: isDirectSale
                                          ? const Color(0xFF0C8CE9)
                                          : Colors.black,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    setState(() {
      _isAgentDropdownOpen = true;
    });
    overlay.insert(backdropEntry);
    overlay.insert(overlayEntry);
  }

  Future<void> _selectSaleDate(
      int layoutIndex, int plotIndex, String key) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF0C8CE9),
              onPrimary: Colors.white,
              onSurface: Colors.black,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      final formattedDate =
          '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
      setState(() {
        _layouts[layoutIndex]['plots'][plotIndex]['saleDate'] = formattedDate;
        _saleDateControllers[key]?.text = formattedDate;
      });
      _saveLayoutsData();
    }
  }
}

// Focus-aware input container widget that dynamically changes shadow based on focus state
class _FocusAwareInputContainer extends StatefulWidget {
  final FocusNode focusNode;
  final Widget child;
  final VoidCallback? onFocusLost;
  final double width;
  final double height;
  final Color backgroundColor;
  final double borderRadius;
  final bool hasError;

  const _FocusAwareInputContainer({
    required this.focusNode,
    required this.child,
    this.onFocusLost,
    this.width = double.infinity,
    this.height = 40,
    this.backgroundColor = const Color(0xFFF8F9FA),
    this.borderRadius = 8,
    this.hasError = false,
  });

  @override
  State<_FocusAwareInputContainer> createState() =>
      _FocusAwareInputContainerState();
}

class _FocusAwareInputContainerState extends State<_FocusAwareInputContainer> {
  late VoidCallback _focusListener;
  bool _hadFocus = false;

  @override
  void initState() {
    super.initState();
    _hadFocus = widget.focusNode.hasFocus;
    _focusListener = () {
      // Call onFocusLost when focus changes from true to false
      if (_hadFocus &&
          !widget.focusNode.hasFocus &&
          widget.onFocusLost != null) {
        widget.onFocusLost!();
      }
      _hadFocus = widget.focusNode.hasFocus;
      setState(() {});
    };
    widget.focusNode.addListener(_focusListener);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        boxShadow: [
          BoxShadow(
            color: widget.focusNode.hasFocus
                ? const Color(
                    0xFF0C8CE9) // Match Project Details focus behavior
                : (widget.hasError
                    ? Colors.red
                    : Colors.black.withOpacity(0.15)),
            blurRadius: 2,
            offset: const Offset(0, 0),
            spreadRadius: 0,
          ),
        ],
      ),
      child: widget.child,
    );
  }
}
